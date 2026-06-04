#!/usr/bin/env python3
"""sync-raknet.py — synchronous RakNet relay + per-request transaction logger.

Unlike the async proxy in raknet.py (relay_main), this relay is REQUEST
SYNCHRONOUS, and it works in terms of MESSAGES, not UDP packets. The encapsulated
RakNet message -- reassembled from however many datagrams/fragments carried it --
is the atomic unit. For every complete client->server message that carries real
content (ACK/NAK and offline handshake datagrams are NOT recorded), it forwards
the datagram(s) upstream, then waits RELAY_RESP_WAIT_MS milliseconds collecting
EVERY server->client datagram that comes back, reassembling them into complete
messages before moving on. A request split across two UDP packets is therefore a
SINGLE transaction, and the '<split frag>' fragmentation concept never surfaces
in the log. The real burst and the emulator's predicted burst -- both as lists
of reassembled messages -- are logged so the emulator can be made byte/semantics
faithful.

Each recorded transaction is one pretty-printed JSON object (every field on its
own line so the real vs predicted decode can be eyeballed). Records are written
back-to-back separated by a blank line; the reader uses raw_decode so the
multi-line objects stay machine-parseable. Field order is chosen for diffing --
real_human_readable sits directly above pred_human_readable, and the bulky raw
hex arrays come last. Every entry in sent/real/pred is one fully-reassembled
MESSAGE payload (mid + body), never a raw UDP datagram:
  {
    "t":   ISO timestamp,
    "peer": "C1" | "C2" | ...,
    "match": bool,                       # WINDOW-based: real burst == pred burst
                                         #   in the same response window. See the
                                         #   reqId-correlated summary below for the
                                         #   authoritative verdict (the real server
                                         #   pipelines, so window match has false
                                         #   mismatches; the summary corrects for it).
    "sent": ["<hex>", ...],              # the complete c2s message(s) forwarded upstream
    "sent_human_readable": "<str>",      # full decode of that c2s message burst
    "real_human_readable": "<str>",      # full decode of the real burst
    "pred_human_readable": "<str>",      # full decode of the predicted burst
    "real": ["<hex>", ...],              # every NON-ACK s2c message the real server sent
    "pred": ["<hex>", ...]               # every NON-ACK s2c message the emulator predicted
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
  serve  (default): bind UDP HOST:PORT and answer clients DIRECTLY from the
         data-oriented predictor (predict.py) — a pure offline Stormancer
         broker with no upstream. This is the drop-in replacement for
         raknet.py's main() that partydeck points the game at.
  relay  (RAKNET_RELAY=1): bind UDP HOST:PORT, proxy to the real dt-live
         cluster, and shadow-predict each response for a faithfulness verdict.
  replay (SYNC_REPLAY=/path/to/relay_capture.jsonl): reconstruct transactions
         from an existing capture (no live game needed) — handy for iterating on
         the emulator / output format.

Env:
  RAKNET_RELAY         if truthy, run live relay + shadow-predict (else: serve)
  SYNC_REPLAY          if set, run offline replay against this capture file
  RELAY_RESP_WAIT_MS   response-collection window in ms (default 100)
  SYNC_ASSERT_FILE     output JSON (default /tmp/pdlog/probe/sync_assert.json)
  (plus all of raknet.py's relay env: RAKNET_RELAY_UPSTREAM, etc.)
"""
import os
import sys
import json
import time
import socket
import select
import datetime
from collections import deque

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
    "SYNC_ASSERT_FILE", "/tmp/pdlog/probe/sync_assert.json")

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


def _decode_raknet_addr(b):
    """Decode a 7-byte RakNet IPv4 SystemAddress (version(1) + complemented
    IPv4(4) + port(2,BE)) into 'a.b.c.d:port'. See raknet.encode_address."""
    if len(b) < 7:
        return None
    ip = ".".join(str((~x) & 0xFF) for x in b[1:5])
    port = int.from_bytes(b[5:7], "big")
    return "%s:%d" % (ip, port)


