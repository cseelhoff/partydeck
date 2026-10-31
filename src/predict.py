#!/usr/bin/env python3
"""predict.py — clean-room, data-oriented Stormancer/RakNet response predictor.

This is a FRESH reimplementation of the offline broker's response logic, written
to be independent of raknet.py:

  * NO classes. All state is plain dicts (see `new_world`, `_new_conn`,
    `_new_party`, `_new_gs`, `_new_binding`). A "world" holds the conn / party /
    gamesession registries; a "conn" holds one client's reliability + scene
    state; everything is JSON-shaped data you can print and diff.

  * NO if/elif ladders for message processing. Each protocol layer has ONE
    dispatch table mapping an id/name to a small handler function:
        _ONLINE_HANDLERS   online message-id  -> handler
        _SYSREQ_HANDLERS   system-request id  -> handler
        _RPC_HANDLERS      scene route name   -> handler
    Adding/!changing a message = editing one table entry + one short function,
    which is exactly what makes a prediction mismatch easy to localise.

  * The RakNet wire codec (datagram framing, reliability numbering, split) and
    the msgpack encoders are reimplemented locally below, so this module shares
    NO logic with raknet.py. The only imports are the captured byte-exact DATA
    modules (`scenes` = real SceneInfos/ConnectionResult blobs + route maps,
    `stoken` = connection-token bytes); those hold real captured data that
    cannot be re-derived and are not "logic".

Entry point:  predict(world, caddr, datagram) -> [(addr, bytes), ...]
    Feed it one client->server datagram; it mutates `world` and returns every
    server->client datagram the broker would emit (the caller filters to the
    ones addressed back to `caddr`). Build `world` once per session/run with
    `new_world()`.
"""
import os
import json
import time
import uuid
import base64
import struct

import scenes
import stoken

DEBUG = bool(os.environ.get("PREDICT_DEBUG"))


def _log(*a):
    if DEBUG:
        print("[predict]", *a, flush=True)


# steam_friends.json: real captured friends.notification push bodies keyed by the
# subscribing peer's SteamID64. The offline emulator has no live Steam friends
# backend, so we replay these byte-exact when a known peer subscribes (see
# _rpc_friends_subscribe). Pure captured DATA, not logic.
def _load_steam_friends():
    path = os.path.join(os.path.dirname(os.path.abspath(__file__)),
                        "steam_friends.json")
    try:
        with open(path, "r") as f:
            doc = json.load(f)
        return doc.get("friends", {})
    except Exception as e:
        _log("steam_friends.json load failed:", e)
        return {}


_STEAM_FRIENDS = _load_steam_friends()


# =========================================================================
# §A  msgpack encoders  (local, so this module shares no logic with raknet.py)
# =========================================================================
MP_NIL = b"\xc0"
MP_TRUE = b"\xc3"
MP_FALSE = b"\xc2"
MP_EMPTY_MAP = b"\x80"


def mp_str(s):
    b = s.encode("utf-8") if isinstance(s, str) else s
    if len(b) < 32:
        return bytes([0xA0 | len(b)]) + b
    if len(b) < 256:
        return bytes([0xD9, len(b)]) + b
    return bytes([0xDA]) + struct.pack(">H", len(b)) + b


def mp_uint(n):
    if n < 0x80:
        return bytes([n])
    if n < 0x100:
        return bytes([0xCC, n])
    if n < 0x10000:
        return bytes([0xCD]) + struct.pack(">H", n)
    if n < 0x100000000:
        return bytes([0xCE]) + struct.pack(">I", n)
    return bytes([0xCF]) + struct.pack(">Q", n)


def mp_bin(b):
    n = len(b)
    if n < 256:
        return bytes([0xC4, n]) + b
    if n < 0x10000:
        return bytes([0xC5]) + struct.pack(">H", n) + b
    return bytes([0xC6]) + struct.pack(">I", n) + b


def mp_array(items):
    n = len(items)
    if n < 16:
        hdr = bytes([0x90 | n])
    elif n < 0x10000:
        hdr = bytes([0xDC]) + struct.pack(">H", n)
    else:
        hdr = bytes([0xDD]) + struct.pack(">I", n)
    return hdr + b"".join(items)


def mp_map(pairs):
    n = len(pairs)
    hdr = bytes([0x80 | n]) if n < 16 else bytes([0xDE]) + struct.pack(">H", n)
    return hdr + b"".join(k + v for k, v in pairs)


def mp_timestamp(when=None):
    """MessagePack reserved timestamp ext (-1 / 0xFF) in the 8-byte timestamp64
    layout (hi 30 bits nanos, lo 34 bits secs)."""
    if when is None:
        when = time.time()
    secs = int(when)
    nanos = int((when - secs) * 1_000_000_000) & 0x3FFFFFFF
    v = (nanos << 34) | (secs & 0x3FFFFFFFF)
    return b"\xd7\xff" + struct.pack(">Q", v)


def mp_read_str(b, i):
    """Read one msgpack string at offset i -> (value, next_i)."""
    t = b[i]
    if 0xA0 <= t <= 0xBF:
        ln = t & 0x1F
        return b[i + 1:i + 1 + ln].decode("utf-8", "replace"), i + 1 + ln
    if t == 0xD9:
        ln = b[i + 1]
        return b[i + 2:i + 2 + ln].decode("utf-8", "replace"), i + 2 + ln
    if t == 0xDA:
        ln = struct.unpack(">H", b[i + 1:i + 3])[0]
        return b[i + 3:i + 3 + ln].decode("utf-8", "replace"), i + 3 + ln
    return "", i + 1


def mp_read_uint(b):
    """Read a leading msgpack unsigned int (fixint / uint8 / uint16 / uint32)."""
    if not b:
        return None
    t = b[0]
    if t < 0x80:
        return t
    if t == 0xCC and len(b) >= 2:
        return b[1]
    if t == 0xCD and len(b) >= 3:
        return (b[1] << 8) | b[2]
    if t == 0xCE and len(b) >= 5:
        return struct.unpack(">I", b[1:5])[0]
    return None


# =========================================================================
# §B  RakNet wire codec  (local reimplementation)
# =========================================================================
MAGIC = bytes([0x00, 0xFF, 0xFF, 0x00, 0xFE, 0xFE, 0xFE, 0xFE,
               0xFD, 0xFD, 0xFD, 0xFD, 0x12, 0x34, 0x56, 0x78])

# Offline (handshake) ids
ID_UNCONNECTED_PING = 0x01
ID_UNCONNECTED_PING_OPEN_CONN = 0x02
ID_OPEN_CONNECTION_REQUEST_1 = 0x05
ID_OPEN_CONNECTION_REPLY_1 = 0x06
ID_OPEN_CONNECTION_REQUEST_2 = 0x07
ID_OPEN_CONNECTION_REPLY_2 = 0x08
# Connected ("online") ids
ID_CONNECTED_PING = 0x00
ID_CONNECTED_PONG = 0x03
ID_CONNECTION_REQUEST = 0x09
ID_CONNECTION_REQUEST_ACCEPTED = 0x10
ID_NEW_INCOMING_CONNECTION = 0x13
ID_DISCONNECTION_NOTIFICATION = 0x15
# Stormancer transport ids (RakNet user packets, >= 134)
ID_SYSTEM_REQUEST = 134
ID_REQUEST_RESPONSE_MSG = 137
ID_REQUEST_RESPONSE_COMPLETE = 138
ID_REQUEST_RESPONSE_ERROR = 139
ID_CONNECTION_RESULT = 140
ID_SCENES = 141

