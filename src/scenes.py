#!/usr/bin/env python3
"""Per-scene SceneInfos / ConnectionResult registry for the offline server.

The client connects to several scenes in sequence (authenticator, friends,
party-manager, the party instance, matchmaking, gamesession). Each plugin only
registers its service if the scene it connects to advertises that plugin's
metadata key in its SceneInfosDto; replaying the *authenticator* blob for every
scene is why friends failed with "Dependency not found".

These blobs were extracted byte-exact from a REAL successful capture
(relay.jsonl) and are identity-independent (they declare scene metadata + route
name->handle maps, no user data), so we replay them verbatim. The server-side
SceneHandle each carries (authenticator=141, friends=142, party-manager=143,
party=144, matchmaking=...) becomes the RakNet message-id byte for that scene's
later traffic, so they must stay unique and consistent — which they already are
in the captured blobs.
"""
import base64
import os
import re
import struct

_DIR = os.path.join(os.path.dirname(os.path.abspath(__file__)), "scenes")


def _load(name):
    with open(os.path.join(_DIR, name), "rb") as f:
        return f.read()


# scene short-name (SceneId suffix) -> (SceneInfosDto blob, ConnectionResult blob)
SCENES = {
    "authenticator": (_load("authenticator.infos.bin"), _load("authenticator.connect.bin")),
    "friends":       (_load("friends.infos.bin"),       _load("friends.connect.bin")),
    "party-manager": (_load("party-manager.infos.bin"), _load("party-manager.connect.bin")),
    "matchmaking":   (_load("matchmaking.infos.bin"),   _load("matchmaking.connect.bin")),
    # The party instance scene is dynamic (party-<guid>); its blobs are templates
    # handled specially by the party-manager RPC layer (Phase 2).
    "party":         (_load("party.infos.bin"),         _load("party.connect.bin")),
}

# --- Dynamic scene templates (Milestone 2) ----------------------------------
# Party instances (party-<guid>) and game sessions (bare <guid>) are created on
# the fly, one per leader / per match. We template the byte-exact captured blobs
# by (a) substituting the baked guid in the SceneId and (b) patching the
# SceneHandle so each scene a single client connects to gets a unique handle.
GAMESESSION_INFOS = _load("gamesession.infos.bin")
GAMESESSION_CONNECT = _load("gamesession.connect.bin")

# Baked guids in the captured templates (full SceneId guid, 36 chars each).
PARTY_TEMPLATE_GUID = "4cf8b129-05b1-4d83-960a-37fa1b21eff1"
GS_TEMPLATE_GUID = "d83d0c4a-b4b7-45d9-8f4e-b1c2a3920f58"
_PT_GUID_B = PARTY_TEMPLATE_GUID.encode()
_GS_GUID_B = GS_TEMPLATE_GUID.encode()


def _patch_handle(connect_blob, new_handle):
    """Replace the SceneHandle value in a ConnectionResult blob. The baked handle
    is always 0xcc-encoded (uint8, since real handles are >= 128); new_handle must
    also be in 128..255 so the byte length is preserved (no msgpack re-framing)."""
    m = re.search(rb"SceneHandle", connect_blob)
    i = m.end()
    if connect_blob[i] != 0xcc or not (128 <= new_handle <= 255):
        raise ValueError(f"cannot patch SceneHandle (byte=0x{connect_blob[i]:02x}, "
                         f"new={new_handle})")
    return connect_blob[:i + 1] + bytes([new_handle]) + connect_blob[i + 2:]


def party_infos(guid):
    return SCENES["party"][0].replace(_PT_GUID_B, guid.encode())


def party_connect(guid, handle):
    return _patch_handle(SCENES["party"][1].replace(_PT_GUID_B, guid.encode()), handle)


def gamesession_infos(guid):
    return GAMESESSION_INFOS.replace(_GS_GUID_B, guid.encode())


def gamesession_connect(guid, handle):
    return _patch_handle(GAMESESSION_CONNECT.replace(_GS_GUID_B, guid.encode()), handle)


# Static scene suffixes (singletons per client, fixed baked handles).
STATIC_SUFFIXES = ("authenticator", "friends", "party-manager", "matchmaking")


