#!/usr/bin/env bash
# Forward-proxy capture for the Ravenswatch joiner (Burp/Fiddler model).
#
# Instead of poisoning DNS + reverse-proxying :443, we run mitmproxy as an
# ordinary HTTPS forward proxy and point the game's Wine prefix at it. Because
# the prefix already trusts our CA, mitmproxy decrypts EVERY HTTPS request the
# game's WinHTTP/WinINET stack makes (cpprestsdk -> WinHttpGetIEProxyConfigForCurrentUser
# reads the proxy from the registry we set below). No /etc/resolv.conf changes,
# no host_aliases dependency, no reverse-target gymnastics.
#
# Runs together, time-aligned, all auto-reverted on exit:
#   1. tcpdump  -> join_<label>_<ts>.pcap          (every interface/port, full pkts)
#   2. mitmdump (regular/forward mode) on :PORT     -> decrypted HTTP -> .mitm.jsonl
#   3. sets HKCU\...\Internet Settings ProxyEnable=1 + ProxyServer in each prefix
#      (reverted on exit).
#
# For the emulated offline Stormancer host(s) (dt-live*), we present the proven
# server.crt (it carries the X509v3 KeyUsage extension Wine's schannel requires;
# mitmproxy's auto-minted leaves only set Extended Key Usage) and redirect just
# those hosts to the local server.py. Every other host (EOS, Steam, GitHub, MS
# telemetry, ...) is decrypted too and forwarded to its real destination; any
# host that pins / rejects our CA is transparently passed through (stays
# encrypted) so the game keeps working.
#
#   MODE=online  (default): dt-live* forwarded to the REAL passtech backend.
#   MODE=offline           : dt-live* redirected to the local server.py
#                            (run: PROBE_PORT=8443 sudo python3 $CA_DIR/server.py
#                             and: python3 $CA_DIR/raknet.py).
#
# Usage:
#   sudo MODE=offline CAPTURE_LABEL=fwd \
#        HOSTS="dt-live.passtechgames.com dt-live-2.passtechgames.com dt-live-3.passtechgames.com" \
#        res/capture_fwdproxy.sh
#
# Then launch partydeck normally and do the join-by-code; Ctrl-C here when done.
# Merge:  python3 src/pcap2csv.py <pcap> out.csv   # auto-finds the .mitm.jsonl
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PY="${PY:-/run/current-system/sw/bin/python3}"
TD="${TCPDUMP:-$(command -v tcpdump || echo /run/current-system/sw/bin/tcpdump)}"
NIXSHELL="${NIXSHELL:-$(command -v nix-shell || echo /run/current-system/sw/bin/nix-shell)}"
CA_DIR="${CA_DIR:-/tmp/pdlog/probe}"
OUTDIR="${OUTDIR:-/tmp/pdlog/probe}"
LABEL="${CAPTURE_LABEL:-fwd}"
MODE="${MODE:-online}"
PORT="${PROXY_PORT:-8080}"                 # the forward-proxy listen port
HOSTS="${HOSTS:-dt-live.passtechgames.com dt-live-2.passtechgames.com dt-live-3.passtechgames.com}"
LOCAL_BACKEND_IP="${LOCAL_BACKEND_IP:-127.0.0.1}"
LOCAL_BACKEND_PORT="${LOCAL_BACKEND_PORT:-8443}"
PFX_ROOT="${PFX_ROOT:-/home/caleb/.local/share/partydeck/prefixes}"
PROXY_HOST="${PROXY_HOST:-127.0.0.1}"      # address the game reaches us at (shared loopback)

# Goldberg (Steam emu) writes STEAM_LOG_<rand>.log to GseAppPath = each instance's
# tmp/ccloader-<idx>/ dir, which partydeck's clear_tmp() deletes the moment the game
# exits. Harvest them on Ctrl-C (while the game is still up) into OUTDIR so the logs
# survive. ccloader-0 = HOST, ccloader-1 = JOINER.
PARTY_ROOT="${PARTY_ROOT:-/home/caleb/.local/share/partydeck}"
PCAP2CSV="${PCAP2CSV:-$HERE/pcap2csv.py}"

if [[ $EUID -ne 0 ]]; then
    echo "[capfwd] must run as root (sudo): tcpdump needs it." >&2; exit 1
fi
for f in ca.crt ca.key; do
    [[ -f "$CA_DIR/$f" ]] || { echo "[capfwd] missing $CA_DIR/$f" >&2; exit 1; }
done

TS="$(date +%H%M%S)"
PCAP="$OUTDIR/join_${LABEL}_${TS}.pcap"
MITMLOG="$OUTDIR/join_${LABEL}_${TS}.mitm.jsonl"
PROXLOG="$OUTDIR/capfwd_proxy.${LABEL}.log"
CONFDIR="$OUTDIR/mitm_confdir_fwd"
GBE_HARVEST_DIR="${GBE_HARVEST_DIR:-$OUTDIR/goldberg_${LABEL}_${TS}}"