# System-request msgIds (the byte after ID_SYSTEM_REQUEST)
SR_SET_METADATA = 0
SR_PING = 2
SR_GET_SESSION_TOKEN = 14
SR_SCENE_READY2 = 16
SR_CONNECT_TO_SCENE = 134
SR_DISCONNECT_FROM_SCENE = 135
SR_GET_SCENE_INFOS = 136
SR_NAMES = {0: "ID_SET_METADATA", 2: "ID_PING", 14: "ID_GET_SESSION_TOKEN",
            16: "ID_SCENE_READY2", 134: "ID_CONNECT_TO_SCENE",
            135: "ID_DISCONNECT_FROM_SCENE", 136: "ID_GET_SCENE_INFOS"}

# PacketReliability
UNRELIABLE = 0
UNRELIABLE_SEQUENCED = 1
RELIABLE = 2
RELIABLE_ORDERED = 3
RELIABLE_SEQUENCED = 4

# Stormancer reserved scene RPC route handles + the authenticator scene's MTU/ids
MAX_INTERNAL_IDS = 32
SERVER_PORT = 30100

# serviceType -> scene suffix (real server's mapping, byte-exact from capture)
SERVICE_SCENE = {
    "stormancer.friends": "friends",
    "stormancer.plugins.partyManagement": "party-manager",
    "stormancer.plugins.gamefinder": "matchmaking",
}
SCENE_ID_BASE = "scene:/passtech-live/darktales/live-1-05-00/"
DYN_HANDLE_BASE = 160


def _u24le(n):
    return bytes([n & 0xFF, (n >> 8) & 0xFF, (n >> 16) & 0xFF])


def _rd_u24le(b, off):
    return b[off] | (b[off + 1] << 8) | (b[off + 2] << 16)


def _rd_u16le(b, off):
    return b[off] | (b[off + 1] << 8)


def _encode_address(ip, port):
    parts = [int(x) for x in ip.split(".")]
    return bytes([4]) + bytes((~p) & 0xFF for p in parts) + struct.pack(">H", port)


_UNASSIGNED_ADDR = _encode_address("0.0.0.0", 0)


def _make_message(reliability, payload, reliable_num=None, ordering_index=None,
                  ordering_channel=0, split=None):
    out = bytes([(reliability << 5) | (0x10 if split else 0)])
    out += struct.pack(">H", len(payload) * 8)
    if reliability in (RELIABLE, RELIABLE_ORDERED, RELIABLE_SEQUENCED):
        out += _u24le(reliable_num)
    if reliability in (UNRELIABLE_SEQUENCED, RELIABLE_SEQUENCED, RELIABLE_ORDERED):
        out += _u24le(ordering_index)
        out += bytes([ordering_channel])
    if split:
        count, sid, index = split
        out += struct.pack(">I", count) + struct.pack(">H", sid) + struct.pack(">I", index)
    return out + payload


def _make_data_datagram(seq, message):
    return bytes([0x80]) + _u24le(seq) + message


def _make_ack(seq):
    return bytes([0xC0]) + struct.pack(">H", 1) + bytes([1]) + _u24le(seq)


def _parse_messages_ex(data, off):
    """Parse encapsulated messages -> list of dicts {reliability, payload, split}."""
    out = []
    n = len(data)
    while off + 3 <= n:
        m = data[off]; off += 1
        reliability = (m >> 5) & 0x7
        has_split = (m >> 4) & 0x1
        if reliability >= 8 or off + 2 > n:
            break
        data_bits = (data[off] << 8) | data[off + 1]; off += 2
        if data_bits == 0:
            break
        if reliability in (RELIABLE, RELIABLE_ORDERED, RELIABLE_SEQUENCED):
            if off + 3 > n:
                break
            off += 3
        if reliability in (UNRELIABLE_SEQUENCED, RELIABLE_SEQUENCED):
            off += 3
        if reliability in (UNRELIABLE_SEQUENCED, RELIABLE_SEQUENCED, RELIABLE_ORDERED):
            off += 4
        split = None
        if has_split:
            if off + 10 > n:
                break
            split = (struct.unpack(">I", data[off:off + 4])[0],
                     struct.unpack(">H", data[off + 4:off + 6])[0],
                     struct.unpack(">I", data[off + 6:off + 10])[0])
            off += 10
        nbytes = (data_bits + 7) // 8
        if off + nbytes > n:
            break
        out.append({"reliability": reliability,
                    "payload": data[off:off + nbytes], "split": split})
        off += nbytes
    return out


# =========================================================================
# §C  Scene route data (parsed once from the captured blobs, kept as dicts)
# =========================================================================
def _sr_dict(sr):
    """Flatten a scenes.SceneRoutes (data parser) into a plain dict."""
    return {
        "suffix": sr.suffix,
        "handle": sr.handle,
        "client_recv": sr.client_recv,          # routeName -> server-sends handle
        "server_recv_rev": sr.server_recv_rev,  # client-sends handle -> routeName
        "rpc_next": sr.rpc_next,
        "rpc_completed": sr.rpc_completed,
    }


def _static_routes(handle):
    sr = scenes.routes_for_handle(handle)
    return _sr_dict(sr) if sr is not None else None


# =========================================================================
# §D  World / connection / party / gamesession state factories (all dicts)
# =========================================================================
def new_world():
    """A fresh, empty broker world. One per session/replay run."""
    return {
        "conns": {},          # addr -> conn
        "parties": {},        # party_guid -> party
        "invites": {},        # invite code -> party_guid
        "gamesessions": {},   # gs_guid -> gs
        "server_guid": struct.unpack(">Q", os.urandom(8))[0],
        "clock0": time.time(),
        "_outbox": [],        # transient: (addr, datagram) emitted this call
    }


def _server_clock_ms(world):
    return int((time.time() - world["clock0"]) * 1000)


def _new_conn(world, addr):
    ip, port = addr
    conn = {
        "world": world, "addr": addr, "ip": ip, "port": port,
        "next_datagram": 0, "next_reliable": 0, "next_ordering": {},
        "next_split": 0, "accepted_bytes": None,
        "established": False, "server_ping_sent": False, "conn_result_sent": False,
        "connection_id": 1,
        "user_id": uuid.uuid4().hex, "username": "", "steam_id": None,
        "party_userdata": None, "party_session_id": None, "steam_lobby_id": None,
        "bindings": {},        # SceneHandle -> binding
        "next_handle": DYN_HANDLE_BASE,
        "own_party_guid": None, "in_gamefinder": False,
    }
    world["conns"][addr] = conn
    return conn


def _new_binding(kind, scene_id, routes, ref=None):
    return {
        "kind": kind, "scene_id": scene_id, "routes": routes, "ref": ref,
        "createlobby_req": None, "member_connected_sent": False, "srv_rpc_id": 1,
    }