def _hr_conn_accepted(body):
    """Decode an ID_CONNECTION_REQUEST_ACCEPTED body (249B for the Stormancer
    32-internal-id RakNet build) into named fields rather than opaque hex:

      cacc remote=<ip:port> sysidx=<n> ip0=<ip:port> ... echo=<ms> srv=<ms>

    Layout: remoteSystemAddress(7) + systemIndex(2,BE) + 32*internalAddr(7) +
    echoedClientTime(8,BE) + serverTime(8,BE). Only non-UNASSIGNED internal
    addresses are listed (the rest are 0.0.0.0:0 padding). Returns None when the
    body is not this fixed size, so the caller falls back to hex (nothing hidden)."""
    expect = 7 + 2 + R.MAX_INTERNAL_IDS * 7 + 8 + 8
    if len(body) != expect:
        return None
    off = 0
    remote = _decode_raknet_addr(body[off:off + 7]); off += 7
    sysidx = int.from_bytes(body[off:off + 2], "big"); off += 2
    ips = []
    for k in range(R.MAX_INTERNAL_IDS):
        a = body[off:off + 7]; off += 7
        if a != R.UNASSIGNED_ADDR:
            ips.append("ip%d=%s" % (k, _decode_raknet_addr(a)))
    echo = int.from_bytes(body[off:off + 8], "big"); off += 8
    srv = int.from_bytes(body[off:off + 8], "big"); off += 8
    parts = ["%s remote=%s sysidx=%d" % (
        RT.ONLINE_IDS.get(R.ID_CONNECTION_REQUEST_ACCEPTED, "cacc"),
        remote, sysidx)]
    parts.extend(ips)
    parts.append("echo=%d srv=%d" % (echo, srv))
    return " ".join(parts)


def _hr_control_frame(mid, body):
    """Decode a connected-layer / transport control frame body into named
    fields instead of leaving it as opaque hex. Returns None when this id has no
    structured body (so the caller falls back to literal hex -- nothing hidden).

      ID_CONNECTED_PING  -> 'ping clk=<ms>'              (one BE uint64 clock)
      ID_CONNECTED_PONG  -> 'pong echo=<ms> clk=<ms>'    (two BE uint64 clocks)
      ID_CONNECTION_RESULT -> 'connres connid=<n>'       (one LE uint64 id, the
                              server-assigned connection id; see raknet.py
                              send path `struct.pack("<Q", connection_id)`)
      ID_CONNECTION_REQUEST -> 'creq guid=<hex8> time=<ms> sec=<0/1>' (the client
                              GUID(8) + RakNet::Time(8,BE) + useSecurity(1); see
                              raknet.send_connection_accepted's payload layout)
      ID_CONNECTION_REQUEST_ACCEPTED -> 'cacc remote=.. sysidx=.. ip0=.. echo=..
                              srv=..' (see _hr_conn_accepted)."""
    if mid in (R.ID_CONNECTED_PING, R.ID_CONNECTED_PONG):
        if not body or len(body) % 8 != 0:
            return None
        clocks = [int.from_bytes(body[i:i + 8], "big")
                  for i in range(0, len(body), 8)]
        abbr = _online_abbr(mid)
        if mid == R.ID_CONNECTED_PING:
            return "%s clk=%d" % (abbr, clocks[0])
        labels = ["echo", "clk"]
        fields = " ".join(
            "%s=%d" % (labels[i] if i < len(labels) else "c%d" % i, c)
            for i, c in enumerate(clocks))
        return "%s %s" % (abbr, fields)
    if mid == R.ID_CONNECTION_RESULT and len(body) == 8:
        return "%s connid=%d" % (
            _online_abbr(mid), int.from_bytes(body, "little"))
    if mid == R.ID_CONNECTION_REQUEST and len(body) >= 16:
        guid = body[:8].hex()
        ts = int.from_bytes(body[8:16], "big")
        sec = body[16] if len(body) > 16 else 0
        return "%s guid=%s time=%d sec=%d" % (
            _online_abbr(mid), guid, ts, sec)
    if mid == R.ID_CONNECTION_REQUEST_ACCEPTED:
        return _hr_conn_accepted(body)
    if mid == R.ID_NEW_INCOMING_CONNECTION and len(body) >= 7 + 16:
        # ID_NEW_INCOMING_CONNECTION = serverAddress(7) + N internal addresses
        # (UNINITIALIZED RakNet stack junk -- not meaningful) + sendPingTime(8) +
        # sendPongTime(8). Only the leading address and the trailing two clocks
        # carry information; the middle is shown as an opaque byte count.
        server = _decode_raknet_addr(body[:7])
        ping = int.from_bytes(body[-16:-8], "big")
        pong = int.from_bytes(body[-8:], "big")
        junk = len(body) - 7 - 16
        return "%s server=%s internal=%dB ping=%d pong=%d" % (
            _online_abbr(mid), server, junk, ping, pong)
    return None


