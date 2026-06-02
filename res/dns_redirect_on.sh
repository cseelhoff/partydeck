#!/usr/bin/env bash
# Safely redirect this host's egress UDP DNS (port 53) into the local
# AAAA-stripping shim, so Wine/winhttp (which queries the real nameserver
# directly over UDP, ignoring the sandbox resolv.conf) gets IPv4-only answers
# for the configured domains.
#
# *** PREFER dns_shim_guard.sh INSTEAD OF THIS SCRIPT. ***
# This installs a *system-wide* rule that persists until explicitly removed. If
# the shim stops while the rule is active, ALL system DNS breaks. The guard ties
# the rule to a foreground process and auto-reverts on exit/crash. Use this
# manual on/off pair only if you want a long-lived rule you manage yourself.
#
# Run:   sudo /home/caleb/partydeck/res/dns_redirect_on.sh
# Undo:  sudo /home/caleb/partydeck/res/dns_redirect_off.sh
set -euo pipefail

# Refuse to install the rule unless the shim is actually listening on :53 —
# otherwise we'd blackhole all system DNS the moment the rule goes in.
if ! ss -lun 2>/dev/null | grep -qE '(127\.0\.0\.1|0\.0\.0\.0):53'; then
    echo "[dns_redirect] REFUSING: no DNS shim listening on :53." >&2
    echo "[dns_redirect] Start it first, e.g.:" >&2
    echo "    python3 /home/caleb/partydeck/res/dns_aaaa_filter.py \\" >&2
    echo "        --listen 127.0.0.1:53 --upstream 10.1.1.1:53 \\" >&2
    echo "        --domain passtechgames.com --tcp-upstream &" >&2
    exit 1
fi

# Allow REDIRECT of locally-generated packets to loopback.
sysctl -w net.ipv4.conf.all.route_localnet=1 >/dev/null

# Idempotent: remove a prior copy of the rule, then add it.
iptables -t nat -D OUTPUT -p udp --dport 53 -j REDIRECT --to-ports 53 2>/dev/null || true
iptables -t nat -A OUTPUT -p udp --dport 53 -j REDIRECT --to-ports 53

echo "[dns_redirect] egress UDP:53 -> 127.0.0.1:53 (shim). route_localnet=1."
echo "[dns_redirect] WARNING: system-wide. If the shim dies, run:"
echo "    sudo /home/caleb/partydeck/res/dns_redirect_off.sh"
