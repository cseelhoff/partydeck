#!/usr/bin/env bash
# Extract the export NAME table of a real steam_api64.dll into steam_exports.txt.
# Different Steamworks SDK versions ship slightly different export sets, so when
# deploying for a new game/version, regenerate the list from THAT game's real
# steam_api64.dll before building:
#
#   ./extract_exports.sh /path/to/<game>/steam_api64.dll
#
set -euo pipefail
cd "$(dirname "$0")"

DLL="${1:-}"
[ -f "$DLL" ] || { echo "usage: $0 <real steam_api64.dll>" >&2; exit 1; }

dump() { x86_64-w64-mingw32-objdump -p "$DLL"; }

if command -v x86_64-w64-mingw32-objdump >/dev/null 2>&1; then
    raw="$(dump)"
elif command -v nix-shell >/dev/null 2>&1; then
    raw="$(nix-shell -p pkgsCross.mingwW64.buildPackages.binutils --run "x86_64-w64-mingw32-objdump -p '$DLL'")"
else
    echo "need x86_64-w64-mingw32-objdump or nix-shell" >&2; exit 1
fi

# The [Ordinal/Name Pointer] Table lists "  [ N] +base[ M]  HHHH Name".
echo "$raw" \
  | awk '/\[Ordinal\/Name Pointer\] Table/{f=1;next} f{print}' \
  | grep -oE '[A-Za-z_][A-Za-z0-9_]+$' \
  | grep -E '^(SteamAPI_|SteamInternal_|Steam_|GetHSteam)' \
  | sort -u > steam_exports.txt

echo "wrote steam_exports.txt: $(wc -l < steam_exports.txt) names"
