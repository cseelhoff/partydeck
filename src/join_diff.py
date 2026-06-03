#!/usr/bin/env python3
"""Shape/byte diff of raknet.py s2c vs REAL Stormancer s2c (ground truth =
relay.B-joinflow.jsonl). Clients are the control variable; any divergence is
raknet.py's fault.

Replay the REAL client's c2s into our broker with a capturing fake socket; decode
both s2c streams; align by signature; compare identity-masked skeletons so
structural bugs surface and identity noise (tokens/uuids/codes/names) does not.
"""
import json, struct, sys, os, re
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import raknet, scenes

RELAY = "/home/caleb/pd_capture_backup/relay.B-joinflow.jsonl"

def mp(b, i=0):
    c = b[i]; i += 1
    if c < 0x80: return c, i
    if c >= 0xe0: return c - 0x100, i
    if 0x80 <= c <= 0x8f:
        d={}; n=c&0xf
        for _ in range(n):
            k,i=mp(b,i); v,i=mp(b,i); d[_k(k)]=v
        return ("map",d), i
    if 0x90 <= c <= 0x9f:
        a=[]; n=c&0xf
        for _ in range(n): v,i=mp(b,i); a.append(v)
        return ("arr",a), i
    if 0xa0 <= c <= 0xbf:
        n=c&0x1f; return ("str",_u(b[i:i+n])), i+n
    if c==0xc0: return None,i
    if c==0xc2: return False,i
    if c==0xc3: return True,i
    if c==0xc4: n=b[i]; i+=1; return ("bin",b[i:i+n]),i+n
    if c==0xc5: n=struct.unpack(">H",b[i:i+2])[0]; i+=2; return ("bin",b[i:i+n]),i+n
    if c==0xc6: n=struct.unpack(">I",b[i:i+4])[0]; i+=4; return ("bin",b[i:i+n]),i+n
    if c==0xc7: n=b[i]; t=b[i+1]; i+=2; return ("ext",t,b[i:i+n]),i+n
    if c==0xc8: n=struct.unpack(">H",b[i:i+2])[0]; t=b[i+2]; i+=3; return ("ext",t,b[i:i+n]),i+n
    if c==0xc9: n=struct.unpack(">I",b[i:i+4])[0]; t=b[i+4]; i+=5; return ("ext",t,b[i:i+n]),i+n
    if c==0xca: return ("f32",struct.unpack(">f",b[i:i+4])[0]),i+4
    if c==0xcb: return ("f64",struct.unpack(">d",b[i:i+8])[0]),i+8
    if c==0xcc: return b[i],i+1
    if c==0xcd: return struct.unpack(">H",b[i:i+2])[0],i+2
    if c==0xce: return struct.unpack(">I",b[i:i+4])[0],i+4
    if c==0xcf: return struct.unpack(">Q",b[i:i+8])[0],i+8
    if c==0xd0: return struct.unpack(">b",b[i:i+1])[0],i+1
    if c==0xd1: return struct.unpack(">h",b[i:i+2])[0],i+2
    if c==0xd2: return struct.unpack(">i",b[i:i+4])[0],i+4
    if c==0xd3: return struct.unpack(">q",b[i:i+8])[0],i+8
    if c in (0xd4,0xd5,0xd6,0xd7,0xd8):
        n={0xd4:1,0xd5:2,0xd6:4,0xd7:8,0xd8:16}[c]; t=b[i]; i+=1
        return ("fixext",t,b[i:i+n]),i+n
    if c==0xd9: n=b[i]; i+=1; return ("str",_u(b[i:i+n])),i+n
    if c==0xda: n=struct.unpack(">H",b[i:i+2])[0]; i+=2; return ("str",_u(b[i:i+n])),i+n
    if c==0xdb: n=struct.unpack(">I",b[i:i+4])[0]; i+=4; return ("str",_u(b[i:i+n])),i+n
    if c==0xdc:
        n=struct.unpack(">H",b[i:i+2])[0]; i+=2; a=[]
        for _ in range(n): v,i=mp(b,i); a.append(v)
        return ("arr",a),i
    if c==0xdd:
        n=struct.unpack(">I",b[i:i+4])[0]; i+=4; a=[]
        for _ in range(n): v,i=mp(b,i); a.append(v)
        return ("arr",a),i
    if c==0xde:
        n=struct.unpack(">H",b[i:i+2])[0]; i+=2; d={}
        for _ in range(n): k,i=mp(b,i); v,i=mp(b,i); d[_k(k)]=v
        return ("map",d),i
    if c==0xdf:
        n=struct.unpack(">I",b[i:i+4])[0]; i+=4; d={}
        for _ in range(n): k,i=mp(b,i); v,i=mp(b,i); d[_k(k)]=v
        return ("map",d),i
    raise ValueError(f"mp 0x{c:02x}@{i-1}")

