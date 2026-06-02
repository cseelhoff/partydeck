#!/usr/bin/env python3
"""pcap -> CSV decoder for Ravenswatch joiner network analysis.

Parses a classic pcap (LINUX_SLL2 / cooked v2) and emits ONE CSV per capture
with every packet, sorted by time, with an order id, time offset, src
service/proc, dst service/proc, raw (hex), decoded, and a 1-line summary.

Focus decoder: the Stormancer RakNet plane (UDP :30100) is PLAINTEXT and fully
decoded (datagram type, encapsulated messages, system-request names, scene
route bytes 0x8e/0x90, request/response/complete). TLS :443 is encrypted -> we
extract SNI from ClientHello and otherwise mark size/direction. Other planes
(EOS P2P, goldberg LAN, RTC media) are labelled by port.

Usage: pcap2csv.py <in.pcap> <out.csv>
"""
import sys, struct, csv, json, base64, os

# ---- RakNet / Stormancer constants (from broker raknet.py) ----
ID_UNCONNECTED_PING = 0x01; ID_UNCONNECTED_PING_OPEN_CONN = 0x02; ID_UNCONNECTED_PONG = 0x1C
ID_CONNECTED_PING = 0x00; ID_CONNECTED_PONG = 0x03
ID_CONNECTION_REQUEST = 0x09; ID_CONNECTION_REQUEST_ACCEPTED = 0x10
ID_NEW_INCOMING_CONNECTION = 0x13; ID_DISCONNECTION_NOTIFICATION = 0x15
ID_CONNECTION_ATTEMPT_FAILED = 0x11; ID_ALREADY_CONNECTED = 0x12
ID_NO_FREE_INCOMING_CONNECTIONS = 0x14; ID_CONNECTION_BANNED = 0x17
ID_IP_RECENTLY_CONNECTED = 0x1A
ID_SYSTEM_REQUEST = 134; ID_REQUEST_RESPONSE_MSG = 137
ID_REQUEST_RESPONSE_COMPLETE = 138; ID_REQUEST_RESPONSE_ERROR = 139
ID_CONNECTION_RESULT = 140; ID_SCENES = 141
ID_OPEN_CONNECTION_REQUEST_1 = 0x05; ID_OPEN_CONNECTION_REPLY_1 = 0x06
ID_OPEN_CONNECTION_REQUEST_2 = 0x07; ID_OPEN_CONNECTION_REPLY_2 = 0x08
RAKNET_OFFLINE_MAGIC = bytes.fromhex("00ffff00fefefefefdfdfdfd12345678")
RAK_NAMES = {
    0x00:"ID_CONNECTED_PING",0x03:"ID_CONNECTED_PONG",0x09:"ID_CONNECTION_REQUEST",
    0x10:"ID_CONNECTION_REQUEST_ACCEPTED",0x13:"ID_NEW_INCOMING_CONNECTION",
    0x15:"ID_DISCONNECTION_NOTIFICATION",0x11:"ID_CONNECTION_ATTEMPT_FAILED",
    0x12:"ID_ALREADY_CONNECTED",0x14:"ID_NO_FREE_INCOMING_CONNECTIONS",
    0x17:"ID_CONNECTION_BANNED",0x1A:"ID_IP_RECENTLY_CONNECTED",
    0x05:"ID_OPEN_CONNECTION_REQUEST_1",0x06:"ID_OPEN_CONNECTION_REPLY_1",
    0x07:"ID_OPEN_CONNECTION_REQUEST_2",0x08:"ID_OPEN_CONNECTION_REPLY_2",
    0x01:"ID_UNCONNECTED_PING",0x02:"ID_UNCONNECTED_PING_OPEN_CONN",0x1C:"ID_UNCONNECTED_PONG",
    134:"ID_SYSTEM_REQUEST",137:"ID_REQUEST_RESPONSE_MSG",138:"ID_REQUEST_RESPONSE_COMPLETE",
    139:"ID_REQUEST_RESPONSE_ERROR",140:"ID_CONNECTION_RESULT",141:"ID_SCENES",
}
SR_NAMES = {0:"SET_METADATA",1:"SCENE_READY",2:"PING",13:"GET_SCENE_INFOS_FROM_TOKEN",
            14:"GET_SESSION_TOKEN",16:"GET_SCENE_HANDLE",134:"CONNECT_TO_SCENE",
            135:"DISCONNECT_FROM_SCENE",136:"GET_SCENE_INFOS"}
UNRELIABLE=0; UNRELIABLE_SEQUENCED=1; RELIABLE=2; RELIABLE_ORDERED=3; RELIABLE_SEQUENCED=4

def rd_u24le(b,o): return b[o]|(b[o+1]<<8)|(b[o+2]<<16)

# ---- PROVEN RakNet message reassembly (ported verbatim from decode_party.py) -
UNREL, UNREL_SEQ, REL, REL_ORD, REL_SEQ = range(5)
def parse_messages(d, off=4):
    """Return list of (split_tuple_or_None, payload). split_tuple=(cnt,sid,sidx)."""
    out = []
    n = len(d)
    while off + 3 <= n:
        m = d[off]; off += 1
        rel = (m >> 5) & 7; hs = (m >> 4) & 1
        if rel > 4 or off + 2 > n: break
        db = (d[off] << 8) | d[off+1]; off += 2
        if db == 0: break
        if rel in (REL, REL_ORD, REL_SEQ):
            if off + 3 > n: break
            off += 3
        if rel in (UNREL_SEQ, REL_SEQ): off += 3
        if rel in (UNREL_SEQ, REL_SEQ, REL_ORD): off += 4
        sp = None
        if hs:
            cnt = struct.unpack(">I", d[off:off+4])[0]; off += 4
            sid = struct.unpack(">H", d[off:off+2])[0]; off += 2
            sidx = struct.unpack(">I", d[off:off+4])[0]; off += 4
            sp = (cnt, sid, sidx)
        nb = (db + 7) // 8
        if off + nb > n: break
        out.append((sp, d[off:off+nb])); off += nb
    return out