def _new_party(world, guid, leader):
    party = {
        "guid": guid, "scene_id": SCENE_ID_BASE + "party-" + guid,
        "leader_user_id": leader["user_id"], "members": [leader],
        "invite_code": None, "gs_guid": None,
        "version": 1, "custom_data": "", "settings_broadcast": False,
        "status_seq": 0, "steam_lobby_id": None, "in_merger": False,
        "join_lobby_sent": False, "lobby_joinable_sent": False,
    }
    world["parties"][guid] = party
    return party


def _new_gs(world, guid, party):
    gs = {"guid": guid, "scene_id": SCENE_ID_BASE + guid,
          "party_guid": party["guid"], "members": list(party["members"]),
          "ready": set()}
    world["gamesessions"][guid] = gs
    return gs


def _next_version(party):
    party["version"] += 1
    return party["version"]


def _alloc_ordering(conn, channel):
    d = conn["next_ordering"]
    i = d.get(channel, 0)
    d[channel] = i + 1
    return i


def _alloc_handle(conn):
    h = conn["next_handle"]
    conn["next_handle"] += 1
    return h


def _binding_for(conn, kind, ref):
    for b in conn["bindings"].values():
        if b["kind"] == kind and b["ref"] == ref:
            return b
    return None


def alias_scene_handle(world, caddr, real_handle, pred_handle):
    """Relay/replay helper (NOT used by the live emulator).

    In a relay or capture replay the client follows the REAL backend's scene
    handles, but this emulator allocates its own. Once the test harness has
    correlated a connect's real handle with the handle the emulator returned, it
    calls this to alias the real handle onto the same binding, so the client's
    subsequent scene messages -- addressed to the real handle -- are routed and
    answered. A pure no-op when the handles already match (e.g. static scenes)."""
    conn = world["conns"].get(caddr)
    if conn is None or real_handle == pred_handle:
        return
    binding = conn["bindings"].get(pred_handle)
    if binding is not None and real_handle not in conn["bindings"]:
        conn["bindings"][real_handle] = binding


def _gen_invite_code(world):
    while True:
        code = "%06d" % (struct.unpack("<I", os.urandom(4))[0] % 1000000)
        if code not in world["invites"]:
            return code


def _adopt_party(conn, key, scene_id):
    """Resolve the party for a CONNECT_TO_SCENE on a party scene.

    In a pure emulator the scene's GUID (`key`) equals the GUID our
    createsession minted, so the party is already in the registry. In a relay /
    replay, the client follows the REAL backend's GUIDs (it connected with the
    real token, not ours), so `key` differs from `own_party_guid`. When that
    happens we re-home our own freshly-minted party under the real `key` so all
    subsequent party RPCs (getpartystate2, updatepartyuserdata, ...) resolve and
    the server-pushes fire. No-op when key is already known."""
    world = conn["world"]
    party = world["parties"].get(key)
    if party is not None:
        return party
    own = conn["own_party_guid"]
    if own is not None and own in world["parties"] and own != key:
        party = world["parties"].pop(own)
        party["guid"] = key
        party["scene_id"] = scene_id
        world["parties"][key] = party
        conn["own_party_guid"] = key
        for code, guid in list(world["invites"].items()):
            if guid == own:
                world["invites"][code] = key
        _log("adopted real party GUID %s (was %s)" % (key, own))
        return party
    return None


def _adopt_gamesession(conn, key, scene_id):
    """Resolve the GameSession for a CONNECT_TO_SCENE on a gamesession scene.

    Mirrors `_adopt_party`: in a relay / replay the client follows the REAL
    backend's gamesession GUID (carried in the gamefinder.update match token),
    which differs from the GUID our `_maybe_start_game` minted. Re-home our
    freshly-created gamesession under the real `key` so the subsequent
    GameSession.GetP2PToken resolves and player.update pushes fire to every
    member. No-op when key is already known."""
    world = conn["world"]
    gs = world["gamesessions"].get(key)
    if gs is not None:
        return gs
    party = None
    for p in world["parties"].values():
        if conn in p["members"] and p["gs_guid"] is not None:
            party = p
            break
    pred_guid = party["gs_guid"] if party is not None else None
    if pred_guid and pred_guid in world["gamesessions"] and pred_guid != key:
        gs = world["gamesessions"].pop(pred_guid)
        gs["guid"] = key
        gs["scene_id"] = scene_id
        world["gamesessions"][key] = gs
        party["gs_guid"] = key
        _log("adopted real gamesession %s (was %s)" % (key, pred_guid))
        return gs
    return None


# =========================================================================
# §E  Outgoing-datagram helpers (operate on a conn dict, append to world outbox)
# =========================================================================
def _out(conn, dg):
    conn["world"]["_outbox"].append((conn["addr"], dg))


def _send_reliable(conn, payload, channel=0):
    MAX_FRAG = 1100
    if len(payload) <= MAX_FRAG:
        msg = _make_message(RELIABLE_ORDERED, payload,
                            reliable_num=conn["next_reliable"],
                            ordering_index=_alloc_ordering(conn, channel),
                            ordering_channel=channel)
        conn["next_reliable"] += 1
        _out(conn, _make_data_datagram(conn["next_datagram"], msg))
        conn["next_datagram"] += 1
        return
    sid = conn["next_split"] & 0xFFFF
    conn["next_split"] += 1
    oidx = _alloc_ordering(conn, channel)
    frags = [payload[i:i + MAX_FRAG] for i in range(0, len(payload), MAX_FRAG)]
    for idx, frag in enumerate(frags):
        msg = _make_message(RELIABLE_ORDERED, frag,
                            reliable_num=conn["next_reliable"],
                            ordering_index=oidx, ordering_channel=channel,
                            split=(len(frags), sid, idx))
        conn["next_reliable"] += 1
        _out(conn, _make_data_datagram(conn["next_datagram"], msg))
        conn["next_datagram"] += 1


def _send_unreliable(conn, payload):
    msg = _make_message(UNRELIABLE, payload)
    _out(conn, _make_data_datagram(conn["next_datagram"], msg))
    conn["next_datagram"] += 1


def _send_scene_msg(conn, scene_handle, route, payload):
    _send_reliable(conn, bytes([scene_handle]) + struct.pack("<H", route) + payload)


def _send_response_msg(conn, req_id, payload):
    _send_reliable(conn, bytes([ID_REQUEST_RESPONSE_MSG])
                   + struct.pack("<H", req_id) + payload)


def _send_response_complete(conn, req_id, has_values):
    _send_reliable(conn, bytes([ID_REQUEST_RESPONSE_COMPLETE])
                   + struct.pack("<H", req_id) + bytes([1 if has_values else 0]))


def _send_response_error(conn, req_id, message):
    b = message.encode("utf-8")
    packed = bytes([0xDA]) + struct.pack(">H", len(b)) + b   # msgpack str16
    _send_reliable(conn, bytes([ID_REQUEST_RESPONSE_ERROR])
                   + struct.pack("<H", req_id) + packed)


