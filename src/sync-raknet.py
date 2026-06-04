#!/usr/bin/env python3
"""sync-raknet.py — synchronous RakNet relay + per-request transaction logger.

Unlike the async proxy in raknet.py (relay_main), this relay is REQUEST
SYNCHRONOUS: for every client->server UDP datagram that carries real content
(ACK/NAK and offline handshake datagrams are NOT recorded), it forwards the one
datagram upstream, then waits RELAY_RESP_WAIT_MS milliseconds collecting EVERY
server->client UDP datagram that comes back before moving on. The real burst and
the emulator's predicted burst are both logged so the emulator can be made
byte/semantics faithful.

Each recorded transaction is one JSON line:
  {
    "t":   ISO timestamp,
    "peer": "C1" | "C2" | ...,
    "match": bool,                       # WINDOW-based: real burst == pred burst
                                         #   in the same response window. See the
                                         #   reqId-correlated summary below for the
                                         #   authoritative verdict (the real server
                                         #   pipelines, so window match has false
                                         #   mismatches; the summary corrects for it).
    "RAW_UDP_SENT": "<hex>",             # the single c2s datagram forwarded upstream
    "udp_sent_human_readable": "<str>",  # full decode of that c2s datagram
    "real": ["<hex>", ...],              # every NON-ACK s2c datagram the real server sent
    "real_human_readable": "<str>",      # full decode of the real burst
    "pred": ["<hex>", ...],              # every NON-ACK s2c datagram the emulator predicted
    "pred_human_readable": "<str>"       # full decode of the predicted burst
  }

The *_human_readable strings are FULL literal decodes — nothing masked, nothing
summarized. Strings are verbatim, binary is hex, every msgpack value is shown in
full. They are detailed enough that any difference between real_human_readable
and pred_human_readable reflects a real difference in the underlying hex arrays.

At the end of a run an HONEST reqId-correlated verdict is printed (and computed
from the faithful log itself): responses are matched to requests by reqId across
the whole capture — not by arrival window — so the count of genuine emulator
divergences is not polluted by the real server's response pipelining. Clock and
per-run-identity differences are labelled as noise; server-initiated pushes (no
reqId) are reported as route coverage (real vs pred counts).

Modes:
  live   (default): bind UDP HOST:PORT, proxy to the real dt-live cluster.
  replay (SYNC_REPLAY=/path/to/relay_capture.jsonl): reconstruct transactions
         from an existing capture (no live game needed) — handy for iterating on
         the output format.

Env:
  RELAY_RESP_WAIT_MS   response-collection window in ms (default 100)
  SYNC_ASSERT_FILE     output JSONL (default /tmp/pdlog/probe/sync_assert.jsonl)
  SYNC_REPLAY          if set, run offline replay against this capture file
  (plus all of raknet.py's relay env: RAKNET_RELAY upstream resolution, etc.)
"""
import os
import sys
import json
import time
import socket
import select
import datetime

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import raknet as R
import join_diff as JD
import raknet_tables as RT
import raknet_hr as H
import predict as P            # fresh, data-oriented clean-room response predictor

# One broker world per run: the fresh predictor mutates this across datagrams.
# (Rebuilt at the start of replay_main / live_main.)
_WORLD = P.new_world()


RESP_WAIT_MS = int(os.environ.get("RELAY_RESP_WAIT_MS", "100"))
SYNC_ASSERT_FILE = os.environ.get(
    "SYNC_ASSERT_FILE", "/tmp/pdlog/probe/sync_assert.jsonl")

# Online connected-layer message id -> name, for rendering non-Stormancer frames.
_ONLINE_NAMES = {
    R.ID_CONNECTED_PING: "ID_CONNECTED_PING",
    R.ID_CONNECTED_PONG: "ID_CONNECTED_PONG",
    R.ID_CONNECTION_REQUEST: "ID_CONNECTION_REQUEST",
    R.ID_CONNECTION_REQUEST_ACCEPTED: "ID_CONNECTION_REQUEST_ACCEPTED",
    R.ID_NEW_INCOMING_CONNECTION: "ID_NEW_INCOMING_CONNECTION",
    R.ID_DISCONNECTION_NOTIFICATION: "ID_DISCONNECTION_NOTIFICATION",
    R.ID_CONNECTION_RESULT: "ID_CONNECTION_RESULT",
}


