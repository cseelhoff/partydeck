#!/usr/bin/env bash
# Deploy / undeploy the steam_api64 shim into a game directory.
#
#   deploy.sh install   <game_dir>   install shim (backs up real API -> _real.dll)
#   deploy.sh uninstall <game_dir>   restore the real Steam API, remove shim
#
# The shim writes its JSONL log to $STEAM_SHIM_LOG (set that in the game's env /
# Steam launch options; default is <cwd>/steam_api_shim.jsonl).
#
# The game loads steam_api64.dll dynamically, so NO WINEDLLOVERRIDE is needed:
# our shim simply replaces the file the game LoadLibrary()s, and forwards every
# untouched export to steam_api64_real.dll.
set -euo pipefail
cd "$(dirname "$0")"

SHIM="$(pwd)/steam_api64.dll"
NAME="steam_api64.dll"
REAL="steam_api64_real.dll"

cmd="${1:-}"; dir="${2:-}"
{ [ -z "$cmd" ] || [ -z "$dir" ]; } && { echo "usage: deploy.sh install|uninstall <game_dir>"; exit 2; }
[ -d "$dir" ] || { echo "no such dir: $dir"; exit 1; }

case "$cmd" in
  install)
    [ -f "$SHIM" ] || { echo "build first: ./build.sh"; exit 1; }
    if [ ! -f "$dir/$REAL" ]; then
      [ -f "$dir/$NAME" ] || { echo "no real $NAME in $dir"; exit 1; }
      # Sanity: refuse to back up our own shim as the real DLL.
      if x86_64-w64-mingw32-objdump -p "$dir/$NAME" 2>/dev/null | grep -q "steam_api64_real"; then
        echo "ERROR: $dir/$NAME is already the shim (forwards to _real). Aborting to avoid a loop." >&2
        exit 1
      fi
      cp -v "$dir/$NAME" "$dir/$REAL"   # preserve genuine Valve API
    fi
    cp -v "$SHIM" "$dir/$NAME"
    echo "[steam_api_shim] installed. real Steam API preserved as $REAL."
    echo "[steam_api_shim] set STEAM_SHIM_LOG in the game's env/launch options."
    ;;
  uninstall)
    [ -f "$dir/$REAL" ] || { echo "no $REAL backup in $dir; nothing to restore"; exit 1; }
    cp -v "$dir/$REAL" "$dir/$NAME"
    rm -v "$dir/$REAL"
    echo "[steam_api_shim] restored real Steam API."
    ;;
  *) echo "unknown command: $cmd"; exit 2;;
esac