def _rpc_respond(conn, routes, rpc_req, result=None):
    """Reply to a scene RPC via this scene's rpc.next / rpc.completed handles.
    The completed message's leading byte is 1 only if an rpc.next was sent."""
    sent = result is not None and routes["rpc_next"] is not None
    if sent:
        _send_scene_msg(conn, routes["handle"], routes["rpc_next"],
                        struct.pack("<H", rpc_req) + result)
    _send_scene_msg(conn, routes["handle"], routes["rpc_completed"],
                    (b"\x01" if sent else b"\x00") + struct.pack("<H", rpc_req))


# =========================================================================
# §F  Identity / token byte builders
# =========================================================================
def _b64url(b):
    return base64.urlsafe_b64encode(b).rstrip(b"=").decode("ascii")


def _make_session_jwt():
    sid = _b64url(os.urandom(16))
    hdr = {"alg": "none", "typ": "JWT", "clusterId": "passtech-live"}
    now = int(time.time())
    body = {"Stormancer/sessionId": sid, "nbf": now, "exp": now + 86400,
            "iat": now, "iss": "passtech-live"}
    token = (_b64url(json.dumps(hdr, separators=(",", ":")).encode()) + "."
             + _b64url(json.dumps(body, separators=(",", ":")).encode()) + ".")
    return token, sid


def _mint_scene_token(scene_id):
    cd = stoken.build_connection_data(scene_id=scene_id)
    tok = (base64.b64encode(cd).decode() + "-"
           + base64.b64encode(os.urandom(32)).decode())
    return json.dumps({
        "token": tok,
        "endpoints": {"raknet": [stoken.RAKNET_ENDPOINT]},
        "encryption": {"algorithm": "aes256", "mode": "GCM",
                       "key": base64.b64encode(os.urandom(32)).decode(),
                       "token": base64.b64encode(os.urandom(74)).decode()},
    }, separators=(",", ":"))