def _hr_clock_reply(key, lit):
    """Decode a sping (SyncClock) system-request RPC reply into named clocks.

    The reply body is one or two little-endian uint64 clocks (serverTime then the
    echoed client clock); the matching c2s request renders as `clk=<ms>`. When a
    RESP_MSG body is exactly 8 or 16 raw bytes that did not decode as msgpack,
    `_skel_or_binary` hands back a `{hex,len}` bin dict that `_hr_bin` would
    otherwise render as an opaque (and truncated) `bin16_<first8bytes>`. Render
    the clocks by name instead. Returns None for anything that is not such a
    reply, so the caller falls back to the normal literal render."""
    if not (key[0] == "SYS" and key[1] == "RESP_MSG"):
        return None
    if not (isinstance(lit, dict) and "hex" in lit and "len" in lit
            and lit["len"] in (8, 16)):
        return None
    raw = bytes.fromhex(lit["hex"])
    srv = int.from_bytes(raw[:8], "little")
    if len(raw) == 8:
        return "srv=%d" % srv
    echo = int.from_bytes(raw[8:16], "little")
    return "srv=%d echo=%d" % (srv, echo)


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

    One decoder per peer. Real s2c bursts are fed through `human_msgs("real", ..)`
    and predicted bursts through `human_msgs("pred", ..)` (after `reassemble_msgs`
    turns datagrams into complete messages); both drive the engine's route tables
    so scene messages resolve their route names and the shadow can adopt the real
    server's scene handles."""

    def __init__(self, label):
        self.label = label
        self.eng = R._RelayAssert(label, JD)
        self.eng.split["c2s"] = {}      # add a c2s split-reassembly bucket

    # ---- decode helpers --------------------------------------------------
    def _lenient_lit(self, body):
        """Full-tile msgpack decode that, unlike _skel_or_binary, does NOT
        require a container/string lead byte. Stormancer scene-route DTOs
        legitimately begin with bare version fixints (e.g. the party
        `[ver, 0, ver]` prefix before the member array), which the strict decoder
        rejects to avoid mistaking raw clock blobs for msgpack. Scene messages are
        addressed to LEARNED handles and are never clock blobs, so a lenient
        decode is safe here. Returns a literal list when the body tiles cleanly
        with no ERR and no leftover bytes, else None (caller keeps the hex)."""
        jd = self.eng.jd
        if not body:
            return None
        try:
            vals, i, n = [], 0, len(body)
            while i < n:
                v, i = jd.mp(body, i)
                if isinstance(v, (tuple, list)) and v and v[0] == "ERR":
                    return None
                vals.append(v)
            if i != n:
                return None
            return [self.eng._literal(v) for v in vals]
        except Exception:
            return None

    def _hr_scene_body(self, body, route_abbr):
        """Render a scene-route body, preferring a structural decode. Tries the
        strict _skel_or_binary first; if that fell back to hex, re-attempts a
        lenient full-tile decode (scene DTOs may lead with scalar version bytes).
        Falls back to the hex literal so nothing is ever hidden."""
        lit = self.eng._skel_or_binary(body)
        if isinstance(lit, dict) and "hex" in lit:
            alt = self._lenient_lit(body)
            if alt is not None:
                lit = alt
        return H.hr_payload(lit, route_abbr)

    # ---- client -> server ------------------------------------------------
    def reassemble_c2s(self, dg):
        """Reassemble one client->server datagram into the COMPLETE message
        payloads it produced. Returns an empty list while a split request is
        still only partially received, so a fragmented request is recorded as a
        single atomic message rather than a packet bearing a '<split frag>'
        placeholder. The message -- not the UDP datagram -- is the unit."""
        return self._reassemble_datagrams("c2s", [dg])

    def human_c2s_msgs(self, msgs):
        """Full decode of a list of complete client->server message payloads."""
        parts = []
        for pl in msgs:
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
            if name == "sping" and len(data) >= 8:
                # ID_PING request body is the client's clock (uint64 LE). Render
                # it as a clock rather than letting _skel_or_binary mis-parse the
                # 8 raw bytes as a stray msgpack array.
                return "sysreq sping#%d = clk=%d" % (
                    req, int.from_bytes(data[:8], "little"))
            return "sysreq %s#%d = %s" % (
                name, req, H.hr_payload(eng._skel_or_binary(data), name))
        if mid in _ONLINE_NAMES and len(pl) <= 2:
            return _online_abbr(mid)
        if mid >= RT.SCENE_HANDLE_MIN and len(pl) >= 3:
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
                    kabbr, rabbr, rid, self._hr_scene_body(body[2:], rabbr))
            return "%s/%s = %s" % (
                kabbr, rabbr, self._hr_scene_body(body, rabbr))
        # Transport / connected-layer control frame (or any short id): render the
        # full literal body, never just a length -- nothing is masked.
        body = pl[1:]
        if not body:
            return _online_abbr(mid)
        clk = _hr_control_frame(mid, body)
        if clk is not None:
            return clk
        return "%s = %s" % (
            _online_abbr(mid), H.hr_payload(eng._skel_or_binary(body), None))

    # ---- server -> client ------------------------------------------------
    def reassemble_msgs(self, side, hexes):
        """Convert raw s2c datagram hexes into the list of COMPLETE encapsulated
        message payloads they carry, reassembling split fragments across
        datagrams (and across response windows). The message -- not the UDP
        datagram -- is the atomic unit logged for `side` ('real' or 'pred')."""
        return self._reassemble_datagrams(
            side, [bytes.fromhex(hx) for hx in hexes])

    def human_msgs(self, side, msgs):
        """Full decode of a list of complete s2c message payloads. Drives the
        engine's route learning / handle adoption for `side`."""
        parts = []
        for pl in msgs:
            try:
                key, lit = self.eng._classify(side, pl)
            except Exception as e:
                parts.append(f"<decode-exc {e}>")
                continue
            if key is None:
                # _classify only keys Stormancer sysreq responses and scene
                # messages on a LEARNED handle. Everything else (transport
                # control frames, scene msgs on a handle this side never
                # learned) must STILL be rendered -- skipping them would let a
                # predicted burst collapse to "" and falsely match. Render the
                # full literal so real vs predicted always compare.
                parts.append(self._render_other(side, pl))
                continue
            prefix = _hr_key_prefix(key)
            rabbr = key[2] if key[0] == "SCN" and len(key) > 2 else None
            clk = _hr_clock_reply(key, lit)
            if clk is not None:
                # A sping (SyncClock) RPC reply: render the two little-endian
                # uint64 clocks by name instead of an opaque 16-byte blob (the
                # matching c2s request already decodes as `clk=...`).
                parts.append("%s = %s" % (prefix, clk))
                continue
            if (key[0] == "SCN" and isinstance(lit, dict)
                    and "hex" in lit):
                # Scene DTO that failed strict decode (leads with scalar version
                # bytes): re-attempt a lenient structural decode.
                alt = self._lenient_lit(bytes.fromhex(lit["hex"]))
                if alt is not None:
                    lit = alt
            parts.append("%s = %s" % (
                prefix, H.hr_payload(lit, H.abbr_route(
                    key[1], rabbr) if rabbr else None)))
        return RT.HR_MSG_SEP.join(parts)

    def _render_other(self, side, pl):
        """Full-literal render of a message `_classify` could not key -- nothing
        masked, nothing dropped. Transport/connected-layer control frames render
        as `<abbr> = <literal>`; a scene message addressed to a handle this side
        never learned renders as `scn?/h<handle>/r#<route> = <literal>`. The body
        goes through the same _skel_or_binary path as everything else, so msgpack
        decodes structurally and raw bytes show as `bin<N>_<hex>`."""
        eng = self.eng
        mid = pl[0]
        if mid >= RT.SCENE_HANDLE_MIN and len(pl) >= 3:
            rh = R._rd_u16le(pl, 1)
            body = pl[3:]
            return "scn?/h%d/r#%d = %s" % (
                mid, rh, self._hr_scene_body(body, None))
        abbr = _online_abbr(mid)
        body = pl[1:]
        if not body:
            return abbr
        clk = _hr_control_frame(mid, body)
        if clk is not None:
            return clk
        return "%s = %s" % (abbr, H.hr_payload(eng._skel_or_binary(body), None))

    def _reassemble_datagrams(self, side, dgs):
        """Parse a sequence of datagrams for `side` and return the list of
        complete encapsulated message payloads, reassembling split fragments.
        Incomplete fragments are buffered (in self.eng.split[side]) and emitted
        only once their final fragment arrives -- possibly on a later datagram or
        a later call -- so splitting is invisible to callers."""
        msgs = []
        for dg in dgs:
            try:
                parsed = R.parse_messages_ex(dg, 4)
            except Exception:
                continue
            for m in parsed:
                pl = m["payload"]
                if not pl:
                    continue
                full = self._reassemble(side, m, pl)
                if full is not None:
                    msgs.append(full)
        return msgs

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
    # Each record is a pretty-printed JSON object (one field per line) so real
    # vs predicted bursts can be eyeballed and diffed. Records are concatenated
    # (blank line between) and the long `real`/`pred` hex lists are kept on a
    # single line each to stay scannable; the reader uses raw_decode so the
    # multi-line objects remain machine-parseable.
    text = _format_record(rec)
    _assert_fh.write(text + "\n\n")