# ---- full msgpack decoder (ported verbatim from decode_party.py) -------------
def mp(b, i=0):
    if i >= len(b): return ("<eof>", i)
    c = b[i]; i += 1
    if c < 0x80: return (c, i)
    if c >= 0xe0: return (c - 256, i)
    if 0x80 <= c <= 0x8f:
        n = c & 0xf; d = {}
        for _ in range(n):
            k, i = mp(b, i); v, i = mp(b, i); d[k] = v
        return (d, i)
    if 0x90 <= c <= 0x9f:
        n = c & 0xf; a = []
        for _ in range(n):
            v, i = mp(b, i); a.append(v)
        return (a, i)
    if 0xa0 <= c <= 0xbf:
        n = c & 0x1f; s = b[i:i+n]; i += n
        try: return (s.decode(), i)
        except: return (s, i)
    if c == 0xc0: return (None, i)
    if c == 0xc2: return (False, i)
    if c == 0xc3: return (True, i)
    if c == 0xcc: return (b[i], i+1)
    if c == 0xcd: return (struct.unpack(">H", b[i:i+2])[0], i+2)
    if c == 0xce: return (struct.unpack(">I", b[i:i+4])[0], i+4)
    if c == 0xcf: return (struct.unpack(">Q", b[i:i+8])[0], i+8)
    if c == 0xd0: return (struct.unpack(">b", b[i:i+1])[0], i+1)
    if c == 0xd1: return (struct.unpack(">h", b[i:i+2])[0], i+2)
    if c == 0xd2: return (struct.unpack(">i", b[i:i+4])[0], i+4)
    if c == 0xd3: return (struct.unpack(">q", b[i:i+8])[0], i+8)
    if c == 0xca: return (struct.unpack(">f", b[i:i+4])[0], i+4)
    if c == 0xcb: return (struct.unpack(">d", b[i:i+8])[0], i+8)
    if c == 0xd9:
        n = b[i]; i += 1; s = b[i:i+n]; i += n
        try: return (s.decode(), i)
        except: return (s, i)
    if c == 0xda:
        n = struct.unpack(">H", b[i:i+2])[0]; i += 2; s = b[i:i+n]; i += n
        try: return (s.decode(), i)
        except: return (s, i)
    if c == 0xdb:
        n = struct.unpack(">I", b[i:i+4])[0]; i += 4; s = b[i:i+n]; i += n
        try: return (s.decode(), i)
        except: return (s, i)
    if c == 0xc4:
        n = b[i]; i += 1; return (b[i:i+n], i+n)
    if c == 0xc5:
        n = struct.unpack(">H", b[i:i+2])[0]; i += 2; return (b[i:i+n], i+n)
    if c == 0xc6:
        n = struct.unpack(">I", b[i:i+4])[0]; i += 4; return (b[i:i+n], i+n)
    if c == 0xdc:
        n = struct.unpack(">H", b[i:i+2])[0]; i += 2; a = []
        for _ in range(n):
            v, i = mp(b, i); a.append(v)
        return (a, i)
    if c == 0xde:
        n = struct.unpack(">H", b[i:i+2])[0]; i += 2; d = {}
        for _ in range(n):
            k, i = mp(b, i); v, i = mp(b, i); d[k] = v
        return (d, i)
    # ext types (fixext1/2/4/8/16 = 0xd4-0xd8 ; ext8/16/32 = 0xc7-0xc9).
    # msgpack ext type -1 (0xff) is a Timestamp (used by Stormancer for Issued/Expiration).
    if 0xd4 <= c <= 0xd8:
        sz = {0xd4:1,0xd5:2,0xd6:4,0xd7:8,0xd8:16}[c]
        et = struct.unpack(">b", b[i:i+1])[0]; i += 1
        data = b[i:i+sz]; i += sz
        return (_mp_ext(et, data), i)
    if c in (0xc7,0xc8,0xc9):
        if c == 0xc7: n = b[i]; i += 1
        elif c == 0xc8: n = struct.unpack(">H", b[i:i+2])[0]; i += 2
        else: n = struct.unpack(">I", b[i:i+4])[0]; i += 4
        et = struct.unpack(">b", b[i:i+1])[0]; i += 1
        data = b[i:i+n]; i += n
        return (_mp_ext(et, data), i)
    return (f"<unk {c:#x}>", i)

def _mp_ext(et, data):
    """Decode a msgpack extension. type -1 = Timestamp (RFC); else opaque."""
    import datetime
    if et == -1:
        if len(data) == 4:
            sec = struct.unpack(">I", data)[0]; ns = 0
        elif len(data) == 8:
            v = struct.unpack(">Q", data)[0]; ns = v >> 34; sec = v & 0x3FFFFFFFF
        elif len(data) == 12:
            ns = struct.unpack(">I", data[:4])[0]; sec = struct.unpack(">q", data[4:])[0]
        else:
            return f"<ts {data.hex()}>"
        try:
            dt = datetime.datetime.fromtimestamp(sec+ns/1e9, datetime.timezone.utc)
            return dt.strftime("%Y-%m-%dT%H:%M:%SZ")
        except Exception:
            return f"<ts {sec}.{ns}>"
    return f"<ext{et} {data.hex()}>"

def mp_all(b):
    vals = []; i = 0
    while i < len(b):
        try:
            v, ni = mp(b, i)
        except Exception as e:
            vals.append(f"<err {e} at {i}>"); break
        if ni <= i: break
        vals.append(v); i = ni
    return vals

def _short(v, maxlen=4096):
    """Repr of a decoded msgpack value for the CSV cell. The `decoded` column is
    meant to be complete, so the cap is large and only guards pathological blobs."""
    s=repr(v)
    if len(s)>maxlen: s=s[:maxlen-1]+"\u2026"
    return s

# ===================== EOS-P2P (NEE emu protobuf) =====================
# The offline EOS P2P plane (UDP :55789 host / :55790 joiner + LAN broadcast)
# carries Nemirtingas-Epic-Emu `Network_Message_pb` (see epic_emu/proto/network_proto.proto):
#   1 source_id(str PUID) 2 dest_id(str PUID) 3 game_id(str) 4 timestamp(int64)
#   oneof: 5 network_advertise 7 presence 8 userinfo 9 session 10 p2p 11 connect
#          12 sessions_search 13 lobby 14 lobbies_search
# Map known PUIDs to the same HOST/JOINER role names used by the RakNet plane.
PUID_ROLE = {
    "d5a26726573fab5615da144fa56e6269": "HOST",    # Dad  (profile, :55789)
    "3b2ac1e835bd0f1c45355f4f1271e2f0": "JOINER",   # Elsie (profile, :55790)
}
def puid_role(puid):
    if not puid: return None
    return PUID_ROLE.get(puid, f"EOS:{puid[:6]}")

def _pb_varint(b,i):
    shift=0; val=0
    while i<len(b):
        c=b[i]; i+=1
        val |= (c&0x7f)<<shift
        if not (c&0x80): return val,i
        shift+=7
    raise ValueError("truncated varint")

def pb_fields(b):
    """Parse a protobuf message into [(field_num, wire_type, value)].
    wire 0=varint(int) 1=fixed64(bytes) 2=len-delim(bytes) 5=fixed32(bytes)."""
    i=0; out=[]
    while i<len(b):
        key,i=_pb_varint(b,i)
        fn=key>>3; wt=key&7
        if wt==0:   v,i=_pb_varint(b,i)
        elif wt==1: v=b[i:i+8]; i+=8
        elif wt==2:
            ln,i=_pb_varint(b,i); v=b[i:i+ln]; i+=ln
            if len(v)<ln: raise ValueError("truncated bytes")
        elif wt==5: v=b[i:i+4]; i+=4
        else: raise ValueError(f"bad wire {wt}")
        out.append((fn,wt,v))
    return out

def _pb_str(fields,fn):
    for f in fields:
        if f[0]==fn and f[1]==2:
            try: return f[2].decode("utf-8")
            except Exception: return f[2].hex()
    return None
def _pb_int(fields,fn):
    for f in fields:
        if f[0]==fn and f[1]==0: return f[2]
    return None
def _pb_sub(fields,fn):
    for f in fields:
        if f[0]==fn and f[1]==2:
            try: return pb_fields(f[2])
            except Exception: return None
    return None
def _first_oneof(fields, names):
    """Return (name, subfields_or_value) for the first present oneof field."""
    for fn,name in names.items():
        for f in fields:
            if f[0]==fn:
                if f[1]==2:
                    try: return name, pb_fields(f[2])
                    except Exception: return name, []
                return name, f[2]
    return None,None

_ADV ={1:"port",2:"peer",3:"accept",4:"peer_connect",5:"peer_disconnect"}
_P2P ={1:"connect_request",2:"connect_response",3:"data",4:"data_ack",5:"close"}
_LOB ={1:"lobby_update",2:"join_request",3:"join_response",4:"invite",
       5:"member_update",6:"member_join",7:"member_leave",8:"member_promote"}
_SES ={1:"request",2:"infos",3:"destroy",4:"join_request",5:"join_response",
       6:"invite",7:"invite_response",8:"register",9:"unregister"}
_PRE ={1:"info_request",2:"info"}
_CON ={1:"request",2:"infos"}
_TOP ={5:("advertise",_ADV),7:("presence",_PRE),8:("userinfo",None),
       9:("session",_SES),10:("p2p",_P2P),11:("connect",_CON),
       12:("sessions_search",None),13:("lobby",_LOB),14:("lobbies_search",None)}

