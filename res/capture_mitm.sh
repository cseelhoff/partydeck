#!/usr/bin/env bash
# Combined capture for the Ravenswatch joiner: full-plane PCAP + decrypted HTTPS.
#
# Runs THREE things together, time-aligned, all auto-reverted on exit:
#   1. tcpdump  -> join_<label>_<ts>.pcap        (every interface/port, full pkts)
#   2. DNS shim -> poisons the game's HTTPS host(s) to 127.0.0.1 so they hit (3)
#   3. mitmdump (the real mitmproxy) -> TLS-terminates :443 with leaf certs minted
#      from the CA the game trusts, forwards to the REAL upstream, and logs every
#      decrypted HTTP transaction (via res/mitm_addon.py) to
#      join_<label>_<ts>.mitm.jsonl. On TLS failure (cert pinning / untrusted CA)
#      mitmproxy transparently PASSES THROUGH the raw bytes instead of erroring,
#      so the game keeps working; that flow just isn't decoded.
#
# mitmproxy is obtained on demand via `nix-shell -p mitmproxy` (NixOS); no global
# install needed. The CA the game already trusts ($CA_DIR/ca.{crt,key}) is fed to
# mitmproxy as its signing CA, so the forged leaves are trusted by the game.
#
# Afterwards, merge the decrypted HTTPS into the packet CSV:
#   python3 src/pcap2csv.py join_<label>_<ts>.pcap out.csv  # auto-finds .mitm.jsonl
#
# Usage:
#   sudo CAPTURE_LABEL=joiner_bycode \
#        HOSTS="dt-live.passtechgames.com dt-live-2.passtechgames.com" \
#        res/capture_mitm.sh
#
# Requirements: the CA in $CA_DIR/ca.crt must already be installed in the game's
# Wine prefix Root store (it is, for this setup). Run as root (rewrites
# /etc/resolv.conf, binds :443). Hosts that pin / don't trust our CA stay
# encrypted (passed through) — that is expected and harmless.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PY="${PY:-/run/current-system/sw/bin/python3}"
TD="${TCPDUMP:-$(command -v tcpdump || echo /run/current-system/sw/bin/tcpdump)}"
NIXSHELL="${NIXSHELL:-$(command -v nix-shell || echo /run/current-system/sw/bin/nix-shell)}"
CA_DIR="${CA_DIR:-/tmp/pdlog/probe}"
OUTDIR="${OUTDIR:-/tmp/pdlog/probe}"
LABEL="${CAPTURE_LABEL:-mitm}"
RESOLV="/etc/resolv.conf"
BAK="$OUTDIR/resolv.conf.mitm.bak"
# Space-separated HTTPS hosts to poison->MITM. Default: the game's Stormancer host.
HOSTS="${HOSTS:-dt-live.passtechgames.com}"
# MODE=online (default): forward decrypted traffic to the REAL passtech backend
#   (DNS-poison the hosts to 127.0.0.1 so the game hits us). Use for capturing the
#   genuine live Steam/Epic/EOS/RakNet join.
# MODE=offline: forward decrypted traffic to the LOCAL self-host server.py instead
#   of the internet. No DNS poisoning — partydeck's host_aliases already pins
#   dt-live* -> 127.0.0.1 inside the sandbox. Run server.py on PROBE_PORT (8443)
#   and raknet.py on :30100 alongside this.
MODE="${MODE:-online}"
# In offline mode, where the decrypted requests are forwarded (the local server.py).
LOCAL_BACKEND_IP="${LOCAL_BACKEND_IP:-127.0.0.1}"
LOCAL_BACKEND_PORT="${LOCAL_BACKEND_PORT:-8443}"

if [[ $EUID -ne 0 ]]; then
    echo "[capmitm] must run as root (sudo)." >&2; exit 1
fi
for f in ca.crt ca.key; do
    [[ -f "$CA_DIR/$f" ]] || { echo "[capmitm] missing $CA_DIR/$f" >&2; exit 1; }
done

