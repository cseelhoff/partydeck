#!/usr/bin/env python3
"""Offline RakNet server for the self-hosted Stormancer backend (Phase B).

Listens on UDP :30100 (the endpoint our authenticator/token envelope points the
game at). Implements the RakNet "offline" connection handshake so the game stops
retrying MTU discovery and proceeds to the connected/online layer. Every packet
that isn't part of the offline handshake is logged in full hex so we can reverse
the datagram framing + first Stormancer system messages empirically.

RakNet reference: facebookarchive/RakNet (Stormancer fork). All multi-byte
integers in the offline messages are big-endian on the wire (RakNet BitStream
writes them with a host->network swap on little-endian platforms).
"""
import socket
import struct
import os
import sys
import time
import datetime
import base64
import json
import uuid
import select

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import blobs  # captured static SceneInfosDto / ConnectionResult msgpack blobs
import stoken  # connection-token builder (mints per-scene tokens)
import scenes  # per-scene byte-exact SceneInfos/ConnectionResult registry

HOST = "0.0.0.0"
PORT = 30100

# RakNet OFFLINE_MESSAGE_DATA_ID — the 16-byte magic every offline message carries.
MAGIC = bytes([
    0x00, 0xFF, 0xFF, 0x00, 0xFE, 0xFE, 0xFE, 0xFE,
    0xFD, 0xFD, 0xFD, 0xFD, 0x12, 0x34, 0x56, 0x78,
])

# Offline message IDs.
ID_UNCONNECTED_PING            = 0x01
ID_UNCONNECTED_PING_OPEN_CONN  = 0x02
ID_UNCONNECTED_PONG            = 0x1C
ID_OPEN_CONNECTION_REQUEST_1   = 0x05
ID_OPEN_CONNECTION_REPLY_1     = 0x06
ID_OPEN_CONNECTION_REQUEST_2   = 0x07
ID_OPEN_CONNECTION_REPLY_2     = 0x08
ID_CONNECTION_ATTEMPT_FAILED   = 0x11
ID_NO_FREE_INCOMING_CONNECTIONS = 0x14
ID_CONNECTION_BANNED           = 0x17
ID_ALREADY_CONNECTED           = 0x12
ID_IP_RECENTLY_CONNECTED       = 0x1A

# Connected-layer ("online") message IDs (MessageIdentifiers.h order).
ID_CONNECTED_PING              = 0x00
ID_CONNECTED_PONG              = 0x03
ID_CONNECTION_REQUEST          = 0x09
ID_CONNECTION_REQUEST_ACCEPTED = 0x10
ID_NEW_INCOMING_CONNECTION     = 0x13
ID_DISCONNECTION_NOTIFICATION  = 0x15

# Stormancer transport-layer message IDs (MessageIDTypes.ts). These ride on top of
# RakNet as user packets (>= ID_USER_PACKET_ENUM = 134).
ID_SYSTEM_REQUEST          = 134  # 0x86
ID_REQUEST_RESPONSE_MSG    = 137
ID_REQUEST_RESPONSE_COMPLETE = 138
ID_REQUEST_RESPONSE_ERROR  = 139
ID_CONNECTION_RESULT       = 140  # 0x8C  server->client: assigns the connection id
ID_SCENES                  = 141

# SystemRequestIDTypes.ts — the `msgId` byte inside an ID_SYSTEM_REQUEST frame.
SR_SET_METADATA       = 0
SR_SCENE_READY        = 1
SR_PING               = 2
SR_GET_SESSION_TOKEN  = 14   # protocol-3: first request; server replies a session JWT
SR_SCENE_READY2       = 16   # protocol-3: post-connect ack carrying the SceneHandle
SR_CONNECT_TO_SCENE   = 134
SR_DISCONNECT_FROM_SCENE = 135
SR_GET_SCENE_INFOS    = 136
SR_NAMES = {
    0: "ID_SET_METADATA", 1: "ID_SCENE_READY", 2: "ID_PING",
    14: "ID_GET_SESSION_TOKEN", 16: "ID_SCENE_READY2",
    134: "ID_CONNECT_TO_SCENE", 135: "ID_DISCONNECT_FROM_SCENE",
    136: "ID_GET_SCENE_INFOS",
}

# Server clock origin (ms) so ID_PING returns a monotonic-ish reference time.
_CLOCK0 = time.time()
def server_clock_ms() -> int:
    return int((time.time() - _CLOCK0) * 1000)

# PacketReliability enum values.
UNRELIABLE = 0
UNRELIABLE_SEQUENCED = 1
RELIABLE = 2
RELIABLE_ORDERED = 3
RELIABLE_SEQUENCED = 4

# A stable 64-bit server GUID for this process.
SERVER_GUID = struct.unpack(">Q", os.urandom(8))[0]

# Per-(addr) connection state for the connected/online layer.
CONNS = {}

# --- Milestone 2: shared party / matchmaking / gamesession registries --------
# These live at module scope because join-by-code links TWO separate client
# connections: the leader hosts a Party (one per createsession), a joiner looks it
# up by invite code, and when the party readies up the server spins up one shared
# GameSession that both members connect to (after which gameplay is pure EOS P2P).
PARTIES = {}        # party_guid -> Party
INVITE_CODES = {}   # invite code (str) -> party_guid
GAMESESSIONS = {}   # gamesession_guid -> GameSession

# Connections that have polled PartyMerging.GetMergerStatus (i.e. are sitting in
# the game finder waiting to be matched), tracked for visibility/logging. The
# offline merge "completes" -- the server reports partiesCount:0, which is what
# makes the deterministic client leave the matchmaking scene and proceed to the
# gamefinder find-by-code -- once a poller is present AND there are >=2
# established broker connections (host + joiner), the pair a single-machine join
# is meant to match (see the GetMergerStatus handler).
MERGER_POLLERS = set()   # set[id(Conn)]

# Base scene-id prefix (matches the real deployment); per-scene suffix appended.
SCENE_ID_BASE = "scene:/passtech-live/darktales/live-1-05-00/"

# Dynamic scene handles start above the static baked ones (141..145) so a single
# client can hold its own party + a joined party + a gamesession without clashing.
DYN_HANDLE_BASE = 160


class Party:
    """A party hosted by a leader connection. Other connections join by code."""
    def __init__(self, guid, leader):
        self.guid = guid
        self.scene_id = SCENE_ID_BASE + "party-" + guid
        self.leader_user_id = leader.user_id
        self.members = [leader]          # list[Conn] in join order (leader first)
        self.invite_code = None
        self.gs_guid = None              # set once a GameSession is spun up
        # --- event-sourced party state (server-authoritative) ---
        # The retail party client is a reducer over a versioned event stream: it
        # only treats the party as "synchronized" (a precondition for the
        # join-by-code coroutine) once it has applied the settingsUpdated /
        # memberDataUpdated notifications the server pushes. `version` is the
        # monotonic party-state version carried in every push (and getpartystate2);
        # `custom_data` is the settings customData JSON the client last set.
        self.version = 1                 # 1 = party created; ++ on each event
        self.custom_data = ""            # settings customData JSON string
        self.settings_broadcast = False  # initial settingsUpdated pushed yet?
        self.status_seq = 0              # memberStatusUpdated sub-counter

    def add_member(self, conn):
        if conn not in self.members:
            self.members.append(conn)

    def next_version(self):
        self.version += 1
        return self.version


class GameSession:
    """One shared game session created when a party readies up to play."""
    def __init__(self, guid, party):
        self.guid = guid
        self.scene_id = SCENE_ID_BASE + guid
        self.party_guid = party.guid
        self.members = list(party.members)
        self.ready = set()               # user_ids that invoked GetP2PToken


class SceneBinding:
    """A scene this connection is attached to: its routes (with the per-conn
    SceneHandle) plus optional party/gamesession back-reference."""
    def __init__(self, kind, scene_id, sr, ref=None):
        self.kind = kind                 # 'static' | 'party' | 'gamesession'
        self.scene_id = scene_id
        self.sr = sr                     # scenes.SceneRoutes (handle patched)
        self.ref = ref                   # party_guid / gamesession_guid
        self.createlobby_req = None      # outstanding Steam.CreateLobby reqId
        self.member_connected_sent = False


def gen_invite_code():
    """A unique 6-digit invite code not currently in use."""
    while True:
        code = f"{struct.unpack('<I', os.urandom(4))[0] % 1000000:06d}"
        if code not in INVITE_CODES:
            return code


class Conn:
    """Reliability-layer state for one connected client (keyed by UDP addr)."""
    def __init__(self, ip, port):
        self.ip = ip
        self.port = port
        self.next_datagram = 0      # our outgoing datagram sequence number
        self.next_reliable = 0      # our outgoing reliableMessageNumber
        self.next_ordering = {}     # orderingChannel -> next orderingIndex
        self.accepted_bytes = None  # cached ID_CONNECTION_REQUEST_ACCEPTED datagram
        self.established = False     # got ID_NEW_INCOMING_CONNECTION back
        self.server_ping_sent = False  # sent our own RakNet ID_CONNECTED_PING
        self.conn_result_sent = False  # sent Stormancer ID_CONNECTION_RESULT
        self.next_split = 0         # our outgoing splitPacketId counter
        self.connection_id = 1      # the id we hand the client
        # --- offline party/session identity (Phase 2 / Milestone 2) ---
        # Unique Stormancer user id per connection (32-hex, matches real format),
        # finalized/echoed at login so this client's party-member id is stable.
        self.user_id = uuid.uuid4().hex
        self.username = ""           # real authenticator returns empty Username
        self.steam_id = None         # SteamID64, parsed from the login ticket
        self.party_userdata = None  # member userdata JSON bytes from createsession
        self.srv_rpc_id = 1000      # server-initiated RPC request-id counter
        self.party_session_id = None  # stable 16-byte session id for our member
        # --- Milestone 2 per-conn scene + matchmaking state ---
        self.scene_bindings = {}    # SceneHandle -> SceneBinding
        self.next_handle = DYN_HANDLE_BASE
        self.own_party_guid = None  # the party this conn created (createsession)
        self.in_gamefinder = False  # readied up to play (updategamefinderplayerstatus)

    def alloc_ordering(self, channel):
        idx = self.next_ordering.get(channel, 0)
        self.next_ordering[channel] = idx + 1
        return idx

    def alloc_handle(self):
        h = self.next_handle
        self.next_handle += 1
        return h

    def binding_for(self, kind, ref):
        for b in self.scene_bindings.values():
            if b.kind == kind and b.ref == ref:
                return b
        return None

_lf = open("/tmp/pdlog/probe/raknet.log", "a", buffering=1)
# Per-connection tagging: the recv loop is single-threaded and processes one
# datagram fully before reading the next, so a module-global "current peer"
# set once per datagram correctly attributes every log line emitted while
# handling it. Each RakNet connection (source addr) gets a stable label
# C1, C2, ... so a single scene exchange can be traced with `grep '[C2:'`.
CURRENT_PEER = ""
_PEER_LABELS = {}
def set_peer(addr):
    """Assign a stable short label per source addr and make it the current peer."""
    global CURRENT_PEER
    lbl = _PEER_LABELS.get(addr)
    if lbl is None:
        lbl = f"C{len(_PEER_LABELS) + 1}"
        _PEER_LABELS[addr] = lbl
        mapping = f"# PEER {lbl} = {addr[0]}:{addr[1]}"
        print(mapping, flush=True)
        _lf.write(mapping + "\n")
    CURRENT_PEER = f"[{lbl}:{addr[1]}]"
    return lbl
def log(*a):
    line = (datetime.datetime.now().strftime("%H:%M:%S.%f")[:-3] + " "
            + (CURRENT_PEER + " " if CURRENT_PEER else "")
            + " ".join(str(x) for x in a))
    print(line, flush=True)
    _lf.write(line + "\n")

def hexdump(b, limit=64):
    h = b[:limit].hex()
    pairs = " ".join(h[i:i+2] for i in range(0, len(h), 2))
    more = "" if len(b) <= limit else f" ...(+{len(b)-limit}B)"
    return pairs + more


def encode_address(ip: str, port: int) -> bytes:
    """RakNet IPv4 SystemAddress: version(1) + complemented IPv4(4) + port(2,BE)."""
    parts = [int(x) for x in ip.split(".")]
    return bytes([4]) + bytes((~p) & 0xFF for p in parts) + struct.pack(">H", port)