# Build mitmproxy's signing CA (key THEN cert) from the CA the game trusts.
mkdir -p "$CONFDIR"
cat "$CA_DIR/ca.key" "$CA_DIR/ca.crt" > "$CONFDIR/mitmproxy-ca.pem"

# Present the proven server.crt (with KeyUsage) for the emulated Stormancer hosts.
# The game may use either the hostname OR a loopback IP literal (e.g. 127.1.33.7,
# a stale Stormancer scene endpoint it resolves dt-live* to) as the TLS SNI, so we
# register the cert under the hostnames AND the loopback IPs in the server.crt SANs.
CERT_HOSTS="$HOSTS 127.1.33.7 127.0.0.1"
CERT_ARGS=()
if [[ -f "$CA_DIR/server.crt" && -f "$CA_DIR/server.key" ]]; then
    cat "$CA_DIR/server.key" "$CA_DIR/server.crt" "$CA_DIR/ca.crt" > "$CONFDIR/server_bundle.pem"
    for h in $CERT_HOSTS; do CERT_ARGS+=("--certs $h=$CONFDIR/server_bundle.pem"); done
    echo "[capfwd] presenting pre-built server.crt for: $CERT_HOSTS"
else
    echo "[capfwd] NOTE: $CA_DIR/server.crt[.key] not found — mitmproxy will MINT leaves" >&2
    echo "[capfwd]   (Wine schannel may reject minted certs lacking KeyUsage for dt-live*)" >&2
fi
CERT_STR="${CERT_ARGS[*]}"

TD_PID="" ; MITM_PID="" ; PROXIED_PFXS=()

