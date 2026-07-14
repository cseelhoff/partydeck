#!/usr/bin/env bash
set -u
pids=()
cleanup() { [ ${#pids[@]} -gt 0 ] && kill "${pids[@]}" 2>/dev/null || true; }
trap cleanup EXIT INT TERM
i=0
for link in /dev/input/by-id/*-event-joystick; do
  [ -e "$link" ] || continue
  i=$((i + 1))
  dev=$(readlink -f "$link")
  echo "pad $i -> $dev"
  #exec /nix/store/723qxyck4gzh0ga462b1f700d3xgincy-python3-3.13.12-env/bin/python3 /home/caleb/partydeck/partydeck-pad-bridge.py "$@"
  /nix/store/723qxyck4gzh0ga462b1f700d3xgincy-python3-3.13.12-env/bin/python3 /home/caleb/partydeck/partydeck-pad-bridge.py --device "$dev" --name "partydeck-kbm-p$i" &
  pids+=($!)
done
if [ "$i" -eq 0 ]; then
  echo "no gamepads found under /dev/input/by-id/*-event-joystick" >&2
  exit 1
fi
echo "started $i pad bridge(s); press Ctrl-C to stop"
wait