def _sub_detail(top, sub, body):
    """Extract the most useful identifiers from a decoded oneof sub-message."""
    if not isinstance(body,list): return ""
    if top=="advertise" and sub=="port":
        p=_pb_int(body,1)
        return f"port={p}" if p is not None else ""
    if top=="p2p" and sub=="data":
        ch=_pb_int(body,2); data=None
        for f in body:
            if f[0]==1 and f[1]==2: data=f[2]
        sock=_pb_str(body,3)
        bits=[]
        if ch is not None: bits.append(f"ch={ch}")
        if data is not None: bits.append(f"{len(data)}B")
        if sock: bits.append(f"sock={sock}")
        return " ".join(bits)
    if top=="lobby":
        lid=_pb_str(body,1)
        if sub in ("member_join","member_leave","member_promote"):
            mid=_pb_str(body,2)
            return f"lobby={lid} member={puid_role(mid) or (mid or '')[:8]}"
        if sub in ("join_request","join_response","invite"):
            inner=_pb_sub(body,1)
            ilid=_pb_str(inner,1) if inner else lid
            return f"lobby={ilid}"
        return f"lobby={lid}" if lid else ""
    if top=="session":
        sid=_pb_str(body,1)
        return f"session={sid}" if sid else ""
    if top=="presence" and sub=="info":
        uid=_pb_str(body,1); rich=_pb_str(body,6)
        bits=[]
        if uid: bits.append(f"user={puid_role(uid) or uid[:8]}")
        if rich: bits.append(f"rich={rich[:24]}")
        return " ".join(bits)
    if top=="connect" and sub=="infos":
        uid=_pb_str(body,1); dn=_pb_str(body,3)
        bits=[]
        if uid: bits.append(f"user={puid_role(uid) or uid[:8]}")
        if dn: bits.append(f"name={dn}")
        return " ".join(bits)
    return ""

def decode_eos_p2p(pl):
    """Decode a NEE-emu Network_Message_pb datagram.
    Returns (summary, decoded, src_role, dst_role) or None if it isn't one."""
    try:
        f=pb_fields(pl)
    except Exception:
        return None
    src=_pb_str(f,1); dst=_pb_str(f,2)
    if src is None and dst is None:
        return None
    ts=_pb_int(f,4)
    top,body=_first_oneof(f,{k:v[0] for k,v in _TOP.items()})
    action="(envelope)"; detail=""
    if top:
        sub_map=_TOP[[k for k,v in _TOP.items() if v[0]==top][0]][1]
        if sub_map and isinstance(body,list):
            sname,sbody=_first_oneof(body,sub_map)
            if sname:
                action=f"{top}/{sname}"
                detail=_sub_detail(top,sname,sbody)
            else:
                action=top
        else:
            action=top
    src_role=puid_role(src); dst_role=puid_role(dst)
    summary=f"P2P {action}" + (f" {detail}" if detail else "")
    parts=[f"NEE-P2P {action}"]
    if src_role: parts.append(f"src={src_role}")
    if dst_role: parts.append(f"dst={dst_role}")
    if detail: parts.append(detail)
    if ts is not None: parts.append(f"ts={ts}")
    decoded=" ".join(parts)
    return summary, decoded, src_role, dst_role
# ===================== end EOS-P2P =====================

# ===================== STEAM-LAN (Goldberg Common_Message) =====================
# Goldberg emu LAN discovery/messaging on UDP :47584 (see gbe_fork/dll/net.proto).
#   Common_Message: 1 source_id(SteamID64) 2 dest_id(SteamID64)
#   oneof: 3 announce 4 low_level 5 lobby 6 lobby_messages 7 network 8 gameserver
#          9 friend 10 auth_ticket 11 friend_messages 12 network_old 13 networking_sockets
#          14 steam_messages 15 networking_messages ...
#   128 source_ip 129 source_port
STEAMID_ROLE = {
    # populate with offline Dad/Elsie SteamID64s if known; falls back to short id
}
def steam_role(sid):
    if sid is None: return None
    s=str(sid)
    return STEAMID_ROLE.get(s, f"STEAM:{s[-5:]}")

def _pb_packed_varints(b):
    out=[]; i=0
    while i<len(b):
        try: v,i=_pb_varint(b,i)
        except Exception: break
        out.append(v)
    return out

_GBE_TOP={3:"announce",4:"low_level",5:"lobby",6:"lobby_messages",7:"network",
          8:"gameserver",9:"friend",10:"auth_ticket",11:"friend_messages",
          12:"network_old",13:"networking_sockets",14:"steam_messages",
          15:"networking_messages",16:"gs_stats",17:"leaderboards",
          18:"user_stats",19:"gs_items"}
_GBE_ANNOUNCE_TYPE={0:"PING",1:"PONG"}
_GBE_LOWLVL_TYPE={0:"HEARTBEAT",1:"CONNECT",2:"DISCONNECT"}

def _gbe_detail(top, body):
    if not isinstance(body,list): return ""
    if top=="announce":
        t=_pb_int(body,1) or 0
        tcp=_pb_int(body,3); appid=_pb_int(body,5)
        npeers=sum(1 for f in body if f[0]==4)
        bits=[_GBE_ANNOUNCE_TYPE.get(t,f"t{t}")]
        if tcp: bits.append(f"tcp={tcp}")
        if appid: bits.append(f"appid={appid}")
        if npeers: bits.append(f"peers={npeers}")
        return " ".join(bits)
    if top=="low_level":
        t=_pb_int(body,1) or 0
        return _GBE_LOWLVL_TYPE.get(t,f"t{t}")
    if top=="lobby":
        room=_pb_int(body,1); owner=_pb_int(body,2)
        bits=[]
        if room is not None: bits.append(f"room={room}")
        if owner is not None: bits.append(f"owner={steam_role(owner)}")
        return " ".join(bits)
    if top=="network":
        ch=_pb_int(body,1)
        return f"ch={ch}" if ch is not None else ""
    if top=="gameserver":
        return f"gsid={_pb_int(body,1)}"
    if top=="friend":
        return f"id={steam_role(_pb_int(body,1))}"
    return ""

def decode_steam_lan(pl):
    """Decode a Goldberg Common_Message datagram. Returns (summary,decoded,src_role,dst_role) or None."""
    try:
        f=pb_fields(pl)
    except Exception:
        return None
    src=_pb_int(f,1); dst=_pb_int(f,2)
    if src is None:
        return None
    top,body=_first_oneof(f,_GBE_TOP)
    if top is None:
        return None
    detail=_gbe_detail(top,body)
    src_role=steam_role(src); dst_role=steam_role(dst) if dst else None
    summary=f"GBE {top}"+(f" {detail}" if detail else "")
    parts=[f"GBE-LAN {top}"]
    if src_role: parts.append(f"src={src_role}")
    if dst_role: parts.append(f"dst={dst_role}")
    if detail: parts.append(detail)
    decoded=" ".join(parts)
    return summary, decoded, src_role, dst_role
# ===================== end STEAM-LAN =====================

# Goldberg TCP channel (:47584): stream of [uint32_le length][Common_Message] frames.
def _gbe_frame_str(body):
    """Decode one Goldberg Common_Message frame body -> (text, src_role, dst_role)."""
    g=decode_steam_lan(body)
    if g:
        _,dec,sr,dr=g
        return (dec[len("GBE-LAN "):] if dec.startswith("GBE-LAN ") else dec), sr, dr
    # frame with no source_id (field 1): a connection hello, or a bare oneof
    # body (e.g. low_level heartbeat) sent after the handshake.
    try:
        f=pb_fields(body); sid=_pb_int(f,1)
        top,sub=_first_oneof(f,_GBE_TOP)
        if top is not None:
            det=_gbe_detail(top,sub)
            return (f"{top}"+(f" {det}" if det else "")), None, None
        if sid is not None:
            return f"hello src={steam_role(sid)}", steam_role(sid), None
    except Exception:
        pass
    return f"{len(body)}B", None, None

