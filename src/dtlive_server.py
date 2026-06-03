#!/usr/bin/env python3
"""Emulated passtech "dt-live" Stormancer federation / auth server.

This is the HTTPS plane of Ravenswatch's online backend (dt-live*.passtechgames.com):
the cluster-status root, the `/_federation` discovery doc, and the Stormancer scene
connection-token endpoint (`.../token`). The RakNet UDP plane is served separately by
raknet.py; the token envelope minted here (via stoken.py) points the game at it.

Two serving modes:
  * Legacy TLS (default): listens HTTPS with the captured server.crt/server.key. Used
    by the direct-:443 and mitmproxy forward-proxy capture flows. Needs the CA trusted
    inside the game's Wine prefix.
  * Plain HTTP (PROBE_PLAIN=1, typically PROBE_PORT=8080): no TLS at all. Used by the
    winhttp_shim refactor, where the in-game winhttp.dll proxy rewrites dt-live* ->
    127.0.0.1:<port> and clears WINHTTP_FLAG_SECURE, so the game speaks cleartext and
    no cert / CA-in-prefix is required.

Env:
  PROBE_DIR    data dir for request dumps, server.log, and (TLS mode) the cert/key.
               Default /tmp/pdlog/probe (kept for backwards compat with the captured
               server.crt/server.key that live there).
  PROBE_PORT   listen port. Default 443.
  PROBE_PLAIN  set to 1/true/yes to serve plain HTTP (skip TLS). Default off.
"""
import ssl, sys, datetime, http.server, socketserver, json, os, base64

# stoken.py lives next to this file; make sure it's importable when run as a script.
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import stoken

# Data dir for request dumps, the log, and (TLS mode) the cert/key. Defaults to the
# historical /tmp/pdlog/probe so the captured server.crt/server.key keep resolving.
D = os.environ.get("PROBE_DIR", "/tmp/pdlog/probe")
REQDIR = D + "/reqs"
os.makedirs(REQDIR, exist_ok=True)
# Bind port. Default 443 (game talks straight to us). When mitmproxy sits in
# front to decrypt+log, run this on 8443 (PROBE_PORT=8443) so mitmproxy owns 443
# and forwards decrypted requests here.
PORT = int(os.environ.get("PROBE_PORT", "443"))

# Plain-HTTP mode (winhttp_shim refactor). When the winhttp.dll proxy shim runs
# inside the game it rewrites dt-live* -> 127.0.0.1:<port> AND clears
# WINHTTP_FLAG_SECURE, so the game speaks PLAIN HTTP to us — no TLS, no cert, no
# CA-in-prefix. Set PROBE_PLAIN=1 (and typically PROBE_PORT=8080) to serve plain
# HTTP and skip the ssl.wrap_socket. Default 0 keeps the legacy TLS behaviour
# used by the mitmproxy/direct-443 flows.
PLAIN = os.environ.get("PROBE_PLAIN", "0") not in ("0", "", "false", "no")

_lf = open(D + "/server.log", "a", buffering=1)
def log(*a):
    line = datetime.datetime.now().strftime("%H:%M:%S.%f")[:-3] + " " + " ".join(str(x) for x in a)
    print(line, flush=True)
    _lf.write(line + "\n")

FED = {
  "current": {"id":"passtech-live","adminEndpoints":["https://dt-live.passtechgames.com"],
              "endpoints":["https://dt-live.passtechgames.com"],"tags":[]},
  "clusters":[{"id":"passtech-live","adminEndpoints":None,
               "endpoints":["https://dt-live.passtechgames.com"],"tags":[]}]
}