# ---- Wine prefix proxy set / revert -------------------------------------
# Sets BOTH proxy sources Wine apps consult:
#   * WinINET (user.reg): Internet Settings ProxyEnable=1 + ProxyServer  -> used
#     by anything calling WinHttpGetIEProxyConfigForCurrentUser / WinINET.
#   * WinHTTP (system.reg): Connections\WinHttpSettings binary blob       -> used
#     by WINHTTP_ACCESS_TYPE_DEFAULT_PROXY (cpprestsdk / Stormancer's HTTP client).
# Whole files are backed up (.pdproxy.bak) and restored verbatim on exit.
apply_proxy() {  # $1=user.reg  $2=system.reg  $3="host:port"
    "$PY" - "$1" "$2" "$3" <<'PYEOF'
import sys, re, io, struct
ureg, sreg, val = sys.argv[1], sys.argv[2], sys.argv[3]

def rd(p):
    with io.open(p, "r", encoding="utf-8", errors="surrogateescape") as f: return f.read()
def wr(p, t):
    with io.open(p, "w", encoding="utf-8", errors="surrogateescape") as f: f.write(t)

# --- WinINET (HKCU user.reg) ---
txt = rd(ureg)
key = r"[Software\\Microsoft\\Windows\\CurrentVersion\\Internet Settings]"
i = txt.find(key)
if i >= 0:
    nl = txt.find("\n", i)
    if txt[nl + 1:].startswith("#time="):
        nl = txt.find("\n", nl + 1)
    nxt = txt.find("\n[", nl); end = nxt if nxt >= 0 else len(txt)
    sec = txt[nl:end]
    sec = re.sub(r'\n"ProxyEnable"=dword:[0-9A-Fa-f]+', "", sec)
    sec = re.sub(r'\n"ProxyServer"="[^"]*"', "", sec)
    sec = ('\n"ProxyEnable"=dword:00000001\n"ProxyServer"="%s"' % val) + sec
    wr(ureg, txt[:nl] + sec + txt[end:])

# --- WinHTTP (HKLM system.reg) Connections\WinHttpSettings ---
proxy = val.encode()
blob = struct.pack("<III", 0x18, 0, 2) + struct.pack("<I", len(proxy)) + proxy + struct.pack("<I", 0)
hexs = ",".join("%02x" % b for b in blob)
line = '"WinHttpSettings"=hex:' + hexs
txt = rd(sreg)
ckey = r"[Software\\Microsoft\\Windows\\CurrentVersion\\Internet Settings\\Connections]"
j = txt.find(ckey)
if j >= 0:
    nl = txt.find("\n", j)
    if txt[nl + 1:].startswith("#time="):
        nl = txt.find("\n", nl + 1)
    nxt = txt.find("\n[", nl); end = nxt if nxt >= 0 else len(txt)
    sec = txt[nl:end]
    sec = re.sub(r'\n"WinHttpSettings"=hex:[0-9a-f,\\\r\n ]*', "", sec)
    sec = "\n" + line + sec
    txt = txt[:nl] + sec + txt[end:]
else:
    txt = txt.rstrip("\n") + "\n\n" + ckey + " 1771255650\n" + line + "\n"
wr(sreg, txt)
print("ok")
PYEOF
}
enable_proxies() {
    for d in "$PFX_ROOT"/*/; do
        ureg="$d/user.reg"; sreg="$d/system.reg"
        [[ -f "$ureg" && -f "$sreg" ]] || continue
        cp -f "$ureg" "$ureg.pdproxy.bak"
        cp -f "$sreg" "$sreg.pdproxy.bak"
        if [[ "$(apply_proxy "$ureg" "$sreg" "$PROXY_HOST:$PORT")" == "ok" ]]; then
            PROXIED_PFXS+=("$d")
            echo "[capfwd] proxy set in $(basename "$d") (WinINET+WinHTTP) -> $PROXY_HOST:$PORT"
        fi
    done
    [[ ${#PROXIED_PFXS[@]} -gt 0 ]] || echo "[capfwd] WARNING: no prefixes proxied (check PFX_ROOT=$PFX_ROOT)" >&2
}
revert_proxies() {
    for d in "${PROXIED_PFXS[@]:-}"; do
        [[ -n "$d" ]] || continue
        for f in user.reg system.reg; do
            [[ -f "$d/$f.pdproxy.bak" ]] && mv -f "$d/$f.pdproxy.bak" "$d/$f"
        done
        echo "[capfwd] proxy reverted in $(basename "$d")"
    done
    PROXIED_PFXS=()
}

# ---- Goldberg (Steam emu) log harvest ----------------------------------
# Copy each instance's STEAM_LOG_<rand>.log out of tmp/ccloader-<idx>/ (GseAppPath)
# BEFORE partydeck's clear_tmp() wipes them on game exit. Runs on Ctrl-C while the
# game is still up. ccloader-0 = HOST, ccloader-1 = JOINER.
GBE_HARVESTED=0
harvest_goldberg() {
    [[ "$GBE_HARVESTED" == "1" ]] && return 0
    GBE_HARVESTED=1
    local tmproot="$PARTY_ROOT/tmp"
    [[ -d "$tmproot" ]] || { echo "[capfwd] goldberg: no tmp dir ($tmproot) — nothing to harvest"; return 0; }
    shopt -s nullglob
    local found=0
    mkdir -p "$GBE_HARVEST_DIR"
    for cc in "$tmproot"/ccloader-*/; do
        local idx role base
        base="$(basename "$cc")"            # ccloader-0
        idx="${base##*-}"
        case "$idx" in
            0) role="HOST" ;;
            1) role="JOINER" ;;
            *) role="IDX$idx" ;;
        esac
        for log in "$cc"STEAM_LOG_*.log "$cc"STEAM_LOG.txt; do
            [[ -f "$log" ]] || continue
            local dst="$GBE_HARVEST_DIR/${base}_${role}_$(basename "$log")"
            cp -f "$log" "$dst" 2>/dev/null && { found=$((found+1)); echo "[capfwd] goldberg: $base ($role) <- $(basename "$log") ($(wc -l <"$dst") lines)"; }
        done
    done
    shopt -u nullglob
    if [[ "$found" -eq 0 ]]; then
        echo "[capfwd] goldberg: no STEAM_LOG_*.log under $tmproot/ccloader-* (game already exited?)"
        rmdir "$GBE_HARVEST_DIR" 2>/dev/null || true
        return 0
    fi
    # make harvested files owned by the real user (script runs as root).
    local owner; owner="$(stat -c %U "$PARTY_ROOT" 2>/dev/null || echo root)"
    [[ "$owner" != "root" ]] && chown -R "$owner" "$GBE_HARVEST_DIR" 2>/dev/null || true
    # quick per-instance summary of the Steam matchmaking ops we care about.
    echo "[capfwd] goldberg: harvested $found log(s) -> $GBE_HARVEST_DIR"
    for f in "$GBE_HARVEST_DIR"/*.log; do
        [[ -f "$f" ]] || continue
        local cl jl ll rl sd
        cl=$(grep -c "CreateLobby"      "$f" 2>/dev/null); cl=${cl:-0}
        jl=$(grep -c "JoinLobby"        "$f" 2>/dev/null); jl=${jl:-0}
        ll=$(grep -c "LeaveLobby"       "$f" 2>/dev/null); ll=${ll:-0}
        rl=$(grep -c "RequestLobbyData" "$f" 2>/dev/null); rl=${rl:-0}
        sd=$(grep -c "send_lobby_data"  "$f" 2>/dev/null); sd=${sd:-0}
        echo "    $(basename "$f"): CreateLobby=$cl JoinLobby=$jl LeaveLobby=$ll RequestLobbyData=$rl send_lobby_data=$sd"
    done
}

cleanup() {
    echo; echo "[capfwd] tearing down..."
    harvest_goldberg
    revert_proxies
    for pid in "$MITM_PID" "$TD_PID"; do [[ -n "$pid" ]] && kill "$pid" 2>/dev/null || true; done
    pkill -f "mitmdump .*mitm_addon.py" 2>/dev/null || true
    echo "[capfwd] DONE."
    echo "    pcap : $PCAP"
    echo "    mitm : $MITMLOG"
    echo "    gbe  : $GBE_HARVEST_DIR"
    echo "    merge: $PY src/pcap2csv.py '$PCAP' out.csv"
}
trap cleanup EXIT INT TERM

# ---- mitmproxy addon environment ----------------------------------------
export MITM_LOG="$MITMLOG"
export MITM_REAL_PORT=443
unset MITM_FORCE_UPSTREAM MITM_RETARGET_REAL MITM_HOSTMAP
if [[ "$MODE" == "offline" ]]; then
    # Only the emulated Stormancer hosts go to the local server.py; everything
    # else is decrypted and forwarded to its real destination.
    LOCAL_CSV=""
    for h in $HOSTS; do LOCAL_CSV="${LOCAL_CSV:+$LOCAL_CSV,}$h"; done
    export MITM_LOCAL_HOSTS="$LOCAL_CSV"
    export MITM_LOCAL_BACKEND="$LOCAL_BACKEND_IP:$LOCAL_BACKEND_PORT"
    # The game often connects to a loopback IP literal (stale Stormancer scene
    # endpoint, e.g. 127.1.33.7) rather than the hostname. In offline mode treat
    # ANY 127.0.0.0/8 destination as our emulated backend -> server.py.
    export MITM_LOCAL_LOOPBACK=1
    echo "[capfwd] MODE=offline ; redirect [$LOCAL_CSV] + any 127.x -> $LOCAL_BACKEND_IP:$LOCAL_BACKEND_PORT ; rest -> real"
    echo "[capfwd]   ensure server.py + raknet.py are running."
else
    unset MITM_LOCAL_HOSTS MITM_LOCAL_BACKEND MITM_LOCAL_LOOPBACK
    echo "[capfwd] MODE=online ; all hosts forwarded to their real destinations"
fi

# 1. tcpdump: all interfaces, all ports, full packets, packet-buffered.
echo "[capfwd] starting tcpdump -> $PCAP"
"$TD" -i any -s 0 -U -w "$PCAP" >/dev/null 2>&1 &
TD_PID=$!
sleep 0.4
kill -0 "$TD_PID" 2>/dev/null || { echo "[capfwd] tcpdump failed to start" >&2; exit 1; }

# 2. mitmdump in regular (forward-proxy) mode.
#    tls_version_client_max=TLS1_2: Wine's schannel can complete a TLS 1.3
#      handshake then choke on post-handshake messages -> ERROR_WINHTTP_SECURE_CHANNEL_ERROR
#      and send NO request. Cap the client side at TLS 1.2.
echo "[capfwd] starting mitmdump (forward proxy) on :$PORT"
"$NIXSHELL" -p mitmproxy --run "mitmdump --mode regular \
    --listen-host 0.0.0.0 --listen-port $PORT \
    --set confdir=$CONFDIR --ssl-insecure \
    --set connection_strategy=lazy \
    --set tls_version_client_max=TLS1_2 \
    $CERT_STR \
    -s $HERE/mitm_addon.py" >"$PROXLOG" 2>&1 &
MITM_PID=$!
for _ in $(seq 1 60); do
    ss -ltn 2>/dev/null | grep -qE "(0\.0\.0\.0|127\.0\.0\.1):$PORT" && break
    kill -0 "$MITM_PID" 2>/dev/null || { echo "[capfwd] mitmdump exited early:" >&2; cat "$PROXLOG" >&2; exit 1; }
    sleep 0.5
done
if ! ss -ltn 2>/dev/null | grep -qE "(0\.0\.0\.0|127\.0\.0\.1):$PORT"; then
    echo "[capfwd] mitmdump not listening on :$PORT after 30s — see $PROXLOG" >&2
    tail -20 "$PROXLOG" >&2; exit 1
fi

# 3. point every prefix at the proxy (reverted on exit).
enable_proxies

echo
echo "[capfwd] READY (label=$LABEL). Launch partydeck now and do the join-by-code."
echo "[capfwd]   proxy: $PROXY_HOST:$PORT   pcap: $PCAP"
echo "[capfwd]   mitm : $MITMLOG   (tail -f to watch decrypted HTTP)"
echo "[capfwd]   proxy log: $PROXLOG"
echo "[capfwd] Press Ctrl-C here when done to stop and revert the prefix proxy."
wait -n "$TD_PID" "$MITM_PID"
echo "[capfwd] a component exited unexpectedly; cleaning up."
