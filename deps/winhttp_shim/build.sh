#!/usr/bin/env bash
# Build the winhttp proxy/shim DLL (cross-compile to win64 with mingw-w64).
#
# Output: winhttp.dll  (the shim).
# Deploy:  copy Proton's builtin winhttp.dll -> winhttp_real.dll in the game dir,
#          drop this winhttp.dll beside it, set WINEDLLOVERRIDES=winhttp=n,b.
#          See deploy.sh.
set -euo pipefail
cd "$(dirname "$0")"

CXX="${CXX:-x86_64-w64-mingw32-g++}"

build() {
    local cxx="$1"
    echo "[winhttp_shim] regenerating exports..."
    ./generate_def.sh
    echo "[winhttp_shim] compiling with $cxx ..."
    "$cxx" -O2 -shared -std=c++17 \
        -static -static-libgcc -static-libstdc++ \
        -DUNICODE -D_UNICODE \
        src/dllmain.cpp src/trampolines.cpp \
        winhttp_shim.def \
        -o winhttp.dll \
        -Wl,--enable-stdcall-fixup -lkernel32 -lwinhttp
    echo "[winhttp_shim] built: $(pwd)/winhttp.dll"
}

if command -v "$CXX" >/dev/null 2>&1; then
    build "$CXX"
elif command -v nix-shell >/dev/null 2>&1; then
    echo "[winhttp_shim] $CXX not on PATH; entering nix-shell with mingw cross toolchain..."
    exec nix-shell -p pkgsCross.mingwW64.buildPackages.gcc --run \
        "CXX=x86_64-w64-mingw32-g++ bash $(basename "$0")"
else
    echo "ERROR: need $CXX or nix-shell to build." >&2
    exit 1
fi