def _is_content_datagram(dg):
    """True if `dg` is an online data datagram (carries encapsulated messages).
    Offline handshake datagrams and ACK/NAK datagrams carry no content and are
    deliberately NOT recorded."""
    if not dg:
        return False
    flags = dg[0]
    if not (flags & 0x80):          # offline (handshake) datagram
        return False
    if flags & 0x40:                # ACK
        return False
    if flags & 0x20:                # NAK
        return False
    return True


def _online_abbr(mid):
    """Short tag for a connected-layer / transport control id."""
    return (RT.ONLINE_IDS.get(mid)
            or RT.TRANSPORT_IDS.get(mid)
            or "id0x%02x" % mid)


def _hr_key_prefix(key):
    """Abbreviated, symbol-free prefix for a classified s2c message key."""
    if key[0] == "SYS":
        sub, req = key[1], key[2]
        tag = {"RESP_MSG": "resp", "RESP_COMPLETE": "done",
               "RESP_ERROR": "rerr"}.get(sub, sub.lower())
        return "%s#%d" % (tag, req)
    # ("SCN", kind, rname[, rid])
    kabbr = H.abbr_kind(key[1])
    rabbr = H.abbr_route(key[1], key[2])
    if len(key) >= 4:
        return "%s/%s#%d" % (kabbr, rabbr, key[3])
    return "%s/%s" % (kabbr, rabbr)


class TxnDecoder:
    """Wraps a raknet._RelayAssert (for route learning + real-handle/party
    adoption) and renders datagrams to full-literal human-readable strings.

    One decoder per peer. Real s2c bursts are fed through `human_s2c(.., "real")`
    and predicted bursts through `human_s2c(.., "pred")`; both drive the engine's
    route tables so scene messages resolve their route names and the shadow can
    adopt the real server's scene handles."""

    def __init__(self, label):
        self.label = label
        self.eng = R._RelayAssert(label, JD)
        self.eng.split["c2s"] = {}      # add a c2s split-reassembly bucket

    # ---- client -> server ------------------------------------------------
    def human_c2s(self, dg):
        """Full decode of one client->server datagram."""
        parts = []
        try:
            msgs = R.parse_messages_ex(dg, 4)
        except Exception as e:
            return f"<parse-exc {e}>"
        for m in msgs:
            pl = m["payload"]
            if not pl:
                continue
            pl = self._reassemble("c2s", m, pl)
            if pl is None:
                continue
            s = self._human_c2s_message(pl)
            if s:
                parts.append(s)
        return RT.HR_MSG_SEP.join(parts)

    def _human_c2s_message(self, pl):
        eng = self.eng
        mid = pl[0]
        if mid == R.ID_SYSTEM_REQUEST and len(pl) >= 4:
            msg_id = pl[1]
            req = R._rd_u16le(pl, 2)
            data = pl[4:]
            name = RT.SYSREQ_IDS.get(msg_id, "sr0x%02x" % msg_id)
            return "sysreq %s#%d = %s" % (
                name, req, H.hr_payload(eng._skel_or_binary(data), name))
        if mid in _ONLINE_NAMES and len(pl) <= 2:
            return _online_abbr(mid)
        if len(pl) >= 3:
            h = mid
            rh = R._rd_u16le(pl, 1)
            body = pl[3:]
            # The client addresses scene messages to the REAL server's handles.
            routes = eng.h2r["real"].get(h)
            kind = eng.h2k["real"].get(h, "scene?")
            rname = (routes or {}).get(rh, "r#%d" % rh)
            kabbr = H.abbr_kind(kind)
            rabbr = H.abbr_route(kind, rname)
            if rname in R._RPC_STREAM_ROUTES and len(body) >= 2:
                rid = R._rd_u16le(body, 0)
                return "%s/%s#%d = %s" % (
                    kabbr, rabbr, rid,
                    H.hr_payload(eng._skel_or_binary(body[2:]), rabbr))
            return "%s/%s = %s" % (
                kabbr, rabbr, H.hr_payload(eng._skel_or_binary(body), rabbr))
        return "id0x%02x %dB" % (mid, len(pl))

    # ---- server -> client ------------------------------------------------
    def human_s2c(self, side, hexes):
        """Full decode of a burst of server->client datagrams (a list of hex
        strings). Drives the engine's route learning / handle adoption for
        `side` ('real' or 'pred')."""
        parts = []
        for hx in hexes:
            dg = bytes.fromhex(hx)
            try:
                msgs = R.parse_messages_ex(dg, 4)
            except Exception as e:
                parts.append(f"<parse-exc {e}>")
                continue
            for m in msgs:
                pl = m["payload"]
                if not pl:
                    continue
                pl = self._reassemble(side, m, pl)
                if pl is None:
                    continue
                try:
                    key, lit = self.eng._classify(side, pl)
                except Exception as e:
                    parts.append(f"<decode-exc {e}>")
                    continue
                if key is None:
                    continue
                prefix = _hr_key_prefix(key)
                rabbr = key[2] if key[0] == "SCN" and len(key) > 2 else None
                parts.append("%s = %s" % (
                    prefix, H.hr_payload(lit, H.abbr_route(
                        key[1], rabbr) if rabbr else None)))
        return RT.HR_MSG_SEP.join(parts)

    def _reassemble(self, side, m, pl):
        """Reassemble split (fragmented) messages per side; return the complete
        payload or None while fragments are still outstanding."""
        sp = m["split"]
        if sp is None:
            return pl
        count, sid, index = sp
        buf = self.eng.split[side].setdefault(sid, {})
        buf[index] = pl
        if len(buf) < count:
            return None
        full = b"".join(buf[i] for i in range(count))
        del self.eng.split[side][sid]
        return full