def _u(bs):
    try: return bs.decode("utf-8")
    except Exception: return "<bin:%d>"%len(bs)
def _k(k):
    if isinstance(k,tuple) and k and k[0]=="str": return k[1]
    return repr(k)
def mp_all(b):
    out=[]; i=0
    while i<len(b):
        try: v,i=mp(b,i); out.append(v)
        except Exception as e:
            out.append(("ERR",str(e),b[i:i+8].hex())); break
    return out

UUID_RE=re.compile(r"^[0-9a-fA-F]{8}-?[0-9a-fA-F]{4}-?[0-9a-fA-F]{4}-?[0-9a-fA-F]{4}-?[0-9a-fA-F]{12}$")
HEX32_RE=re.compile(r"^[0-9a-fA-F]{32}$")
def skel(v):
    if isinstance(v,tuple):
        tag=v[0]
        if tag=="map": return {k:skel(val) for k,val in v[1].items()}
        if tag=="arr": return [skel(x) for x in v[1]]
        if tag=="str":
            s=v[1]
            if UUID_RE.match(s) or HEX32_RE.match(s): return "<id>"
            if len(s)>16: return "<str:%d>"%len(s)
            if s.isdigit() and len(s)>=5: return "<code>"
            return s
        if tag=="bin": return "<bin:%d>"%len(v[1])
        if tag in ("f32","f64"): return "<float>"
        if tag in ("ext","fixext"): return "<ext>"
    if v is None: return None
    if isinstance(v,bool): return v
    if isinstance(v,int): return "<int>" if abs(v)>100000 else v
    return v

def sig_of(m):
    t=m["t"]
    if t in ("RESP_MSG","RESP_COMPLETE","RESP_ERROR"): return (t,m["reqId"])
    if t=="SCENE": return ("SCENE",m["rname"],m.get("rpcReqId"))
    return (t,)

def classify(payload,hr):
    R=raknet; mid=payload[0]
    if mid==R.ID_CONNECTION_REQUEST_ACCEPTED: return {"t":"CONN_ACCEPTED"}
    if mid==R.ID_CONNECTION_RESULT: return {"t":"CONNECTION_RESULT"}
    if mid==R.ID_CONNECTED_PING: return {"t":"PING"}
    if mid==R.ID_CONNECTED_PONG: return {"t":"PONG"}
    if mid==R.ID_REQUEST_RESPONSE_MSG:
        req=struct.unpack("<H",payload[1:3])[0]
        return {"t":"RESP_MSG","reqId":req,"raw":payload[3:],"vals":mp_all(payload[3:])}
    if mid==R.ID_REQUEST_RESPONSE_COMPLETE:
        req=struct.unpack("<H",payload[1:3])[0]
        return {"t":"RESP_COMPLETE","reqId":req,"hasVals":payload[3] if len(payload)>3 else None}
    if mid==R.ID_REQUEST_RESPONSE_ERROR:
        req=struct.unpack("<H",payload[1:3])[0]
        return {"t":"RESP_ERROR","reqId":req,"raw":payload[3:],"vals":mp_all(payload[3:])}
    if len(payload)>=3:
        handle=mid; route=struct.unpack("<H",payload[1:3])[0]; body=payload[3:]
        rname=hr.get(handle,{}).get(route,f"route#{route}")
        d={"t":"SCENE","handle":handle,"route":route,"rname":rname,"raw":body}
        if rname in ("stormancer.rpc.next","stormancer.rpc.completed","stormancer.rpc.error") and len(body)>=2:
            d["rpcReqId"]=struct.unpack("<H",body[0:2])[0]; d["vals"]=mp_all(body[2:])
        else:
            d["vals"]=mp_all(body)
        return d
    return {"t":f"MID_0x{mid:02x}"}

def classify_raw(payload):
    if payload and payload[0]==raknet.ID_REQUEST_RESPONSE_MSG:
        return {"t":"RESP_MSG","raw":payload[3:]}
    return None

class FakeSock:
    def __init__(self): self.sent=[]
    def sendto(self,b,addr): self.sent.append(bytes(b))
    def drain(self):
        s=self.sent; self.sent=[]; return s