# Cluster-node status the real server returns for `GET /`. The Stormancer client
# parses this during connection and expects string fields (name, version,
# leader.endpoint, ...); returning a bare "{}" makes it throw
# "[Exception: not a string]" in UsersApi::loginImpl. Captured from the real
# dt-live server (mitm/0005_GET_root_RESP.txt).
ROOT = {
  "name": "dt-live-1", "version": "9.3.0.2", "reportedStatus": "Leader",
  "leader": {"uid": "5w0GiaMkGUuN+QnuOyHTKQ", "name": "dt-live-1",
             "endpoint": "dt-live.passtechgames.com:40243",
             "cluster": "passtech-live"},
  "cluster": "passtech-live", "logLastCommittedEntryId": 19,
  "logLastEntryId": 19, "logLastSnapshot": None, "state": "Running",
  "id": "5w0GiaMkGUuN+QnuOyHTKQ"
}

_seq = [0]
def dump_request(handler, body):
    try:
        _seq[0] += 1
        n = _seq[0]
        safe = handler.path.strip("/").replace("/", "_").split("?")[0] or "root"
        fn = f"{REQDIR}/{n:04d}_{handler.command}_{safe}"[:200] + ".txt"
        with open(fn, "wb") as f:
            f.write(f"{handler.command} {handler.path}\n".encode())
            for k, v in handler.headers.items():
                f.write(f"{k}: {v}\n".encode())
            f.write(b"\n--- BODY ---\n")
            f.write(body or b"")
            f.write(b"\n--- BODY-HEX ---\n")
            f.write((body or b"").hex().encode())
    except Exception as e:
        log("  (dump_request skipped:", repr(e), ")")

# =========================================================================
# RELAY MODE (env RELAY=1)
# -------------------------------------------------------------------------
# Forward /_federation, /, and the bootstrap /token to the REAL dt-live backend
# instead of self-minting. For /token we keep the real (signed) token blob and
# the real AES key verbatim, but rewrite endpoints.raknet[0] to our local RakNet
# proxy (raknet.py in RAKNET_RELAY mode) so the client's UDP traffic flows
# through us to the real cluster. The real raknet endpoint + key are written to
# RELAY_STATE_FILE for raknet.py to learn its upstream. Every relayed token is
# also diffed against what stoken.make_token_envelope() would have produced and
# the comparison is appended to RELAY_DIFF_FILE (non-halting).
# =========================================================================
RELAY = os.environ.get("RELAY", "0") not in ("0", "", "false", "no")
# Where the client should send RakNet UDP (our proxy). Defaults to the same
# RAKNET_ENDPOINT the offline emulator uses.
RELAY_LOCAL_RAKNET = os.environ.get("RAKNET_ENDPOINT", "127.0.0.1:30100")
RELAY_STATE_FILE = os.environ.get("RELAY_STATE_FILE", D + "/relay_upstream.json")
RELAY_DIFF_FILE = os.environ.get("RELAY_DIFF_FILE", D + "/relay_token_diff.jsonl")
# Real backend host to relay HTTPS to (the cluster the client's Host header names).
RELAY_REAL_HOST = os.environ.get("RELAY_REAL_HOST", "dt-live.passtechgames.com")


def _real_fetch(method, host, path, body, headers):
    """IPv4 HTTPS request to the real backend (dt-live AAAA is dead; force A).
    Returns (status, resp_headers_dict, resp_body_bytes)."""
    import http.client, socket
    ai = socket.getaddrinfo(host, 443, socket.AF_INET, socket.SOCK_STREAM)
    ip = ai[0][4][0]
    ctx = ssl.create_default_context()
    raw = socket.create_connection((ip, 443), timeout=10)
    sock = ctx.wrap_socket(raw, server_hostname=host)
    conn = http.client.HTTPConnection(host)
    conn.sock = sock
    fwd = {k: v for k, v in (headers or {}).items()
           if k.lower() not in ("content-length", "host", "connection",
                                "accept-encoding")}
    fwd["Host"] = host
    fwd["Accept-Encoding"] = "identity"
    conn.request(method, path, body=body or b"", headers=fwd)
    r = conn.getresponse()
    rb = r.read()
    rh = {k: v for k, v in r.getheaders()}
    conn.close()
    return r.status, rh, rb


