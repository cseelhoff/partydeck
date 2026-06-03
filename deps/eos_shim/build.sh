#!/usr/bin/env bash
# Build the EOS proxy/shim DLL (cross-compile to win64 with mingw-w64).
#
# Output: EOSSDK-Win64-Shipping.dll  (the shim).
# Deploy:  rename the game's real EOSSDK-Win64-Shipping.dll -> .orig.dll, then
#          drop this shim in its place. See deploy.sh.
set -euo pipefail
cd "$(dirname "$0")"

CXX="${CXX:-x86_64-w64-mingw32-g++}"

build() {
    local cxx="$1"
    echo "[eos_shim] regenerating exports..."
    ./generate_def.sh
    echo "[eos_shim] compiling with $cxx ..."
    "$cxx" -O2 -shared -std=c++17 \
        -static -static-libgcc -static-libstdc++ \
        -DUNICODE -D_UNICODE \
        -I include -I include/eos_sdk \
        src/dllmain.cpp src/trampolines.cpp \
        eos_shim.def \
        -o EOSSDK-Win64-Shipping.dll \
        -Wl,--enable-stdcall-fixup -lkernel32
    echo "[eos_shim] built: $(pwd)/EOSSDK-Win64-Shipping.dll"
}

if command -v "$CXX" >/dev/null 2>&1; then
    build "$CXX"
elif command -v nix-shell >/dev/null 2>&1; then
    echo "[eos_shim] $CXX not on PATH; entering nix-shell with mingw cross toolchain..."
    exec nix-shell -p pkgsCross.mingwW64.buildPackages.gcc --run \
        "CXX=x86_64-w64-mingw32-g++ bash $(basename "$0")"
else
    echo "ERROR: need $CXX or nix-shell to build." >&2
    exit 1
fi
