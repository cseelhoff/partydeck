# CMake toolchain for cross-compiling to x86_64-w64-mingw32 from Linux/nix.
#
# Used by shell.nix in this directory. NEE's own CMakeLists requires either
# -DX86=ON or -DX64=ON; pass -DX64=ON on the configure command line.

set(CMAKE_SYSTEM_NAME Windows)
set(CMAKE_SYSTEM_PROCESSOR x86_64)

set(TARGET_TRIPLE x86_64-w64-mingw32)

# Nix's wrapped cross-gcc is already on PATH inside the nix shell.
set(CMAKE_C_COMPILER   ${TARGET_TRIPLE}-gcc)
set(CMAKE_CXX_COMPILER ${TARGET_TRIPLE}-g++)
set(CMAKE_RC_COMPILER  ${TARGET_TRIPLE}-windres)
set(CMAKE_AR           ${TARGET_TRIPLE}-ar)
set(CMAKE_RANLIB       ${TARGET_TRIPLE}-ranlib)

# Match NEE's CRT linkage expectations (static). -static also folds winpthread
# and libmcfgthread in so the produced DLL has no lib*.dll runtime sidecars.
set(CMAKE_EXE_LINKER_FLAGS_INIT    "-static -static-libgcc -static-libstdc++")
set(CMAKE_SHARED_LINKER_FLAGS_INIT "-static -static-libgcc -static-libstdc++")

# Find packages only in cross sysroot, not host.
set(CMAKE_FIND_ROOT_PATH_MODE_PROGRAM NEVER)
set(CMAKE_FIND_ROOT_PATH_MODE_LIBRARY ONLY)
set(CMAKE_FIND_ROOT_PATH_MODE_INCLUDE ONLY)
set(CMAKE_FIND_ROOT_PATH_MODE_PACKAGE ONLY)