# UNASSIGNED_SYSTEM_ADDRESS serialized for IPv4 (0.0.0.0:0 -> ~ip = ff ff ff ff).
UNASSIGNED_ADDR = encode_address("0.0.0.0", 0)
# The Stormancer RakNet build overrides MAXIMUM_NUMBER_OF_INTERNAL_IDS to 32 (the
# stock default is 10). The CLIENT uses the same constant to parse
# ID_CONNECTION_REQUEST_ACCEPTED, reading exactly this many internal addresses
# before the two ping/pong timestamps. A real capture's ACCEPTED is 250 bytes =
# 1 + 7 + 2 + 7*32 + 8 + 8, confirming 32 slots. Sending only 10 makes the client
# consume our timestamps as bogus addresses, corrupting its connection clock so
# the transport-ready callback (which fires the first system request) never runs.
MAX_INTERNAL_IDS = 32


def u24le(n: int) -> bytes:
    return bytes([n & 0xFF, (n >> 8) & 0xFF, (n >> 16) & 0xFF])


def rd_u24le(b: bytes, off: int) -> int:
    return b[off] | (b[off + 1] << 8) | (b[off + 2] << 16)


def make_message(reliability: int, payload: bytes, reliable_num=None,
                 ordering_index=None, ordering_channel=0, split=None) -> bytes:
    """Encapsulate one application payload (WriteToBitStreamFromInternalPacket).

    Sub-byte fields (reliability 3 bits + split 1 bit) sit at the top of the
    first byte, then everything is byte-aligned, so we can build bytes directly.
    `split`, if set, is (count, id, index) for a split-packet fragment.
    """
    out = bytes([(reliability << 5) | (0x10 if split else 0)])
    out += struct.pack(">H", len(payload) * 8)              # dataBitLength, BE
    if reliability in (RELIABLE, RELIABLE_ORDERED, RELIABLE_SEQUENCED):
        out += u24le(reliable_num)                          # reliableMessageNumber
    if reliability in (UNRELIABLE_SEQUENCED, RELIABLE_SEQUENCED,
                       RELIABLE_ORDERED):
        out += u24le(ordering_index)                        # orderingIndex
        out += bytes([ordering_channel])                    # orderingChannel
    if split:
        count, sid, index = split
        out += struct.pack(">I", count)                     # splitPacketCount
        out += struct.pack(">H", sid)                       # splitPacketId
        out += struct.pack(">I", index)                     # splitPacketIndex
    out += payload
    return out


def make_data_datagram(seq: int, message: bytes) -> bytes:
    """Wrap an encapsulated message in a data datagram (flags 0x80 + uint24 seq)."""
    return bytes([0x80]) + u24le(seq) + message


def make_ack(seq: int) -> bytes:
    """ACK datagram for a single received datagram seq number."""
    # flags 0xC0 (isValid+isACK, hasBAndAS=0) + count(BE u16)=1 + maxEqMin(1) + min uint24 LE
    return bytes([0xC0]) + struct.pack(">H", 1) + bytes([1]) + u24le(seq)


def parse_messages(data: bytes, off: int):
    """Yield (reliability, reliable_num, payload) for each encapsulated message
    starting at byte offset `off` (already past the datagram header)."""
    msgs = []
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
        reliable_num = None
        if reliability in (RELIABLE, RELIABLE_ORDERED, RELIABLE_SEQUENCED):
            if off + 3 > n:
                break
            reliable_num = rd_u24le(data, off); off += 3
        if reliability in (UNRELIABLE_SEQUENCED, RELIABLE_SEQUENCED):
            off += 3                                         # sequencingIndex
        if reliability in (UNRELIABLE_SEQUENCED, RELIABLE_SEQUENCED,
                           RELIABLE_ORDERED):
            off += 3                                         # orderingIndex
            off += 1                                         # orderingChannel
        if has_split:
            off += 10                                        # count(4)+id(2)+index(4)
        nbytes = (data_bits + 7) // 8
        if off + nbytes > n:
            break
        payload = data[off:off + nbytes]; off += nbytes
        msgs.append((reliability, reliable_num, payload))
    return msgs


def parse_messages_ex(data: bytes, off: int):
    """Like parse_messages but also surfaces split-packet metadata so callers can
    reassemble fragmented messages. Yields dicts with keys:
    reliability, reliable_num, payload, split (None or (count, id, index))."""
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
        reliable_num = None
        if reliability in (RELIABLE, RELIABLE_ORDERED, RELIABLE_SEQUENCED):
            if off + 3 > n:
                break
            reliable_num = rd_u24le(data, off); off += 3
        if reliability in (UNRELIABLE_SEQUENCED, RELIABLE_SEQUENCED):
            off += 3                                         # sequencingIndex
        if reliability in (UNRELIABLE_SEQUENCED, RELIABLE_SEQUENCED,
                           RELIABLE_ORDERED):
            off += 3                                         # orderingIndex
            off += 1                                         # orderingChannel
        split = None
        if has_split:
            if off + 10 > n:
                break
            count = struct.unpack(">I", data[off:off + 4])[0]
            sid = struct.unpack(">H", data[off + 4:off + 6])[0]
            index = struct.unpack(">I", data[off + 6:off + 10])[0]
            split = (count, sid, index)
            off += 10
        nbytes = (data_bits + 7) // 8
        if off + nbytes > n:
            break
        payload = data[off:off + nbytes]; off += nbytes
        out.append({"reliability": reliability, "reliable_num": reliable_num,
                    "payload": payload, "split": split})
    return out


def send_connection_accepted(sock, conn, payload):
    """Reply to ID_CONNECTION_REQUEST with ID_CONNECTION_REQUEST_ACCEPTED."""
    if conn.accepted_bytes is None:
        # payload = 0x09 + clientGUID(8) + RakNet::Time ts(8) + useSecurity(1)
        incoming_ts = payload[9:17] if len(payload) >= 17 else b"\x00" * 8
        body = bytes([ID_CONNECTION_REQUEST_ACCEPTED])
        body += encode_address(conn.ip, conn.port)           # remoteSystemAddress
        body += struct.pack(">H", 0)                         # systemIndex = 0
        body += encode_address("127.0.0.1", PORT)            # ipList[0]
        body += UNASSIGNED_ADDR * (MAX_INTERNAL_IDS - 1)     # ipList[1..9]
        body += incoming_ts                                  # echo client timestamp
        body += struct.pack(">Q", int(time.time() * 1000))   # server time
        msg = make_message(RELIABLE_ORDERED, body,
                           reliable_num=conn.next_reliable,
                           ordering_index=conn.alloc_ordering(0),
                           ordering_channel=0)
        conn.next_reliable += 1
        conn.accepted_bytes = make_data_datagram(conn.next_datagram, msg)
        conn.next_datagram += 1
        log(f"  <- ID_CONNECTION_REQUEST_ACCEPTED ({len(conn.accepted_bytes)}B) "
            f"to {conn.ip}:{conn.port}")
    sock.sendto(conn.accepted_bytes, (conn.ip, conn.port))


def send_reliable(sock, conn, payload, ordered=True, channel=0):
    """Send one application payload as a reliable (ordered) RakNet message,
    splitting it across multiple datagrams if it exceeds the MTU. A split
    message shares one orderingIndex + splitPacketId; each fragment gets its own
    reliableMessageNumber and datagram (as the real server does)."""
    MAX_FRAG = 1100  # fragment data size that fits inside the negotiated MTU
    if len(payload) <= MAX_FRAG:
        if ordered:
            msg = make_message(RELIABLE_ORDERED, payload,
                               reliable_num=conn.next_reliable,
                               ordering_index=conn.alloc_ordering(channel),
                               ordering_channel=channel)
        else:
            msg = make_message(RELIABLE, payload, reliable_num=conn.next_reliable)
        conn.next_reliable += 1
        dg = make_data_datagram(conn.next_datagram, msg)
        conn.next_datagram += 1
        sock.sendto(dg, (conn.ip, conn.port))
        return dg
    # Split into fragments sharing one orderingIndex + splitPacketId.
    sid = conn.next_split & 0xFFFF
    conn.next_split += 1
    oidx = conn.alloc_ordering(channel)
    frags = [payload[i:i + MAX_FRAG] for i in range(0, len(payload), MAX_FRAG)]
    for idx, frag in enumerate(frags):
        msg = make_message(RELIABLE_ORDERED, frag,
                           reliable_num=conn.next_reliable,
                           ordering_index=oidx, ordering_channel=channel,
                           split=(len(frags), sid, idx))
        conn.next_reliable += 1
        dg = make_data_datagram(conn.next_datagram, msg)
        conn.next_datagram += 1
        sock.sendto(dg, (conn.ip, conn.port))
    return None


def send_connection_result(sock, conn):
    """Stormancer transport handshake: tell the client its connection id so its
    transport.connect() promise resolves and it proceeds to the system requests."""
    if conn.conn_result_sent:
        return
    conn.conn_result_sent = True
    payload = bytes([ID_CONNECTION_RESULT]) + struct.pack("<Q", conn.connection_id)
    send_reliable(sock, conn, payload)
    log(f"  <- ID_CONNECTION_RESULT id={conn.connection_id} to {conn.ip}:{conn.port}")


def send_server_ping(sock, conn):
    """Send our own RakNet ID_CONNECTED_PING (unreliable). The real server does
    this right after the connection is established; the C++ client appears to
    gate its transport-ready callback (and thus the first system request) on the
    RakNet clock sync that this ping/pong round trip provides."""
    if conn.server_ping_sent:
        return
    conn.server_ping_sent = True
    ping = bytes([ID_CONNECTED_PING]) + struct.pack(">Q", int(time.time() * 1000))
    msg = make_message(UNRELIABLE, ping)
    sock.sendto(make_data_datagram(conn.next_datagram, msg), (conn.ip, conn.port))
    conn.next_datagram += 1
    log(f"  <- ID_CONNECTED_PING (server-initiated) to {conn.ip}:{conn.port}")


def b64url(b: bytes) -> str:
    return base64.urlsafe_b64encode(b).rstrip(b"=").decode("ascii")


def make_session_jwt():
    """Mint an alg=none session JWT shaped like the real authenticator's reply.
    Returns (token, sessionId). We are the whole backend, so the signature is
    irrelevant; the client just stores these and echoes them to scenes."""
    sid = b64url(os.urandom(16))                     # ~22 url-safe chars
    hdr = {"alg": "none", "typ": "JWT", "clusterId": "passtech-live"}
    now = int(time.time())
    body = {"Stormancer/sessionId": sid, "nbf": now, "exp": now + 86400,
            "iat": now, "iss": "passtech-live"}
    token = (b64url(json.dumps(hdr, separators=(",", ":")).encode())
             + "." + b64url(json.dumps(body, separators=(",", ":")).encode()) + ".")
    return token, sid


def mp_str(s) -> bytes:
    """Encode a Python str/bytes as a msgpack string."""
    b = s.encode("utf-8") if isinstance(s, str) else s
    if len(b) < 32:
        return bytes([0xA0 | len(b)]) + b
    if len(b) < 256:
        return bytes([0xD9, len(b)]) + b
    return bytes([0xDA]) + struct.pack(">H", len(b)) + b


# --- minimal msgpack encoders for building DTOs (PartyState etc.) -------------
MP_NIL = b"\xc0"
MP_TRUE = b"\xc3"
MP_FALSE = b"\xc2"
MP_EMPTY_MAP = b"\x80"


def mp_uint(n) -> bytes:
    if n < 0x80:
        return bytes([n])
    if n < 0x100:
        return bytes([0xCC, n])
    if n < 0x10000:
        return bytes([0xCD]) + struct.pack(">H", n)
    if n < 0x100000000:
        return bytes([0xCE]) + struct.pack(">I", n)
    return bytes([0xCF]) + struct.pack(">Q", n)


def mp_bin(b: bytes) -> bytes:
    n = len(b)
    if n < 256:
        return bytes([0xC4, n]) + b
    if n < 0x10000:
        return bytes([0xC5]) + struct.pack(">H", n) + b
    return bytes([0xC6]) + struct.pack(">I", n) + b


def mp_array(items) -> bytes:
    """Encode a list of already-encoded msgpack byte chunks as an array."""
    n = len(items)
    if n < 16:
        hdr = bytes([0x90 | n])
    elif n < 0x10000:
        hdr = bytes([0xDC]) + struct.pack(">H", n)
    else:
        hdr = bytes([0xDD]) + struct.pack(">I", n)
    return hdr + b"".join(items)