def _format_record(rec):
    """Render one transaction as a readable multi-line JSON object: every field
    on its own line (so the *_human_readable strings sit real-above-pred for easy
    diffing), with each value kept on a single line."""
    keys = list(rec.keys())
    lines = ["{"]
    for i, k in enumerate(keys):
        comma = "," if i < len(keys) - 1 else ""
        lines.append("  %s: %s%s" % (
            json.dumps(k), json.dumps(rec[k], default=str), comma))
    lines.append("}")
    return "\n".join(lines)


def _read_records(path):
    """Parse the multi-line concatenated-JSON assert file back into records."""
    with open(path) as fh:
        text = fh.read()
    dec = json.JSONDecoder()
    records = []
    i, n = 0, len(text)
    while i < n:
        while i < n and text[i] in " \t\r\n":
            i += 1
        if i >= n:
            break
        obj, end = dec.raw_decode(text, i)
        records.append(obj)
        i = end
    return records


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
    """Run the FRESH clean-room predictor (predict.py) for one c2s datagram.
    Returns (own, cross): `own` = predicted s2c datagrams (hex) addressed back
    to the triggering client; `cross` = list of (addr, hex) for server-initiated
    pushes the emulator addressed to OTHER peers (e.g. a party broadcast a peer's
    update triggers to every member). The predictor is fully independent of
    raknet.py. `dec` is still used to RENDER the bytes (human_msgs)."""
    out = P.predict(_WORLD, caddr, c2s)
    own, cross = [], []
    for (addr, dg) in out:
        if not _is_content_datagram(dg):
            continue
        if addr == caddr:
            own.append(dg.hex())
        else:
            cross.append((addr, dg.hex()))
    return own, cross


