#!/usr/bin/env bash
# Deploy / remove the winhttp proxy shim for a game directory.
#
#   deploy.sh install <gamedir> [protondir]   install shim + renamed builtin
#   deploy.sh uninstall <gamedir>             remove shim, restore original
#
# The shim works by Wine's native-DLL override: our winhttp.dll sits next to the
# game exe and Proton's BUILTIN winhttp is copied alongside as winhttp_real.dll
# (our forward target). You MUST also run the game with:
#     WINEDLLOVERRIDES="winhttp=n,b"
# so Wine loads our native winhttp.dll instead of its builtin. For partydeck add
# that to the Ravenswatch handler.json "env" field.
set -euo pipefail
cd "$(dirname "$0")"

ACTION="${1:-}"
GAMEDIR="${2:-}"
PROTONDIR="${3:-}"

SHIM="$(pwd)/winhttp.dll"

usage() { echo "usage: $0 install <gamedir> [protondir] | uninstall <gamedir>" >&2; exit 1; }
[[ -n "$ACTION" && -n "$GAMEDIR" ]] || usage
[[ -d "$GAMEDIR" ]] || { echo "gamedir not found: $GAMEDIR" >&2; exit 1; }

find_builtin_winhttp() {
    # 1) explicit protondir arg
    if [[ -n "$PROTONDIR" ]]; then
        local p
        for p in "$PROTONDIR"/files/lib/wine/x86_64-windows/winhttp.dll \
                 "$PROTONDIR"/files/lib64/wine/x86_64-windows/winhttp.dll; do
            [[ -f "$p" ]] && { echo "$p"; return 0; }
        done
    fi
    # 2) newest GE-Proton in the Steam compat tools dir. MUST match the Proton
    #    partydeck launches with: an empty proton_version makes umu resolve the
    #    bare name "GE-Proton" to the NEWEST GE-Proton*, so prefer the highest
    #    GE-Proton version here (the winhttp builtin differs between point
    #    releases). Only fall back to other Proton flavours if no GE-Proton.
    local base="$HOME/.local/share/Steam/compatibilitytools.d"
    local steamapps="$HOME/.local/share/Steam/steamapps/common"
    local d p
    for d in $(ls -d "$base"/GE-Proton*/ 2>/dev/null | sort -rV); do
        for p in "$d"files/lib/wine/x86_64-windows/winhttp.dll \
                 "$d"files/lib64/wine/x86_64-windows/winhttp.dll; do
            [[ -f "$p" ]] && { echo "$p"; return 0; }
        done
    done
    for d in $(ls -d "$base"/*/ "$steamapps"/Proton*/ 2>/dev/null | sort -rV); do
        for p in "$d"files/lib/wine/x86_64-windows/winhttp.dll \
                 "$d"files/lib64/wine/x86_64-windows/winhttp.dll; do
            [[ -f "$p" ]] && { echo "$p"; return 0; }
        done
    done
    return 1
}

case "$ACTION" in
install)
    [[ -f "$SHIM" ]] || { echo "build the shim first: ./build.sh" >&2; exit 1; }
    builtin="$(find_builtin_winhttp || true)"
    [[ -n "$builtin" ]] || { echo "could not find Proton builtin winhttp.dll; pass <protondir>" >&2; exit 1; }
    echo "[winhttp_shim] builtin winhttp: $builtin"
    cp -f "$builtin" "$GAMEDIR/winhttp_real.dll"
    cp -f "$SHIM"    "$GAMEDIR/winhttp.dll"
    echo "[winhttp_shim] installed into $GAMEDIR"
    echo "[winhttp_shim] REMEMBER: run with WINEDLLOVERRIDES=\"winhttp=n,b\""
    ;;
uninstall)
    rm -f "$GAMEDIR/winhttp.dll" "$GAMEDIR/winhttp_real.dll"
    echo "[winhttp_shim] removed shim from $GAMEDIR"
    ;;
*)
    usage
    ;;
esac