def classify_scene(scene_id):
    """Map a full SceneId to (kind, key):
      ('static', suffix) | ('party', guid) | ('gamesession', guid)."""
    if not scene_id:
        return ("static", "authenticator")
    suf = scene_id.rsplit("/", 1)[-1]
    if suf in STATIC_SUFFIXES:
        return ("static", suf)
    if suf.startswith("party-"):
        return ("party", suf[len("party-"):])
    return ("gamesession", suf)        # bare guid -> game session scene


def request_scene_id(data):
    """Recover the full SceneId from a GET_SCENE_INFOS / CONNECT_TO_SCENE body."""
    m = re.search(rb"Token", data)
    if not m:
        return None
    tok, _ = _read_mp_str(data, m.end())
    return token_scene_id(tok)


def scene_handle(connect_blob):
    """Read the SceneHandle out of a ConnectionResult blob (fixmap: SceneHandle first)."""
    # blob = fixmap2 {SceneHandle: u8/u16, RouteMappings: {...}}; find "SceneHandle".
    m = re.search(rb"SceneHandle", connect_blob)
    if not m:
        return None
    i = m.end()
    c = connect_blob[i]
    if c <= 0x7f:
        return c
    if c == 0xcc:
        return connect_blob[i + 1]
    if c == 0xcd:
        return struct.unpack(">H", connect_blob[i + 1:i + 3])[0]
    return None


def _read_mp_str(b, i):
    """Read one msgpack string at offset i -> (value, next_i) or (None, i)."""
    if i >= len(b):
        return None, i
    c = b[i]
    if 0xa0 <= c <= 0xbf:
        n = c & 0x1f; i += 1
    elif c == 0xd9:
        n = b[i + 1]; i += 2
    elif c == 0xda:
        n = struct.unpack(">H", b[i + 1:i + 3])[0]; i += 3
    else:
        return None, i
    return b[i:i + n].decode("utf-8", "replace"), i + n


def token_scene_id(connection_token):
    """Recover the full SceneId from a connection token string we minted.

    Token = base64(ConnectionData msgpack) + "-" + base64(signature). The
    ConnectionData carries a plaintext "SceneId" msgpack string. Returns the
    full scene id (e.g. ".../friends") or None.
    """
    if not connection_token:
        return None
    head = connection_token.split("-", 1)[0]
    try:
        cd = base64.b64decode(head + "=" * (-len(head) % 4))
    except Exception:
        return None
    m = re.search(rb"SceneId", cd)
    if not m:
        return None
    val, _ = _read_mp_str(cd, m.end())
    return val


def scene_suffix(scene_id):
    """Map a full SceneId to its registry key (suffix after last '/')."""
    if not scene_id:
        return None
    suf = scene_id.rsplit("/", 1)[-1]
    if suf.startswith("party-") and suf != "party-manager":
        return "party"          # dynamic party instance -> party template
    return suf


def request_scene_suffix(data):
    """Given a GET_SCENE_INFOS / CONNECT_TO_SCENE request body (msgpack map with a
    'Token' string), return the registry suffix of the scene being requested."""
    m = re.search(rb"Token", data)
    if not m:
        return None
    tok, _ = _read_mp_str(data, m.end())
    return scene_suffix(token_scene_id(tok))


def get_scene_infos(suffix):
    e = SCENES.get(suffix)
    return e[0] if e else None


def get_connect_result(suffix):
    e = SCENES.get(suffix)
    return e[1] if e else None


def party_scene_id():
    """Return the party instance scene's short SceneId (e.g. 'party-<guid>') as
    baked into the byte-exact party.infos.bin template. The offline server mints
    its createsession token for this exact id so CONNECT_TO_SCENE resolves back to
    the same byte-exact party blobs (handle 144) — one party per session, which is
    all local co-op needs."""
    infos = SCENES["party"][0]
    m = re.search(rb"SceneId", infos)
    if not m:
        return None
    sid, _ = _read_mp_str(infos, m.end())
    return sid