TS="$(date +%H%M%S)"
PCAP="$OUTDIR/join_${LABEL}_${TS}.pcap"
MITMLOG="$OUTDIR/join_${LABEL}_${TS}.mitm.jsonl"
DNSLOG="$OUTDIR/capmitm_dns.${LABEL}.log"
PROXLOG="$OUTDIR/capmitm_proxy.${LABEL}.log"
CONFDIR="$OUTDIR/mitm_confdir"

# Discover the REAL upstream nameserver BEFORE poisoning (proxy uses it to find
# the genuine backend IPs; bypasses the poisoned resolv.conf).
UPSTREAM="$(awk '/^nameserver/ && $2 !~ /^127\./ {print $2; exit}' "$RESOLV")"
[[ -z "${UPSTREAM:-}" ]] && UPSTREAM="1.1.1.1"

# Build the addon's static host=ip map + pick PRIMARY (reverse-mode target host).
HOSTMAP=""
PRIMARY=""
if [[ "$MODE" == "offline" ]]; then
    # Point every host at the LOCAL server.py; no real DNS, no poisoning.
    REAL_PORT="$LOCAL_BACKEND_PORT"
    for h in $HOSTS; do
        HOSTMAP="${HOSTMAP:+$HOSTMAP,}$h=$LOCAL_BACKEND_IP"
        [[ -z "$PRIMARY" ]] && PRIMARY="$h"
    done
    echo "[capmitm] MODE=offline ; forward decrypted -> $LOCAL_BACKEND_IP:$REAL_PORT (server.py) ; hostmap = $HOSTMAP"
else
    # Pre-resolve every target host to its REAL IPv4 NOW (before DNS is poisoned),
    # and build the addon's static host=ip map so it never loops back to us.
    REAL_PORT=443
    for h in $HOSTS; do
        ip="$(getent ahostsv4 "$h" 2>/dev/null | awk '/STREAM/{print $1; exit}')"
        [[ -z "$ip" ]] && ip="$(getent ahostsv4 "$h" 2>/dev/null | awk '{print $1; exit}')"
        [[ "$ip" =~ ^[0-9.]+$ ]] || { echo "[capmitm] WARN could not resolve $h" >&2; continue; }
        HOSTMAP="${HOSTMAP:+$HOSTMAP,}$h=$ip"
        [[ -z "$PRIMARY" ]] && PRIMARY="$h"
    done
    echo "[capmitm] MODE=online ; real upstream NS = $UPSTREAM ; hostmap = $HOSTMAP"
fi
[[ -z "$PRIMARY" ]] && { echo "[capmitm] no HOSTS resolved — aborting." >&2; exit 1; }

# Build mitmproxy's signing CA from the CA the game already trusts (key THEN cert).
mkdir -p "$CONFDIR"
cat "$CA_DIR/ca.key" "$CA_DIR/ca.crt" > "$CONFDIR/mitmproxy-ca.pem"

# Use the EXACT pre-built server cert (server.crt) the game already accepted when
# talking straight to server.py, instead of letting mitmproxy MINT a leaf. The
# minted leaf lacked the critical KeyUsage (Digital Signature, Key Encipherment)
# extension, which Wine's schannel requires for the TLS 1.2 RSA/ECDHE key
# exchange -> the game completed the handshake then sent NO request and
# disconnected (proxy log: connect/disconnect, server.py got nothing, no join
# code). server.crt has KeyUsage + SANs for all dt-live* hosts + 127.0.0.1.
# Bundle = key + leaf + CA chain (PEM), presented per target host via --certs.
CERT_ARGS=()
if [[ -f "$CA_DIR/server.crt" && -f "$CA_DIR/server.key" ]]; then
    cat "$CA_DIR/server.key" "$CA_DIR/server.crt" "$CA_DIR/ca.crt" > "$CONFDIR/server_bundle.pem"
    for h in $HOSTS; do CERT_ARGS+=("--certs $h=$CONFDIR/server_bundle.pem"); done
    echo "[capmitm] presenting pre-built server.crt to the game for: $HOSTS"
else
    echo "[capmitm] NOTE: $CA_DIR/server.crt[.key] not found — mitmproxy will MINT leaves" >&2
    echo "[capmitm]   (Wine schannel may reject minted certs lacking KeyUsage; prefer server.crt)" >&2