def decode_steam_lan_tcp(pl, streambuf=None, skey=None):
    """Decode Goldberg framed Common_Message(s) from a TCP segment.

    A single Goldberg message can exceed the TCP MSS and span many segments
    (e.g. a ~135 KB lobby blob). To handle that, payloads are appended to a
    per-stream buffer (streambuf[skey]) and only *complete* length-prefixed
    frames are decoded; the partial tail is carried to the next segment.
    Returns (summary, decoded, src_role, dst_role) or None."""
    if streambuf is not None and skey is not None:
        buf=streambuf.get(skey, b"") + pl
    else:
        buf=pl
    msgs=[]; src_role=dst_role=None; i=0; n=len(buf)
    while i+4<=n:
        ln=struct.unpack("<I",buf[i:i+4])[0]
        if ln==0:
            i+=4; continue
        if i+4+ln>n:
            break  # frame not fully arrived yet -> keep tail for next segment
        body=buf[i+4:i+4+ln]; i+=4+ln
        txt,sr,dr=_gbe_frame_str(body)
        src_role=src_role or sr; dst_role=dst_role or dr
        msgs.append(txt)
    # stash the unconsumed remainder for the next segment of this stream
    if streambuf is not None and skey is not None:
        streambuf[skey]=buf[i:]
    if not msgs:
        pend=n-i
        if pend>4:
            ln=struct.unpack("<I",buf[i:i+4])[0]
            return (f"GBE-TCP reassembling {pend-4}/{ln}B",
                    f"GBE-TCP reassembling {pend-4}/{ln}B", None, None)
        return None
    summary="GBE-TCP "+msgs[0].split(" src=")[0]
    decoded="GBE-TCP "+" ; ".join(msgs)
    return summary, decoded, src_role, dst_role

def decode_eos_p2p_tcp(pl, streambuf=None, skey=None):
    """Decode EOS-P2P frames carried over the local relay TCP socket.

    Framing = [uint32 BE length][Network_Message_pb protobuf]. Frames can span
    TCP segments, so we reassemble per-stream and decode only complete frames.
    Returns (summary, decoded, src_role, dst_role) or None."""
    if streambuf is not None and skey is not None:
        buf=streambuf.get(skey, b"") + pl
    else:
        buf=pl
    msgs=[]; src_role=dst_role=None; i=0; n=len(buf)
    while i+4<=n:
        ln=struct.unpack(">I",buf[i:i+4])[0]
        if ln==0 or ln>0x200000:   # 0-length keepalive or implausible -> stop
            if ln==0: i+=4; continue
            break
        if i+4+ln>n:
            break  # frame not fully arrived yet
        body=buf[i+4:i+4+ln]; i+=4+ln
        r=decode_eos_p2p(body)
        if r:
            txt,sr,dr=r[1],r[2],r[3]
            src_role=src_role or sr; dst_role=dst_role or dr
            msgs.append(txt.replace("NEE-P2P ",""))
        else:
            # small control frame (e.g. field 5 ack); show generic protobuf fields
            fs=pb_fields(body)
            msgs.append("ctrl "+",".join(f"f{fn}" for fn,_,_ in fs) if fs else "ctrl")
    if streambuf is not None and skey is not None:
        streambuf[skey]=buf[i:]
    if not msgs:
        pend=n-i
        if pend>4:
            ln=struct.unpack(">I",buf[i:i+4])[0]
            return (f"P2P-TCP reassembling {pend-4}/{ln}B",
                    f"P2P-TCP reassembling {pend-4}/{ln}B", None, None)
        return None
    summary="P2P-TCP "+msgs[0]
    decoded="NEE-P2P-TCP "+" ; ".join(msgs)
    return summary, decoded, src_role, dst_role

def decode_http(pl):
    """Decode a plaintext HTTP request or response head. Returns (summary, decoded) or None."""
    try:
        head=pl.split(b"\r\n\r\n",1)[0]
        lines=head.split(b"\r\n")
        if not lines: return None
        first=lines[0].decode("latin1")
        hdrs={}
        for ln in lines[1:]:
            if b":" in ln:
                k,v=ln.split(b":",1); hdrs[k.decode("latin1").lower()]=v.strip().decode("latin1")
        if first.startswith(("GET ","POST ","PUT ","HEAD ","DELETE ","OPTIONS ")):
            meth,path,*_=first.split(" ")
            host=hdrs.get("host","")
            summary=f"HTTP {meth} {path[:40]}"
            decoded=f"HTTP {meth} {host}{path}"+(f" UA={hdrs['user-agent']}" if "user-agent" in hdrs else "")
            return summary, decoded
        if first.startswith("HTTP/"):
            status=first.split(" ",1)[1] if " " in first else first
            ct=hdrs.get("content-type",""); cl=hdrs.get("content-length","")
            summary=f"HTTP resp {status[:30]}"
            decoded=f"HTTP {first}"+(f" type={ct}" if ct else "")+(f" len={cl}" if cl else "")
            return summary, decoded
        return None
    except Exception:
        return None

def decode_scene_payload(mp_msg):
    """PROVEN semantics: scene route message = [handle:1][route:1][msgpack body...].
    handle is the sceneHandle (mid), route is a single byte, body is msgpack."""
    sh=mp_msg[0]
    route=mp_msg[1] if len(mp_msg)>=2 else None
    body=mp_all(mp_msg[2:]) if len(mp_msg)>2 else []
    label=f"scene h=0x{sh:02x} route={route}"
    if body:
        label+=" :: "+" | ".join(_short(v) for v in body)
    return label

def _rak_addr(b, i):
    """RakNet SystemAddress: ver(1) + (IPv4: 4 bytes complemented + port:2be).
    Returns (str, next_index) or (None, i) if it doesn't look like an address."""
    if i>=len(b): return None,i
    ver=b[i]
    if ver==4 and i+7<=len(b):
        ip=".".join(str(b[i+1+k]^0xff) for k in range(4))
        port=struct.unpack(">H",b[i+5:i+7])[0]
        return f"{ip}:{port}", i+7
    if ver==6 and i+29<=len(b):  # IPv6 (rare here)
        return "[ipv6]", i+29
    return None,i

def decode_open_conn(b0, payload):
    """Decode RakNet offline connection handshake (0x05-0x08).
    Returns (decoded, summary, names) or None if not an offline-magic message."""
    nm=RAK_NAMES.get(b0)
    if nm is None or len(payload)<17 or payload[1:17]!=RAKNET_OFFLINE_MAGIC:
        return None
    short=nm.replace("ID_OPEN_CONNECTION_","OPEN_")
    i=17; bits=[]
    if b0==ID_OPEN_CONNECTION_REQUEST_1:
        ver=payload[i] if i<len(payload) else None
        if ver is not None: bits.append(f"proto={ver}")
        bits.append(f"mtu~{len(payload)}B")
    elif b0==ID_OPEN_CONNECTION_REPLY_1:
        if i+8<=len(payload):
            bits.append("guid="+payload[i:i+8].hex()); i+=8
        if i<len(payload): bits.append(f"sec={payload[i]}"); i+=1
        if i+2<=len(payload): bits.append(f"mtu={struct.unpack('>H',payload[i:i+2])[0]}")
    elif b0==ID_OPEN_CONNECTION_REQUEST_2:
        addr,i=_rak_addr(payload,i)
        if addr: bits.append(f"server={addr}")
        if i+2<=len(payload): bits.append(f"mtu={struct.unpack('>H',payload[i:i+2])[0]}"); i+=2
        if i+8<=len(payload): bits.append("clientGuid="+payload[i:i+8].hex())
    elif b0==ID_OPEN_CONNECTION_REPLY_2:
        if i+8<=len(payload):
            bits.append("guid="+payload[i:i+8].hex()); i+=8
        addr,i=_rak_addr(payload,i)
        if addr: bits.append(f"client={addr}")
        if i+2<=len(payload): bits.append(f"mtu={struct.unpack('>H',payload[i:i+2])[0]}"); i+=2
        if i<len(payload): bits.append(f"sec={payload[i]}")
    detail=" ".join(bits)
    decoded=f"{nm}"+(f" :: {detail}" if detail else "")
    summary=f"{short}"+(f" {detail}" if detail else "")
    return decoded, summary, [nm]