def _mp_value_len(b, i):
    """Byte length of the msgpack value at offset i (the subset we meet in route
    maps). Best-effort; raises on unsupported wide types."""
    c = b[i]
    if c <= 0x7f or c >= 0xe0 or c in (0xc0, 0xc2, 0xc3):
        return 1
    if 0xa0 <= c <= 0xbf:
        return 1 + (c & 0x1f)
    if c in (0xcc, 0xd0):
        return 2
    if c in (0xcd, 0xd1):
        return 3
    if c in (0xce, 0xd2, 0xca):
        return 5
    if c in (0xcf, 0xd3, 0xcb):
        return 9
    if c == 0xd9:
        return 2 + b[i + 1]
    if c == 0xda:
        return 3 + struct.unpack(">H", b[i + 1:i + 3])[0]
    if 0x80 <= c <= 0x8f:                       # fixmap: sum of its k/v lengths
        n = c & 0xf; j = i + 1
        for _ in range(2 * n):
            j += _mp_value_len(b, j)
        return j - i
    raise ValueError(f"unsupported mp type 0x{c:02x} at {i}")


def _read_handle(b, i):
    h = b[i]
    if h <= 0x7f:
        return h, i + 1
    if h == 0xcc:
        return b[i + 1], i + 2
    if h == 0xcd:
        return struct.unpack(">H", b[i + 1:i + 3])[0], i + 3
    return None, i + 1


def _read_route_mappings(connect_blob):
    """ConnectionResult.RouteMappings -> {routeName: clientRecvHandle}.
    Handles the SERVER uses when sending TO the client on this scene."""
    m = re.search(rb"RouteMappings", connect_blob)
    if not m:
        return {}
    i = m.end()
    c = connect_blob[i]
    if 0x80 <= c <= 0x8f:
        n = c & 0xf; i += 1
    elif c == 0xde:
        n = struct.unpack(">H", connect_blob[i + 1:i + 3])[0]; i += 3
    else:
        return {}
    out = {}
    for _ in range(n):
        name, i = _read_mp_str(connect_blob, i)
        handle, i = _read_handle(connect_blob, i)
        if name is not None and handle is not None:
            out[name] = handle
    return out


def _read_server_routes(infos_blob):
    """SceneInfosDto.Routes -> {routeName: serverRecvHandle}.
    Handles the CLIENT uses when sending TO the server (invoking RPCs)."""
    m = re.search(rb"Routes", infos_blob)
    if not m:
        return {}
    i = m.end()
    c = infos_blob[i]
    if 0x90 <= c <= 0x9f:
        n = c & 0xf; i += 1
    elif c == 0xdc:
        n = struct.unpack(">H", infos_blob[i + 1:i + 3])[0]; i += 3
    elif c == 0xdd:
        n = struct.unpack(">I", infos_blob[i + 1:i + 5])[0]; i += 5
    else:
        return {}
    out = {}
    for _ in range(n):
        hc = infos_blob[i]
        if 0x80 <= hc <= 0x8f:
            fields = hc & 0xf; i += 1
        elif hc == 0xde:
            fields = struct.unpack(">H", infos_blob[i + 1:i + 3])[0]; i += 3
        else:
            break
        name = handle = None
        for _ in range(fields):
            key, i = _read_mp_str(infos_blob, i)
            if key == "Name":
                name, i = _read_mp_str(infos_blob, i)
            elif key == "Handle":
                handle, i = _read_handle(infos_blob, i)
            else:
                i += _mp_value_len(infos_blob, i)
        if name is not None and handle is not None:
            out[name] = handle
    return out


class SceneRoutes:
    """Resolved route handles for one scene (parsed once from the blobs)."""
    def __init__(self, suffix, infos, connect):
        self.suffix = suffix
        self.handle = scene_handle(connect)                # RakNet msg-id byte
        self.server_recv = _read_server_routes(infos)      # name -> client-sends handle
        self.client_recv = _read_route_mappings(connect)   # name -> server-sends handle
        self.server_recv_rev = {v: k for k, v in self.server_recv.items()}
        self.rpc_next = self.client_recv.get("stormancer.rpc.next")
        self.rpc_completed = self.client_recv.get("stormancer.rpc.completed")


# scene-handle (RakNet msg-id byte) -> SceneRoutes
ROUTES_BY_HANDLE = {}
for _suf, (_infos, _connect) in SCENES.items():
    _sr = SceneRoutes(_suf, _infos, _connect)
    if _sr.handle is not None:
        ROUTES_BY_HANDLE[_sr.handle] = _sr


def routes_for_handle(handle):
    return ROUTES_BY_HANDLE.get(handle)


def known_scene_handle(handle):
    return handle in ROUTES_BY_HANDLE