def mp_map(pairs) -> bytes:
    """Encode a list of (keyBytes, valueBytes) already-encoded pairs as a map."""
    n = len(pairs)
    if n < 16:
        hdr = bytes([0x80 | n])
    else:
        hdr = bytes([0xDE]) + struct.pack(">H", n)
    return hdr + b"".join(k + v for k, v in pairs)


# Stormancer RPC reserved-route handles, as assigned by the CLIENT in its
# CONNECT_TO_SCENE "Routes" list (confirmed in relay capture):
#   stormancer.rpc.completed -> 1, stormancer.rpc.next -> 2.
# The server delivers an RPC result on route 2 (next) then closes it on route 1
# (completed). The client invokes an RPC by sending on the *procedure* route
# (login = handle 6 on the authenticator scene) with [reqId u16][msgpack args].
RPC_NEXT = 2
RPC_COMPLETED = 1
ROUTE_LOGIN = 6  # authenticator "login" procedure route handle (client->server)
# Authenticator-scene procedure routes the client invokes after login (handles
# come from the SceneInfosDto route list we replay; confirmed by decoding
# blobs.SCENE_INFOS_AUTH Name->Handle map):
ROUTE_GET_SCENE_TOKEN = 19  # Locator.GetSceneConnectionToken(serviceType, name) -> str
ROUTE_UPDATE_USEROPTS = 15  # UserSession.UpdateUserOptions(key, content) -> void

# serviceType -> scene id we hand back in the connection token. We are the whole
# backend, so any consistent id works as long as our GET_SCENE_INFOS /
# CONNECT_TO_SCENE handlers answer for the same id later. (SCENE_ID_BASE is
# defined once near the registries at module top.)

# The real server maps the client's serviceType to a DIFFERENT scene name (decoded
# byte-exact from the real capture's connection tokens): e.g. serviceType
# "stormancer.friends" -> scene "friends". If we mint a token whose SceneId is the
# raw serviceType, our scene registry can't find the right SceneInfos and friends
# fails with "Dependency not found". Map serviceType -> scene suffix here.
SERVICE_SCENE = {
    "stormancer.friends": "friends",
    "stormancer.plugins.partyManagement": "party-manager",
    "stormancer.plugins.gamefinder": "matchmaking",
}


def mp_read_str(b, i):
    """Read one msgpack string starting at offset i; return (value, next_i)."""
    t = b[i]
    if 0xA0 <= t <= 0xBF:
        ln = t & 0x1F; return b[i+1:i+1+ln].decode("utf-8", "replace"), i+1+ln
    if t == 0xD9:
        ln = b[i+1]; return b[i+2:i+2+ln].decode("utf-8", "replace"), i+2+ln
    if t == 0xDA:
        ln = struct.unpack(">H", b[i+1:i+3])[0]
        return b[i+3:i+3+ln].decode("utf-8", "replace"), i+3+ln
    return "", i+1


def mp_read_uint(b):
    """Read a leading msgpack unsigned int (fixint / uint8 / uint16 / uint32).

    Used to decode the SceneHandle argument carried by DISCONNECT_FROM_SCENE. In
    the real joiner capture that argument was the bytes `cc 90` = msgpack uint8
    0x90 (the handle of the game-finder scene the client was leaving)."""
    if not b:
        return None
    t = b[0]
    if t < 0x80:                       # positive fixint (0..127)
        return t
    if t == 0xCC and len(b) >= 2:      # uint8
        return b[1]
    if t == 0xCD and len(b) >= 3:      # uint16 (big-endian)
        return (b[1] << 8) | b[2]
    if t == 0xCE and len(b) >= 5:      # uint32 (big-endian)
        return struct.unpack(">I", b[1:5])[0]
    return None


def send_scene_msg(sock, conn, scene_handle, route, payload):
    """Send a Stormancer scene message: [sceneHandle:1][routeHandle:2 LE][payload]."""
    body = bytes([scene_handle]) + struct.pack("<H", route) + payload
    send_reliable(sock, conn, body)


def rpc_respond(sock, conn, sr, rpc_req, result=None):
    """Reply to a scene RPC using this scene's own rpc.next / rpc.completed
    handles (they differ per scene). optional rpc.next(result) then rpc.completed.
    result=None means a void return (rpc.completed only)."""
    if result is not None and sr.rpc_next is not None:
        send_scene_msg(sock, conn, sr.handle, sr.rpc_next,
                       struct.pack("<H", rpc_req) + result)
    send_scene_msg(sock, conn, sr.handle, sr.rpc_completed,
                   b"\x01" + struct.pack("<H", rpc_req))


def _extract_member_userdata(data):
    """Pull the member-userdata JSON object bytes (built by the client) out of a
    createsession request body. It's a msgpack bin holding
    {"RequestedHero":...,"PlayerName":...,"m_sSteamUserId":...,...}."""
    i = data.find(b'{"RequestedHero')
    if i < 0:
        return None
    depth = 0
    for j in range(i, len(data)):
        c = data[j]
        if c == 0x7B:           # '{'
            depth += 1
        elif c == 0x7D:         # '}'
            depth -= 1
            if depth == 0:
                return data[i:j + 1]
    return None


def _extract_settings_customdata(data):
    """Pull the settings customData JSON string out of a party.updatepartysettings
    request body. The client sends a settings array whose 2nd element is the
    customData JSON object {"InvitationCode":...,"GameMode":...,...}."""
    i = data.find(b'{"InvitationCode')
    if i < 0:
        return None
    depth = 0
    for j in range(i, len(data)):
        c = data[j]
        if c == 0x7B:           # '{'
            depth += 1
        elif c == 0x7D:         # '}'
            depth -= 1
            if depth == 0:
                return data[i:j + 1].decode("utf-8", "replace")
    return None


def party_data_token(party):
    """Build the partyDataToken (b64(json).b64(sig)) embedded in Steam.CreateLobby.
    Other clients decode this to resolve the party. JSON =
    {"PartyId":guid,"LeaderUserId":userId,"LeaderSteamId":steamId(number)}."""
    leader = party.members[0] if party.members else None
    ud = (leader.party_userdata if leader else None) or b"{}"
    steam_id = 0
    try:
        steam_id = int(json.loads(ud.decode("utf-8", "replace")).get("m_sSteamUserId", 0))
    except Exception:
        pass
    payload = json.dumps({"PartyId": party.guid, "LeaderUserId": party.leader_user_id,
                          "LeaderSteamId": steam_id}, separators=(",", ":"))
    return (base64.b64encode(payload.encode()).decode() + "."
            + base64.b64encode(os.urandom(32)).decode())


def send_steam_createlobby(sock, conn, binding):
    """Server-initiated RPC invoked right after a party scene becomes ready. The
    client GATES party.getpartystate2 on this handshake, so the party never
    finalizes (Multiplayer stays grey) until we ask the client to create its
    platform lobby. Route Steam.CreateLobby, args byte-exact from capture:
    [lobbyType=1, maxMembers=4, joinable=True, {partyDataToken}]."""
    sr = binding.sr
    route = sr.client_recv.get("Steam.CreateLobby")
    if route is None:
        log("  !! Steam.CreateLobby route not found in party scene")
        return
    party = PARTIES.get(binding.ref)
    if party is None:
        return
    req = conn.srv_rpc_id
    conn.srv_rpc_id += 1
    binding.createlobby_req = req
    args = mp_array([
        mp_uint(1), mp_uint(4), MP_TRUE,
        mp_map([(mp_str("partyDataToken"), mp_str(party_data_token(party)))]),
    ])
    send_scene_msg(sock, conn, sr.handle, route, struct.pack("<H", req) + args)
    log(f"  <- Steam.CreateLobby (server RPC) reqId={req} route={route} "
        f"party={party.guid} (scene ready)")


def build_party_member(conn):
    """Build the single PartyMember array shared by getpartystate2 and the
    party.memberConnected notification. Shape (byte-exact from capture):
      member    = [userId, status(0), userdataBin, sessionId16, platforms, 2]
      platforms = [['steam', userId, 'anonymous', steamId(str), nil, 0]]"""
    ud = conn.party_userdata or b"{}"
    if conn.party_session_id is None:
        conn.party_session_id = os.urandom(16)
    return mp_array([
        mp_str(conn.user_id),       # userId
        mp_uint(0),                 # status
        mp_bin(ud),                 # userData (member JSON)
        mp_bin(conn.party_session_id),  # sessionId (16 bytes, stable per conn)
        build_member_platforms(conn),   # platform identities
        mp_uint(2),                 #
    ])


def _member_steam_id(conn):
    """The steam id string embedded in this member's userdata (or "")."""
    ud = conn.party_userdata or b"{}"
    try:
        return str(json.loads(ud.decode("utf-8", "replace")).get("m_sSteamUserId", ""))
    except Exception:
        return ""


def build_member_platforms(conn, slot5=MP_NIL):
    """platforms = [['steam', userId, 'anonymous', steamId(str), slot5, 0]]

    The 5th platform slot is a nullable string. Captured BYTE-EXACT, it differs
    by message: the FULL member (getpartystate2 + party.memberConnected) carries
    `nil` there, but the SLIM member in party.memberDataUpdated carries an empty
    string "". The retail client's memberDataUpdated DTO deserializer expects a
    string in that slot; receiving `nil` makes it drop the event, so the member's
    data update is never applied and MemberDataInitialized never advances to true
    (which is what gates the join-by-code coroutine). Hence the per-caller slot5."""
    return mp_array([mp_array([
        mp_str("steam"), mp_str(conn.user_id), mp_str("anonymous"),
        mp_str(_member_steam_id(conn)), slot5, mp_uint(0),
    ])])


def build_memberdata_member(conn):
    """Slim member representation carried by party.memberDataUpdated (4 elements,
    byte-exact from capture, distinct from the 6-element getpartystate member):
      member = [userId, userdataBin, platforms, 2]
    NOTE: the platform 5th slot here is an empty string "" (not nil as in the
    full member) -- see build_member_platforms."""
    ud = conn.party_userdata or b"{}"
    return mp_array([
        mp_str(conn.user_id),
        mp_bin(ud),
        build_member_platforms(conn, slot5=mp_str("")),
        mp_uint(2),
    ])


def build_settings_array(party):
    """The 8-element party-settings array used by BOTH getpartystate2 and the
    party.settingsUpdated push. Shape byte-exact from capture:
      [gameFinderName, customData, settingsRev, onlyLeaderCanInvite(False),
       isJoinable(True), serverData{}, '', partyId(bare guid)]
    `settingsRev` tracked the party version minus 2 in every captured sample
    (settingsUpdated v3->1, v5->3, v7->5, v9->7)."""
    return mp_array([
        mp_str("matchmaking"),               # gameFinderName
        mp_str(party.custom_data),           # customData JSON (client-set)
        mp_uint(max(1, party.version - 2)),  # settings revision
        MP_FALSE,                            # onlyLeaderCanInvite
        MP_TRUE,                             # isJoinable
        MP_EMPTY_MAP,                        # public server data
        mp_str(""),                          #
        mp_str(party.guid),                  # partyId (bare guid)
    ])


def build_party_state(party):
    """Build the getpartystate2 result (PartyState) listing ALL party members.
    Shape decoded byte-exact from a real capture:
      PartyState = array4 [ settings(8), leaderUserId, members(N), version ]"""
    members = mp_array([build_party_member(m) for m in party.members])
    return mp_array([build_settings_array(party), mp_str(party.leader_user_id),
                     members, mp_uint(party.version)])