def _scene_step(scene_id, route_or_token="connect"):
    """Short (<6 word) human step name for a Stormancer scene, per flow_working_online.md."""
    s=(scene_id or "").lower()
    if "authenticator" in s:           return "connect auth scene"
    if "gamesession" in s:             return "connect gamesession"
    if "partymanagement" in s or "party-manager" in s or "party.manager" in s:
        return "party plumbing"
    if s.startswith("party-") or "/party-" in s or "stormancer.party" in s:
        return "connect party scene"
    if "gamefinder" in s or "matchmaking" in s:
        return "register gamefinder"
    if "friends" in s:                 return "connect friends scene"
    if "serverpool" in s:              return "server pool"
    if "leaderboard" in s:             return "leaderboards scene"
    if scene_id:                       return f"connect {scene_id.split('/')[-1]}"
    return "connect scene"

def decode_storm_token(tok):
    """Decode a Stormancer connection token (base64 -> msgpack map).
    Returns (dict, scene_id) or (None, None)."""
    if not isinstance(tok,str) or len(tok)<8: return None,None
    import base64
    try:
        raw=base64.b64decode(tok+"="*(-len(tok)%4))
    except Exception:
        return None,None
    try:
        v,_=mp(raw,0)
    except Exception:
        return None,None
    if not isinstance(v,dict): return None,None
    return v, v.get("SceneId")

def _fmt_token(tk):
    """Compact one-line view of the interesting token fields for the `decoded` cell."""
    keep=[("SceneId","scene"),("Application","app"),("AccountId","acct"),
          ("Issued","issued"),("Expiration","expires"),("DeploymentId","dep"),
          ("Version","v")]
    bits=[]
    for k,lbl in keep:
        if k in tk and tk[k] not in (None,""):
            bits.append(f"{lbl}={tk[k]}")
    return "TOKEN{ "+", ".join(bits)+" }"

def decode_raknet(payload, splitbuf, ckey):
    """Return (decoded_str, summary, msg_names) for a RakNet UDP datagram.

    splitbuf: dict for cross-datagram split reassembly, keyed by (ckey, sid).
    ckey:     per-connection+direction key so fragments don't cross streams.
    The join-by-code submit is frequently a SPLIT packet, so reassembly is
    mandatory or it vanishes from the decode entirely."""
    if not payload: return "", "empty", []
    b0=payload[0]
    # offline/unconnected single-byte-id messages
    if b0 in (ID_UNCONNECTED_PING,ID_UNCONNECTED_PING_OPEN_CONN,ID_UNCONNECTED_PONG,
              ID_CONNECTION_ATTEMPT_FAILED,ID_ALREADY_CONNECTED,ID_NO_FREE_INCOMING_CONNECTIONS,
              ID_CONNECTION_BANNED,ID_IP_RECENTLY_CONNECTED):
        nm=RAK_NAMES.get(b0,f"0x{b0:02x}"); return nm, nm, [nm]
    if b0==0xC0 or b0==0xA0:  # ACK / NAK
        kind="ACK" if b0==0xC0 else "NAK"; return kind, kind, [kind]
    if b0 in (ID_OPEN_CONNECTION_REQUEST_1,ID_OPEN_CONNECTION_REPLY_1,
              ID_OPEN_CONNECTION_REQUEST_2,ID_OPEN_CONNECTION_REPLY_2):
        oc=decode_open_conn(b0,payload)
        if oc: return oc
    if not (b0&0x80):  # not a data datagram and not known offline id
        nm=RAK_NAMES.get(b0)
        if nm: return nm,nm,[nm]
        return f"raw 0x{b0:02x}", f"raw 0x{b0:02x}", []
    # data datagram: 0x80|flags + uint24 seq + encapsulated messages
    seq=rd_u24le(payload,1)
    raw=parse_messages(payload,4)
    # --- split reassembly: collect fragments, emit only completed payloads ---
    msgs=[]; pending=[]   # pending = split fragments buffered but not yet complete
    for sp,data in raw:
        if not data: continue
        if sp is None:
            msgs.append(data)
        else:
            cnt,sid,sidx=sp
            key=(ckey,sid)
            buf=splitbuf.setdefault(key,{})
            buf[sidx]=data
            if len(buf)>=cnt:
                full=b"".join(buf[k] for k in sorted(buf))
                splitbuf.pop(key,None)
                msgs.append(full)
            else:
                # still waiting for more fragments on a later datagram; note the
                # fragment so the row isn't mislabeled as a bare keepalive.
                pending.append((sid,sidx,cnt))
    parts=[]; summ=[]
    ep_key=ckey[0] if isinstance(ckey,(tuple,list)) and ckey else ckey
    reqmap=splitbuf.setdefault(("__reqmap__",ep_key),{})  # reqId -> short step name
    for m in msgs:
        if not m: continue
        mid=m[0]
        if mid==ID_SYSTEM_REQUEST and len(m)>=2:
            sysid=m[1]
            reqid=struct.unpack("<H",m[2:4])[0] if len(m)>=4 else None
            nm=SR_NAMES.get(sysid,f"sys{sysid}")
            extra=""; step=None
            if len(m)>4:
                try:
                    body=mp_all(m[4:])
                    # CONNECT_TO_SCENE / token-bearing requests carry {'Token': <b64 msgpack>}
                    tok=None
                    if body and isinstance(body[0],dict) and "Token" in body[0]:
                        tk,scene=decode_storm_token(body[0]["Token"])
                        if tk:
                            extra=" :: "+_fmt_token(tk)
                            step=_scene_step(scene)
                    if not extra and body:
                        extra=" :: "+" | ".join(_short(v) for v in body)
                        # GET_SCENE_INFOS etc. often carry the scene id as a plain string
                        for v in body:
                            if isinstance(v,str) and ("scene:" in v or v.startswith("party-")):
                                step=_scene_step(v); break
                except Exception: pass
            if step is None and sysid==134: step="connect scene"
            if step is None and sysid==135: step="leave scene"
            # always map reqId->step so the matching response can be named; fall
            # back to the friendly sysreq name when no scene step applies.
            if reqid is not None:
                reqmap[reqid]=step or nm.lower().replace("_"," ")
            parts.append(f"SYSREQ {nm}"+(f" reqId={reqid}" if reqid is not None else "")+extra)
            summ.append(step or nm)
        elif mid in (ID_REQUEST_RESPONSE_MSG,ID_REQUEST_RESPONSE_COMPLETE,ID_REQUEST_RESPONSE_ERROR):
            nm=RAK_NAMES[mid]
            reqid=struct.unpack("<H",m[1:3])[0] if len(m)>=3 else None
            # RESPONSE_MSG carries a msgpack body (SceneHandle/RouteMappings,
            # session token, etc.) after the u16 reqId; COMPLETE/ERROR are bare.
            extra=""
            if mid==ID_REQUEST_RESPONSE_MSG and len(m)>3:
                try:
                    body=mp_all(m[3:])
                    if body:
                        shown=[]
                        for v in body:
                            if isinstance(v,str) and len(v)>40 and v[:2]=="i6":
                                tk,_=decode_storm_token(v)
                                shown.append(_fmt_token(tk) if tk else _short(v))
                            else:
                                shown.append(_short(v))
                        extra=" :: "+" | ".join(shown)
                except Exception: pass
            parts.append(nm+(f" reqId={reqid}" if reqid is not None else "")+extra)
            step=reqmap.get(reqid) if reqid is not None else None
            kind={ID_REQUEST_RESPONSE_MSG:"reply",ID_REQUEST_RESPONSE_COMPLETE:"ack",
                  ID_REQUEST_RESPONSE_ERROR:"error"}[mid]
            summ.append(f"{step} {kind}" if step else nm.replace("ID_REQUEST_RESPONSE_","RESP_"))
        elif mid in (ID_CONNECTED_PING,ID_CONNECTED_PONG):
            parts.append(RAK_NAMES[mid]); summ.append(RAK_NAMES[mid].replace("ID_",""))
        elif mid==ID_SCENES:
            # ID_SCENES: 0x8d + sceneHandle(u16 LE) + msgpack stream
            # (route ints + scene name / connection token / metadata).
            handle=struct.unpack("<H",m[1:3])[0] if len(m)>=3 else None
            body=[]
            try: body=mp_all(m[3:]) if len(m)>3 else []
            except Exception: pass
            label=f"ID_SCENES h={handle}"
            if body:
                shown=[]
                for v in body:
                    if isinstance(v,str) and len(v)>40 and v[:2]=="i6":
                        tk,scene=decode_storm_token(v)
                        shown.append(_fmt_token(tk) if tk else _short(v))
                    else:
                        shown.append(_short(v))
                label+=" :: "+" | ".join(shown)
            parts.append(label)
            # short summary: name the scene if a scene name string is present
            sname=next((v for v in body if isinstance(v,str) and v and not v.startswith("i6")),None)
            summ.append(f"SCENES {sname}" if sname else "SCENES")
        elif mid in (ID_CONNECTION_REQUEST,ID_CONNECTION_REQUEST_ACCEPTED,
                     ID_NEW_INCOMING_CONNECTION,ID_DISCONNECTION_NOTIFICATION,
                     ID_CONNECTION_RESULT):
            parts.append(RAK_NAMES[mid]); summ.append(RAK_NAMES[mid].replace("ID_",""))
        else:
            # Stormancer scene message: first byte IS the sceneHandle (any value
            # not claimed by a RakNet/system id above, incl. dynamic handles like
            # 0x8e gamefinder / 0x90 matchmaking). Decode route + msgpack body
            # (this is where the 6-digit join code / tokens live).
            sc=decode_scene_payload(m)
            parts.append(sc)
            tail=sc.split(" :: ")[-1] if " :: " in sc else f"scene0x{mid:02x}"
            summ.append(f"SCENE h=0x{mid:02x} {tail}")
    if not parts:
        if pending:
            frag=", ".join(f"sid={s} frag {x+1}/{c}" for s,x,c in pending)
            return f"dg seq={seq} :: split fragment ({frag}) — reassembles later", \
                   "split fragment", []
        return f"dg seq={seq} (ack/keepalive)", "keepalive", []
    return f"dg seq={seq} :: "+" | ".join(parts), "; ".join(summ[:3]), summ