_assert_fh = None
def _write(rec):
    global _assert_fh
    if _assert_fh is None:
        os.makedirs(os.path.dirname(SYNC_ASSERT_FILE), exist_ok=True)
        _assert_fh = open(SYNC_ASSERT_FILE, "a", buffering=1)
    _assert_fh.write(json.dumps(rec, default=str) + "\n")


def _sync_handle_aliases(dec, caddr):
    """Bridge the harness's learned real/predicted connect handles into the fresh
    predictor's plain-dict bindings (replay only -- not used live).

    `dec.eng` (the _RelayAssert that renders both real and predicted bursts)
    correlates each connect reqId to the REAL server's SceneHandle and to the
    handle the predictor returned. The retail client addresses its scene messages
    to the real handles, so we alias each real handle onto the predictor binding
    created under its own handle. No-op for static scenes (handles already match)."""
    eng = dec.eng
    real = getattr(eng, "_connect", {}).get("real", {})
    pred = getattr(eng, "_connect", {}).get("pred", {})
    for req, h_real in real.items():
        h_pred = pred.get(req)
        if h_pred is not None:
            P.alias_scene_handle(_WORLD, caddr, h_real, h_pred)


def _predict(dec, caddr, c2s):
    """Run the FRESH clean-room predictor (predict.py) for one c2s datagram;
    return the list of predicted s2c datagrams (hex) addressed back to this
    client. The predictor is fully independent of raknet.py -- this is what the
    real-vs-predicted verdict now measures. `dec` is still used to RENDER the
    predicted bytes (human_s2c) but no longer to produce them."""
    out = P.predict(_WORLD, caddr, c2s)
    return [dg.hex() for (addr, dg) in out
            if addr == caddr and _is_content_datagram(dg)]


def _finalize(dec, peer, t_iso, c2s_hex, c2s_human, reals_hex, preds_hex):
    real_human = dec.human_s2c("real", reals_hex)
    pred_human = dec.human_s2c("pred", preds_hex)
    rec = {
        "t": t_iso,
        "peer": peer,
        "match": real_human == pred_human,
        "RAW_UDP_SENT": c2s_hex,
        "udp_sent_human_readable": c2s_human,
        "real": reals_hex,
        "real_human_readable": real_human,
        "pred": preds_hex,
        "pred_human_readable": pred_human,
    }
    _write(rec)
    if not rec["match"]:
        R.log(f"  [sync {peer}] DIFF {c2s_human[:80]}")