def build_merger_status(conn, parties=1):
    """Build the PartyMerging.GetMergerStatus result.

    Shape decoded BYTE-EXACT from the real joiner capture (relay.joiner_bycode
    .jsonl, s2c reqId=7 answering the `0x90 :: default` poll):
        [statusInt, {
            "partiesCount": N,
            "algorithm":    "DtPartyMergerAlgorithm",
            "playersCount": M,
            "details": {
                "nbPartiesByDifficulty": {"0": 1, "1": 1},
                "nbPlayersByDifficulty": {"0": 3, "1": 2},
            },
        }]
    i.e. a 2-element array of [statusInt, detailMap]. statusInt stays 1 (the
    steady "searching / merging in progress" state) throughout; the merge
    COMPLETION is signalled by `partiesCount` reaching 0 inside that map.

    A raknet_diff of the WORKING online join (join_online_102258) vs the HANGING
    offline join (join_fwd_*) proved this: online the merger pushed
    partiesCount 2 -> 1 -> 2 -> 0, and the instant the client saw partiesCount:0
    it issued DISCONNECT_FROM_SCENE ("leave scene") and advanced to the gamefinder
    find-by-code. Offline we had been pinning partiesCount:1 forever, so the
    deterministic client never saw the completion and parked in the matchmaking
    scene -- the exact hang. We now drive `parties` to 0 once the match is ready
    (see the GetMergerStatus handler). The earlier belief that the match is
    delivered out-of-band via a gamefinder.update push is SUPERSEDED: the retail
    client gates on partiesCount:0 here, not on that push.
    """
    players = parties
    by_parties = mp_map([(mp_str("0"), mp_uint(parties))])
    by_players = mp_map([(mp_str("0"), mp_uint(players))])
    details = mp_map([
        (mp_str("nbPartiesByDifficulty"), by_parties),
        (mp_str("nbPlayersByDifficulty"), by_players),
    ])
    info = mp_map([
        (mp_str("partiesCount"), mp_uint(parties)),
        (mp_str("algorithm"), mp_str("DtPartyMergerAlgorithm")),
        (mp_str("playersCount"), mp_uint(players)),
        (mp_str("details"), details),
    ])
    # statusInt=1 == the steady "searching/merging" value seen in the real capture.
    return mp_array([mp_uint(1), info])


def send_member_connected(sock, target_conn, about_conn, binding, party):
    """Notify target_conn that about_conn is a member of the party (route
    party.memberConnected). Body byte-exact from capture = [ver,0,ver] prefix +
    PartyMember array, where `ver` is the party-state version this membership
    event lands at (the first member connects at version 2, matching the captured
    [2,0,2]). The client gates getpartystate2 on this notification after it has
    created its platform lobby in response to Steam.CreateLobby."""
    route = binding.sr.client_recv.get("party.memberConnected")
    if route is None:
        log("  !! party.memberConnected route not found in party scene")
        return
    ver = party.next_version()
    body = mp_uint(ver) + b"\x00" + mp_uint(ver) + build_party_member(about_conn)
    send_scene_msg(sock, target_conn, binding.sr.handle, route, body)
    log(f"  <- party.memberConnected v{ver} to {target_conn.user_id[:8]} "
        f"about {about_conn.user_id[:8]} route={route} ({len(body)}B)")


def broadcast_settings_updated(sock, party):
    """Push party.settingsUpdated to every member. Body byte-exact from capture =
    [ver,0,ver] prefix + the 8-element settings array. The retail client's party
    reducer requires this versioned notification (and memberDataUpdated) to mark
    the party synchronized; without it the join-by-code coroutine never arms."""
    ver = party.next_version()
    prefix = mp_uint(ver) + b"\x00" + mp_uint(ver)
    body = prefix + build_settings_array(party)
    for m in party.members:
        b = m.binding_for("party", party.guid)
        if b is None:
            continue
        route = b.sr.client_recv.get("party.settingsUpdated")
        if route is None:
            continue
        send_scene_msg(sock, m, b.sr.handle, route, body)
    log(f"  <- party.settingsUpdated v{ver} party={party.guid} "
        f"customData={len(party.custom_data)}B -> {len(party.members)} member(s)")


def broadcast_member_data(sock, party, about_conn):
    """Push party.memberDataUpdated (about about_conn) to every member. Body
    byte-exact from capture = [ver,0,ver] prefix + the 4-element slim member."""
    ver = party.next_version()
    prefix = mp_uint(ver) + b"\x00" + mp_uint(ver)
    body = prefix + build_memberdata_member(about_conn)
    for m in party.members:
        b = m.binding_for("party", party.guid)
        if b is None:
            continue
        route = b.sr.client_recv.get("party.memberDataUpdated")
        if route is None:
            continue
        send_scene_msg(sock, m, b.sr.handle, route, body)
    log(f"  <- party.memberDataUpdated v{ver} party={party.guid} "
        f"about={about_conn.user_id[:8]} -> {len(party.members)} member(s)")


def broadcast_member_status(sock, party, about_conn, status=1):
    """Push party.memberStatusUpdated (about about_conn) to every member. Body
    byte-exact from capture = [ver,0,statusSeq, [[[userId, status]]]]. Fires when
    a member updates its gamefinder/ready status (party.updategamefinderplayerstatus)."""
    ver = party.next_version()
    party.status_seq += 1
    prefix = mp_uint(ver) + b"\x00" + mp_uint(party.status_seq)
    entry = mp_array([mp_array([mp_array([
        mp_str(about_conn.user_id), mp_uint(status)])])])
    body = prefix + entry
    for m in party.members:
        b = m.binding_for("party", party.guid)
        if b is None:
            continue
        route = b.sr.client_recv.get("party.memberStatusUpdated")
        if route is None:
            continue
        send_scene_msg(sock, m, b.sr.handle, route, body)
    log(f"  <- party.memberStatusUpdated v{ver} party={party.guid} "
        f"about={about_conn.user_id[:8]} status={status} -> {len(party.members)} member(s)")


def on_member_lobby_ready(sock, conn, party):
    """Called once a member's client has created its platform lobby (it completed
    our Steam.CreateLobby RPC). Announce this member to everyone in the party
    (including itself, which is what un-greys the leader's Multiplayer button) and
    tell this member about every other member already present, so both the leader
    and a joiner converge on the same member list. Then push the initial
    settingsUpdated snapshot the client's party reducer waits for."""
    for m in party.members:
        b = m.binding_for("party", party.guid)
        if b is not None:
            send_member_connected(sock, m, conn, b, party)  # announce conn to m
    mybind = conn.binding_for("party", party.guid)
    if mybind is not None:
        for m in party.members:
            if m is conn:
                continue
            send_member_connected(sock, conn, m, mybind, party)  # tell conn about m
    # Initial settings snapshot (empty customData) -- server-initiated, exactly
    # like the real backend pushes settingsUpdated v3 right after memberConnected.
    if not party.settings_broadcast:
        party.settings_broadcast = True
        broadcast_settings_updated(sock, party)


def mint_scene_token(scene_id):
    """Mint the JSON connection-token envelope (token + raknet endpoint + AES
    block) the client needs to connect to a scene. Same shape the party token
    uses; the embedded ConnectionData carries the plaintext SceneId."""
    cd = stoken.build_connection_data(scene_id=scene_id)
    tok = (base64.b64encode(cd).decode() + "-"
           + base64.b64encode(os.urandom(32)).decode())
    return json.dumps({
        "token": tok,
        "endpoints": {"raknet": [stoken.RAKNET_ENDPOINT]},
        "encryption": {
            "algorithm": "aes256", "mode": "GCM",
            "key": base64.b64encode(os.urandom(32)).decode(),
            "token": base64.b64encode(os.urandom(74)).decode(),
        },
    }, separators=(",", ":"))


def maybe_start_game(sock, party):
    """If every member of the party has readied up to play, create one shared
    GameSession and push gamefinder.update (carrying the gamesession token) to
    each member on their matchmaking scene. After both connect + ask for a P2P
    token, gameplay runs purely over EOS P2P between the NEE emulators."""
    if party.gs_guid is not None:
        return
    if not party.members or not all(m.in_gamefinder for m in party.members):
        return
    guid = str(uuid.uuid4())
    gs = GameSession(guid, party)
    GAMESESSIONS[guid] = gs
    party.gs_guid = guid
    token = mint_scene_token(gs.scene_id)
    log(f"  ** MATCH: party={party.guid} members={len(party.members)} -> "
        f"GameSession {guid}")
    for m in party.members:
        mb = m.binding_for("static", SCENE_ID_BASE + "matchmaking")
        if mb is None:
            log(f"  !! member {m.user_id[:8]} has no matchmaking scene; "
                f"cannot deliver gamefinder.update")
            continue
        route = mb.sr.client_recv.get("gamefinder.update")
        value = mp_array([mp_uint(3), mp_str(token)])
        send_scene_msg(sock, m, mb.sr.handle, route, value)
        log(f"  <- gamefinder.update to {m.user_id[:8]} route={route} "
            f"(GameSession token, {len(token)}B json)")