# ---- TLS SNI extraction from ClientHello ----
def tls_sni(payload):
    try:
        if len(payload)<6 or payload[0]!=0x16: return None  # not handshake
        # TLS record: type(1) ver(2) len(2) ; handshake: type(1) len(3) ver(2) random(32)...
        p=payload[5:]
        if not p or p[0]!=0x01: return None  # not ClientHello
        i=4+2+32
        if i>=len(p): return None
        sidlen=p[i]; i+=1+sidlen
        cslen=struct.unpack(">H",p[i:i+2])[0]; i+=2+cslen
        complen=p[i]; i+=1+complen
        if i+2>len(p): return None
        extlen=struct.unpack(">H",p[i:i+2])[0]; i+=2
        end=i+extlen
        while i+4<=end:
            et=struct.unpack(">H",p[i:i+2])[0]; el=struct.unpack(">H",p[i+2:i+4])[0]; i+=4
            if et==0x00:  # SNI
                # server_name_list len(2) type(1) name_len(2) name
                j=i+2+1; nl=struct.unpack(">H",p[j:j+2])[0]; j+=2
                return p[j:j+nl].decode("ascii","replace")
            i+=el
    except Exception:
        return None
    return None

# ---- DNS decoder (UDP :53) ----
_DNS_QTYPE={1:"A",2:"NS",5:"CNAME",6:"SOA",12:"PTR",15:"MX",16:"TXT",
            28:"AAAA",33:"SRV",65:"HTTPS",257:"CAA"}
def _dns_name(b,i):
    """Read a (possibly compressed) DNS name. Returns (name, next_index)."""
    parts=[]; jumped=False; nexti=i; hops=0
    while i<len(b) and hops<128:
        l=b[i]
        if l==0:
            i+=1
            if not jumped: nexti=i
            break
        if l&0xc0==0xc0:
            ptr=((l&0x3f)<<8)|b[i+1]
            if not jumped: nexti=i+2
            jumped=True; i=ptr; hops+=1; continue
        parts.append(b[i+1:i+1+l].decode("latin1")); i+=1+l
        if not jumped: nexti=i
    return ".".join(parts), nexti
def decode_dns(pl):
    """Decode a DNS query/response packet. Returns (summary, decoded) or None."""
    try:
        if len(pl)<12: return None
        flags=(pl[2]<<8)|pl[3]
        qr=flags>>15; rcode=flags&0xf
        qd=(pl[4]<<8)|pl[5]; an=(pl[6]<<8)|pl[7]
        i=12; qs=[]
        for _ in range(qd):
            nm,i=_dns_name(pl,i)
            qt=struct.unpack(">H",pl[i:i+2])[0]; i+=4
            qs.append(f"{_DNS_QTYPE.get(qt,qt)} {nm}")
        ans=[]
        if qr:
            for _ in range(an):
                nm,i=_dns_name(pl,i)
                if i+10>len(pl): break
                at=struct.unpack(">H",pl[i:i+2])[0]
                rdl=struct.unpack(">H",pl[i+8:i+10])[0]; i+=10
                rd=pl[i:i+rdl]; i+=rdl
                if at==1 and rdl==4: ans.append(".".join(map(str,rd)))
                elif at==28 and rdl==16:
                    ans.append(":".join(f"{(rd[k]<<8)|rd[k+1]:x}" for k in range(0,16,2)))
                elif at in (5,2,12):  # CNAME/NS/PTR -> name
                    cn,_=_dns_name(pl,i-rdl); ans.append(cn)
                else: ans.append(f"{_DNS_QTYPE.get(at,at)}")
        qname=qs[0].split(" ",1)[1] if qs else "?"
        if qr:
            rc={0:"",3:" NXDOMAIN",2:" SERVFAIL"}.get(rcode,f" rcode={rcode}")
            decoded=f"DNS resp {'; '.join(qs)} -> {', '.join(ans) if ans else '(no A)'}{rc}"
            summary=f"DNS resp {qname}"
        else:
            decoded=f"DNS query {'; '.join(qs)}"
            summary=f"DNS query {qname}"
        return summary, decoded
    except Exception:
        return None

# ---- pcap (classic, LINUX_SLL2) parser ----
def parse_pcap(path):
    with open(path,"rb") as f:
        gh=f.read(24)
        magic=struct.unpack("<I",gh[:4])[0]
        if magic==0xa1b2c3d4: endian="<"; nano=False
        elif magic==0xd4c3b2a1: endian=">"; nano=False
        elif magic==0xa1b23c4d: endian="<"; nano=True
        elif magic==0x4d3cb2a1: endian=">"; nano=True
        else: raise SystemExit(f"bad pcap magic {magic:#x}")
        linktype=struct.unpack(endian+"I",gh[20:24])[0]
        pkts=[]
        while True:
            ph=f.read(16)
            if len(ph)<16: break
            ts_sec,ts_frac,caplen,origlen=struct.unpack(endian+"IIII",ph)
            data=f.read(caplen)
            if len(data)<caplen: break
            ts=ts_sec+(ts_frac/1e9 if nano else ts_frac/1e6)
            pkts.append((ts,data))
        return linktype,pkts

def parse_sll2(d):
    """LINUX_SLL2: proto(2) reserved(2) ifindex(4) arphrd(2) pkttype(1) halen(1) addr(8)=20 hdr."""
    if len(d)<20: return None
    proto=struct.unpack(">H",d[0:2])[0]
    pkttype=d[10]
    return proto,pkttype,d[20:]

