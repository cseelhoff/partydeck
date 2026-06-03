"""mitmproxy addon for the Ravenswatch capture.

Loaded by ``mitmdump -s mitm_addon.py`` (see res/capture_mitm.sh). Responsibilities:

1. **Decrypted-HTTP logging** in the exact JSONL schema ``src/pcap2csv.py`` merges
   (epoch ``t`` + ``client_port`` are the join keys).
2. **Dynamic upstream selection**: the game's DNS is poisoned so every target host
   resolves to 127.0.0.1 (us). We re-resolve the *real* upstream IP via a clean
   resolver (``MITM_REAL_DNS`` env, falling back to ``MITM_HOSTMAP`` static
   ``host=ip`` pairs) and retarget the flow there while keeping Host + SNI =
   original hostname, so upstream TLS still validates.
3. **TLS-failure bypass**: if the client/library refuses our forged cert (pinning,
   unknown CA, etc.), the connection is added to an ignore set and tunneled as
   raw bytes (mitmproxy "ignore_connection") instead of erroring — the game keeps
   working; that flow just isn't decoded. A ``tls_error`` record is logged so the
   merge can still show the encrypted attempt.

Env vars (set by capture_mitm.sh):
    MITM_LOG       output JSONL path (default ./mitm_http.jsonl)
    MITM_REAL_DNS  real resolver IP for upstream lookups (bypasses poisoned DNS)
    MITM_HOSTMAP   "host1=ip1,host2=ip2" static upstream overrides
    MITM_REAL_PORT upstream port (default 443)
"""
import base64, json, os, socket, struct, threading, time

from mitmproxy import ctx, http, tls


def _real_dns_query(host, dns_ip):
    """Resolve an A record by querying a real DNS directly (bypasses resolv.conf)."""
    try:
        tid = os.getpid() & 0xFFFF
        q = struct.pack(">HHHHHH", tid, 0x0100, 1, 0, 0, 0)
        for label in host.split("."):
            q += bytes([len(label)]) + label.encode()
        q += b"\x00" + struct.pack(">HH", 1, 1)
        s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        s.settimeout(3)
        s.sendto(q, (dns_ip, 53))
        data, _ = s.recvfrom(2048)
        s.close()
        ancount = struct.unpack(">H", data[6:8])[0]
        i = 12
        while data[i] != 0:
            if data[i] & 0xC0 == 0xC0:
                i += 2
                break
            i += 1 + data[i]
        else:
            i += 1
        i += 4
        for _ in range(ancount):
            if data[i] & 0xC0 == 0xC0:
                i += 2
            else:
                while data[i] != 0:
                    i += 1 + data[i]
                i += 1
            atype, _cls, _ttl, rdl = struct.unpack(">HHIH", data[i:i + 10])
            i += 10
            if atype == 1 and rdl == 4:
                return ".".join(map(str, data[i:i + 4]))
            i += rdl
    except Exception:
        return None
    return None