def handle_scene_message(sock, conn, payload):
    """A connected-layer message whose id is a scene handle. Resolve the scene +
    route NAME from THIS connection's bindings (handles are assigned per-conn for
    dynamic party/gamesession scenes) and answer the RPC the client invoked."""
    scene = payload[0]
    route = struct.unpack("<H", payload[1:3])[0]
    rest = payload[3:]
    binding = conn.scene_bindings.get(scene)
    sr = binding.sr if binding is not None else scenes.routes_for_handle(scene)
    if sr is None:
        log(f"  ** SCENE MSG unknown handle=0x{scene:02x} route={route} "
            f"({len(rest)}B): {hexdump(rest, 48)} (no response)")
        return
    rname = sr.server_recv_rev.get(route, f"route#{route}")
    rpc_req = struct.unpack("<H", rest[0:2])[0] if len(rest) >= 2 else 0

    if rname == "Authentication.Login":
        log(f"  ** LOGIN RPC scene={sr.suffix} rpcReqId={rpc_req} "
            f"({len(rest)-2}B args): {hexdump(rest[2:], 48)}")
        _parse_login_steam_id(conn, rest[2:])
        send_login_success(sock, conn, sr, rpc_req)
    elif rname == "Locator.GetSceneConnectionToken":
        svc, i = mp_read_str(rest, 2)
        name, _ = mp_read_str(rest, i)
        suffix = SERVICE_SCENE.get(svc, name or svc)
        scene_id = SCENE_ID_BASE + suffix
        cd = stoken.build_connection_data(scene_id=scene_id)
        token = base64.b64encode(cd).decode() + "-" + \
            base64.b64encode(os.urandom(32)).decode()
        log(f"  ** GET_SCENE_TOKEN rpcReqId={rpc_req} service='{svc}' name='{name}'"
            f" -> scene_id={scene_id}")
        rpc_respond(sock, conn, sr, rpc_req, mp_str(token))
        log(f"  <- TOKEN sent ({len(token)}B) for '{svc}'")
    elif rname == "UserSession.UpdateUserOptions":
        key, _ = mp_read_str(rest, 2)
        log(f"  ** UPDATE_USEROPTS rpcReqId={rpc_req} key='{key}' (void)")
        rpc_respond(sock, conn, sr, rpc_req, result=None)
        log(f"  <- COMPLETE (UpdateUserOptions void) rpcReqId={rpc_req}")
    elif rname == "Friends.Subscribe":
        # Friends.Subscribe returns void; the server later pushes
        # friends.notification updates. Empty friends list is fine offline.
        log(f"  ** FRIENDS.SUBSCRIBE rpcReqId={rpc_req} (void)")
        rpc_respond(sock, conn, sr, rpc_req, result=None)
        log(f"  <- COMPLETE (Friends.Subscribe void) rpcReqId={rpc_req}")
    elif rname in ("Friends.Get", "Friends.GetBlockedList"):
        # Return an empty array (no friends / no blocked users).
        log(f"  ** {rname} rpcReqId={rpc_req} -> []")
        rpc_respond(sock, conn, sr, rpc_req, b"\x90")  # msgpack empty array
        log(f"  <- COMPLETE ({rname} []) rpcReqId={rpc_req}")
    elif rname == "partymanagement.createsession":
        # Client asks the party-manager to create a party. Args end with the
        # member userdata JSON the client built (PlayerName/steam/eos). We register
        # a fresh Party (unique guid) led by this connection and hand back a
        # connection token for its dedicated party instance scene.
        conn.party_userdata = _extract_member_userdata(rest)
        guid = str(uuid.uuid4())
        party = Party(guid, conn)
        PARTIES[guid] = party
        conn.own_party_guid = guid
        token_json = mint_scene_token(party.scene_id)
        log(f"  ** CREATESESSION rpcReqId={rpc_req} -> NEW party {guid} "
            f"leader={conn.user_id[:8]} "
            f"userdata={'yes' if conn.party_userdata else 'MISSING'}")
        rpc_respond(sock, conn, sr, rpc_req, mp_str(token_json))
        log(f"  <- PARTY TOKEN sent ({len(token_json)}B json) rpcReqId={rpc_req}")
    elif rname == "PartyManagement.CreateConnectionTokenFromInvitationCode":
        # JOIN-BY-CODE (party-manager RPC path): rest = [reqId][code:str]
        # [memberUserdata:bin]. Look the code up; if it resolves to a hosted
        # party, return a connection token for THAT party's scene so the joiner
        # connects into it as a second member.
        #
        # REAL-CAPTURE NOTE (relay.joiner_bycode.jsonl): the retail client does
        # NOT actually take this party-manager RPC path for join-by-code. Instead
        # it submits the host code on the GAME-FINDER scene as a find request whose
        # InvitationCode field is set to the host's code:
        #     c2s `0x8e :: 325496`  (gamefinder find route, args[0]=code)
        #     s2c `0x8e :: {token}`  -> a connection token whose embedded SceneId
        #                              is `party-<HOST GUID>` (the host's party).
        # So the OUTCOME is identical to this handler -- the joiner ends up with a
        # connection token to the host's party scene -- which is why keeping this
        # path is still correct. Whichever route the offline client actually uses,
        # both converge on "resolve code -> host party token". (If a retest shows
        # the offline client uses the gamefinder find route, wire that route's
        # handler to call the same INVITE_CODES lookup + mint_scene_token below.)
        code, _ = mp_read_str(rest, 2)
        guid = INVITE_CODES.get(code)
        ud = _extract_member_userdata(rest)
        if ud is not None:
            conn.party_userdata = ud
        log(f"  ** JOIN-BY-CODE rpcReqId={rpc_req} code='{code}' -> "
            f"party={guid or 'UNKNOWN'}")
        if guid is None or guid not in PARTIES:
            # Unknown code (likely a typo): complete the RPC with no token so the
            # client's join attempt fails cleanly instead of hanging.
            rpc_respond(sock, conn, sr, rpc_req, result=None)
            log(f"  <- code '{code}' unknown (rejected, void)")
        else:
            party = PARTIES[guid]
            token_json = mint_scene_token(party.scene_id)
            rpc_respond(sock, conn, sr, rpc_req, mp_str(token_json))
            log(f"  <- JOIN TOKEN sent for party {guid} ({len(token_json)}B json)")
    elif rname == "party.getpartystate2":
        party = PARTIES.get(binding.ref) if binding else None
        if party is None:
            log(f"  !! getpartystate2 on non-party binding; rejecting")
            rpc_respond(sock, conn, sr, rpc_req, result=None)
        else:
            ps = build_party_state(party)
            log(f"  ** GETPARTYSTATE2 rpcReqId={rpc_req} party={party.guid} "
                f"members={len(party.members)} -> PartyState ({len(ps)}B)")
            rpc_respond(sock, conn, sr, rpc_req, ps)
            log(f"  <- COMPLETE (getpartystate2) rpcReqId={rpc_req}")
    elif rname == "Party.CreateInvitationCode":
        party = PARTIES.get(binding.ref) if binding else None
        if party is None:
            code = gen_invite_code()
        else:
            if party.invite_code is None:
                party.invite_code = gen_invite_code()
                INVITE_CODES[party.invite_code] = party.guid
            code = party.invite_code
        log(f"  ** CREATEINVITATIONCODE rpcReqId={rpc_req} party="
            f"{party.guid if party else '?'} -> '{code}'")
        rpc_respond(sock, conn, sr, rpc_req, mp_str(code))
        log(f"  <- COMPLETE (CreateInvitationCode '{code}') rpcReqId={rpc_req}")
    elif rname == "party.updategamefinderplayerstatus":
        # The "ready to play" signal. args = [gameFinderName, statusJson, want:bool,
        # ...]. When `want` is true the member wants to enter the game finder; once
        # every member of the party is ready we spin up the shared GameSession.
        try:
            _, i = mp_read_str(rest, 2)            # gameFinderName
            _, i = mp_read_str(rest, i)            # status JSON
            want = (i < len(rest) and rest[i] == 0xC3)
        except Exception:
            want = False
        conn.in_gamefinder = want
        party = PARTIES.get(binding.ref) if binding else None
        log(f"  ** UPDATEGAMEFINDERSTATUS rpcReqId={rpc_req} want={want} "
            f"party={party.guid if party else '?'}")
        rpc_respond(sock, conn, sr, rpc_req, result=None)
        if party is not None:
            # The party reducer expects a memberStatusUpdated event when a member
            # changes ready state (captured: route 8 carries [[[userId, status]]]).
            broadcast_member_status(sock, party, conn, status=1 if want else 0)
            if want:
                maybe_start_game(sock, party)
    elif rname in ("party.updatepartysettings",):
        # The leader edits party settings (game mode / difficulty / invite code).
        # The party state is EVENT-SOURCED: we must apply the new customData, bump
        # the party version, and push party.settingsUpdated to every member -- the
        # retail client's reducer waits on this versioned notification to mark the
        # party synchronized (a precondition for the join-by-code coroutine).
        cd = _extract_settings_customdata(rest)
        party = PARTIES.get(binding.ref) if binding else None
        if cd is not None and party is not None:
            party.custom_data = cd
        log(f"  ** UPDATEPARTYSETTINGS rpcReqId={rpc_req} party="
            f"{party.guid if party else '?'} customData={len(cd or '')}B")
        rpc_respond(sock, conn, sr, rpc_req, result=None)
        if party is not None:
            broadcast_settings_updated(sock, party)
    elif rname in ("party.updatepartyuserdata", "Party.UpdatePartyUserData2"):
        # A member updates its own userdata (PlayerName / hero / MemberDataInitialized).
        # Apply it and push party.memberDataUpdated to every member, same versioned
        # event-source contract as settingsUpdated above.
        ud = _extract_member_userdata(rest)
        if ud is not None:
            conn.party_userdata = ud
        party = PARTIES.get(binding.ref) if binding else None
        log(f"  ** {rname} rpcReqId={rpc_req} party={party.guid if party else '?'} "
            f"userdata={'yes' if ud else 'unchanged'}")
        rpc_respond(sock, conn, sr, rpc_req, result=None)
        if party is not None:
            broadcast_member_data(sock, party, conn)
    elif rname in ("party.promoteleader", "Party.CancelInvitationCode",
                   "party.sendinvitation"):
        # These mutate party state and return void; offline single party accepts.
        log(f"  ** {rname} rpcReqId={rpc_req} (void ack)")
        rpc_respond(sock, conn, sr, rpc_req, result=None)
        log(f"  <- COMPLETE ({rname} void) rpcReqId={rpc_req}")
    elif rname == "PartyMerging.GetMergerStatus":
        # Matchmaking-phase poll (the `0x90 :: default` request in the real joiner
        # capture; route arg is the merger name "default"). The joiner polls this
        # continuously while sitting in the game finder -- both during ordinary
        # auto-matchmaking AND in the seconds right before a join-by-code click.
        # We answer with the real DtPartyMergerAlgorithm shape (see
        # build_merger_status) instead of the old wrong `[0, {}]` empty map.
        #
        # NOTE (2026-06-03): partiesCount is the OPEN-MATCHMAKING merger pool size,
        # NOT the join-by-code gate. A retest that forced partiesCount:0 did NOT
        # make the client leave the matchmaking scene, because join-by-code is
        # driven by the client submitting an InvitationCode on the gamefinder
        # scene (route 4: ['matchmaking', '{"InvitationCode":...}']), which the
        # offline joiner never sends. So we report the honest steady "searching"
        # state (partiesCount:1) and address the missing code-submit elsewhere.
        status = build_merger_status(conn)
        log(f"  ** PARTYMERGING.GETMERGERSTATUS rpcReqId={rpc_req} -> "
            f"DtPartyMergerAlgorithm (real shape)")
        rpc_respond(sock, conn, sr, rpc_req, status)
        log(f"  <- COMPLETE (GetMergerStatus) rpcReqId={rpc_req}")
    elif rname == "GameSession.GetP2PToken":
        # On the GameSession scene the client asks for a P2P relay token. We return
        # [nil, false, nil] (no relay -> use direct EOS P2P), then broadcast this
        # player's status to every member so each client learns the others are in.
        log(f"  ** GETP2PTOKEN rpcReqId={rpc_req} gs={binding.ref if binding else '?'}")
        rpc_respond(sock, conn, sr, rpc_req,
                    mp_array([MP_NIL, MP_FALSE, MP_NIL]))
        gs = GAMESESSIONS.get(binding.ref) if binding else None
        if gs is not None:
            gs.ready.add(conn.user_id)
            broadcast_player_update(sock, gs, conn, status=1)
            log(f"  <- P2P token (direct), player.update broadcast "
                f"({len(gs.ready)}/{len(gs.members)} ready)")
    elif rname in ("stormancer.rpc.next", "stormancer.rpc.completed",
                   "stormancer.rpc.cancel", "stormancer.rpc.error"):
        # A client response to one of OUR server-initiated RPCs (e.g. the client
        # confirming it created its platform lobby for Steam.CreateLobby).
        log(f"  ** client rpc reply scene={sr.suffix} route='{rname}' "
            f"({len(rest)}B): {hexdump(rest, 32)}")
        # When the client COMPLETES our Steam.CreateLobby RPC, its platform lobby
        # exists; sync party membership so everyone (and itself) converges and the
        # client proceeds to getpartystate2 (which un-greys Multiplayer).
        if (rname == "stormancer.rpc.completed" and binding is not None
                and binding.kind == "party" and binding.createlobby_req is not None
                and not binding.member_connected_sent and len(rest) >= 3):
            done_req = struct.unpack("<H", rest[1:3])[0]
            if done_req == binding.createlobby_req:
                binding.member_connected_sent = True
                party = PARTIES.get(binding.ref)
                if party is not None:
                    on_member_lobby_ready(sock, conn, party)
    else:
        log(f"  ** SCENE RPC scene={sr.suffix} route='{rname}'({route}) "
            f"rpcReqId={rpc_req} ({len(rest)-2}B): {hexdump(rest[2:], 64)} "
            f"(NOT IMPLEMENTED)")


def broadcast_player_update(sock, gs, about_conn, status):
    """Send player.update([[userId, status, '', False]]) about about_conn to every
    member connected to this GameSession scene (each on their own gs handle)."""
    member = mp_array([mp_array([
        mp_str(about_conn.user_id), mp_uint(status), mp_str(""), MP_FALSE,
    ])])
    for m in gs.members:
        b = m.binding_for("gamesession", gs.guid)
        if b is None:
            continue
        route = b.sr.client_recv.get("player.update")
        send_scene_msg(sock, m, b.sr.handle, route, member)