def parse_ip(eth_payload):
    if not eth_payload: return None
    v=eth_payload[0]>>4
    if v==4:
        ihl=(eth_payload[0]&0xf)*4
        proto=eth_payload[9]
        src=".".join(str(x) for x in eth_payload[12:16])
        dst=".".join(str(x) for x in eth_payload[16:20])
        return 4,proto,src,dst,eth_payload[ihl:]
    if v==6:
        proto=eth_payload[6]
        src=":".join(eth_payload[8:24][i:i+2].hex() for i in range(0,16,2))
        dst=":".join(eth_payload[24:40][i:i+2].hex() for i in range(0,16,2))
        return 6,proto,src,dst,eth_payload[40:]
    return None

def parse_l4(proto,p):
    if proto==6 and len(p)>=20:  # TCP
        sp,dp=struct.unpack(">HH",p[0:4]); off=(p[12]>>4)*4
        flags=p[13]
        return "TCP",sp,dp,p[off:],flags
    if proto==17 and len(p)>=8:  # UDP
        sp,dp=struct.unpack(">HH",p[0:4]); ln=struct.unpack(">H",p[4:6])[0]
        return "UDP",sp,dp,p[8:ln if ln>=8 else len(p)],0
    if proto==1: return "ICMP",0,0,p,0
    return f"ip{proto}",0,0,p,0

def lbl_end(ip,port,roles):
    """Service/role label for one endpoint. `roles` maps a :30100 client
    (ip,port) -> HOST/JOINER so the src/dst columns read like 'JOINER -> RAKNET'."""
    if port==30100: return "RAKNET"
    r=roles.get((ip,port))
    if r: return r
    # known backend services by ip/port
    if ip in ("162.19.19.130","162.19.84.58","162.19.19.131"): return f"PASSTECH:{port}"
    if ip.startswith("104.18.12"): return f"EOS-LOBBY-WSS:{port}"      # api.epicgames.dev
    if ip.startswith(("3.12","3.13","3.14","18.","52.","15.","13.")): return f"EOS-RTC:{port}"
    if port==53: return "DNS"
    if ip in ("255.255.255.255","10.1.1.255"): return "LAN-BCAST"
    if port in (47584,47585) or 47700<=port<=47800: return f"STEAM-LAN:{port}"
    if 55780<=port<=55820: return f"EOS-P2P:{port}"
    if 53700<=port<=57400: return f"EOS-RTC-MEDIA:{port}"
    LH=ip.startswith("127.") or ip=="::1"
    if ip=="10.1.1.129": return f"GAME:{port}"
    if LH: return f"local:{port}"
    return f"{ip}:{port}"

# ---- MITM HTTPS sidecar merge (decrypted from res/mitm_https.py JSONL) ----
def _mitm_body(headers, raw):
    """Render a decoded HTTP body: msgpack -> repr, text -> string, else hex."""
    if not raw: return ""
    ctype=""
    for k,v in (headers or []):
        if k.lower()=="content-type": ctype=v.lower(); break
    # msgpack bodies (Stormancer uses application/msgpack a lot)
    if "msgpack" in ctype or (raw[:1] and raw[0] in range(0x80,0xff) and "json" not in ctype and "text" not in ctype):
        try:
            vals=mp_all(raw)
            if vals: return "mp="+" | ".join(_short(v) for v in vals)
        except Exception: pass
    # printable text (json/jwt/plain)
    try:
        t=raw.decode("utf-8")
        if t.isprintable() or "\n" in t:
            return t if len(t)<=4096 else t[:4096]+f"...(+{len(t)-4096}B)"
    except Exception: pass
    return f"<{len(raw)}B> "+raw[:48].hex()

def decode_mitm_record(rec):
    """Turn one mitm_https.py JSON record into (summary, decoded, raw_hex)."""
    if rec.get("kind")=="tls_error":
        sni=rec.get("sni") or "?"
        return (f"HTTPS-TLS-FAIL {sni}",
                f"HTTPS TLS handshake refused sni={sni} :: {rec.get('error','')[:120]}", "")
    method=rec.get("method","?"); path=rec.get("path","/"); status=rec.get("status")
    host=rec.get("host") or rec.get("sni") or rec.get("server_ip") or "?"
    tail=path.split("?")[0].rstrip("/").rsplit("/",1)[-1] or path
    try: reqb=base64.b64decode(rec.get("req_body_b64","") or "")
    except Exception: reqb=b""
    try: respb=base64.b64decode(rec.get("resp_body_b64","") or "")
    except Exception: respb=b""
    parts=[f"HTTPS {method} {host}{path} -> {status}"]
    rb=_mitm_body(rec.get("req_headers"), reqb)
    sb=_mitm_body(rec.get("resp_headers"), respb)
    if rb: parts.append(f"req: {rb}")
    if sb: parts.append(f"resp: {sb}")
    summary=f"HTTPS {status} {method} {tail}"
    raw_hex=(respb or reqb)[:64].hex()
    return summary, " :: ".join(parts), raw_hex

def load_mitm(path):
    """Load a mitm_https.py JSONL sidecar -> list of records (dicts with epoch t)."""
    recs=[]
    try:
        with open(path) as f:
            for line in f:
                line=line.strip()
                if not line: continue
                try: recs.append(json.loads(line))
                except Exception: pass
    except FileNotFoundError:
        return []
    return recs