# =========================================================================
# OFFLINE REPLAY — reconstruct transactions from an existing relay_capture.jsonl
# =========================================================================

def replay_main(path):
    global _WORLD
    R.CONNS.clear(); R.PARTIES.clear(); R._RELAY_ENGINES.clear()
    _WORLD = P.new_world()      # fresh predictor world for this run
    try:
        R.GAMESESSIONS.clear()
    except Exception:
        pass
    os.makedirs(os.path.dirname(SYNC_ASSERT_FILE), exist_ok=True)
    R._relay_rotate(SYNC_ASSERT_FILE)

    rows = [json.loads(l) for l in open(path)]
    # Synthetic per-peer client addresses + engine registration (so cross-peer
    # broadcasts route correctly inside the shadow).
    decs = {}
    addrs = {}
    nidx = 1
    active = {}     # peer -> dict(t,c2s_hex,c2s_human,preds,reals)

    def ensure(peer):
        nonlocal nidx
        if peer not in decs:
            decs[peer] = TxnDecoder(peer)
            addrs[peer] = ("10.0.0.%d" % nidx, nidx)
            R._RELAY_ENGINES[addrs[peer]] = decs[peer].eng
            nidx += 1
        return decs[peer], addrs[peer]

    def flush(peer):
        a = active.pop(peer, None)
        if a is None:
            return
        dec = decs[peer]
        _finalize(dec, peer, a["t"], a["c2s_hex"], a["c2s_human"],
                  a["reals"], a["preds"])

    for r in rows:
        peer = r["peer"]
        dec, caddr = ensure(peer)
        dg = bytes.fromhex(r["hex"])
        if r["dir"] == "c2s":
            if not _is_content_datagram(dg):
                # ACK/NAK/handshake: still let the predictor process the
                # handshake so a connection exists, but do not start a recorded
                # transaction. (dec.eng still learns routes from the real s2c.)
                P.predict(_WORLD, caddr, dg)
                continue
            # A new client request finalizes the previous one (lock-step client).
            flush(peer)
            _sync_handle_aliases(dec, caddr)
            preds = _predict(dec, caddr, dg)
            active[peer] = {
                "t": r["t"],
                "c2s_hex": r["hex"],
                "c2s_human": dec.human_c2s(dg),
                "preds": preds,
                "reals": [],
            }
        else:  # s2c
            if not _is_content_datagram(dg):
                continue
            a = active.get(peer)
            if a is not None:
                a["reals"].append(r["hex"])
    for peer in list(active):
        flush(peer)
    R.log(f"sync replay written -> {SYNC_ASSERT_FILE}")
    summarize_file(SYNC_ASSERT_FILE)


# =========================================================================
# LIVE SYNCHRONOUS RELAY
# =========================================================================