def flatten(dgrams):
    out=[]
    for dg in dgrams:
        if not dg: continue
        if (dg[0]>>6)&1: continue
        if not ((dg[0]>>7)&1): continue
        for rel,num,pl in raknet.parse_messages(dg,4):
            if pl: out.append(pl)
    return out

def main():
    recs=[json.loads(l) for l in open(RELAY) if l.strip()]
    addr=("10.9.9.9",55555); fake=FakeSock()
    groups=[]; cur=None
    for r in recs:
        data=bytes.fromhex(r["hex"])
        if r["dir"]=="c2s":
            cur={"c2s":data,"real":[]}; groups.append(cur)
        else:
            if cur is None: cur={"c2s":None,"real":[data]}; groups.append(cur)
            else: cur["real"].append(data)

    real_flat=[]; our_flat=[]; conn=None
    for g in groups:
        if g["c2s"] is not None:
            c2s=g["c2s"]; mid=c2s[0]; is_off=len(c2s)>=17 and c2s[1:17]==raknet.MAGIC
            try:
                if mid==raknet.ID_OPEN_CONNECTION_REQUEST_1 and is_off: raknet.handle_ocr1(fake,c2s,addr)
                elif mid==raknet.ID_OPEN_CONNECTION_REQUEST_2 and is_off: raknet.handle_ocr2(fake,c2s,addr)
                elif is_off: pass
                else: raknet.handle_connected(fake,c2s,addr)
            except Exception as e:
                print("OUR EXC:",type(e).__name__,e)
            conn=raknet.CONNS.get(addr)
            our_flat+=flatten(fake.drain())
        real_flat+=flatten(g["real"])

    # ---- per-side handle -> {routeHandle: routeName}, from RouteMappings ----
    def kind_of_routes(names):
        s=set(names)
        if "users.renewCredentials" in s: return "authenticator"
        if "Steam.GetFriends" in s or "friends.notification" in s: return "friends"
        if any(n.startswith("party.") for n in s) or "memberConnected" in s: return "party"
        if any("amefinder" in n or "atchmak" in n or "Merger" in n or n.startswith("gf.") for n in s):
            return "matchmaking"
        if any("amesession" in n or "GameSession" in n for n in s): return "gamesession"
        return "scene?"

    # real: from ConnectionResult RouteMappings (s2c)
    real_h2routes={}  # handle -> {routeHandle:int -> name}
    for m in [classify_raw(p) for p in real_flat]:
        if m and m["t"]=="RESP_MSG":
            for v in mp_all(m["raw"]):
                if isinstance(v,tuple) and v[0]=="map" and "RouteMappings" in v[1] and "SceneHandle" in v[1]:
                    sh=v[1]["SceneHandle"]; rm=v[1]["RouteMappings"]
                    if isinstance(sh,int) and isinstance(rm,tuple) and rm[0]=="map":
                        real_h2routes[sh]={int(rh):name for name,rh in rm[1].items() if isinstance(rh,int)}
    # ours: from conn bindings (client_recv: name->routeHandle)
    our_h2routes={}
    if conn:
        for h,b in conn.scene_bindings.items():
            our_h2routes[h]={v:k for k,v in b.sr.client_recv.items()}

    real_h2kind={h:kind_of_routes(rts.values()) for h,rts in real_h2routes.items()}
    our_h2kind ={h:kind_of_routes(rts.values()) for h,rts in our_h2routes.items()}

    # classify scene messages with per-side route-name + scene-kind resolution
    def classify_side(payload,h2routes,h2kind):
        R=raknet; mid=payload[0]
        if mid==R.ID_REQUEST_RESPONSE_MSG:
            req=struct.unpack("<H",payload[1:3])[0]
            return {"t":"RESP_MSG","reqId":req,"raw":payload[3:]}
        if mid==R.ID_REQUEST_RESPONSE_COMPLETE:
            req=struct.unpack("<H",payload[1:3])[0]
            return {"t":"RESP_COMPLETE","reqId":req,"hasVals":payload[3] if len(payload)>3 else None}
        if mid==R.ID_REQUEST_RESPONSE_ERROR:
            req=struct.unpack("<H",payload[1:3])[0]
            return {"t":"RESP_ERROR","reqId":req,"raw":payload[3:],"vals":mp_all(payload[3:])}
        if len(payload)>=3:
            h=mid; rh=struct.unpack("<H",payload[1:3])[0]; body=payload[3:]
            kind=h2kind.get(h,"scene?")
            rname=h2routes.get(h,{}).get(rh,f"r#{rh}")
            d={"t":"SCENE","handle":h,"kind":kind,"rname":rname,"raw":body}
            if rname in ("stormancer.rpc.next","stormancer.rpc.completed","stormancer.rpc.error") and len(body)>=2:
                d["rpcReqId"]=struct.unpack("<H",body[0:2])[0]; d["vals"]=mp_all(body[2:])
            else:
                d["vals"]=mp_all(body)
            return d
        return {"t":f"MID_0x{mid:02x}"}

    realmsgs=[classify_side(p,real_h2routes,real_h2kind) for p in real_flat]
    ourmsgs =[classify_side(p,our_h2routes ,our_h2kind ) for p in our_flat]
    keep=lambda m: m["t"] in ("RESP_MSG","RESP_COMPLETE","RESP_ERROR","SCENE")
    realmsgs=[m for m in realmsgs if keep(m)]
    ourmsgs =[m for m in ourmsgs  if keep(m)]

    MP_MARK=set(range(0x80,0x90))|{0xde,0xdf}
    def is_msgpack_map(raw):
        return bool(raw) and raw[0] in MP_MARK
    def sk(m):
        if m["t"]=="RESP_MSG":
            return [skel(v) for v in mp_all(m["raw"])] if is_msgpack_map(m["raw"]) else "<binary:%d>"%len(m["raw"])
        if m["t"]=="RESP_ERROR": return [skel(v) for v in m["vals"]]
        if m["t"]=="RESP_COMPLETE": return {"hasVals":m["hasVals"]}
        if m["t"]=="SCENE": return {"rname":m["rname"],"vals":[skel(v) for v in m["vals"]]}
        return m["t"]

    def keyed(msgs):
        sysd={}; scn={}; cnt={}
        for m in msgs:
            t=m["t"]
            if t in ("RESP_MSG","RESP_COMPLETE","RESP_ERROR"):
                sysd[(t,m["reqId"])]=m
            elif t=="SCENE":
                kind=m["kind"]; rn=m["rname"]; rid=m.get("rpcReqId")
                if rid is None:
                    c=cnt.get((kind,rn),0); cnt[(kind,rn)]=c+1; rid=("#",c)
                scn[(kind,rn,rid)]=m
        return sysd,scn
    rsys,rscn=keyed(realmsgs); osys,oscn=keyed(ourmsgs)

    out=open("/tmp/join_skel.txt","w")
    def emit(*a):
        s=" ".join(str(x) for x in a); print(s); out.write(s+"\n")
    emit(f"REAL sys={len(rsys)} scene={len(rscn)}   OUR sys={len(osys)} scene={len(oscn)}")
    emit("real handle->kind:",real_h2kind)
    emit("our  handle->kind:",our_h2kind)
    mism=0
    def cmp_section(title,rd,od,keyfn,skipbin=False):
        nonlocal mism
        emit("\n"+"="*100); emit(title); emit("="*100)
        for k in sorted(set(rd)|set(od),key=keyfn):
            r=rd.get(k); o=od.get(k)
            if r and o:
                a,b=sk(r),sk(o)
                if skipbin and a==b: continue
                if skipbin and isinstance(a,str) and a.startswith("<binary") and isinstance(b,str) and b.startswith("<binary"):
                    continue
                same=a==b
                emit(f"[{'OK ' if same else 'DIFF'}] {fmtsig(k)}")
                if not same:
                    mism+=1; emit(f"      REAL: {a}"); emit(f"      OURS: {b}")
            elif r and not o:
                mism+=1; emit(f"[ONLY-REAL] {fmtsig(k)}  << real sends, OURS does NOT >>")
                emit(f"      REAL: {sk(r)}")
            else:
                mism+=1; emit(f"[ONLY-OURS] {fmtsig(k)}  << OURS sends, real does NOT >>")
                emit(f"      OURS: {sk(o)}")
    cmp_section("SYSTEM RESPONSES (msgpack only; binary clock/handshake skipped)",rsys,osys,
                lambda k:(k[1] if isinstance(k[1],int) else 0,k[0]),skipbin=True)
    cmp_section("SCENE MESSAGES (kind/route/rpcReqId)",rscn,oscn,
                lambda k:(str(k[0]),str(k[1]),str(k[2])))
    emit("\n"+"="*100); emit(f"TOTAL MISMATCHES: {mism}")
    out.close(); print("\n[full -> /tmp/join_skel.txt]")

def fmtsig(s): return " / ".join(str(x) for x in s) if isinstance(s,tuple) else str(s)

if __name__=="__main__":
    main()