fi
CERT_STR="${CERT_ARGS[*]}"

TD_PID="" ; DNS_PID="" ; MITM_PID="" ; RESOLV_SWAPPED=0

restore_resolv() {
    [[ "$RESOLV_SWAPPED" -eq 1 ]] || return 0
    chattr -i "$RESOLV" 2>/dev/null || true
    [[ -f "$BAK" ]] && { cp -f "$BAK" "$RESOLV" && rm -f "$BAK"; \
        echo "[capmitm] /etc/resolv.conf restored."; }
    RESOLV_SWAPPED=0
}
cleanup() {
    echo; echo "[capmitm] tearing down..."
    restore_resolv
    for pid in "$MITM_PID" "$DNS_PID" "$TD_PID"; do
        [[ -n "$pid" ]] && kill "$pid" 2>/dev/null || true
    done
    # mitmdump runs under nix-shell; make sure the child is gone too
    pkill -f "mitmdump .*mitm_addon.py" 2>/dev/null || true
    command -v resolvectl >/dev/null 2>&1 && resolvectl flush-caches 2>/dev/null || true
    echo "[capmitm] DONE."
    echo "    pcap : $PCAP"
    echo "    mitm : $MITMLOG"
    echo "    merge: $PY src/pcap2csv.py '$PCAP' out.csv  # auto-finds the .mitm.jsonl"
}
trap cleanup EXIT INT TERM

# 1. tcpdump: all interfaces, all ports, full packets, packet-buffered.
echo "[capmitm] starting tcpdump -> $PCAP"
"$TD" -i any -s 0 -U -w "$PCAP" >/dev/null 2>&1 &
TD_PID=$!
sleep 0.4
kill -0 "$TD_PID" 2>/dev/null || { echo "[capmitm] tcpdump failed to start" >&2; exit 1; }

# 2. DNS responder on 127.0.0.1:53: poison HOSTS -> 127.0.0.1, forward the rest.
#    (online mode only — offline relies on partydeck host_aliases for routing.)
if [[ "$MODE" != "offline" ]]; then
    REDIR_ARGS=()
    for h in $HOSTS; do REDIR_ARGS+=(--redirect "$h" --to 127.0.0.1); done
    "$PY" "$CA_DIR/dns_capture.py" --listen 127.0.0.1:53 --upstream "${UPSTREAM}:53" \
        "${REDIR_ARGS[@]}" >"$DNSLOG" 2>&1 &
    DNS_PID=$!
    sleep 0.5
    if ! ss -lun 2>/dev/null | grep -qE '127\.0\.0\.1:53'; then
        echo "[capmitm] DNS shim failed to bind 127.0.0.1:53 — aborting." >&2
        cat "$DNSLOG" >&2; exit 1
    fi

    # 3. Repoint resolv.conf at our shim (immutable so resolvconf can't clobber it).
    cp -f "$RESOLV" "$BAK"
    chattr -i "$RESOLV" 2>/dev/null || true
    printf 'nameserver 127.0.0.1\noptions edns0\n' > "$RESOLV"
    chattr +i "$RESOLV" 2>/dev/null || true
    RESOLV_SWAPPED=1
    echo "[capmitm] /etc/resolv.conf -> 127.0.0.1 (backup $BAK)"

    # Self-test: prove the first host poisons before launching the game.
    TEST_IP="$(getent ahostsv4 "$PRIMARY" 2>/dev/null | awk '{print $1; exit}')"
    [[ "$TEST_IP" == "127.0.0.1" ]] && echo "[capmitm] self-test OK: $PRIMARY -> 127.0.0.1" \
        || echo "[capmitm] WARNING self-test: $PRIMARY -> '${TEST_IP:-<none>}' (expected 127.0.0.1)" >&2
else
    echo "[capmitm] MODE=offline: skipping DNS poisoning (partydeck host_aliases pins dt-live* -> 127.0.0.1)."
    echo "[capmitm]   make sure server.py is running:  PROBE_PORT=$LOCAL_BACKEND_PORT sudo python3 $CA_DIR/server.py"
    echo "[capmitm]   and the broker:                  python3 $CA_DIR/raknet.py"