def _relay_token(real_body):
    """Rewrite the real token envelope's raknet endpoint to our proxy; stash the
    real endpoint + AES key; diff against the emulator's envelope. Returns the
    (possibly rewritten) body bytes to send back to the client."""
    try:
        env = json.loads(real_body)
    except Exception as e:
        log("  RELAY /token: real body not JSON (", repr(e), ") - passthrough")
        return real_body
    real_raknet = (env.get("endpoints", {}) or {}).get("raknet") or []
    real_ep = real_raknet[0] if real_raknet else None
    real_key = (env.get("encryption", {}) or {}).get("key")
    # Persist upstream so raknet.py relay knows where to forward.
    try:
        with open(RELAY_STATE_FILE, "w") as f:
            json.dump({"raknet": real_ep, "key": real_key,
                       "ts": datetime.datetime.now().isoformat()}, f)
    except Exception as e:
        log("  RELAY state write failed:", repr(e))
    # Diff real vs emulated (non-halting).
    try:
        emu = stoken.make_token_envelope()
        diff = {
            "t": datetime.datetime.now().isoformat(),
            "real_raknet": real_ep,
            "emu_raknet": (emu.get("endpoints", {}) or {}).get("raknet"),
            "real_has_enc": "encryption" in env,
            "emu_has_enc": "encryption" in emu,
            "real_token_len": len(env.get("token", "")),
            "emu_token_len": len(emu.get("token", "")),
            "real_keys": sorted(env.keys()),
            "emu_keys": sorted(emu.keys()),
            "real_enc_keys": sorted((env.get("encryption") or {}).keys()),
            "emu_enc_keys": sorted((emu.get("encryption") or {}).keys()),
        }
        with open(RELAY_DIFF_FILE, "a") as f:
            f.write(json.dumps(diff) + "\n")
        log("  RELAY token diff: real_raknet", real_ep,
            "-> rewrite", RELAY_LOCAL_RAKNET,
            "| real_enc_keys", diff["real_enc_keys"])
    except Exception as e:
        log("  RELAY token diff failed:", repr(e))
    # Rewrite the raknet endpoint to our proxy; keep everything else verbatim.
    if real_ep is not None:
        env.setdefault("endpoints", {})["raknet"] = [RELAY_LOCAL_RAKNET]
    return json.dumps(env).encode()