def _finalize(dec, peer, t_iso, sent_msgs, sent_human, reals_hex, preds_hex):
    real_msgs = dec.reassemble_msgs("real", reals_hex)
    pred_msgs = dec.reassemble_msgs("pred", preds_hex)
    real_human = dec.human_msgs("real", real_msgs)
    pred_human = dec.human_msgs("pred", pred_msgs)
    # Field order is chosen for eyeball diffing: the three *_human_readable
    # strings sit together (real directly above pred) so a mismatch is obvious,
    # and the bulky raw hex arrays go last. Every entry in sent/real/pred is one
    # fully-reassembled MESSAGE payload (the atomic protocol unit), never a raw
    # UDP datagram -- splitting/fragmentation is resolved before logging.
    rec = {
        "t": t_iso,
        "peer": peer,
        "match": real_human == pred_human,
        "sent": [m.hex() for m in sent_msgs],
        "sent_human_readable": sent_human,
        "real_human_readable": real_human,
        "pred_human_readable": pred_human,
        "real": [m.hex() for m in real_msgs],
        "pred": [m.hex() for m in pred_msgs],
    }
    _write(rec)
    if not rec["match"]:
        R.log(f"  [sync {peer}] DIFF {sent_human[:80]}")


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
    active = {}     # peer -> dict(t, sent_msgs, sent_human, preds, reals)
    peer_by_addr = {}   # synthetic addr -> peer (for cross-peer push routing)
    pending = {}        # peer -> [hex] cross-peer pushes awaiting that peer's next txn

    def ensure(peer):
        nonlocal nidx
        if peer not in decs:
            decs[peer] = TxnDecoder(peer)
            addrs[peer] = ("10.0.0.%d" % nidx, nidx)
            R._RELAY_ENGINES[addrs[peer]] = decs[peer].eng
            peer_by_addr[addrs[peer]] = peer
            nidx += 1
        return decs[peer], addrs[peer]

    def route_cross(cross):
        """Attribute server-initiated pushes the emulator sent to OTHER peers to
        that peer's open transaction (or buffer for its next one). The emulator
        really transmits these bytes; the single-stream filter used to drop them,
        which understated server-push coverage."""
        for taddr, hx in cross:
            tpeer = peer_by_addr.get(taddr)
            if tpeer is None:
                continue
            ta = active.get(tpeer)
            if ta is not None:
                ta["preds"].append(hx)
            else:
                pending.setdefault(tpeer, []).append(hx)

    def flush(peer):
        a = active.pop(peer, None)
        if a is None:
            return
        dec = decs[peer]
        _finalize(dec, peer, a["t"], a["sent_msgs"], a["sent_human"],
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
                _, cross = _predict(dec, caddr, dg)
                route_cross(cross)
                continue
            msgs = dec.reassemble_c2s(dg)
            if not msgs:
                # A pure split-fragment carrier: no complete client message yet,
                # so this is NOT its own transaction. Advance the predictor and
                # carry any (rare) predictions onto the transaction the
                # completing fragment will open.
                own, cross = _predict(dec, caddr, dg)
                if own:
                    pending.setdefault(peer, []).extend(own)
                route_cross(cross)
                continue
            # A complete client message finalizes the previous transaction
            # (lock-step client) and opens a new one keyed on this atomic message.
            flush(peer)
            _sync_handle_aliases(dec, caddr)
            own, cross = _predict(dec, caddr, dg)
            active[peer] = {
                "t": r["t"],
                "sent_msgs": msgs,
                "sent_human": dec.human_c2s_msgs(msgs),
                "preds": pending.pop(peer, []) + own,
                "reals": [],
            }
            route_cross(cross)
        else:  # s2c
            if not _is_content_datagram(dg):
                continue
            a = active.get(peer)
            if a is not None:
                a["reals"].append(r["hex"])
    # Drain any cross-peer pushes still buffered for a peer that never opened
    # another transaction into a trailing record so they are counted.
    for peer, hxs in list(pending.items()):
        if not hxs:
            continue
        if peer in active:
            active[peer]["preds"].extend(hxs)
        else:
            decs[peer]  # ensure exists
            _finalize(decs[peer], peer, rows[-1]["t"] if rows else "",
                      [], "(trailing cross-peer pushes)", [], list(hxs))
        pending[peer] = []
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
    sendq = {}              # peer label -> queued content c2s datagrams
    peer_by_addr = {}       # client addr -> peer label
    pending = {}            # peer label -> predicted cross-peer pushes

    def ensure_dec(label):
        if label not in decs:
            decs[label] = TxnDecoder(label)
        return decs[label]

    def finalize(label):
        a = active.pop(label, None)
        if a is None:
            return
        _finalize(decs[label], label, a["t"], a["sent_msgs"], a["sent_human"],
                  a["reals"], a["preds"])

    def route_cross(cross):
        for taddr, hx in cross:
            tlabel = peer_by_addr.get(taddr)
            if tlabel is None:
                continue
            ta = active.get(tlabel)
            if ta is not None:
                ta["preds"].append(hx)
            else:
                pending.setdefault(tlabel, []).append(hx)

    def start_next(label):
        if label in active:
            return
        q = sendq.get(label)
        if not q:
            return
        data, caddr, us = q.popleft()
        dec = ensure_dec(label)
        msgs = dec.reassemble_c2s(data)
        try:
            us.send(data)
        except OSError as e:
            R.log(f"  !! upstream send failed: {e}")
        own, cross = _predict(dec, caddr, data)
        route_cross(cross)
        if not msgs:
            # A pure split-fragment carrier: forwarded upstream and fed to the
            # predictor (which buffers it), but it is NOT its own transaction.
            # Carry any rare predictions onto the next one and process the next
            # queued datagram -- the completing fragment -- immediately.
            if own:
                pending.setdefault(label, []).extend(own)
            start_next(label)
            return
        active[label] = {
            "t": datetime.datetime.now().isoformat(),
            "sent_msgs": msgs,
            "sent_human": dec.human_c2s_msgs(msgs),
            "preds": pending.pop(label, []) + own,
            "reals": [],
            "deadline": time.monotonic() + wait_s,
        }

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
                    peer_by_addr[caddr] = label
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
                    if not _is_content_datagram(data):
                        # Handshake/ACK: forward promptly and let the predictor
                        # process it, but don't pace or record it.
                        try:
                            us.send(data)
                        except OSError as e:
                            R.log(f"  !! upstream send failed: {e}")
                        out = P.predict(_WORLD, caddr, data)
                        route_cross([(addr, dg.hex()) for addr, dg in out
                                     if _is_content_datagram(dg) and addr != caddr])
                        continue
                    sendq.setdefault(label, deque()).append((data, caddr, us))
                    start_next(label)
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
                start_next(label)
    finally:
        for label, hxs in list(pending.items()):
            if label in active:
                active[label]["preds"].extend(hxs)
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
    # Decoded sping/SyncClock reply: 'srv=<ms> echo=<ms>'. The absolute server
    # clock is environment-relative; the echoed client clock matches by design.
    if rv.startswith("srv=") and pv.startswith("srv="):
        return "clock"
    # Auth-token response: a decoded JWT (header/payload claims) plus the bare
    # Stormancer session id. The session id, nbf/exp/iat and signature are all
    # per-session identity/clock values that differ every run by design -- not a
    # protocol divergence. Same JWT skeleton on both sides => identity noise.
    if "jwt " in rv and "jwt " in pv:
        return "identity"
    # Same shape, differing only in an opaque/truncated id token => identity.
    if ("~" in rv and "~" in pv) and rv.split()[:1] == pv.split()[:1]:
        return "identity"
    return "genuine"


def summarize_records(records):
    """Compute the honest reqId-correlated verdict from logged transactions."""
    real_by, pred_by = {}, {}
    real_push, pred_push = {}, {}
    txn_total = txn_match = 0
    txn_mismatch_routes = {}
    for r in records:
        txn_total += 1
        if r.get("match"):
            txn_match += 1
        else:
            # Bucket each window-mismatched transaction by the c2s route that
            # triggered it, so the (large) per-record mismatch count is broken
            # down into something actionable rather than just a raw total.
            c2s = r.get("sent_human_readable", "") or "(none)"
            route = c2s.split(" = ", 1)[0].split(RT.HR_MSG_SEP)[0]
            txn_mismatch_routes[route] = txn_mismatch_routes.get(route, 0) + 1
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
        "transactions": {
            "total": txn_total,
            "match": txn_match,
            "mismatch": txn_total - txn_match,
            "mismatch_routes": sorted(
                txn_mismatch_routes.items(), key=lambda kv: -kv[1]),
        },
        "responses": {"same": same, "diff": diffs,
                      "real_only": real_only, "pred_only": pred_only},
        "genuine": genuine, "clock": clock, "identity": identity,
        "push": [(rt, real_push.get(rt, 0), pred_push.get(rt, 0))
                 for rt in push_routes],
        "push_gaps": push_gaps,
    }


