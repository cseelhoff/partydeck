#!/usr/bin/env bash
# Remove the partydeck egress DNS REDIRECT and restore normal resolution.
#
# Safe to run from ANY directory and any number of times. Deletes *all* copies
# of the rule, resets route_localnet, and flushes resolver caches (the original
# breakage lingered because nscd/systemd-resolved cached failures while the
# rule had no listener).
#
# Run:  sudo /home/caleb/partydeck/res/dns_redirect_off.sh

# NOTE: deliberately no `set -e` — every cleanup step must run even if an
# earlier one "fails" (e.g. the rule is already gone).

removed=0
# Delete every matching rule (a rule can be present more than once).
while iptables -t nat -D OUTPUT -p udp --dport 53 -j REDIRECT --to-ports 53 2>/dev/null; do
    removed=$((removed + 1))
done
# Also clear any DNAT-style variant we may have used.
while iptables -t nat -D OUTPUT -p udp --dport 53 -j DNAT --to-destination 127.0.0.1:53 2>/dev/null; do
    removed=$((removed + 1))
done

sysctl -w net.ipv4.conf.all.route_localnet=0 >/dev/null 2>&1 || true

# Flush resolver caches so previously-cached failures don't persist.
command -v resolvectl >/dev/null 2>&1 && resolvectl flush-caches 2>/dev/null || true
command -v nscd >/dev/null 2>&1 && nscd -i hosts 2>/dev/null || true

echo "[dns_redirect] removed ${removed} redirect rule(s); route_localnet=0; caches flushed."
echo "[dns_redirect] DNS restored."