def live_main():
    global _WORLD
    _WORLD = P.new_world()      # fresh predictor world for this run
    R._relay_rotate(SYNC_ASSERT_FILE)
    wait_s = RESP_WAIT_MS / 1000.0
    upstream = None
    cli = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    cli.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    cli.bind((R.HOST, R.PORT))
    R.log(f"sync-raknet listening on {R.HOST}:{R.PORT}; resp window "
          f"{RESP_WAIT_MS}ms; asserts -> {SYNC_ASSERT_FILE}")

    up_by_client = {}       # caddr -> upstream socket
    client_by_fd = {}       # upstream fileno -> caddr
    decs = {}               # peer label -> TxnDecoder
    active = {}             # peer label -> transaction dict (with deadline)

    def ensure_dec(label):
        if label not in decs:
            decs[label] = TxnDecoder(label)
        return decs[label]

    def finalize(label):
        a = active.pop(label, None)
        if a is None:
            return
        _finalize(decs[label], label, a["t"], a["c2s_hex"], a["c2s_human"],
                  a["reals"], a["preds"])

    try:
        while True:
            # Wake up no later than the soonest pending response-window deadline.
            timeout = 30.0
            now = time.monotonic()
            for a in active.values():
                timeout = min(timeout, max(0.0, a["deadline"] - now))
            rlist = [cli] + list(up_by_client.values())
            ready, _, _ = select.select(rlist, [], [], timeout)

            for s in ready:
                if s is cli:
                    data, caddr = cli.recvfrom(65535)
                    if not data:
                        continue
                    label = R.set_peer(caddr)
                    if upstream is None:
                        upstream, ulabel = R._relay_resolve_upstream()
                        R.log(f"sync upstream = {ulabel} {upstream}")
                    us = up_by_client.get(caddr)
                    if us is None:
                        us = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
                        us.connect(upstream)
                        up_by_client[caddr] = us
                        client_by_fd[us.fileno()] = caddr
                        R.log(f"-> new client {caddr[0]}:{caddr[1]}")
                    dec = ensure_dec(label)
                    # Always forward the client's datagram upstream promptly.
                    try:
                        us.send(data)
                    except OSError as e:
                        R.log(f"  !! upstream send failed: {e}")
                    if not _is_content_datagram(data):
                        # Handshake/ACK: let the predictor process it, don't record.
                        P.predict(_WORLD, caddr, data)
                        continue
                    # A new request closes the prior transaction (lock-step).
                    finalize(label)
                    preds = _predict(dec, caddr, data)
                    active[label] = {
                        "t": datetime.datetime.now().isoformat(),
                        "c2s_hex": data.hex(),
                        "c2s_human": dec.human_c2s(data),
                        "preds": preds,
                        "reals": [],
                        "deadline": time.monotonic() + wait_s,
                    }
                else:
                    caddr = client_by_fd.get(s.fileno())
                    if caddr is None:
                        continue
                    try:
                        data = s.recv(65535)
                    except OSError:
                        continue
                    if not data:
                        continue
                    R.set_peer(caddr)
                    label = R._PEER_LABELS.get(caddr, "?")
                    # Always forward the server's datagram back to the client.
                    cli.sendto(data, caddr)
                    if not _is_content_datagram(data):
                        continue
                    a = active.get(label)
                    if a is not None:
                        a["reals"].append(data.hex())

            # Finalize any transaction whose response window has elapsed.
            now = time.monotonic()
            for label in [l for l, a in active.items() if now >= a["deadline"]]:
                finalize(label)
    finally:
        for label in list(active):
            finalize(label)
        R.log(f"sync-raknet asserts written -> {SYNC_ASSERT_FILE}")
        try:
            summarize_file(SYNC_ASSERT_FILE)
        except Exception as e:
            R.log(f"  !! summary failed: {e}")


# =========================================================================
# HONEST reqId-CORRELATED SUMMARY
# -------------------------------------------------------------------------
# The per-transaction `match` field above is WINDOW-based: it compares whatever
# real datagrams arrived in the response window after one c2s against what the
# shadow predicted synchronously. But the real server PIPELINES -- it answers
# reqId=N after the client has already sent reqId=N+1,N+2 -- so a real response
# lands in a LATER c2s window than the request it answers, making `match` show
# spurious mismatches. The honest verdict correlates responses to requests BY
# reqId across the whole run (a resp#N/done#N/rerr#N segment answers the SAME
# reqId regardless of which window carried it). Server-initiated pushes have no
# reqId; they are reported separately as route coverage (real vs pred counts).
# This is computed from the faithful log itself -- nothing is masked.
# =========================================================================
import re as _re

_RESP_SEG = _re.compile(r"^(resp|done|rerr)#(\d+) = (.*)$")
_PUSH_SEG = _re.compile(r"^([a-z?]+)/([A-Za-z0-9._*#-]+) = (.*)$")


def _segments(hr):
    """Split a human-readable burst into its ' then '-separated messages."""
    if not hr:
        return []
    return hr.split(RT.HR_MSG_SEP)


def _index_responses(hr, out):
    """Map reqId -> response hr (first wins) for resp/done/rerr segments."""
    for seg in _segments(hr):
        m = _RESP_SEG.match(seg)
        if m:
            out.setdefault((m.group(1), int(m.group(2))), m.group(3))


def _push_routes(hr):
    """Yield (route, body_hr) for server-initiated push segments (no reqId)."""
    for seg in _segments(hr):
        if _RESP_SEG.match(seg):
            continue
        m = _PUSH_SEG.match(seg)
        if m and "#" not in m.group(2):     # rpc-stream segs carry #rpcReqId
            yield ("%s/%s" % (m.group(1), m.group(2)), m.group(3))