fi

# 4. mitmdump on :443 (the real mitmproxy, via nix-shell). The addon retargets
#    each flow to the configured upstream (real backend online / server.py offline)
#    and logs decrypted HTTP.
#    --ssl-insecure: don't fail if an upstream cert can't be verified here.
#    connection_strategy=lazy: let the addon set the upstream before connecting.
#    keep_host_header: preserve the game's real Host header for upstream routing.
#    tls_version_client_max=TLS1_2: CRITICAL — Wine's schannel/winhttp can complete
#      a TLS 1.3 handshake but then chokes on post-handshake messages
#      (NewSessionTicket/KeyUpdate), returning ERROR_WINHTTP_SECURE_CHANNEL_ERROR
#      and sending NO request (client connects then instantly disconnects). The
#      real passtech backend AND our server.py both cap at TLS 1.2; mitmproxy must
#      too on its client-facing side or the game never sends a single request.
export MITM_LOG="$MITMLOG"
export MITM_REAL_DNS="$UPSTREAM"
export MITM_HOSTMAP="$HOSTMAP"
export MITM_REAL_PORT="$REAL_PORT"
# Offline: force ALL flows to the local server.py so nothing can leak to the real
# backend even if a Host header doesn't match the hostmap. (Online leaves this
# unset so the addon retargets to the pre-resolved real upstream per host.)
if [[ "$MODE" == "offline" ]]; then
    export MITM_FORCE_UPSTREAM="$LOCAL_BACKEND_IP:$LOCAL_BACKEND_PORT"
    # Reverse target IS the local server.py: mitmproxy reverse mode pins the
    # upstream to this address (the request-hook override alone does NOT escape
    # reverse-mode DNS), guaranteeing every request reaches server.py.
    REVERSE_TARGET="https://$LOCAL_BACKEND_IP:$LOCAL_BACKEND_PORT"
else
    unset MITM_FORCE_UPSTREAM
    REVERSE_TARGET="https://$PRIMARY"
fi
"$NIXSHELL" -p mitmproxy --run "mitmdump --mode reverse:$REVERSE_TARGET \
    --listen-host 0.0.0.0 --listen-port 443 \
    --set confdir=$CONFDIR --set connection_strategy=lazy \
    --set keep_host_header=true --ssl-insecure \
    --set tls_version_client_max=TLS1_2 \
    $CERT_STR \
    -s $HERE/mitm_addon.py" >"$PROXLOG" 2>&1 &
MITM_PID=$!
# nix-shell may need to realise mitmproxy on first run; give it a moment.
for _ in $(seq 1 60); do
    ss -ltn 2>/dev/null | grep -qE '(0\.0\.0\.0|127\.0\.0\.1):443' && break
    kill -0 "$MITM_PID" 2>/dev/null || { echo "[capmitm] mitmdump exited early:" >&2; cat "$PROXLOG" >&2; exit 1; }
    sleep 0.5
done
if ! ss -ltn 2>/dev/null | grep -qE '(0\.0\.0\.0|127\.0\.0\.1):443'; then
    echo "[capmitm] mitmdump not listening on :443 after 30s — see $PROXLOG" >&2
    tail -20 "$PROXLOG" >&2
fi

echo
echo "[capmitm] READY (label=$LABEL). Launch Ravenswatch now."
echo "[capmitm]   pcap : $PCAP"
echo "[capmitm]   mitm : $MITMLOG  (tail -f to watch decrypted HTTP)"
echo "[capmitm]   proxy log: $PROXLOG ; dns log: $DNSLOG"
echo "[capmitm] Press Ctrl-C here when done to stop and restore DNS."
WAIT_PIDS=()
for pid in "$TD_PID" "$DNS_PID" "$MITM_PID"; do
    [[ -n "$pid" ]] && WAIT_PIDS+=("$pid")
done
wait -n "${WAIT_PIDS[@]}"
echo "[capmitm] a component exited unexpectedly; cleaning up."

