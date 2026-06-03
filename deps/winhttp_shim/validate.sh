#!/usr/bin/env bash
# validate.sh -- empirical validation harness for the winhttp proxy shim.
#
# Per the refactor risk plan: BEFORE wiring the shim into partydeck's Rust launch
# path, prove the renamed-builtin trick actually works in this Proton by:
#   1. building + deploying the shim into the Ravenswatch game dir,
#   2. running the offline backend in PLAIN HTTP mode (no TLS, no CA),
#   3. launching Ravenswatch through partydeck and confirming the shim log shows
#      WinHttpConnect.redirect + WinHttpOpenRequest.unsecure AND the server log
#      shows GET /_federation 200 over plain HTTP and a join code generates.
#
# This script does the deterministic, reversible shim-side setup and prints the
# exact runbook for the manual launch step. It does NOT modify handler.json or
# launch the game for you.
#
# Usage:
#   ./validate.sh setup     [gamedir]   build+deploy shim, print runbook
#   ./validate.sh teardown  [gamedir]   remove shim from the game dir
set -euo pipefail
cd "$(dirname "$0")"
HERE="$(pwd)"

ACTION="${1:-setup}"
GAMEDIR="${2:-$HOME/.local/share/Steam/steamapps/common/Ravenswatch}"

PROBE_DIR="${PROBE_DIR:-/tmp/pdlog/probe}"
PLAIN_PORT="${WINHTTP_SHIM_TARGET_PORT:-8080}"
REDIRECT_HOSTS="${WINHTTP_SHIM_REDIRECT_HOSTS:-dt-live.passtechgames.com,dt-live-2.passtechgames.com,dt-live-3.passtechgames.com}"
SHIM_LOG="${WINHTTP_SHIM_LOG:-$PROBE_DIR/winhttp_shim.jsonl}"

[[ -d "$GAMEDIR" ]] || { echo "game dir not found: $GAMEDIR" >&2; exit 1; }

case "$ACTION" in
setup)
    [[ -f "$HERE/winhttp.dll" ]] || { echo "[validate] building shim..."; ./build.sh; }
    echo "[validate] deploying shim into game dir..."
    ./deploy.sh install "$GAMEDIR"
    cat <<RUNBOOK

================= winhttp_shim empirical validation runbook =================
Shim deployed to: $GAMEDIR
  winhttp.dll       (our proxy)
  winhttp_real.dll  (renamed Proton builtin -> forward target)

1) Start the offline backend in PLAIN HTTP mode (NO TLS, NO CA). RAKNET_ENDPOINT
   goes on the PYTHON processes (they mint the tokens), NOT on the game. The
   dt-live federation server lives in the project src/ dir; PROBE_DIR keeps its
   logs/dumps (and, in TLS mode, certs) under $PROBE_DIR:
     cd $HOME/partydeck/src
     RAKNET_ENDPOINT=127.0.0.1:30100 PROBE_DIR=$PROBE_DIR PROBE_PLAIN=1 PROBE_PORT=$PLAIN_PORT python3 dtlive_server.py &
     RAKNET_ENDPOINT=127.0.0.1:30100 python3 raknet.py &
   (both import scenes/stoken/blobs from src/ via sys.path; run from src/ as above.)

2) Add this to the Ravenswatch handler.json "env" (and set host_aliases to [] for
   the test so you prove the shim alone steers HTTPS + RakNet):
     WINEDLLOVERRIDES=winhttp=n,b
     WINHTTP_SHIM_TARGET_HOST=127.0.0.1
     WINHTTP_SHIM_TARGET_PORT=$PLAIN_PORT
     WINHTTP_SHIM_REDIRECT_HOSTS=$REDIRECT_HOSTS
     WINHTTP_SHIM_LOG=$SHIM_LOG
   (do NOT put RAKNET_ENDPOINT here -- the game never mints tokens.)

3) Launch partydeck, start Ravenswatch (Dad + Elsie), have Elsie join Dad.

4) PASS criteria:
   - $SHIM_LOG contains:
       "ev":"shim_attach"  and  "ev":"WinHttpConnect.redirect"
       "ev":"WinHttpOpenRequest.unsecure"   (TLS flag cleared)
   - $PROBE_DIR/server.log contains:
       REQUEST GET /_federation ... (plain http)   -> 200
       REQUEST POST .../token       -> token envelope raknet 127.0.0.1:30100
   - A join code is generated in-game.
   If all true, the renamed-builtin trick works in this Proton -> safe to wire
   the shim into the Rust launch path and retire the mitmproxy/CA stack.

   Watch the shim log live:
     tail -f $SHIM_LOG

5) When done:  ./validate.sh teardown
============================================================================
RUNBOOK
    ;;
teardown)
    ./deploy.sh uninstall "$GAMEDIR"
    echo "[validate] shim removed. (restore handler.json env / host_aliases manually if you changed them.)"
    ;;
*)
    echo "usage: $0 setup|teardown [gamedir]" >&2
    exit 1
    ;;
esac
