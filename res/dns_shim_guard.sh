#!/usr/bin/env bash
# Safe, self-cleaning DNS shim + redirect for partydeck.
#
# Runs the AAAA-stripping shim AND installs the egress UDP:53 redirect, then
# stays in the FOREGROUND. On exit for ANY reason — Ctrl-C, terminal close,
# kill, error, or the shim dying — it automatically removes the iptables rule,
# resets route_localnet, kills the shim, and flushes resolver caches. This makes
# it impossible to leave the system without DNS (the failure mode that bit us
# before, where a dead shim + a lingering rule blackholed all name resolution).
#
# Usage:
#   sudo /home/caleb/partydeck/res/dns_shim_guard.sh [DOMAIN ...]
# e.g.
#   sudo /home/caleb/partydeck/res/dns_shim_guard.sh passtechgames.com
#
# Then launch the game in partydeck. When done, press Ctrl-C here (or just close
# the terminal) and DNS is fully restored.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
SHIM_PY="${SCRIPT_DIR}/dns_aaaa_filter.py"

if [[ $EUID -ne 0 ]]; then
    echo "[guard] must run as root (sudo)." >&2
    exit 1
fi
if [[ ! -f "$SHIM_PY" ]]; then
    echo "[guard] cannot find shim: $SHIM_PY" >&2
    exit 1
fi

# Domains to AAAA-strip (default: passtechgames.com for Ravenswatch).
DOMAINS=("$@")
[[ ${#DOMAINS[@]} -eq 0 ]] && DOMAINS=("passtechgames.com")

# Discover the host's real upstream nameserver (first non-loopback entry).
UPSTREAM="$(awk '/^nameserver/ && $2 != "127.0.0.1" {print $2; exit}' /etc/resolv.conf)"
[[ -z "${UPSTREAM:-}" ]] && UPSTREAM="1.1.1.1"

SHIM_PID=""
RULE_INSTALLED=0

cleanup() {
    # Idempotent teardown; runs on any exit path.
    trap - EXIT INT TERM HUP
    echo
    echo "[guard] cleaning up..."
    if [[ $RULE_INSTALLED -eq 1 ]]; then
        while iptables -t nat -D OUTPUT -p udp --dport 53 -j REDIRECT --to-ports 53 2>/dev/null; do :; done
        sysctl -w net.ipv4.conf.all.route_localnet=0 >/dev/null 2>&1 || true
    fi
    if [[ -n "$SHIM_PID" ]] && kill -0 "$SHIM_PID" 2>/dev/null; then
        kill "$SHIM_PID" 2>/dev/null || true
        wait "$SHIM_PID" 2>/dev/null || true
    fi
    command -v resolvectl >/dev/null 2>&1 && resolvectl flush-caches 2>/dev/null || true
    command -v nscd >/dev/null 2>&1 && nscd -i hosts 2>/dev/null || true
    echo "[guard] DNS restored."
}
trap cleanup EXIT INT TERM HUP

# 1) Start the shim on 127.0.0.1:53 (TCP upstream). Run it as root so it can
#    always bind the privileged port without needing an ip_unprivileged_port_start
#    sysctl tweak. It only listens on loopback and forwards DNS — minimal surface.
shim_args=(--listen 127.0.0.1:53 --upstream "${UPSTREAM}:53" --tcp-upstream)
for d in "${DOMAINS[@]}"; do shim_args+=(--domain "$d"); done

echo "[guard] starting shim: AAAA-strip ${DOMAINS[*]}; upstream ${UPSTREAM} (tcp)"
python3 "$SHIM_PY" "${shim_args[@]}" &
SHIM_PID=$!

# 2) Wait for the shim to actually listen before touching iptables.
for _ in $(seq 1 20); do
    if ss -lun 2>/dev/null | grep -qE '127\.0\.0\.1:53'; then
        break
    fi
    if ! kill -0 "$SHIM_PID" 2>/dev/null; then
        echo "[guard] shim exited before binding :53 (port in use?)." >&2
        exit 1
    fi
    sleep 0.2
done
if ! ss -lun 2>/dev/null | grep -qE '127\.0\.0\.1:53'; then
    echo "[guard] shim never bound 127.0.0.1:53; aborting (no rule installed)." >&2
    exit 1
fi

# 3) Install the redirect (only now that the shim is confirmed up).
sysctl -w net.ipv4.conf.all.route_localnet=1 >/dev/null
iptables -t nat -D OUTPUT -p udp --dport 53 -j REDIRECT --to-ports 53 2>/dev/null || true
iptables -t nat -A OUTPUT -p udp --dport 53 -j REDIRECT --to-ports 53
RULE_INSTALLED=1

echo "[guard] redirect active. Launch the game now."
echo "[guard] Press Ctrl-C (or close this terminal) when done to restore DNS."

# 4) Stay foreground; if the shim dies, tear everything down immediately so the
#    redirect never outlives its listener.
while kill -0 "$SHIM_PID" 2>/dev/null; do
    sleep 1
done
echo "[guard] shim exited — tearing down." >&2