def _classify_diff(req_kind, rv, pv):
    """Label a real-vs-pred response difference as noise or genuine.
      'clock'    -> ping/clock reply (both 16-byte bin); absolute server clock is
                    environment-relative, not a protocol value.
      'identity' -> session token / per-run id (resp#1 second value et al.).
      'genuine'  -> a real semantic divergence to investigate.
    """
    if rv.startswith("bin16_") and pv.startswith("bin16_"):
        return "clock"
    # Same shape, differing only in an opaque/truncated id token => identity.
    if ("~" in rv and "~" in pv) and rv.split()[:1] == pv.split()[:1]:
        return "identity"
    return "genuine"


def summarize_records(records):
    """Compute the honest reqId-correlated verdict from logged transactions."""
    real_by, pred_by = {}, {}
    real_push, pred_push = {}, {}
    for r in records:
        _index_responses(r.get("real_human_readable"), real_by)
        _index_responses(r.get("pred_human_readable"), pred_by)
        for rt, _b in _push_routes(r.get("real_human_readable")):
            real_push[rt] = real_push.get(rt, 0) + 1
        for rt, _b in _push_routes(r.get("pred_human_readable")):
            pred_push[rt] = pred_push.get(rt, 0) + 1

    keys = sorted(set(real_by) | set(pred_by))
    same = diffs = 0
    real_only = pred_only = 0
    genuine, clock, identity = [], [], []
    for k in keys:
        rv, pv = real_by.get(k), pred_by.get(k)
        if rv is None:
            pred_only += 1
        elif pv is None:
            real_only += 1
        elif rv == pv:
            same += 1
        else:
            diffs += 1
            cls = _classify_diff(k[0], rv, pv)
            (genuine if cls == "genuine" else
             clock if cls == "clock" else identity).append((k, rv, pv))

    push_routes = sorted(set(real_push) | set(pred_push))
    push_gaps = [(rt, real_push.get(rt, 0), pred_push.get(rt, 0))
                 for rt in push_routes
                 if real_push.get(rt, 0) != pred_push.get(rt, 0)]
    return {
        "responses": {"same": same, "diff": diffs,
                      "real_only": real_only, "pred_only": pred_only},
        "genuine": genuine, "clock": clock, "identity": identity,
        "push": [(rt, real_push.get(rt, 0), pred_push.get(rt, 0))
                 for rt in push_routes],
        "push_gaps": push_gaps,
    }


def _print_summary(s):
    R.log("")
    R.log("=== HONEST reqId-correlated verdict ===")
    rr = s["responses"]
    R.log("  responses: same=%d  diff=%d  real_only=%d  pred_only=%d"
          % (rr["same"], rr["diff"], rr["real_only"], rr["pred_only"]))
    R.log("  diff breakdown: genuine=%d  clock-noise=%d  identity-noise=%d"
          % (len(s["genuine"]), len(s["clock"]), len(s["identity"])))
    if s["genuine"]:
        R.log("  --- GENUINE response divergences (investigate) ---")
        for (kind, req), rv, pv in s["genuine"]:
            R.log("    %s#%d" % (kind, req))
            R.log("      real: %s" % rv[:160])
            R.log("      pred: %s" % pv[:160])
    if s["push_gaps"]:
        R.log("  --- SERVER-PUSH coverage gaps (route: real/pred) ---")
        for rt, rc, pc in s["push_gaps"]:
            R.log("    %3d / %3d  %s" % (rc, pc, rt))
    R.log("=======================================")


def summarize_file(path):
    """Read a sync_assert.jsonl and print + return the honest verdict."""
    records = []
    with open(path) as fh:
        for line in fh:
            line = line.strip()
            if line:
                records.append(json.loads(line))
    s = summarize_records(records)
    _print_summary(s)
    return s


if __name__ == "__main__":
    replay = os.environ.get("SYNC_REPLAY")
    try:
        if replay:
            replay_main(replay)
        else:
            live_main()
    except KeyboardInterrupt:
        R.log("sync-raknet stopped")
        sys.exit(0)