class H(http.server.BaseHTTPRequestHandler):
    def _read_body(self):
        ln = self.headers.get("Content-Length")
        if ln:
            try:
                return self.rfile.read(int(ln))
            except Exception:
                return b""
        return b""

    def _send(self, code, body, ctype="application/json", extra_headers=None):
        if isinstance(body, str):
            body = body.encode()
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Server", "Kestrel")
        self.send_header("Cache-Control", "no-cache")
        if extra_headers:
            for k, v in extra_headers.items():
                self.send_header(k, v)
        self.end_headers()
        if self.command != "HEAD":
            self.wfile.write(body)

    def _relay(self, p, body):
        """Forward the request to the real dt-live backend; for /token rewrite
        the raknet endpoint to our proxy. Falls back to the local emulator
        response if the real fetch fails (so a transient network error doesn't
        wedge the client)."""
        try:
            status, rh, rb = _real_fetch(
                self.command, RELAY_REAL_HOST, self.path, body, dict(self.headers))
            log("  RELAY <-", status, self.command, p, "real", len(rb), "B")
            if p.endswith("/token"):
                rb = _relay_token(rb)
            ctype = rh.get("Content-Type", "application/json")
            return self._send(status, rb, ctype=ctype,
                              extra_headers={"x-version": rh.get("x-version", "3")})
        except Exception as e:
            log("  RELAY fetch FAILED for", p, ":", repr(e), "- local fallback")
            if p == "/_federation":
                return self._send(200, json.dumps(FED))
            if p.endswith("/token"):
                return self._send(200, json.dumps(stoken.make_token_envelope()),
                                  ctype="application/json; charset=utf-8",
                                  extra_headers={"x-version": "3"})
            if p == "/":
                return self._send(200, json.dumps(ROOT))
            return self._send(200, "{}")

    def _route(self):
        body = self._read_body()
        log("REQUEST", self.command, self.path, "from", self.client_address, "clen", len(body))
        dump_request(self, body)
        p = self.path.split("?")[0]
        # mitmproxy (forward mode, after the addon rewrites request.host) forwards
        # the request in ABSOLUTE form, e.g. "https://127.0.0.1:8443/_federation".
        # Strip the scheme://authority so origin-form path matching below works.
        if "://" in p:
            p = "/" + p.split("://", 1)[1].split("/", 1)[1] if "/" in p.split("://", 1)[1] else "/"

        if RELAY:
            return self._relay(p, body)

        if p == "/_federation":
            return self._send(200, json.dumps(FED))

        # Stormancer scene connection token endpoint. The real server returns a
        # JSON envelope: {token: base64(msgpack ConnectionData)-sig, endpoints:
        # {raknet:[host:port]}, encryption:{...}}. The client base64-decodes the
        # token's first '-' part into ConnectionData, then opens a RakNet UDP
        # connection to endpoints.raknet[0]. We point raknet at our local server.
        if p.endswith("/token"):
            env = stoken.make_token_envelope()
            log("  -> token envelope raknet", env["endpoints"]["raknet"],
                "enc", "yes" if "encryption" in env else "no")
            return self._send(200, json.dumps(env),
                              ctype="application/json; charset=utf-8",
                              extra_headers={"x-version": "3"})

        # Cluster-node status; client parses string fields from this.
        if p == "/":
            return self._send(200, json.dumps(ROOT))

        return self._send(200, "{}")

    do_GET = _route
    do_POST = _route
    do_PUT = _route
    do_HEAD = _route
    def log_message(self, *a): pass

class Srv(socketserver.ThreadingTCPServer):
    allow_reuse_address = True

if PLAIN:
    # Plain HTTP: no TLS context, serve requests directly. The winhttp shim has
    # already stripped WINHTTP_FLAG_SECURE so the game connects over cleartext.
    class LoggingSrv(Srv):
        def get_request(self):
            sock, addr = super().get_request()
            log("TCP CONNECT from", addr, "(plain http)")
            return sock, addr
else:
    ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    # Cap at TLS 1.2: Wine's schannel/winhttp can complete a TLS 1.3 handshake but
    # then choke on post-handshake messages (NewSessionTicket/KeyUpdate), returning
    # ERROR_WINHTTP_SECURE_CHANNEL_ERROR (12157) and sending no HTTP request. The
    # real passtech backend uses TLS 1.2, so match it.
    ctx.maximum_version = ssl.TLSVersion.TLSv1_2
    ctx.load_cert_chain(f"{D}/server.crt", f"{D}/server.key")

    # Wrap to log low-level TLS handshake attempts (proves a SYN+TLS reached us even if cert rejected)
    class LoggingSrv(Srv):
        def get_request(self):
            sock, addr = super().get_request()
            log("TCP CONNECT from", addr)
            try:
                ssock = ctx.wrap_socket(sock, server_side=True)
                log("TLS HANDSHAKE OK from", addr)
                return ssock, addr
            except Exception as e:
                log("TLS HANDSHAKE FAILED from", addr, "->", repr(e))
                raise

if __name__ == "__main__":
    proto = "HTTP (plain)" if PLAIN else "HTTPS (cert SAN dt-live.passtechgames.com)"
    log(f"dt-live federation server starting on 0.0.0.0:{PORT} -- {proto} (data dir {D})")
    with LoggingSrv(("0.0.0.0", PORT), H) as s:
        s.serve_forever()