def _parse_login_steam_id(conn, args):
    """Extract SteamID64 from the Authentication.Login Steam ticket hex."""
    try:
        pos = args.find(b"14000000")
        if pos < 0:
            return
        end, n = pos, len(args)
        while end < n and args[end:end + 1] in b"0123456789ABCDEFabcdef":
            end += 1
        tic_hex = args[pos:end]
        if len(tic_hex) < 40:
            return
        b = bytes.fromhex(tic_hex.decode("ascii", "ignore")[:len(tic_hex) // 2 * 2])
        if len(b) < 20 or b[0:4] != b"\x14\x00\x00\x00":
            return
        conn["steam_id"] = struct.unpack("<Q", b[12:20])[0]
    except Exception as e:
        _log("login steam-id parse failed:", e)


def _extract_member_userdata(data):
    i = data.find(b'{"RequestedHero')
    if i < 0:
        return None
    depth = 0
    for j in range(i, len(data)):
        c = data[j]
        if c == 0x7B:
            depth += 1
        elif c == 0x7D:
            depth -= 1
            if depth == 0:
                return data[i:j + 1]
    return None


def _extract_settings_customdata(data):
    i = data.find(b'{"InvitationCode')
    if i < 0:
        return None
    depth = 0
    for j in range(i, len(data)):
        c = data[j]
        if c == 0x7B:
            depth += 1
        elif c == 0x7D:
            depth -= 1
            if depth == 0:
                return data[i:j + 1].decode("utf-8", "replace")
    return None


def _member_steam_id(conn):
    ud = conn["party_userdata"] or b"{}"
    try:
        return str(json.loads(ud.decode("utf-8", "replace")).get("m_sSteamUserId", ""))
    except Exception:
        return ""


def _party_data_token(party):
    leader = party["members"][0] if party["members"] else None
    ud = (leader["party_userdata"] if leader else None) or b"{}"
    steam_id = 0
    try:
        steam_id = int(json.loads(ud.decode("utf-8", "replace")).get("m_sSteamUserId", 0))
    except Exception:
        pass
    payload = json.dumps({"PartyId": party["guid"],
                          "LeaderUserId": party["leader_user_id"],
                          "LeaderSteamId": steam_id}, separators=(",", ":"))
    return (base64.b64encode(payload.encode()).decode() + "."
            + base64.b64encode(os.urandom(32)).decode())


# =========================================================================
# §G  DTO byte builders (party member / settings / pushes) — validated bytes
# =========================================================================
def _member_platforms(conn, slot5=MP_NIL):
    return mp_array([mp_array([
        mp_str("steam"), mp_str(conn["user_id"]), mp_str("anonymous"),
        mp_str(_member_steam_id(conn)), slot5, mp_uint(0)])])


def _party_member(conn):
    """Full PartyMember: [userId, 0, userdataBin, sessionId16, platforms, 2]."""
    ud = conn["party_userdata"] or b"{}"
    if conn["party_session_id"] is None:
        conn["party_session_id"] = os.urandom(16)
    return mp_array([
        mp_str(conn["user_id"]), mp_uint(0), mp_bin(ud),
        mp_bin(conn["party_session_id"]), _member_platforms(conn), mp_uint(2)])


def _memberdata_member(conn):
    """Slim member for memberDataUpdated: [userId, userdataBin, platforms, 2]
    (platform slot5 is "" here, not nil)."""
    ud = conn["party_userdata"] or b"{}"
    return mp_array([
        mp_str(conn["user_id"]), mp_bin(ud),
        _member_platforms(conn, slot5=mp_str("")), mp_uint(2)])


def _settings_array(party):
    """8-element party-settings array (shared by getpartystate2 + settingsUpdated).
    Once a match exists: isJoinable=False + serverData partyStatus map."""
    if party["gs_guid"] is not None:
        joinable = MP_FALSE
        server_data = mp_map([
            (mp_str("stormancer.partyStatus"), mp_str("gamesession")),
            (mp_str("stormancer.partyStatus.details"), mp_str(party["gs_guid"]))])
    else:
        joinable = MP_TRUE
        server_data = MP_EMPTY_MAP
    return mp_array([
        mp_str("matchmaking"), mp_str(party["custom_data"]),
        mp_uint(max(1, party["version"] - 2)), MP_FALSE, joinable,
        server_data, mp_str(""), mp_str(party["guid"])])


def _party_state(party):
    members = mp_array([_party_member(m) for m in party["members"]])
    return mp_array([_settings_array(party), mp_str(party["leader_user_id"]),
                     members, mp_uint(party["version"])])


def _merger_status(parties=1):
    players = parties
    details = mp_map([
        (mp_str("nbPartiesByDifficulty"), mp_map([(mp_str("0"), mp_uint(parties))])),
        (mp_str("nbPlayersByDifficulty"), mp_map([(mp_str("0"), mp_uint(players))]))])
    info = mp_map([
        (mp_str("partiesCount"), mp_uint(parties)),
        (mp_str("algorithm"), mp_str("DtPartyMergerAlgorithm")),
        (mp_str("playersCount"), mp_uint(players)),
        (mp_str("details"), details)])
    return mp_array([mp_uint(1), info])


def _gamefinder_match(gs, party, token):
    """Match-found gamefinder.update value = 3 CONCATENATED top values:
    mp_uint(3) + token + gsInfo (NOT a wrapping array)."""
    members = []
    for m in party["members"]:
        ud = m["party_userdata"] or b"{}"
        if m["party_session_id"] is None:
            m["party_session_id"] = os.urandom(16)
        members.append((mp_str(m["user_id"]), mp_array([
            mp_bin(ud), mp_bin(m["party_session_id"]), mp_str(m["user_id"]), MP_NIL])))
    bucket_entry = mp_array([
        mp_str(party["guid"]), mp_map(members), mp_str(party["custom_data"] or "{}"),
        mp_timestamp(), mp_uint(0), mp_str(party["leader_user_id"]), MP_NIL])
    gs_info = mp_array([
        mp_str(gs["guid"]), MP_EMPTY_MAP,
        mp_array([mp_array([mp_str("0"), mp_array([bucket_entry])])])])
    return mp_uint(3) + mp_str(token) + gs_info


# =========================================================================
# §H  Server-initiated pushes
# =========================================================================
def _push_member_connected(target_conn, about_conn, binding, party):
    route = binding["routes"]["client_recv"].get("party.memberConnected")
    if route is None:
        return
    ver = _next_version(party)
    body = struct.pack("<H", ver & 0xFFFF) + mp_uint(ver) + _party_member(about_conn)
    _send_scene_msg(target_conn, binding["routes"]["handle"], route, body)


def _broadcast_settings_updated(party):
    ver = _next_version(party)
    body = struct.pack("<H", ver & 0xFFFF) + mp_uint(ver) + _settings_array(party)
    for m in party["members"]:
        b = _binding_for(m, "party", party["guid"])
        if b is None:
            continue
        route = b["routes"]["client_recv"].get("party.settingsUpdated")
        if route is not None:
            _send_scene_msg(m, b["routes"]["handle"], route, body)


def _broadcast_member_data(party, about_conn):
    ver = _next_version(party)
    body = struct.pack("<H", ver & 0xFFFF) + mp_uint(ver) + _memberdata_member(about_conn)
    for m in party["members"]:
        b = _binding_for(m, "party", party["guid"])
        if b is None:
            continue
        route = b["routes"]["client_recv"].get("party.memberDataUpdated")
        if route is not None:
            _send_scene_msg(m, b["routes"]["handle"], route, body)


def _broadcast_member_status(party, about_conn, status=1):
    ver = _next_version(party)
    party["status_seq"] += 1
    prefix = struct.pack("<H", ver & 0xFFFF) + mp_uint(party["status_seq"])
    entry = mp_array([mp_array([mp_array([
        mp_str(about_conn["user_id"]), mp_uint(status)])])])
    body = prefix + entry
    for m in party["members"]:
        b = _binding_for(m, "party", party["guid"])
        if b is None:
            continue
        route = b["routes"]["client_recv"].get("party.memberStatusUpdated")
        if route is not None:
            _send_scene_msg(m, b["routes"]["handle"], route, body)


def _broadcast_member_disconnected(party, about_conn):
    ver = _next_version(party)
    body = struct.pack("<H", ver & 0xFFFF) + mp_uint(ver) + mp_array([
        mp_str(about_conn["user_id"]), mp_uint(0)])
    for m in party["members"]:
        b = _binding_for(m, "party", party["guid"])
        if b is None:
            continue
        route = b["routes"]["client_recv"].get("party.memberDisconnected")
        if route is not None:
            _send_scene_msg(m, b["routes"]["handle"], route, body)


def _broadcast_player_update(gs, about_conn, status):
    member = mp_array([
        mp_str(about_conn["user_id"]), mp_uint(status), mp_str(""), MP_FALSE])
    for m in gs["members"]:
        b = _binding_for(m, "gamesession", gs["guid"])
        if b is None:
            continue
        route = b["routes"]["client_recv"].get("player.update")
        if route is not None:
            _send_scene_msg(m, b["routes"]["handle"], route, member)


def _send_steam_createlobby(conn, binding):
    routes = binding["routes"]
    route = routes["client_recv"].get("Steam.CreateLobby")
    party = conn["world"]["parties"].get(binding["ref"])
    if route is None or party is None:
        return
    req = binding["srv_rpc_id"]
    binding["srv_rpc_id"] += 1
    binding["createlobby_req"] = req
    args = mp_array([mp_uint(1), mp_uint(4), MP_TRUE,
                     mp_map([(mp_str("partyDataToken"), mp_str(_party_data_token(party)))])])
    _send_scene_msg(conn, routes["handle"], route, struct.pack("<H", req) + args)


def _send_steam_joinlobby(conn, binding, lobby_id):
    routes = binding["routes"]
    route = routes["client_recv"].get("Steam.JoinLobby")
    if route is None:
        return
    req = binding["srv_rpc_id"]
    binding["srv_rpc_id"] += 1
    args = mp_array([mp_uint(lobby_id or 0)])
    _send_scene_msg(conn, routes["handle"], route, struct.pack("<H", req) + args)


def _send_steam_updatelobbyjoinable(conn, binding, lobby_id, joinable):
    routes = binding["routes"]
    route = routes["client_recv"].get("Steam.UpdateLobbyJoinable")
    if route is None:
        return
    req = binding["srv_rpc_id"]
    binding["srv_rpc_id"] += 1
    args = mp_array([mp_uint(lobby_id or 0), MP_TRUE if joinable else MP_FALSE])
    _send_scene_msg(conn, routes["handle"], route, struct.pack("<H", req) + args)


def _on_member_lobby_ready(conn, party):
    """A member's platform lobby exists: announce it to all, tell it about the
    others, then push the initial settingsUpdated snapshot."""
    for m in party["members"]:
        b = _binding_for(m, "party", party["guid"])
        if b is not None:
            _push_member_connected(m, conn, b, party)
    mybind = _binding_for(conn, "party", party["guid"])
    if mybind is not None:
        for m in party["members"]:
            if m is conn:
                continue
            _push_member_connected(conn, m, mybind, party)
    if not party["settings_broadcast"]:
        party["settings_broadcast"] = True
        _broadcast_settings_updated(party)


def _try_party_merge(conn):
    """DtPartyMergerAlgorithm: once >=2 distinct parties are pooled, survivor =
    min-guid party; each joiner is told Steam.JoinLobby the survivor's lobby."""
    world = conn["world"]
    party = world["parties"].get(conn["own_party_guid"])
    if party is None:
        return
    party["in_merger"] = True
    pool = [p for p in world["parties"].values() if p["in_merger"] and p["members"]]
    if len({p["guid"] for p in pool}) < 2:
        return
    survivor = min(pool, key=lambda p: p["guid"])
    if party is survivor or party["join_lobby_sent"]:
        return
    binding = _binding_for(conn, "party", party["guid"])
    if binding is None:
        return
    party["join_lobby_sent"] = True
    _send_steam_joinlobby(conn, binding, survivor["steam_lobby_id"])
    if not survivor["lobby_joinable_sent"] and survivor["members"]:
        leader = survivor["members"][0]
        lb = _binding_for(leader, "party", survivor["guid"])
        if lb is not None:
            survivor["lobby_joinable_sent"] = True
            _send_steam_updatelobbyjoinable(leader, lb, survivor["steam_lobby_id"], False)


def _maybe_start_game(conn, party):
    """If every member readied up, create one GameSession and push the
    match-found gamefinder.update to each, then the in-gamesession settings."""
    world = conn["world"]
    if party["gs_guid"] is not None:
        return
    if not party["members"] or not all(m["in_gamefinder"] for m in party["members"]):
        return
    guid = str(uuid.uuid4())
    gs = _new_gs(world, guid, party)
    party["gs_guid"] = guid
    for m in party["members"]:
        mb = _binding_for(m, "static", SCENE_ID_BASE + "matchmaking")
        if mb is None:
            continue
        route = mb["routes"]["client_recv"].get("gamefinder.update")
        token = _mint_scene_token(gs["scene_id"])
        value = _gamefinder_match(gs, party, token)
        _send_scene_msg(m, mb["routes"]["handle"], route, value)
    _broadcast_settings_updated(party)


# =========================================================================
# §I  Scene-RPC handlers  (dispatch table: route name -> handler)
# -------------------------------------------------------------------------
# Each handler signature is (conn, binding, routes, rpc_req, rest) where:
#   binding  = the conn's scene binding (or None for static fallbacks)
#   routes   = the scene's route dict (handle / client_recv / rpc_next / ...)
#   rpc_req  = the client's RPC request id (echoed in the response)
#   rest     = scene-message body AFTER [sceneHandle][routeHandle] (incl. reqId)
# =========================================================================
def _rpc_login(conn, binding, routes, rpc_req, rest):
    _parse_login_steam_id(conn, rest[2:])
    if conn["steam_id"] is not None:
        platform_ids = mp_map([(mp_str("steam"), mp_str("steam:%d" % conn["steam_id"]))])
    else:
        platform_ids = MP_EMPTY_MAP
    result = (bytes([0x96]) + b"\xc0" + b"\xc3" + mp_str(conn["user_id"])
              + mp_str(conn["username"]) + platform_ids + b"\x80")
    _rpc_respond(conn, routes, rpc_req, result)


def _rpc_get_scene_token(conn, binding, routes, rpc_req, rest):
    svc, i = mp_read_str(rest, 2)
    name, _ = mp_read_str(rest, i)
    suffix = SERVICE_SCENE.get(svc, name or svc)
    scene_id = SCENE_ID_BASE + suffix
    cd = stoken.build_connection_data(scene_id=scene_id)
    token = base64.b64encode(cd).decode() + "-" + base64.b64encode(os.urandom(32)).decode()
    _rpc_respond(conn, routes, rpc_req, mp_str(token))


def _rpc_void(conn, binding, routes, rpc_req, rest):
    _rpc_respond(conn, routes, rpc_req, result=None)


def _rpc_friends_subscribe(conn, binding, routes, rpc_req, rest):
    """Friends.Subscribe is void, but the real server then pushes the peer's
    friends list as friends.notification messages. Offline we have no Steam
    friends backend, so replay the byte-exact captured notifications for this
    SteamID64 from steam_friends.json (empty/absent -> no push, same as before)."""
    _rpc_respond(conn, routes, rpc_req, result=None)
    entry = _STEAM_FRIENDS.get(str(conn["steam_id"])) if conn["steam_id"] else None
    if not entry:
        return
    route = routes["client_recv"].get("friends.notification")
    if route is None:
        return
    for body_hex in entry.get("notifications", []):
        _send_scene_msg(conn, routes["handle"], route, bytes.fromhex(body_hex))


def _rpc_empty_array(conn, binding, routes, rpc_req, rest):
    _rpc_respond(conn, routes, rpc_req, b"\x90")


def _rpc_createsession(conn, binding, routes, rpc_req, rest):
    conn["party_userdata"] = _extract_member_userdata(rest)
    guid = str(uuid.uuid4())
    party = _new_party(conn["world"], guid, conn)
    conn["own_party_guid"] = guid
    _rpc_respond(conn, routes, rpc_req, mp_str(_mint_scene_token(party["scene_id"])))


def _rpc_join_by_code(conn, binding, routes, rpc_req, rest):
    code, _ = mp_read_str(rest, 2)
    world = conn["world"]
    guid = world["invites"].get(code)
    ud = _extract_member_userdata(rest)
    if ud is not None:
        conn["party_userdata"] = ud
    if guid is None or guid not in world["parties"]:
        _rpc_respond(conn, routes, rpc_req, result=None)
        return
    party = world["parties"][guid]
    _rpc_respond(conn, routes, rpc_req, mp_str(_mint_scene_token(party["scene_id"])))


def _rpc_getpartystate2(conn, binding, routes, rpc_req, rest):
    party = conn["world"]["parties"].get(binding["ref"]) if binding else None
    if party is None:
        _rpc_respond(conn, routes, rpc_req, result=None)
    else:
        _rpc_respond(conn, routes, rpc_req, _party_state(party))


def _rpc_create_invite(conn, binding, routes, rpc_req, rest):
    world = conn["world"]
    party = world["parties"].get(binding["ref"]) if binding else None
    if party is None:
        code = _gen_invite_code(world)
    else:
        if party["invite_code"] is None:
            party["invite_code"] = _gen_invite_code(world)
            world["invites"][party["invite_code"]] = party["guid"]
        code = party["invite_code"]
    _rpc_respond(conn, routes, rpc_req, mp_str(code))


def _rpc_update_gamefinder_status(conn, binding, routes, rpc_req, rest):
    status_val = 0
    try:
        if rest[2] in (0x92, 0x91) and len(rest) >= 4:
            status_val = mp_read_uint(rest[3:]) or 0
        else:
            status_val = mp_read_uint(rest[2:]) or 0
    except Exception:
        status_val = 0
    want = status_val != 0
    conn["in_gamefinder"] = want
    party = conn["world"]["parties"].get(binding["ref"]) if binding else None
    _rpc_respond(conn, routes, rpc_req, result=None)
    if party is not None:
        _broadcast_member_status(party, conn, status=1 if want else 0)
        if want:
            _maybe_start_game(conn, party)


def _rpc_update_settings(conn, binding, routes, rpc_req, rest):
    cd = _extract_settings_customdata(rest)
    party = conn["world"]["parties"].get(binding["ref"]) if binding else None
    if cd is not None and party is not None:
        party["custom_data"] = cd
    _rpc_respond(conn, routes, rpc_req, result=None)
    if party is not None:
        _broadcast_settings_updated(party)


def _rpc_update_userdata(conn, binding, routes, rpc_req, rest):
    ud = _extract_member_userdata(rest)
    if ud is not None:
        conn["party_userdata"] = ud
    party = conn["world"]["parties"].get(binding["ref"]) if binding else None
    _rpc_respond(conn, routes, rpc_req, result=None)
    if party is not None:
        _broadcast_member_data(party, conn)


def _rpc_get_merger_status(conn, binding, routes, rpc_req, rest):
    _rpc_respond(conn, routes, rpc_req, _merger_status())
    _try_party_merge(conn)


def _rpc_get_p2p_token(conn, binding, routes, rpc_req, rest):
    _rpc_respond(conn, routes, rpc_req, mp_array([MP_NIL, MP_FALSE, MP_NIL]))
    gs = conn["world"]["gamesessions"].get(binding["ref"]) if binding else None
    if gs is not None:
        gs["ready"].add(conn["user_id"])
        _broadcast_player_update(gs, conn, status=1)


def _rpc_client_reply(conn, binding, routes, rpc_req, rest):
    """A client response to one of OUR server-initiated RPCs (e.g. it confirming
    Steam.CreateLobby). rest = [routeName-already-resolved][rpcReqId...]; here
    `rest` is the full body, rname dispatched. We inspect rpc.next/.completed."""
    rname = routes.get("_reply_rname")
    if (rname == "stormancer.rpc.next" and binding is not None
            and binding["kind"] == "party" and binding["createlobby_req"] is not None
            and len(rest) >= 3):
        next_req = _rd_u16le(rest, 1)
        if next_req == binding["createlobby_req"]:
            p = rest.find(b"\xcf", 3)
            if p >= 0 and p + 9 <= len(rest):
                lobby_id = int.from_bytes(rest[p + 1:p + 9], "big")
                conn["steam_lobby_id"] = lobby_id
                party = conn["world"]["parties"].get(binding["ref"])
                if party is not None:
                    party["steam_lobby_id"] = lobby_id
    if (rname == "stormancer.rpc.completed" and binding is not None
            and binding["kind"] == "party" and binding["createlobby_req"] is not None
            and not binding["member_connected_sent"] and len(rest) >= 3):
        done_req = _rd_u16le(rest, 1)
        if done_req == binding["createlobby_req"]:
            binding["member_connected_sent"] = True
            party = conn["world"]["parties"].get(binding["ref"])
            if party is not None:
                _on_member_lobby_ready(conn, party)


_RPC_HANDLERS = {
    "Authentication.Login": _rpc_login,
    "Locator.GetSceneConnectionToken": _rpc_get_scene_token,
    "UserSession.UpdateUserOptions": _rpc_void,
    "Friends.Subscribe": _rpc_friends_subscribe,
    "Friends.Get": _rpc_empty_array,
    "Friends.GetBlockedList": _rpc_empty_array,
    "partymanagement.createsession": _rpc_createsession,
    "PartyManagement.CreateConnectionTokenFromInvitationCode": _rpc_join_by_code,
    "party.getpartystate2": _rpc_getpartystate2,
    "Party.CreateInvitationCode": _rpc_create_invite,
    "party.updategamefinderplayerstatus": _rpc_update_gamefinder_status,
    "party.updatepartysettings": _rpc_update_settings,
    "party.updatepartyuserdata": _rpc_update_userdata,
    "Party.UpdatePartyUserData2": _rpc_update_userdata,
    "party.promoteleader": _rpc_void,
    "Party.CancelInvitationCode": _rpc_void,
    "party.sendinvitation": _rpc_void,
    "PartyMerging.GetMergerStatus": _rpc_get_merger_status,
    "GameSession.GetP2PToken": _rpc_get_p2p_token,
    "stormancer.rpc.next": _rpc_client_reply,
    "stormancer.rpc.completed": _rpc_client_reply,
    "stormancer.rpc.cancel": _rpc_client_reply,
    "stormancer.rpc.error": _rpc_client_reply,
}


def _on_scene_message(conn, payload):
    scene = payload[0]
    route = _rd_u16le(payload, 1)
    rest = payload[3:]
    binding = conn["bindings"].get(scene)
    routes = binding["routes"] if binding is not None else _static_routes(scene)
    if routes is None:
        return
    rname = routes["server_recv_rev"].get(route, "route#%d" % route)
    rpc_req = _rd_u16le(rest, 0) if len(rest) >= 2 else 0
    handler = _RPC_HANDLERS.get(rname)
    if handler is None:
        _log("scene RPC not implemented:", rname)
        return
    if handler is _rpc_client_reply:
        routes = dict(routes)
        routes["_reply_rname"] = rname
    handler(conn, binding, routes, rpc_req, rest)


# =========================================================================
# §J  System-request handlers  (dispatch table: msgId -> handler)
# -------------------------------------------------------------------------
# Each handler signature is (conn, req_id, data) where data = bytes after the
# [ID_SYSTEM_REQUEST][msgId][reqId:2] header.
# =========================================================================
def _sr_session_token(conn, req_id, data):
    token, sid = _make_session_jwt()
    _send_response_msg(conn, req_id, mp_str(token) + mp_str(sid))
    _send_response_complete(conn, req_id, has_values=True)


def _sr_scene_infos(conn, req_id, data):
    scene_id = scenes.request_scene_id(data)
    kind, key = scenes.classify_scene(scene_id)
    if kind == "static":
        blob = scenes.get_scene_infos(key) or scenes.get_scene_infos("authenticator")
    elif kind == "party":
        blob = scenes.party_infos(key)
    else:
        blob = scenes.gamesession_infos(key)
    _send_response_msg(conn, req_id, blob)
    _send_response_complete(conn, req_id, has_values=True)


def _sr_connect_to_scene(conn, req_id, data):
    scene_id = scenes.request_scene_id(data)
    kind, key = scenes.classify_scene(scene_id)
    if kind == "static":
        blob = scenes.get_connect_result(key) or scenes.get_connect_result("authenticator")
        handle = scenes.scene_handle(blob)
        routes = _static_routes(handle)
        conn["bindings"][handle] = _new_binding("static", scene_id, routes, scene_id)
    elif kind == "party":
        handle = _alloc_handle(conn)
        infos = scenes.party_infos(key)
        blob = scenes.party_connect(key, handle)
        routes = _sr_dict(scenes.SceneRoutes("party", infos, blob))
        conn["bindings"][handle] = _new_binding("party", scene_id, routes, key)
        party = _adopt_party(conn, key, scene_id)
        if party is not None and conn not in party["members"]:
            party["members"].append(conn)
    else:
        handle = _alloc_handle(conn)
        infos = scenes.gamesession_infos(key)
        blob = scenes.gamesession_connect(key, handle)
        routes = _sr_dict(scenes.SceneRoutes("gamesession", infos, blob))
        conn["bindings"][handle] = _new_binding("gamesession", scene_id, routes, key)
        gs = _adopt_gamesession(conn, key, scene_id)
        if gs is not None and conn not in gs["members"]:
            gs["members"].append(conn)
    _send_response_msg(conn, req_id, blob)
    _send_response_complete(conn, req_id, has_values=True)
    if kind == "static" and key == "authenticator":
        gv = routes["client_recv"].get("gameVersion.update")
        if gv is not None:
            _send_scene_msg(conn, handle, gv, mp_str("bot,1.05.*"))


def _sr_ping(conn, req_id, data):
    echo = data[:8] if len(data) >= 8 else b"\x00" * 8
    ref = struct.pack("<Q", _server_clock_ms(conn["world"])) + echo
    _send_response_msg(conn, req_id, ref)
    _send_response_complete(conn, req_id, has_values=True)


def _sr_set_metadata(conn, req_id, data):
    _send_response_complete(conn, req_id, has_values=False)


def _sr_scene_ready2(conn, req_id, data):
    _send_response_msg(conn, req_id, b"\x81\xa1\x76\xc3")  # {"v": true}
    _send_response_complete(conn, req_id, has_values=True)
    ready_handle = scenes.scene_handle(data)
    binding = conn["bindings"].get(ready_handle) if ready_handle else None
    if binding is not None and binding["kind"] == "party":
        _send_steam_createlobby(conn, binding)


def _sr_disconnect_from_scene(conn, req_id, data):
    handle = mp_read_uint(data)
    binding = conn["bindings"].pop(handle, None) if handle is not None else None
    if binding is not None and binding["kind"] == "party":
        party = conn["world"]["parties"].get(binding["ref"])
        if party is not None and conn in party["members"]:
            party["members"].remove(conn)
            if party["members"]:
                _broadcast_member_disconnected(party, conn)
    _send_response_msg(conn, req_id, b"\x81\xa1\x76\xc3")  # {"v": true}
    _send_response_complete(conn, req_id, has_values=True)


_SYSREQ_HANDLERS = {
    SR_GET_SESSION_TOKEN: _sr_session_token,
    SR_GET_SCENE_INFOS: _sr_scene_infos,
    SR_CONNECT_TO_SCENE: _sr_connect_to_scene,
    SR_PING: _sr_ping,
    SR_SET_METADATA: _sr_set_metadata,
    SR_SCENE_READY2: _sr_scene_ready2,
    SR_DISCONNECT_FROM_SCENE: _sr_disconnect_from_scene,
}


def _on_system_request(conn, payload):
    if len(payload) < 4:
        return
    msg_id = payload[1]
    req_id = _rd_u16le(payload, 2)
    data = payload[4:]
    handler = _SYSREQ_HANDLERS.get(msg_id)
    if handler is None:
        name = SR_NAMES.get(msg_id, "0x%02x" % msg_id)
        _send_response_error(conn, req_id, "%s not implemented by offline probe" % name)
        return
    handler(conn, req_id, data)


# =========================================================================
# §K  Online (connected-layer) handlers  (dispatch table: msgId -> handler)
# =========================================================================
def _online_connection_request(conn, seq, payload):
    if conn["accepted_bytes"] is None:
        incoming_ts = payload[9:17] if len(payload) >= 17 else b"\x00" * 8
        body = bytes([ID_CONNECTION_REQUEST_ACCEPTED])
        body += _encode_address(conn["ip"], conn["port"])
        body += struct.pack(">H", 0)
        body += _encode_address("127.0.0.1", SERVER_PORT)
        body += _UNASSIGNED_ADDR * (MAX_INTERNAL_IDS - 1)
        body += incoming_ts
        body += struct.pack(">Q", int(time.time() * 1000))
        msg = _make_message(RELIABLE_ORDERED, body,
                            reliable_num=conn["next_reliable"],
                            ordering_index=_alloc_ordering(conn, 0), ordering_channel=0)
        conn["next_reliable"] += 1
        conn["accepted_bytes"] = _make_data_datagram(conn["next_datagram"], msg)
        conn["next_datagram"] += 1
    _out(conn, conn["accepted_bytes"])


def _online_new_incoming(conn, seq, payload):
    conn["established"] = True
    if not conn["server_ping_sent"]:
        conn["server_ping_sent"] = True
        _send_unreliable(conn, bytes([ID_CONNECTED_PING])
                         + struct.pack(">Q", int(time.time() * 1000)))


def _online_connected_ping(conn, seq, payload):
    ping_ts = payload[1:9] if len(payload) >= 9 else b"\x00" * 8
    _send_unreliable(conn, bytes([ID_CONNECTED_PONG]) + ping_ts
                     + struct.pack(">Q", int(time.time() * 1000)))


def _online_connected_pong(conn, seq, payload):
    if conn["established"] and not conn["conn_result_sent"]:
        conn["conn_result_sent"] = True
        _send_reliable(conn, bytes([ID_CONNECTION_RESULT])
                       + struct.pack("<Q", conn["connection_id"]))


def _online_system_request(conn, seq, payload):
    _on_system_request(conn, payload)


_ONLINE_HANDLERS = {
    ID_CONNECTION_REQUEST: _online_connection_request,
    ID_NEW_INCOMING_CONNECTION: _online_new_incoming,
    ID_CONNECTED_PING: _online_connected_ping,
    ID_CONNECTED_PONG: _online_connected_pong,
    ID_SYSTEM_REQUEST: _online_system_request,
}


def _is_scene_handle(conn, mid):
    return (mid in conn["bindings"] or scenes.known_scene_handle(mid)
            or mid == ID_SCENES)


def _on_connected(conn, data):
    """Connected/online datagram: ACK it, then dispatch each message."""
    flags = data[0]
    if not (flags & 0x80):       # offline
        return
    if flags & 0x60:             # ACK (0x40) or NAK (0x20)
        return
    seq = _rd_u24le(data, 1)
    _out(conn, _make_ack(seq))   # ACK the datagram (filtered out by the caller)
    for m in _parse_messages_ex(data, 4):
        payload = m["payload"]
        if not payload:
            continue
        mid = payload[0]
        handler = _ONLINE_HANDLERS.get(mid)
        if handler is not None:
            handler(conn, seq, payload)
        elif _is_scene_handle(conn, mid):
            _on_scene_message(conn, payload)
        else:
            _log("unknown online id 0x%02x" % mid)


# =========================================================================
# §L  Offline handshake handlers
# =========================================================================
def _on_ocr1(conn, data):
    mtu = min(len(data) + 28, 1492)
    _out(conn, bytes([ID_OPEN_CONNECTION_REPLY_1]) + MAGIC
         + struct.pack(">Q", conn["world"]["server_guid"]) + bytes([0])
         + struct.pack(">H", mtu))


def _on_ocr2(conn, data):
    off = 1 + 16 + 7
    mtu = struct.unpack(">H", data[off:off + 2])[0]
    _out(conn, bytes([ID_OPEN_CONNECTION_REPLY_2]) + MAGIC
         + struct.pack(">Q", conn["world"]["server_guid"])
         + _encode_address(conn["ip"], conn["port"])
         + struct.pack(">H", mtu) + bytes([0]))


# =========================================================================
# §M  Top-level entry point
# =========================================================================
def predict(world, caddr, datagram):
    """Process one client->server datagram against `world`; return the list of
    (addr, bytes) server->client datagrams the broker would emit. The caller
    filters to those addressed back to `caddr`."""
    world["_outbox"] = []
    if not datagram:
        return []
    conn = world["conns"].get(caddr) or _new_conn(world, caddr)
    try:
        mid = datagram[0]
        is_off = len(datagram) >= 17 and datagram[1:17] == MAGIC
        if mid == ID_OPEN_CONNECTION_REQUEST_1 and is_off:
            _on_ocr1(conn, datagram)
        elif mid == ID_OPEN_CONNECTION_REQUEST_2 and is_off:
            _on_ocr2(conn, datagram)
        elif mid in (ID_UNCONNECTED_PING, ID_UNCONNECTED_PING_OPEN_CONN) and is_off:
            pass
        else:
            _on_connected(conn, datagram)
    except Exception as e:
        _log("EXC %s: %s" % (type(e).__name__, e))
    return list(world["_outbox"])
