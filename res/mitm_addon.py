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
                     f"hostmap={self.hostmap or '{}'}")

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
        ip = self._resolve_real(host)
        if ip:
            try:
                flow.server_conn.address = (ip, self.real_port)
                flow.server_conn.sni = host
            except Exception as e:
                ctx.log.warn(f"[capture-addon] retarget failed for {host}: {e!r}")

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
        req_body = flow.request.raw_content or b""
        resp_body = flow.response.raw_content or b"" if flow.response else b""
        self._emit({
            "t": (flow.response.timestamp_end if flow.response else time.time()),
            "kind": "http",
            "client_ip": peer[0], "client_port": peer[1],
            "server_ip": server_ip, "server_port": self.real_port,
            "sni": sni, "host": host,
            "method": flow.request.method, "path": flow.request.path,
            "status": flow.response.status_code if flow.response else None,
            "req_headers": list(flow.request.headers.items(True)),
            "req_body_b64": base64.b64encode(req_body).decode(),
            "resp_headers": list(flow.response.headers.items(True)) if flow.response else [],
            "resp_body_b64": base64.b64encode(resp_body).decode(),
        })


addons = [CaptureAddon()]