class CaptureAddon:
    def __init__(self):
        self.logpath = os.environ.get("MITM_LOG", "mitm_http.jsonl")
        self.real_dns = os.environ.get("MITM_REAL_DNS", "").strip()
        self.real_port = int(os.environ.get("MITM_REAL_PORT", "443"))
        # Offline override: force EVERY flow to one upstream "ip:port" (the local
        # server.py), bypassing all host-header parsing / DNS. Set by
        # capture_mitm.sh MODE=offline so traffic can never leak to the real
        # backend even if a Host header doesn't match the hostmap.
        self.force_upstream = None
        fu = os.environ.get("MITM_FORCE_UPSTREAM", "").strip()
        if fu:
            fip, _, fport = fu.partition(":")
            self.force_upstream = (fip, int(fport) if fport else self.real_port)
        # Forward-proxy (regular mode) selective redirect: only the hosts listed
        # in MITM_LOCAL_HOSTS are retargeted to the local backend (server.py);
        # every OTHER host is forwarded to its real destination, which mitmproxy
        # resolves itself from the CONNECT host. This is the Burp/Fiddler model:
        # the game is configured to use us as its HTTPS proxy, we decrypt all of
        # it, and only the emulated Stormancer hosts are pointed at server.py.
        self.local_backend = None
        lb = os.environ.get("MITM_LOCAL_BACKEND", "").strip()
        if lb:
            lip, _, lport = lb.partition(":")
            self.local_backend = (lip, int(lport) if lport else self.real_port)
        self.local_hosts = {h.strip() for h in
                            os.environ.get("MITM_LOCAL_HOSTS", "").split(",") if h.strip()}
        # In offline forward-proxy mode the game frequently connects to a loopback
        # IP literal (a stale Stormancer scene endpoint, e.g. 127.1.33.7) instead
        # of the hostname. When MITM_LOCAL_LOOPBACK is set, treat ANY 127.0.0.0/8
        # destination as the emulated backend and redirect it to local_backend.
        self.local_loopback = os.environ.get("MITM_LOCAL_LOOPBACK", "").strip() in ("1", "true", "yes")
        # Legacy reverse-online behavior: re-resolve the real upstream IP for
        # every flow (needed only when DNS was poisoned). In forward mode this is
        # OFF — mitmproxy connects to the real host on its own.
        self.retarget_real = os.environ.get("MITM_RETARGET_REAL", "").strip() in ("1", "true", "yes")
        self.hostmap = {}
        for pair in os.environ.get("MITM_HOSTMAP", "").split(","):
            if "=" in pair:
                h, ip = pair.split("=", 1)
                self.hostmap[h.strip()] = ip.strip()
        self._cache = dict(self.hostmap)
        self._ignore = set()        # hosts to TLS-passthrough after a failure
        self._lock = threading.Lock()
        self._fp = open(self.logpath, "a", buffering=1)

    # -- helpers ---------------------------------------------------------
    def _emit(self, rec):
        line = json.dumps(rec, separators=(",", ":")) + "\n"
        with self._lock:
            self._fp.write(line)
            self._fp.flush()

    @staticmethod
    def _is_loopback(h):
        return bool(h) and (h == "localhost" or h.startswith("127."))

    def _resolve_real(self, host):
        if not host:
            return None
        # already an IP?
        try:
            socket.inet_aton(host)
            return host
        except OSError:
            pass
        with self._lock:
            if host in self._cache:
                return self._cache[host]
        ip = _real_dns_query(host, self.real_dns) if self.real_dns else None
        if not ip:
            try:
                ip = socket.gethostbyname(host)   # last resort (maybe poisoned)
            except OSError:
                ip = None
        if ip:
            with self._lock:
                self._cache[host] = ip
        return ip

    # -- mitmproxy hooks -------------------------------------------------
    def load(self, loader):
        ctx.log.info(f"[capture-addon] log={self.logpath} real_dns={self.real_dns or '(system)'} "
                     f"hostmap={self.hostmap or '{}'} local_backend={self.local_backend} "
                     f"local_hosts={self.local_hosts or '{}'} local_loopback={self.local_loopback}")

    def tls_clienthello(self, data: tls.ClientHelloData):
        """If a previous handshake to this host failed, tunnel raw bytes through."""
        sni = data.client_hello.sni
        if sni and sni in self._ignore:
            data.ignore_connection = True

    def tls_failed_client(self, data):
        """Client rejected our forged cert -> remember host, passthrough next time."""
        try:
            sni = data.conn.sni if hasattr(data, "conn") else None
        except Exception:
            sni = None
        peer = getattr(data.context.client, "peername", (None, None))
        self._ignore.add(sni) if sni else None
        self._emit({"t": time.time(), "kind": "tls_error",
                    "client_ip": peer[0], "client_port": peer[1],
                    "sni": sni, "error": "client rejected MITM cert (passthrough enabled)"})

    def request(self, flow: http.HTTPFlow):
        """Retarget the connection to the real upstream IP, keeping Host + SNI.

        The game's DNS is poisoned so the hostname would resolve back to us; we
        override only the server *address* (not request.host) so SNI and the Host
        header stay the real hostname and upstream TLS validates normally."""
        host = flow.request.host_header or flow.request.pretty_host or flow.request.host
        if host and ":" in host:
            host = host.split(":")[0]
        # The CONNECT target the client asked for (set before we override it).
        # For an HTTPS tunnel this is the host/IP from the CONNECT line, which is
        # the reliable signal when the game uses a loopback IP literal.
        conn_host = None
        try:
            if flow.server_conn.address:
                conn_host = flow.server_conn.address[0]
        except Exception:
            conn_host = None
        # The TLS SNI the client sent (real hostname even when CONNECT used an IP).
        sni = getattr(flow.client_conn, "sni", None)
        if self.force_upstream:
            # Legacy reverse/offline: pin everything to the local server.py.
            try:
                flow.server_conn.address = self.force_upstream
                flow.server_conn.sni = host
            except Exception as e:
                ctx.log.warn(f"[capture-addon] force-upstream failed for {host}: {e!r}")
            return
        if self.local_backend and (
                host in self.local_hosts or sni in self.local_hosts
                or (self.local_loopback and (self._is_loopback(host) or self._is_loopback(conn_host)))):
            # Forward proxy: the emulated Stormancer endpoints (hostname or a
            # loopback IP) go to server.py; everything else is left for mitmproxy
            # to reach at its real address. For a CONNECT tunnel the upstream is
            # pinned at CONNECT time, so overriding flow.server_conn.address in the
            # request hook is too late — rewrite the request target (host/port)
            # instead, which mitmproxy honors for the (lazy) upstream connection.
            orig = sni or host or conn_host
            try:
                if orig:
                    flow.request.host_header = orig    # preserve real Host for server.py + logging
                flow.request.host = self.local_backend[0]
                flow.request.port = self.local_backend[1]
                flow.server_conn.sni = orig if (orig and not self._is_loopback(orig)) else \
                    (next(iter(self.local_hosts), None) or orig)
                ctx.log.info(f"[capture-addon] local-redirect {orig} -> {self.local_backend}")
            except Exception as e:
                ctx.log.warn(f"[capture-addon] local-redirect failed for {orig}: {e!r}")
            return
        if self.retarget_real:
            ip = self._resolve_real(host)
            if ip:
                try:
                    flow.server_conn.address = (ip, self.real_port)
                    flow.server_conn.sni = host
                except Exception as e:
                    ctx.log.warn(f"[capture-addon] retarget failed for {host}: {e!r}")
            return
        # Forward/regular mode (default): let mitmproxy connect to the real host
        # parsed from the CONNECT request — no override needed.

    def response(self, flow: http.HTTPFlow):
        cc = flow.client_conn
        peer = getattr(cc, "peername", (None, None)) or (None, None)
        sni = getattr(cc, "sni", None)
        host = flow.request.headers.get("Host") or sni or flow.request.host
        server_ip = None
        try:
            server_ip = flow.server_conn.peername[0] if flow.server_conn.peername else flow.request.host
        except Exception:
            server_ip = flow.request.host
        # actual upstream port we connected to (force_upstream/offline aware)
        try:
            server_port = flow.server_conn.peername[1] if flow.server_conn.peername else self.real_port
        except Exception:
            server_port = self.real_port
        req_body = flow.request.raw_content or b""
        resp_body = flow.response.raw_content or b"" if flow.response else b""
        self._emit({
            "t": (flow.response.timestamp_end if flow.response else time.time()),
            "kind": "http",
            "client_ip": peer[0], "client_port": peer[1],
            "server_ip": server_ip, "server_port": server_port,
            "sni": sni, "host": host,
            "method": flow.request.method, "path": flow.request.path,
            "status": flow.response.status_code if flow.response else None,
            "req_headers": list(flow.request.headers.items(True)),
            "req_body_b64": base64.b64encode(req_body).decode(),
            "resp_headers": list(flow.response.headers.items(True)) if flow.response else [],
            "resp_body_b64": base64.b64encode(resp_body).decode(),
        })


addons = [CaptureAddon()]