def _print_summary(s):
    R.log("")
    R.log("=== sync-raknet verdict ===")
    tx = s["transactions"]
    R.log("  transactions: %d total  %d match  %d MISMATCH (window-based)"
          % (tx["total"], tx["match"], tx["mismatch"]))
    if tx["mismatch_routes"]:
        R.log("  --- window-mismatches by c2s route (route: count) ---")
        for route, cnt in tx["mismatch_routes"]:
            R.log("    %4d  %s" % (cnt, route))
    R.log("")
    R.log("  reqId-correlated (pipelining-corrected, the authoritative verdict):")
    rr = s["responses"]
    R.log("    responses: same=%d  diff=%d  real_only=%d  pred_only=%d"
          % (rr["same"], rr["diff"], rr["real_only"], rr["pred_only"]))
    R.log("    diff breakdown: genuine=%d  clock-noise=%d  identity-noise=%d"
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
    R.log("===========================")


def summarize_file(path):
    """Read a sync_assert file and print + return the honest verdict."""
    records = _read_records(path)
    s = summarize_records(records)
    _print_summary(s)
    return s


# =========================================================================
# PURE EMULATOR BACKEND — drop-in replacement for raknet.py main()
# -------------------------------------------------------------------------
# Bind HOST:PORT and answer clients DIRECTLY from the data-oriented predictor
# (predict.py). No upstream, no real dt-live cluster: this IS the offline
# Stormancer broker partydeck points the game at. Every client datagram is fed
# to P.predict(); the returned outbox is sent straight back (addressed per
# connection, so cross-peer pushes — memberConnected, settingsUpdated, etc. —
# reach the other connected clients too).
# =========================================================================

def serve_main():
    global _WORLD
    _WORLD = P.new_world()
    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    sock.bind((R.HOST, R.PORT))
    R.log(f"sync-raknet emulator listening on {R.HOST}:{R.PORT} "
          f"(data-oriented predict.py backend)")
    try:
        while True:
            data, addr = sock.recvfrom(65535)
            if not data:
                continue
            R.set_peer(addr)
            for out_addr, dg in P.predict(_WORLD, addr, data):
                try:
                    sock.sendto(dg, out_addr)
                except OSError as e:
                    R.log(f"  !! send to {out_addr} failed: {e}")
    finally:
        sock.close()


if __name__ == "__main__":
    replay = os.environ.get("SYNC_REPLAY")
    relay = os.environ.get("RAKNET_RELAY", "0") not in ("0", "", "false", "no")
    try:
        if replay:
            replay_main(replay)        # offline capture replay + verdict
        elif relay:
            live_main()                # live relay + shadow-predict + verdict
        else:
            serve_main()               # pure emulator backend (default)
    except KeyboardInterrupt:
        R.log("sync-raknet stopped")
        sys.exit(0)
