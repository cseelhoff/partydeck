#!/usr/bin/env bash
# Deploy / undeploy the EOS shim into a game directory.
#
#   deploy.sh install   <game_dir>   install shim (backs up real SDK -> .orig.dll)
#   deploy.sh uninstall <game_dir>   restore the real SDK, remove shim
#
# The shim writes its JSONL log to $EOS_SHIM_LOG (set that in the game's env;
# default is <cwd>/eos_shim.jsonl).
set -euo pipefail
cd "$(dirname "$0")"

SHIM="$(pwd)/EOSSDK-Win64-Shipping.dll"
NAME="EOSSDK-Win64-Shipping.dll"
ORIG="EOSSDK-Win64-Shipping-pointed-to-by-shim.dll"

cmd="${1:-}"; dir="${2:-}"
[ -z "$cmd" ] || [ -z "$dir" ] && { echo "usage: deploy.sh install|uninstall <game_dir>"; exit 2; }
[ -d "$dir" ] || { echo "no such dir: $dir"; exit 1; }

case "$cmd" in
  install)
    [ -f "$SHIM" ] || { echo "build first: ./build.sh"; exit 1; }
    if [ ! -f "$dir/$ORIG" ]; then
      [ -f "$dir/$NAME" ] || { echo "no real $NAME in $dir"; exit 1; }
      cp -v "$dir/$NAME" "$dir/$ORIG"   # preserve genuine SDK
    fi
    cp -v "$SHIM" "$dir/$NAME"
    echo "installed shim. real SDK preserved as $ORIG."
    ;;
  uninstall)
    [ -f "$dir/$ORIG" ] || { echo "no $ORIG backup in $dir; nothing to restore"; exit 1; }
    cp -v "$dir/$ORIG" "$dir/$NAME"
    rm -v "$dir/$ORIG"
    echo "restored real SDK."
    ;;
  *) echo "unknown command: $cmd"; exit 2;;
esac
