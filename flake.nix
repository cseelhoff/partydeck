{
  description = "PartyDeck – split-screen game launcher for Linux";

  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixos-25.11";
  };

  outputs = { self, nixpkgs }:
    let
      system = "x86_64-linux";
      pkgs = nixpkgs.legacyPackages.${system};
    in {
      devShells.${system}.default = pkgs.mkShell {
        hardeningDisable = [ "fortify" ];
        nativeBuildInputs = with pkgs; [
          # Rust toolchain
          rustc
          cargo
          pkg-config
          cmake

          # gamescope-kbm build (meson/ninja + C/C++ deps)
          meson
          ninja
          glslang

          # get_deps_releases.sh needs these
          curl
          p7zip
          python3

          # NixOS: system umu-launcher replaces bundled umu-run
          # (bundled binary can't run on NixOS due to dynamic linking)
          umu-launcher
        ];

        buildInputs = with pkgs; [
          # Rust crate native deps (eframe/egui, x11rb, wayland, etc.)
          libxkbcommon
          libGL
          xorg.libX11
          xorg.libXcursor
          xorg.libXrandr
          xorg.libXi
          xorg.libxcb
          wayland
          openssl

          # gamescope-kbm deps
          vulkan-headers
          vulkan-loader
          libdrm
          xorg.libXdamage
          xorg.libXcomposite
          xorg.libXrender
          xorg.libXext
          xorg.libXfixes
          xorg.libXxf86vm
          xorg.libXtst
          xorg.libXres
          xorg.libXmu
          xorg.xcbutilwm        # provides xcb-ewmh
          xorg.xcbutilimage
          xorg.xcbutilerrors
          xwayland
          libinput
          libei
          seatd
          pixman
          libcap
          libdecor
          pipewire
          SDL2
          hwdata
          luajit
          openvr
          libavif
          lcms2
          gbenchmark

          # wayland protocols (needed by wlroots subproject)
          wayland-protocols
          wayland-scanner
        ];

        # Help pkg-config and linker find everything
        LD_LIBRARY_PATH = pkgs.lib.makeLibraryPath [
          pkgs.libGL
          pkgs.vulkan-loader
          pkgs.wayland
          pkgs.libxkbcommon
          pkgs.xorg.libX11
          pkgs.xorg.libXcursor
          pkgs.xorg.libXrandr
          pkgs.xorg.libXi
        ];

        shellHook = ''
          # 1. Initialize git submodules if needed
          if [ ! -f deps/gamescope/meson.build ]; then
            echo "📦 Initializing git submodules..."
            git submodule update --init
            # gamescope has a broken gitlink for glm (no .gitmodules entry)
            # which poisons all git-submodule commands. Remove it from the
            # index so the real submodules can be initialised, then let
            # meson's glm.wrap fetch glm at configure time.
            (cd deps/gamescope \
              && git rm --cached subprojects/glm 2>/dev/null || true \
              && rm -rf subprojects/glm \
              && git submodule update --init --recursive)
          fi

          # 2. Download Goldberg + UMU releases if not already present
          if [ ! -d deps/releases/gbe-linux-release ]; then
            echo "⬇️  Downloading Goldberg + UMU releases..."
            sh ./get_deps_releases.sh
          fi

          # 3. Build gamescope-kbm if not already built
          if [ ! -f deps/gamescope/build/src/gamescope ]; then
            echo "🔨 Building gamescope-kbm..."
            (cd deps/gamescope && meson setup build/ && ninja -C build/)
          fi

          # NixOS fix: build.sh copies a bundled umu-run that can't run on NixOS
          # (dynamically linked against FHS paths). Replace it with the Nix package.
          if [ -f build/bin/umu-run ] && [ ! -L build/bin/umu-run ]; then
            echo "🔧 Replacing bundled umu-run with NixOS umu-launcher..."
            rm build/bin/umu-run
            ln -s "$(command -v umu-run)" build/bin/umu-run
          fi

          echo ""
          echo "🎮 PartyDeck dev shell ready"
          echo "  Run: sh build.sh             (cargo build + assemble)"
          echo "  Launch: cd build && ./partydeck"
        '';
      };
    };
}
