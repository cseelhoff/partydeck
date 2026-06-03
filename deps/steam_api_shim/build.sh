#!/usr/bin/env bash
# Build the steam_api64 proxy/shim DLL (cross-compile to win64 with mingw-w64).
#
# Output: steam_api64.dll  (the shim).
# Deploy:  rename the game's real steam_api64.dll -> steam_api64_real.dll, then
#          drop this shim in its place. See deploy.sh.
set -euo pipefail
cd "$(dirname "$0")"

CXX="${CXX:-x86_64-w64-mingw32-g++}"

build() {
    local cxx="$1"
    echo "[steam_api_shim] regenerating exports..."
    ./generate_def.sh
    echo "[steam_api_shim] compiling with $cxx ..."
    "$cxx" -O2 -shared -std=c++17 \
        -static -static-libgcc -static-libstdc++ \
        -DUNICODE -D_UNICODE \
        src/dllmain.cpp src/trampolines.cpp src/matchmaking.cpp \
        steam_api_shim.def \
        -o steam_api64.dll \
        -Wl,--enable-stdcall-fixup -lkernel32
    echo "[steam_api_shim] built: $(pwd)/steam_api64.dll"
}

if command -v "$CXX" >/dev/null 2>&1; then
    build "$CXX"
elif command -v nix-shell >/dev/null 2>&1; then
    echo "[steam_api_shim] $CXX not on PATH; entering nix-shell with mingw cross toolchain..."
    exec nix-shell -p pkgsCross.mingwW64.buildPackages.gcc --run \
        "CXX=x86_64-w64-mingw32-g++ bash $(basename "$0")"
else
    echo "ERROR: need $CXX or nix-shell to build." >&2
    exit 1
fi