def _parse_login_steam_id(conn, args):
    """Extract the player's SteamID64 from the Authentication.Login arguments and
    store it on the connection. The login args carry a Steam auth-session ticket
    as a hex ASCII string; that ticket begins with a 4-byte gcTokenSize (=0x14,
    i.e. the ASCII "14000000") followed by an 8-byte GC token and then the 8-byte
    SteamID64 (little-endian). We locate the ticket's ASCII hex in the raw args
    and parse the SteamID64 from it. Verified byte-exact against a live relay
    capture (yields steam:<SteamID64> identical to the real authenticator)."""
    try:
        pos = args.find(b"14000000")           # ASCII start of the ticket hex
        if pos < 0:
            return
        # read forward while characters are hex digits -> the full ticket hex
        end = pos
        n = len(args)
        while end < n and args[end:end + 1] in b"0123456789ABCDEFabcdef":
            end += 1
        tic_hex = args[pos:end]
        if len(tic_hex) < 40:                   # need at least 20 ticket bytes
            return
        b = bytes.fromhex(tic_hex.decode("ascii", "ignore")[:len(tic_hex) // 2 * 2])
        if len(b) < 20 or b[0:4] != b"\x14\x00\x00\x00":
            return
        conn.steam_id = struct.unpack("<Q", b[12:20])[0]
    except Exception as e:
        log(f"  !! login steam-id parse failed: {e}")


def send_login_success(sock, conn, sr, rpc_req):
    """Reply to the authenticator login RPC with a successful LoginResult.

    LoginResult is a msgpack array(6): [ErrorMsg, Success, UserId, Username,
    PlatformIds, Authentications]. The REAL authenticator returns an EMPTY
    Username and a PlatformIds map {"steam": "steam:<SteamID64>"} (verified
    against a live relay capture); the SteamID64 is parsed from the login
    ticket at login time. We send [nil, true, userId, "", {steam:...}, {}],
    framed as rpc.next (this scene's next handle) then rpc.completed.

    UserId MUST be unique per connection (assigned in Conn.__init__ as a fresh
    uuid). Hardcoding it made every local instance share one identity, so a
    joiner's invite code resolved to its own party and join-by-code self-collided.
    """
    user_id = conn.user_id          # unique per-connection Stormancer id
    username = conn.username        # real authenticator returns ""
    if conn.steam_id is not None:
        platform_ids = mp_map([(mp_str("steam"),
                                mp_str(f"steam:{conn.steam_id}"))])
    else:
        platform_ids = MP_EMPTY_MAP
    result = (bytes([0x96])           # fixarray(6)
              + b"\xc0"               # [0] ErrorMsg = nil
              + b"\xc3"               # [1] Success  = true
              + mp_str(user_id)       # [2] UserId
              + mp_str(username)      # [3] Username (empty, as real)
              + platform_ids          # [4] PlatformIds {"steam": "steam:<id>"}
              + b"\x80")              # [5] {} (authentications)
    rpc_respond(sock, conn, sr, rpc_req, result)
    log(f"  <- LOGIN SUCCESS rpcReqId={rpc_req} userId={user_id} "
        f"steam={conn.steam_id} (rpc.next + rpc.completed)")


def send_response_msg(sock, conn, req_id, payload):
    """ID_REQUEST_RESPONSE_MSG: deliver the values for an in-flight system request."""
    body = bytes([ID_REQUEST_RESPONSE_MSG]) + struct.pack("<H", req_id) + payload
    send_reliable(sock, conn, body)


def send_response_complete(sock, conn, req_id, has_values):
    """ID_REQUEST_RESPONSE_COMPLETE: terminate an in-flight system request."""
    body = bytes([ID_REQUEST_RESPONSE_COMPLETE]) + struct.pack("<H", req_id) \
        + bytes([1 if has_values else 0])
    send_reliable(sock, conn, body)


def send_response_error(sock, conn, req_id, message):
    """ID_REQUEST_RESPONSE_ERROR: fail an in-flight system request (msgpack str)."""
    try:
        import msgpack
        packed = msgpack.packb(message, use_bin_type=False)
    except Exception:
        b = message.encode("utf-8")
        packed = bytes([0xDA]) + struct.pack(">H", len(b)) + b  # msgpack str16
    body = bytes([ID_REQUEST_RESPONSE_ERROR]) + struct.pack("<H", req_id) + packed
    send_reliable(sock, conn, body)


def handle_system_request(sock, conn, payload):
    """Decode an ID_SYSTEM_REQUEST frame and answer it the way the real
    authenticator server does (see relay.jsonl capture). Frame:
    [134][msgId:1][reqId:2 LE][msgpack data...]."""
    if len(payload) < 4:
        log(f"  !! ID_SYSTEM_REQUEST too short: {hexdump(payload)}")
        return
    msg_id = payload[1]
    req_id = struct.unpack("<H", payload[2:4])[0]
    data = payload[4:]
    name = SR_NAMES.get(msg_id, f"0x{msg_id:02x}")
    log(f"  ** SYSTEM REQUEST {name} reqId={req_id} ({len(data)}B): "
        f"{hexdump(data, 64)}")

    if msg_id == SR_GET_SESSION_TOKEN:                       # 14: first request
        token, sid = make_session_jwt()
        values = mp_str(token) + mp_str(sid)
        send_response_msg(sock, conn, req_id, values)
        send_response_complete(sock, conn, req_id, has_values=True)
        log(f"  <- RESPONSE session JWT reqId={req_id} sid={sid}")
    elif msg_id == SR_GET_SCENE_INFOS:                       # 136
        scene_id = scenes.request_scene_id(data)
        kind, key = scenes.classify_scene(scene_id)
        if kind == "static":
            blob = scenes.get_scene_infos(key)
            if blob is None:
                blob = blobs.SCENE_INFOS_AUTH
                log(f"  !! GET_SCENE_INFOS unknown static '{key}', "
                    f"falling back to authenticator")
        elif kind == "party":
            blob = scenes.party_infos(key)
        else:                                                # gamesession
            blob = scenes.gamesession_infos(key)
        send_response_msg(sock, conn, req_id, blob)
        send_response_complete(sock, conn, req_id, has_values=True)
        log(f"  <- RESPONSE SceneInfosDto reqId={req_id} kind={kind} key='{key}' "
            f"({len(blob)}B)")
    elif msg_id == SR_CONNECT_TO_SCENE:                      # 134
        scene_id = scenes.request_scene_id(data)
        kind, key = scenes.classify_scene(scene_id)
        if kind == "static":
            blob = scenes.get_connect_result(key)
            if blob is None:
                blob = blobs.CONNECT_RESULT_AUTH
                log(f"  !! CONNECT_TO_SCENE unknown static '{key}', "
                    f"falling back to authenticator")
            handle = scenes.scene_handle(blob)
            sr = scenes.routes_for_handle(handle)
            conn.scene_bindings[handle] = SceneBinding("static", scene_id, sr)
        elif kind == "party":
            handle = conn.alloc_handle()
            infos = scenes.party_infos(key)
            blob = scenes.party_connect(key, handle)
            sr = scenes.SceneRoutes("party", infos, blob)
            conn.scene_bindings[handle] = SceneBinding("party", scene_id, sr, key)
            party = PARTIES.get(key)
            if party is not None and conn not in party.members:
                party.add_member(conn)
                log(f"  ** party {key}: {conn.user_id[:8]} JOINED "
                    f"(now {len(party.members)} members)")
        else:                                                # gamesession
            handle = conn.alloc_handle()
            infos = scenes.gamesession_infos(key)
            blob = scenes.gamesession_connect(key, handle)
            sr = scenes.SceneRoutes("gamesession", infos, blob)
            conn.scene_bindings[handle] = SceneBinding("gamesession", scene_id, sr, key)
        send_response_msg(sock, conn, req_id, blob)
        send_response_complete(sock, conn, req_id, has_values=True)
        log(f"  <- RESPONSE ConnectionResult reqId={req_id} kind={kind} key='{key}' "
            f"handle={handle} ({len(blob)}B)")
        if kind == "static" and key == "authenticator":
            # The real authenticator pushes gameVersion.update right after its
            # scene connects (an unsolicited server->client message carrying the
            # accepted client-version pattern). Verified value from live capture.
            gv_route = sr.client_recv.get("gameVersion.update")
            if gv_route is not None:
                send_scene_msg(sock, conn, handle, gv_route,
                               mp_str("bot,1.05.*"))
                log(f"  <- gameVersion.update 'bot,1.05.*' (authenticator push)")
    elif msg_id == SR_PING:                                  # 2
        # request data = client tStart (uint64 LE); reply [serverClock LE][echo LE].
        echo = data[:8] if len(data) >= 8 else b"\x00" * 8
        ref = struct.pack("<Q", server_clock_ms()) + echo
        send_response_msg(sock, conn, req_id, ref)
        send_response_complete(sock, conn, req_id, has_values=True)
        log(f"  <- RESPONSE ping reqId={req_id} clock={server_clock_ms()}")
    elif msg_id == SR_SET_METADATA:                          # 0
        send_response_complete(sock, conn, req_id, has_values=False)
        log(f"  <- RESPONSE_COMPLETE reqId={req_id} (ID_SET_METADATA ack)")
    elif msg_id == SR_SCENE_READY2:                          # 16: post-connect confirm
        # The client's type-16 handler expects a RETURN VALUE (an object), not
        # void. The real server replies msgpack {"v": true} then COMPLETE with
        # has_values=True. Returning void makes the client throw
        # "Tried to return oid from a system request of type 16 that returned
        # void." and abort connection confirmation (party/friends never start).
        send_response_msg(sock, conn, req_id, b"\x81\xa1\x76\xc3")  # {"v": true}
        send_response_complete(sock, conn, req_id, has_values=True)
        ready_handle = scenes.scene_handle(data)
        log(f"  <- RESPONSE {{v:true}} reqId={req_id} (scene-ready confirm, "
            f"handle={ready_handle})")
        binding = conn.scene_bindings.get(ready_handle) if ready_handle else None
        if binding is not None and binding.kind == "party":
            # A party scene is ready: invoke Steam.CreateLobby so the client
            # creates its platform lobby and proceeds to getpartystate2 (which
            # un-greys Multiplayer once membership is synced).
            send_steam_createlobby(sock, conn, binding)
    elif msg_id == SR_DISCONNECT_FROM_SCENE:                # 135
        # The client is leaving a scene. This is the FIRST thing the retail client
        # does on a join-by-code click (real capture: DISCONNECT_FROM_SCENE reqId=33
        # AND 34 to drop its own game-finder scenes, THEN it submits the host's
        # invite code). It is the Stormancer analogue of the EOS _OnLobbyDestroyed
        # step our offline join used to hang on.
        #
        # Request `data` is the target SceneHandle as a msgpack uint (real bytes:
        # `cc 90` = uint8 0x90). The continuation that emits the join-by-code submit
        # is awaited on THIS request completing SUCCESSFULLY.
        #
        # The real server replies ID_REQUEST_RESPONSE_MSG {"v":true} then
        # ID_REQUEST_RESPONSE_COMPLETE -- byte-exact `89 <reqId> 81 a1 76 c3` -- the
        # SAME {"v":true} value as the type-16 scene-ready confirm. Our OLD code had
        # no branch for msgId 135, so it fell through to the generic `else` below and
        # sent ID_REQUEST_RESPONSE_ERROR ("not implemented"). That error almost
        # certainly faulted the client's disconnect continuation, so the
        # join-by-code submit was never sent and the offline join silently hung.
        handle = mp_read_uint(data)
        binding = conn.scene_bindings.pop(handle, None) if handle is not None else None
        if binding is not None and binding.kind == "party":
            party = PARTIES.get(binding.ref)
            if party is not None and conn in party.members:
                party.members.remove(conn)
        send_response_msg(sock, conn, req_id, b"\x81\xa1\x76\xc3")  # {"v": true}
        send_response_complete(sock, conn, req_id, has_values=True)
        log(f"  <- RESPONSE {{v:true}} reqId={req_id} (DISCONNECT_FROM_SCENE ack, "
            f"handle={handle}, binding={'dropped' if binding else 'none'})")
    else:
        send_response_error(sock, conn, req_id,
                            f"{name} not implemented by offline probe")
        log(f"  <- RESPONSE_ERROR reqId={req_id} ({name} not implemented yet)")



def handle_connected(sock, data, addr):
    """Connected/online-layer datagram: ACK it and act on its messages."""
    ip, port = addr
    flags = data[0]
    is_valid = (flags >> 7) & 1
    is_ack = (flags >> 6) & 1
    if not is_valid:
        return
    if is_ack:
        log(f"-> ACK from {addr}: {hexdump(data, 16)}")
        return
    is_nak = (flags >> 5) & 1
    if is_nak:
        log(f"-> NAK from {addr}: {hexdump(data, 16)}")
        return

    seq = rd_u24le(data, 1)
    conn = CONNS.get(addr)
    if conn is None:
        conn = CONNS[addr] = Conn(ip, port)

    # Acknowledge the datagram so the client stops resending it.
    sock.sendto(make_ack(seq), addr)

    for reliability, reliable_num, payload in parse_messages(data, 4):
        if not payload:
            continue
        mid = payload[0]
        if mid == ID_CONNECTION_REQUEST:
            log(f"-> ID_CONNECTION_REQUEST seq={seq} from {addr}")
            send_connection_accepted(sock, conn, payload)
        elif mid == ID_NEW_INCOMING_CONNECTION:
            conn.established = True
            log(f"-> ID_NEW_INCOMING_CONNECTION seq={seq} from {addr} "
                f"== CONNECTION ESTABLISHED ==")
            # Send our own RakNet ping to drive the clock sync the C++ client
            # waits for. ID_CONNECTION_RESULT is sent only after the client pongs.
            send_server_ping(sock, conn)
        elif mid == ID_CONNECTED_PING:
            # reply pong: 0x03 + echo ping time(8) + our time(8)
            ping_ts = payload[1:9] if len(payload) >= 9 else b"\x00" * 8
            pong = bytes([ID_CONNECTED_PONG]) + ping_ts \
                + struct.pack(">Q", int(time.time() * 1000))
            msg = make_message(UNRELIABLE, pong)
            sock.sendto(make_data_datagram(conn.next_datagram, msg), addr)
            conn.next_datagram += 1
            log(f"-> ID_CONNECTED_PING seq={seq}; replied PONG")
        elif mid == ID_CONNECTED_PONG:
            # The client answered our server-initiated ping -> RakNet clock is
            # synced. Now hand it the Stormancer connection id so it proceeds to
            # the system-request flow (ID_GET_SESSION_TOKEN, etc.).
            log(f"-> ID_CONNECTED_PONG seq={seq}")
            if conn.established and not conn.conn_result_sent:
                send_connection_result(sock, conn)
        elif mid == ID_SYSTEM_REQUEST:
            log(f"-> ID_SYSTEM_REQUEST seq={seq} rel={reliability} "
                f"relnum={reliable_num} ({len(payload)}B)")
            handle_system_request(sock, conn, payload)
        elif mid == ID_SCENES or scenes.known_scene_handle(mid) \
                or mid in conn.scene_bindings:
            # Scene message: [sceneHandle][routeHandle u16 LE][...]. Static scenes
            # keep their baked handles (141..145); dynamic party/gamesession scenes
            # use per-conn handles allocated at CONNECT_TO_SCENE.
            log(f"-> SCENE MSG seq={seq} rel={reliability} relnum={reliable_num} "
                f"id=0x{mid:02x} ({len(payload)}B): {hexdump(payload, 64)}")
            handle_scene_message(sock, conn, payload)
        else:
            # Unknown -> almost certainly a Stormancer system message. Log full
            # hex so we can reverse the next protocol layer.
            log(f"-> ONLINE MSG seq={seq} rel={reliability} relnum={reliable_num} "
                f"id=0x{mid:02x} ({len(payload)}B): {hexdump(payload, 96)}")


def handle_ocr1(sock, data, addr):
    # 0x05 + magic(16) + protocol(1) + zero-padding(to MTU)
    # The MTU we offer back = size of the received datagram + UDP/IP overhead (28).
    protocol = data[17] if len(data) > 17 else 6
    mtu = len(data) + 28
    if mtu > 1492:
        mtu = 1492
    reply = bytes([ID_OPEN_CONNECTION_REPLY_1]) + MAGIC \
        + struct.pack(">Q", SERVER_GUID) \
        + bytes([0]) \
        + struct.pack(">H", mtu)
    sock.sendto(reply, addr)
    log(f"  <- OCR1 reply: protocol={protocol} mtu={mtu} guid={SERVER_GUID:016x}")


def handle_ocr2(sock, data, addr):
    # 0x07 + magic(16) + serverAddress(7) + mtu(2) + clientGuid(8)
    off = 1 + 16
    # server (binding) address the client targeted — 7 bytes for IPv4
    server_addr = data[off:off+7]; off += 7
    mtu = struct.unpack(">H", data[off:off+2])[0]; off += 2
    client_guid = data[off:off+8]; off += 8
    client_ip, client_port = addr
    reply = bytes([ID_OPEN_CONNECTION_REPLY_2]) + MAGIC \
        + struct.pack(">Q", SERVER_GUID) \
        + encode_address(client_ip, client_port) \
        + struct.pack(">H", mtu) \
        + bytes([0])
    sock.sendto(reply, addr)
    log(f"  <- OCR2 reply: mtu={mtu} client_guid={client_guid.hex()} "
        f"client={client_ip}:{client_port}")


def main():
    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    sock.bind((HOST, PORT))
    log(f"RakNet server listening on {HOST}:{PORT} guid={SERVER_GUID:016x}")
    seen_online = 0
    while True:
        data, addr = sock.recvfrom(65535)
        if not data:
            continue
        set_peer(addr)
        msg_id = data[0]
        is_offline = len(data) >= 17 and data[1:17] == MAGIC
        if msg_id == ID_OPEN_CONNECTION_REQUEST_1 and is_offline:
            log(f"-> OCR1 from {addr} len={len(data)}")
            handle_ocr1(sock, data, addr)
        elif msg_id == ID_OPEN_CONNECTION_REQUEST_2 and is_offline:
            log(f"-> OCR2 from {addr} len={len(data)}")
            handle_ocr2(sock, data, addr)
        elif msg_id in (ID_UNCONNECTED_PING, ID_UNCONNECTED_PING_OPEN_CONN) and is_offline:
            log(f"-> UNCONNECTED_PING from {addr} (ignored)")
        else:
            # Online / connected-layer datagram: ACK + handshake + log.
            seen_online += 1
            handle_connected(sock, data, addr)


# =========================================================================
# RELAY MODE (env RAKNET_RELAY=1)
# -------------------------------------------------------------------------
# Instead of emulating the Stormancer backend, transparently proxy every UDP
# datagram to the REAL dt-live RakNet cluster and forward its replies back to
# the client. This makes join-by-code actually work through us (the real
# backend does all the work), which is the decisive datapoint: if join
# completes through the relay, the ONLY difference vs the emulator is the
# emulator's own responses. Every datagram (both directions) is captured to a
# JSONL file (dir + full hex) so join_diff.py can do a field-level diff of the
# real wire against what raknet.py would have generated.
#
# The real RakNet endpoint is learned from dtlive_server (relay mode), which
# writes it to RELAY_STATE_FILE when it forwards the bootstrap /token. We fall
# back to RAKNET_RELAY_UPSTREAM (host:port) or dt-live.passtechgames.com:30100.
# =========================================================================

RELAY_STATE_FILE = os.environ.get(
    "RELAY_STATE_FILE", "/tmp/pdlog/probe/relay_upstream.json")
RELAY_CAPTURE_FILE = os.environ.get(
    "RELAY_CAPTURE", "/tmp/pdlog/probe/relay_capture.jsonl")
_DEFAULT_UPSTREAM = os.environ.get(
    "RAKNET_RELAY_UPSTREAM", "dt-live.passtechgames.com:30100")


def _relay_resolve_upstream():
    """Resolve the real RakNet cluster endpoint to an (ip, port) tuple, forcing
    IPv4 (the dt-live AAAA records are dead; only A records route)."""
    ep = os.environ.get("RAKNET_RELAY_UPSTREAM")
    if not ep:
        try:
            with open(RELAY_STATE_FILE) as f:
                ep = (json.load(f) or {}).get("raknet")
        except Exception:
            ep = None
    if not ep:
        ep = _DEFAULT_UPSTREAM
    host, _, port = ep.rpartition(":")
    port = int(port)
    ai = socket.getaddrinfo(host, port, socket.AF_INET, socket.SOCK_DGRAM)
    return (ai[0][4][0], port), f"{host}:{port}"


_relay_cap_fh = None
def _relay_capture(direction, peer_label, data):
    """Append one datagram (full hex + direction) to the capture JSONL."""
    global _relay_cap_fh
    if _relay_cap_fh is None:
        os.makedirs(os.path.dirname(RELAY_CAPTURE_FILE), exist_ok=True)
        _relay_cap_fh = open(RELAY_CAPTURE_FILE, "a", buffering=1)
    rec = {"t": datetime.datetime.now().isoformat(),
           "dir": direction, "peer": peer_label, "hex": data.hex()}
    _relay_cap_fh.write(json.dumps(rec) + "\n")


def _relay_rotate(path):
    """Move an existing per-run output file aside so each relay run starts with a
    clean file. Without this the capture/assert JSONL would APPEND across runs,
    mixing sessions -- which silently pollutes the diff (e.g. a stale pre-fix
    prediction lingering next to the current run's). The previous file is kept as
    '<path>.<mtime>.bak' so nothing is lost."""
    try:
        if os.path.exists(path) and os.path.getsize(path) > 0:
            mt = datetime.datetime.fromtimestamp(
                os.path.getmtime(path)).strftime("%Y%m%d-%H%M%S")
            bak = f"{path}.{mt}.bak"
            os.replace(path, bak)
            log(f"  rotated previous {os.path.basename(path)} -> "
                f"{os.path.basename(bak)}")
    except Exception as e:
        log(f"  !! rotate {path} failed: {e}")


# First-byte -> short tag for the live snoop log (best-effort; the rigorous
# decode is done offline by join_diff.py against the JSONL capture).
_RELAY_MSG_TAGS = {
    0x00: "PING", 0x03: "PONG", 0x09: "CONN_REQ",
    0x10: "CONN_REQ_ACCEPTED", 0x13: "NEW_INCOMING", 0x15: "DISCONNECT",
    0x86: "SYSTEM_REQUEST", 0x89: "RESP_MSG", 0x8a: "RESP_COMPLETE",
    0x8b: "RESP_ERROR", 0x8c: "CONNECTION_RESULT",
}


def _relay_snoop(direction, data):
    """Best-effort human-readable one-liners for a relayed datagram so the join
    flow can be watched live. Decodes the RakNet data-datagram envelope and the
    first byte of each encapsulated message; scene handles (>=0x8d) are reported
    raw since their meaning needs the per-session scene map."""
    if not data:
        return
    flags = data[0]
    if (flags & 0xC0) == 0xC0:      # ACK/NAK
        return
    if not (flags & 0x80):          # offline (handshake) datagram
        log(f"  [{direction}] offline id=0x{flags:02x} len={len(data)}")
        return
    try:
        msgs = parse_messages(data, 4)
    except Exception:
        return
    for rel, rnum, payload in msgs:
        if not payload:
            continue
        b0 = payload[0]
        tag = _RELAY_MSG_TAGS.get(b0)
        if tag is None:
            if b0 >= 0x8d:
                tag = f"scene h=0x{b0:02x}"
            else:
                tag = f"id=0x{b0:02x}"
        log(f"  [{direction}] {tag} ({len(payload)}B)")


# =========================================================================
# INLINE PREDICTION + ASSERT (the "shadow emulator")
# -------------------------------------------------------------------------
# For every client->server datagram, we ALSO feed it to the real emulator
# handlers (handle_ocr1/ocr2/handle_connected) through a capturing fake socket.
# Whatever the emulator WOULD have replied is the PREDICTION. When the real
# server's reply comes back, we compare the two per Stormancer message, keyed by
# system reqId (RESP_MSG/COMPLETE/ERROR) or by resolved (scene-kind, route,
# rpcReqId) so the comparison aligns across the two sides even though the
# emulator allocates different numeric scene handles than the real cluster.
# Each comparison is appended to RELAY_ASSERT_FILE as one JSON line
# {match, key, real, pred}; mismatches are also printed live. Nothing halts.
#
# Caveat (inherent, not a bug): the shadow emulator never ingests the real
# server's replies, so after the first divergence its later predictions are
# based on its own earlier output, not reality. That is exactly what we are
# measuring -- where the emulator would have diverged from the live server.
# =========================================================================

RELAY_ASSERT_FILE = os.environ.get(
    "RELAY_ASSERT", "/tmp/pdlog/probe/relay_assert.jsonl")

_RPC_STREAM_ROUTES = ("stormancer.rpc.next", "stormancer.rpc.completed",
                      "stormancer.rpc.error", "stormancer.rpc.cancel")
_MP_MAP_MARKERS = set(range(0x80, 0x90)) | {0xde, 0xdf}


def _rd_u16le(b, i):
    return b[i] | (b[i + 1] << 8)


def _kind_of_routes(names):
    """Classify a scene by the route names it exposes (handle numbers differ
    between emulator and real server, so we key scenes by kind instead)."""
    s = set(names)
    if "users.renewCredentials" in s:
        return "authenticator"
    if "Steam.GetFriends" in s or "friends.notification" in s:
        return "friends"
    if any(n.startswith("party.") for n in s) or "memberConnected" in s:
        return "party"
    if any("amefinder" in n or "atchmak" in n or "Merger" in n
           or n.startswith("gf.") for n in s):
        return "matchmaking"
    if any("amesession" in n or "GameSession" in n for n in s):
        return "gamesession"
    return "scene?"


class _ShadowSock:
    """Captures every datagram the emulator would have transmitted."""
    def __init__(self):
        self.out = []

    def sendto(self, b, addr):
        self.out.append(bytes(b))


class _RelayAssert:
    """Per-client prediction-vs-reality comparison engine."""

    def __init__(self, label, jd):
        self.label = label
        self.jd = jd                       # join_diff module (msgpack + skel)
        self.h2r = {"pred": {}, "real": {}}   # side -> handle -> {routeH: name}
        self.h2k = {"pred": {}, "real": {}}   # side -> handle -> kind
        self.skels = {"pred": {}, "real": {}}  # side -> key -> skeleton
        self.split = {"pred": {}, "real": {}}  # side -> splitId -> {idx: frag}
        self.done = set()                  # keys already emitted as matched
        self.n_ok = 0
        self.n_diff = 0
        # --- relay handle adoption (so the shadow can route the client's c2s) ---
        # In relay mode the client follows the REAL server's scene handles, but
        # the shadow emulator allocates its own. Track each side's SceneHandle
        # per connect reqId; when the real handle is known, alias it into the
        # shadow connection's bindings so party/gamesession c2s the client sends
        # (addressed to real handles) are actually processed by the shadow.
        self._shadow_conn = None
        self._connect = {"pred": {}, "real": {}}   # side -> reqId -> SceneHandle
        self._last_learned = []            # handles learned by last _decode_for_routes

    @staticmethod
    def _is_mp(raw):
        return bool(raw) and raw[0] in _MP_MAP_MARKERS

    def _learn_routes(self, side, vals):
        """A scene-connect response carries {SceneHandle, RouteMappings}; record
        the side's handle->route table so later scene messages resolve. Returns
        the list of SceneHandles learned from this payload."""
        learned = []
        for v in vals:
            if (isinstance(v, tuple) and v[0] == "map"
                    and "RouteMappings" in v[1] and "SceneHandle" in v[1]):
                sh = v[1]["SceneHandle"]
                rm = v[1]["RouteMappings"]
                if isinstance(sh, int) and isinstance(rm, tuple) and rm[0] == "map":
                    routes = {int(rh): name for name, rh in rm[1].items()
                              if isinstance(rh, int)}
                    self.h2r[side][sh] = routes
                    self.h2k[side][sh] = _kind_of_routes(routes.values())
                    learned.append(sh)
        return learned

    def _adopt_real_handle(self, req):
        """Once both sides' SceneHandle for a connect reqId are known, alias the
        REAL handle onto the shadow connection's binding (created under the
        shadow's own handle) so the client's subsequent c2s -- addressed to the
        real handle -- are routed and answered by the shadow emulator."""
        h_real = self._connect["real"].get(req)
        h_pred = self._connect["pred"].get(req)
        conn = self._shadow_conn
        if (h_real is None or h_pred is None or h_real == h_pred
                or conn is None):
            return
        binding = conn.scene_bindings.get(h_pred)
        if binding is not None and h_real not in conn.scene_bindings:
            conn.scene_bindings[h_real] = binding
            log(f"  [assert {self.label}] adopt real scene handle "
                f"{h_real} <- shadow {h_pred} (reqId {req})")

    def _classify(self, side, payload):
        """Return (alignment_key, skeleton) for one encapsulated message."""
        jd = self.jd
        mid = payload[0]
        if mid == ID_REQUEST_RESPONSE_MSG:
            req = _rd_u16le(payload, 1)
            raw = payload[3:]
            vals = self._decode_for_routes(side, raw)
            if self._last_learned:
                # This RESP_MSG carried a scene-connect result; remember its
                # SceneHandle under the connect reqId and try to align the
                # shadow's binding with the real server's handle.
                self._connect[side][req] = self._last_learned[-1]
                self._adopt_real_handle(req)
            return ("SYS", "RESP_MSG", req), self._skel_or_binary(raw, vals)
        if mid == ID_REQUEST_RESPONSE_COMPLETE:
            req = _rd_u16le(payload, 1)
            return ("SYS", "RESP_COMPLETE", req), \
                {"hasVals": payload[3] if len(payload) > 3 else None}
        if mid == ID_REQUEST_RESPONSE_ERROR:
            req = _rd_u16le(payload, 1)
            raw = payload[3:]
            return ("SYS", "RESP_ERROR", req), self._skel_or_binary(raw)
        if len(payload) >= 3:
            h = mid
            rh = _rd_u16le(payload, 1)
            body = payload[3:]
            kind = self.h2k[side].get(h, "scene?")
            rname = self.h2r[side].get(h, {}).get(rh, "r#%d" % rh)
            if rname in _RPC_STREAM_ROUTES and len(body) >= 2:
                rid = _rd_u16le(body, 0)
                return ("SCN", kind, rname, rid), self._skel_or_binary(body[2:])
            return ("SCN", kind, rname), self._skel_or_binary(body)
        return None, None

    def _decode_for_routes(self, side, raw):
        """Decode raw msgpack and, if it carries scene RouteMappings, learn them.
        Returns the decoded value list (possibly containing an ERR sentinel)."""
        self._last_learned = []
        if not self._is_mp(raw):
            return None
        vals = self.jd.mp_all(raw)
        self._last_learned = self._learn_routes(side, vals)
        return vals

    def _skel_or_binary(self, raw, vals=None):
        """Identity-masked skeleton of a msgpack payload, or "<binary:N>" when the
        bytes are not cleanly decodable msgpack. Many RakNet system payloads
        (ping/clock = 16 bytes) are raw binary whose first byte can land in the
        msgpack fixmap range (0x80..0x8f); decoding those yields a spurious ERR
        sentinel that differs per side. Treating any payload whose decode hits an
        ERR (or which lacks a msgpack marker) as binary keeps the two sides
        aligned and avoids false DIFFs."""
        if not self._is_mp(raw):
            return "<binary:%d>" % len(raw)
        if vals is None:
            vals = self.jd.mp_all(raw)
        if any(isinstance(v, (tuple, list)) and v and v[0] == "ERR" for v in vals):
            return "<binary:%d>" % len(raw)
        return [self.jd.skel(v) for v in vals]

    def feed(self, side, datagram):
        """Decode one s2c datagram (real or predicted) and compare as keys land
        on both sides. Split (fragmented) messages are reassembled per side by
        splitPacketId before classification, so large blobs (SceneInfos, party
        state) are not falsely flagged at fragment boundaries that differ between
        the emulator's MTU and the real server's."""
        if not datagram:
            return
        flags = datagram[0]
        if not (flags & 0x80) or (flags & 0xC0) == 0xC0:   # offline / ACK / NAK
            return
        try:
            msgs = parse_messages_ex(datagram, 4)
        except Exception:
            return
        for m in msgs:
            pl = m["payload"]
            if not pl:
                continue
            sp = m["split"]
            if sp is not None:
                count, sid, index = sp
                buf = self.split[side].setdefault(sid, {})
                buf[index] = pl
                if len(buf) < count:
                    continue                       # await remaining fragments
                pl = b"".join(buf[i] for i in range(count))
                del self.split[side][sid]
            try:
                key, sk = self._classify(side, pl)
            except Exception as e:
                log(f"  [assert {self.label}] classify EXC: {e}")
                continue
            if key is None:
                continue
            self.skels[side][key] = sk
            self._maybe_emit(key)

    def _maybe_emit(self, key):
        if key in self.done:
            return
        pred = self.skels["pred"].get(key)
        real = self.skels["real"].get(key)
        if pred is None or real is None:
            return
        self.done.add(key)
        match = pred == real
        if match:
            self.n_ok += 1
        else:
            self.n_diff += 1
        _relay_assert_write({
            "t": datetime.datetime.now().isoformat(),
            "peer": self.label, "match": match, "key": list(key),
            "real": real, "pred": pred,
        })
        if not match:
            log(f"  [assert {self.label}] DIFF {key}")

    def flush_unmatched(self):
        """At teardown, report keys that only one side ever produced."""
        only_real = only_pred = 0
        for key in set(self.skels["real"]) | set(self.skels["pred"]):
            if key in self.done:
                continue
            pred = self.skels["pred"].get(key)
            real = self.skels["real"].get(key)
            side = "real" if pred is None else "pred"
            if side == "real":
                only_real += 1
            else:
                only_pred += 1
            _relay_assert_write({
                "t": datetime.datetime.now().isoformat(),
                "peer": self.label, "match": False, "only": side,
                "key": list(key), "real": real, "pred": pred,
            })
        log(f"  [assert {self.label}] summary: ok={self.n_ok} diff={self.n_diff} "
            f"only_real={only_real} only_pred={only_pred}")


_relay_assert_fh = None
def _relay_assert_write(rec):
    global _relay_assert_fh
    if _relay_assert_fh is None:
        os.makedirs(os.path.dirname(RELAY_ASSERT_FILE), exist_ok=True)
        _relay_assert_fh = open(RELAY_ASSERT_FILE, "a", buffering=1)
    _relay_assert_fh.write(json.dumps(rec, default=str) + "\n")


def _relay_shadow_predict(eng, data, caddr):
    """Run the emulator against one real c2s datagram and feed its would-be
    replies into the assert engine as the PREDICTION."""
    shadow = _ShadowSock()
    try:
        mid = data[0]
        is_off = len(data) >= 17 and data[1:17] == MAGIC
        if mid == ID_OPEN_CONNECTION_REQUEST_1 and is_off:
            handle_ocr1(shadow, data, caddr)
        elif mid == ID_OPEN_CONNECTION_REQUEST_2 and is_off:
            handle_ocr2(shadow, data, caddr)
        elif mid in (ID_UNCONNECTED_PING, ID_UNCONNECTED_PING_OPEN_CONN) and is_off:
            pass
        else:
            handle_connected(shadow, data, caddr)
    except Exception as e:
        log(f"  [shadow {eng.label}] EXC {type(e).__name__}: {e}")
    # Link the shadow connection so real scene handles can be adopted onto it.
    eng._shadow_conn = CONNS.get(caddr, eng._shadow_conn)
    for dg in shadow.out:
        eng.feed("pred", dg)


def relay_main():
    """Transparent UDP proxy to the real dt-live RakNet cluster."""
    import join_diff as _jd                # msgpack decoder + skeleton masker
    # Start each run with fresh per-run outputs (previous ones backed up), so the
    # capture and assert JSONL reflect ONLY this session.
    os.makedirs(os.path.dirname(RELAY_CAPTURE_FILE), exist_ok=True)
    _relay_rotate(RELAY_CAPTURE_FILE)
    _relay_rotate(RELAY_ASSERT_FILE)
    upstream, upstream_label = None, None
    cli = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    cli.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    cli.bind((HOST, PORT))
    log(f"RakNet RELAY listening on {HOST}:{PORT} -> (upstream resolved on "
        f"first client packet); capture -> {RELAY_CAPTURE_FILE}; "
        f"asserts -> {RELAY_ASSERT_FILE}")

    # Per client_addr: dedicated upstream socket (so replies route back).
    up_by_client = {}      # client_addr -> upstream socket
    client_by_fd = {}      # upstream socket fileno -> client_addr
    asserts = {}           # peer label -> _RelayAssert (shadow comparison)

    try:
        while True:
            rlist = [cli] + list(up_by_client.values())
            ready, _, _ = select.select(rlist, [], [], 30.0)
            for s in ready:
                if s is cli:
                    data, caddr = cli.recvfrom(65535)
                    if not data:
                        continue
                    label = set_peer(caddr)
                    if upstream is None:
                        upstream, upstream_label = _relay_resolve_upstream()
                        log(f"RELAY upstream = {upstream_label} {upstream}")
                    us = up_by_client.get(caddr)
                    if us is None:
                        us = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
                        us.connect(upstream)
                        up_by_client[caddr] = us
                        client_by_fd[us.fileno()] = caddr
                        log(f"-> new client {caddr[0]}:{caddr[1]} bound to "
                            f"upstream {upstream_label}")
                    _relay_capture("c2s", label, data)
                    _relay_snoop("c2s", data)
                    # PREDICT: run the emulator against this request.
                    eng = asserts.get(label)
                    if eng is None:
                        eng = asserts[label] = _RelayAssert(label, _jd)
                    _relay_shadow_predict(eng, data, caddr)
                    try:
                        us.send(data)
                    except OSError as e:
                        log(f"  !! upstream send failed: {e}")
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
                    set_peer(caddr)
                    label = _PEER_LABELS.get(caddr, "?")
                    _relay_capture("s2c", label, data)
                    _relay_snoop("s2c", data)
                    # COMPARE: real reply vs the emulator's prediction.
                    eng = asserts.get(label)
                    if eng is not None:
                        eng.feed("real", data)
                    cli.sendto(data, caddr)
    finally:
        for eng in asserts.values():
            try:
                eng.flush_unmatched()
            except Exception:
                pass
        log(f"RELAY asserts written -> {RELAY_ASSERT_FILE}")


_RELAY_ON = os.environ.get("RAKNET_RELAY", "0") not in ("0", "", "false", "no")


if __name__ == "__main__":
    try:
        relay_main() if _RELAY_ON else main()
    except KeyboardInterrupt:
        log("RakNet server stopped")
        sys.exit(0)