def main():
    if len(sys.argv)<2:
        raise SystemExit(f"usage: {sys.argv[0]} <input.pcap> [output.csv] [mitm.jsonl]")
    inp=sys.argv[1]
    out=sys.argv[2] if len(sys.argv)>2 else os.path.splitext(inp)[0]+".csv"
    linktype,pkts=parse_pcap(inp)
    if not pkts: raise SystemExit("no packets")
    t0=pkts[0][0]

    # ---- pass 1: flatten packets into events ----
    events=[]
    for ts,d in pkts:
        if linktype==276:  # LINUX_SLL2
            s=parse_sll2(d)
            if not s: continue
            _,pkttype,ethp=s; ipr=parse_ip(ethp)
        elif linktype==1:  # EN10MB
            ipr=parse_ip(d[14:]); pkttype=0
        elif linktype==113:  # SLL v1
            ipr=parse_ip(d[16:]); pkttype=0
        else:
            ipr=parse_ip(d); pkttype=0
        if not ipr: continue
        ver,proto,src,dst,l4=ipr
        l4n,sp,dp,pl,flags=parse_l4(proto,l4)
        events.append({"ts":ts,"src":src,"sp":sp,"dst":dst,"dp":dp,
                       "l4n":l4n,"pl":pl,"flags":flags,"out":(pkttype==4)})

    # ---- decode RakNet :30100 first (split reassembly is per conn+dir) ----
    splitbuf={}
    firstseen=[]          # (ip,port) of :30100 clients, first-seen order
    handshakers=[]        # clients that freshly (re)connected during capture
    for e in events:
        if e["l4n"]=="UDP" and (e["sp"]==30100 or e["dp"]==30100):
            c2s = (e["dp"]==30100)
            cip,cport = (e["src"],e["sp"]) if c2s else (e["dst"],e["dp"])
            ep=(cip,cport)
            if ep not in firstseen: firstseen.append(ep)
            dirn="c2s" if c2s else "s2c"
            dec,summ,names=decode_raknet(e["pl"],splitbuf,(ep,dirn))
            e["dec"],e["summ"],e["names"]=dec,summ,names
            e["cep"]=ep
            if any(("CONNECTION_REQUEST" in n) or ("NEW_INCOMING_CONNECTION" in n)
                   for n in names):
                if ep not in handshakers: handshakers.append(ep)

    # ---- assign roles: the client that freshly handshook = JOINER ----
    # (user relaunched Elsie to capture from her game start; the already-running
    #  host does not re-handshake). Fallback: first-seen=HOST, second=JOINER.
    roles={}
    if handshakers:
        for ep in handshakers: roles[ep]="JOINER"
        for ep in firstseen:
            if ep not in roles: roles[ep]="HOST"
    else:
        names_pool=["HOST","JOINER","GAME3","GAME4"]
        for i,ep in enumerate(firstseen):
            roles[ep]=names_pool[i] if i<len(names_pool) else f"GAME{i+1}"

    # ---- pass 2: build rows with src/dst role labels ----
    rows=[]
    gbe_stream={}                          # per-direction Goldberg TCP reassembly buffer
    p2p_stream={}                          # per-direction EOS-P2P-over-TCP reassembly buffer
    p2p_tcp_streams=set()                  # 4-tuples identified as EOS-P2P relay streams
    def _loop(ip): return ip.startswith("127.") or ip=="::1" or set(ip)<=set("0:1")
    for e in events:
        src,sp,dst,dp,l4n,pl,flags=e["src"],e["sp"],e["dst"],e["dp"],e["l4n"],e["pl"],e["flags"]
        srcl=lbl_end(src,sp,roles); dstl=lbl_end(dst,dp,roles)
        rawhex=pl[:64].hex()
        if "dec" in e:                     # already-decoded RakNet
            decoded,summary=e["dec"],e["summ"]
        elif l4n=="TCP" and (dp==443 or sp==443):
            sni=tls_sni(pl)
            if sni: decoded=f"TLS ClientHello SNI={sni}"; summary=f"TLS-HELLO {sni}"
            elif len(pl)==0:
                fl=[]
                if flags&0x01: fl.append("FIN")
                if flags&0x02: fl.append("SYN")
                if flags&0x10: fl.append("ACK")
                if flags&0x04: fl.append("RST")
                decoded="TLS ctrl "+",".join(fl); summary="tcp-ctrl"
            else: decoded=f"TLS app-data {len(pl)}B (encrypted)"; summary="tls-data"
        elif l4n=="UDP":
            p2p=None
            if (55780<=sp<=55820 or 55780<=dp<=55820) and pl[:1]==b"\x0a":
                p2p=decode_eos_p2p(pl)
            if p2p:
                summary,decoded,sr,dr=p2p
                if sr: srcl=sr
                if dr and dstl not in ("LAN-BCAST",): dstl=dr
            elif sp==53 or dp==53:
                dns=decode_dns(pl)
                if dns: summary,decoded=dns
                else: decoded=f"UDP {len(pl)}B"; summary="udp"
            elif sp==5353 or dp==5353:
                dns=decode_dns(pl)
                if dns: summary,decoded=("mDNS "+dns[0], "m"+dns[1])
                else: decoded=f"UDP {len(pl)}B"; summary="udp"
            elif (sp in (47584,47585) or dp in (47584,47585)) and pl[:1]==b"\x08":
                gbe=decode_steam_lan(pl)
                if gbe:
                    summary,decoded,sr,dr=gbe
                    if dr and dstl not in ("LAN-BCAST",): dstl=dr
                else:
                    decoded=f"UDP {len(pl)}B"; summary="udp"
            else:
                decoded=f"UDP {len(pl)}B"; summary="udp"
        elif l4n=="TCP":
            stream4=(src,sp,dst,dp)
            rev4=(dst,dp,src,sp)
            is_p2p=(stream4 in p2p_tcp_streams or rev4 in p2p_tcp_streams)
            if not is_p2p and pl and _loop(src) and _loop(dst) and len(pl)>=5 \
               and pl[4]==0x0a and struct.unpack(">I",pl[:4])[0]<=len(pl)-4 \
               and sp not in (443,30100) and dp not in (443,30100):
                is_p2p=True; p2p_tcp_streams.add(stream4)
            if (sp in (47584,47585) or dp in (47584,47585)):
                if len(pl)==0:
                    fl=[]
                    if flags&0x02: fl.append("SYN")
                    if flags&0x01: fl.append("FIN")
                    if flags&0x10: fl.append("ACK")
                    if flags&0x04: fl.append("RST")
                    decoded="GBE-TCP ctrl "+",".join(fl); summary="gbe-tcp-ctrl"
                else:
                    gbe=decode_steam_lan_tcp(pl, gbe_stream, (src,sp,dst,dp))
                    if gbe:
                        summary,decoded,sr,dr=gbe
                        if dr and dstl not in ("LAN-BCAST",): dstl=dr
                    else:
                        decoded=f"TCP {len(pl)}B"; summary="tcp"
            elif is_p2p and len(pl)>0:
                p2p=decode_eos_p2p_tcp(pl, p2p_stream, (src,sp,dst,dp))
                if p2p:
                    summary,decoded,sr,dr=p2p
                    if sr: srcl=sr
                    if dr: dstl=dr
                else:
                    decoded=f"TCP {len(pl)}B"; summary="tcp"
            elif (sp==80 or dp==80) and len(pl)>0:
                h=decode_http(pl)
                if h: summary,decoded=h
                else: decoded=f"TCP {len(pl)}B"; summary="tcp"
            elif len(pl)==0:
                fl=[]
                if flags&0x02: fl.append("SYN")
                if flags&0x01: fl.append("FIN")
                if flags&0x10: fl.append("ACK")
                if flags&0x04: fl.append("RST")
                decoded="TCP ctrl "+",".join(fl); summary="tcp-ctrl"
            else:
                decoded=f"TCP {len(pl)}B"; summary="tcp"
        else:
            decoded=l4n; summary=l4n
        rows.append({"id":0,"t_off":f"{e['ts']-t0:.6f}","summary":summary,
                     "src":srcl,"dst":dstl,"decoded":decoded,"raw_hex":rawhex})

    # ---- merge decrypted HTTPS from the MITM sidecar (res/mitm_https.py) ----
    mitm_path=sys.argv[3] if len(sys.argv)>3 else None
    if not mitm_path:
        stem=os.path.splitext(inp)[0]
        for cand in (stem+".mitm.jsonl", os.path.join(os.path.dirname(inp) or ".","mitm_http.jsonl")):
            if os.path.exists(cand): mitm_path=cand; break
    if mitm_path and os.path.exists(mitm_path):
        recs=load_mitm(mitm_path)
        client_ports=set()
        added=0
        for rec in recs:
            t=rec.get("t")
            if t is None: continue
            cp=rec.get("client_port")
            if cp: client_ports.add(cp)
            summ_,dec_,rh_=decode_mitm_record(rec)
            cip=rec.get("client_ip","127.0.0.1"); cport=rec.get("client_port",0)
            host=rec.get("host") or rec.get("sni") or rec.get("server_ip") or "?"
            rows.append({"id":0,"t_off":f"{t-t0:.6f}","summary":summ_,
                         "src":lbl_end(cip,cport,roles),"dst":f"HTTPS:{host}",
                         "decoded":dec_,"raw_hex":rh_})
            added+=1
        # relabel the now-redundant encrypted loopback :443 rows that belong to a
        # MITM'd connection, so the reader knows the plaintext is in the HTTPS rows.
        relabeled=0
        if client_ports:
            for r in rows:
                if r["summary"] in ("tls-data","tcp-ctrl") and (":443" in r["src"] or ":443" in r["dst"]):
                    import re as _re
                    ports={int(p) for p in _re.findall(r":(\d+)",r["src"]+" "+r["dst"])}
                    if ports & client_ports:
                        r["summary"]="tls-decoded"
                        r["decoded"]=r["decoded"]+" [decrypted -> see HTTPS rows]"
                        relabeled+=1
        print(f"  merged {added} HTTPS records from {mitm_path} ({relabeled} tls rows relabeled)")

    rows.sort(key=lambda r:float(r["t_off"]))
    for i,r in enumerate(rows,1): r["id"]=i
    with open(out,"w",newline="") as f:
        w=csv.DictWriter(f,fieldnames=["id","t_off","summary","src","dst","decoded","raw_hex"])
        w.writeheader()
        for r in rows: w.writerow(r)
    print(f"wrote {len(rows)} rows -> {out}")
    for ep,r in roles.items(): print(f"  role {r:8s} = {ep[0]}:{ep[1]}")

if __name__=="__main__":
    main()
