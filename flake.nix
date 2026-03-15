{
  description = "PartyDeck – split-screen game launcher for Linux";

  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixos-25.11";
  };

  outputs = { self, nixpkgs }:
    let
      system = "x86_64-linux";
      pkgs = nixpkgs.legacyPackages.${system};
      lib = pkgs.lib;

      # ---------------------------------------------------------------
      # Goldberg Steam Emu – pre-built binaries for LAN multiplayer
      # ---------------------------------------------------------------
      gbeVersion = "release-2026_03_10";
      gbe-linux-src = pkgs.fetchurl {
        url = "https://github.com/Detanup01/gbe_fork/releases/download/${gbeVersion}/emu-linux-release.tar.bz2";
        hash = "sha256-AyUAyhALcv0tqpTuwyY898b+Y0h2I/nijXDu5BpYuwE=";
      };
      gbe-win-src = pkgs.fetchurl {
        url = "https://github.com/Detanup01/gbe_fork/releases/download/${gbeVersion}/emu-win-release.7z";
        hash = "sha256-D2ekISqk5qcfhIeaOgD2dcsqjEPhPjjgsnq1yeal5l8=";
      };

      goldberg-emu = pkgs.stdenv.mkDerivation {
        pname = "goldberg-emu";
        version = gbeVersion;
        src = gbe-linux-src;
        nativeBuildInputs = [ pkgs.p7zip ];
        sourceRoot = ".";
        unpackPhase = ''
          mkdir -p linux win
          tar -xf ${gbe-linux-src} -C linux
          7z x -aoa ${gbe-win-src} -owin
        '';
        installPhase = ''
          mkdir -p $out/share/goldberg/{linux32,linux64,win}
          cp linux/release/regular/x32/steamclient.so  $out/share/goldberg/linux32/
          cp linux/release/regular/x64/steamclient.so  $out/share/goldberg/linux64/
          cp win/release/steamclient_experimental/steamclient.dll        \
             win/release/steamclient_experimental/steamclient64.dll      \
             win/release/steamclient_experimental/GameOverlayRenderer.dll   \
             win/release/steamclient_experimental/GameOverlayRenderer64.dll \
             $out/share/goldberg/win/
        '';
      };

      # ---------------------------------------------------------------
      # gamescope-kbm source + all submodules (fetched individually
      # because the repo has a broken glm gitlink that prevents
      # fetchSubmodules from working)
      # ---------------------------------------------------------------
      gamescope-kbm-main = pkgs.fetchFromGitHub {
        owner = "davidawesome02-backup";
        repo = "gamescope";
        rev = "35b04f17724c7d9b55bbb0b45547f58e83054a27";
        hash = "sha256-fbESRw4DBUBviTZyXd++3vOVeawNYKxjEj+NCSMMPiI=";
      };

      # Git submodules (from .gitmodules)
      wlroots-src = pkgs.fetchFromGitHub {
        owner = "Joshua-Ashton"; repo = "wlroots";
        rev = "54e844748029d4874e14d0c086d50092c04c8899";
        hash = "sha256-BbxhVUaVithvTwDPUANe4kn1E7WNwO/dXKZ+e0rQr2s=";
      };
      libliftoff-src = pkgs.fetchFromGitLab {
        domain = "gitlab.freedesktop.org";
        owner = "emersion"; repo = "libliftoff";
        rev = "8b08dc1c14fd019cc90ddabe34ad16596b0691f4";
        hash = "sha256-PcQY8OXPqfn8C30+GAYh0Z916ba5pik8U0fVpZtFb5g=";
      };
      vkroots-src = pkgs.fetchFromGitHub {
        owner = "Joshua-Ashton"; repo = "vkroots";
        rev = "5106d8a0df95de66cc58dc1ea37e69c99afc9540";
        hash = "sha256-SgHFIWjifZ5L10/1RL7lXoX6evS5LsFvFKWMhHEHN0M=";
      };
      libdisplay-info-src = pkgs.fetchFromGitLab {
        domain = "gitlab.freedesktop.org";
        owner = "emersion"; repo = "libdisplay-info";
        rev = "66b802d05b374cd8f388dc6ad1e7ae4f08cb3300";
        hash = "sha256-6xmWBrPHghjok43eIDGeshpUEQTuwWLXNHg7CnBUt3Q=";
      };
      openvr-src = pkgs.fetchFromGitHub {
        owner = "ValveSoftware"; repo = "openvr";
        rev = "ff87f683f41fe26cc9353dd9d9d7028357fd8e1a";
        hash = "sha256-SdCN1BmYa2XyBi+aIKrk7RQBRG9+NeEpO7RsEmEBRjc=";
      };
      reshade-src = pkgs.fetchFromGitHub {
        owner = "Joshua-Ashton"; repo = "reshade";
        rev = "696b14cd6006ae9ca174e6164450619ace043283";
        hash = "sha256-RRHw7T77LfXNSwzJApz+ugXbizhQZ+sXsnCh9u5wcP8=";
      };
      spirv-headers-src = pkgs.fetchFromGitHub {
        owner = "KhronosGroup"; repo = "SPIRV-Headers";
        rev = "d790ced752b5bfc06b6988baadef6eb2d16bdf96";
        hash = "sha256-OqLxyrTzg1Q2zmQd0YalWtl7vX5lRJFmE2VH7fHC8/8=";
      };

      # Meson wrap sources (not git submodules, fetched by meson at configure time)
      glm-src = pkgs.fetchFromGitHub {
        owner = "g-truc"; repo = "glm";
        rev = "0af55ccecd98d4e5a8d1fad7de25ba429d60e863";
        hash = "sha256-GnGyzNRpzuguc3yYbEFtYLvG+KiCtRAktiN+NvbOICE=";
      };
      stb-src = pkgs.fetchFromGitHub {
        owner = "nothings"; repo = "stb";
        rev = "5736b15f7ea0ffb08dd38af21067c314d6a3aae9";
        hash = "sha256-s2ASdlT3bBNrqvwfhhN6skjbmyEnUgvNOrvhgUSRj98=";
      };
      edid-decode-src = pkgs.fetchgit {
        url = "https://git.linuxtv.org/edid-decode.git";
        rev = "c6b859d7f0251e2433fb81bd3f67bd2011c2036c";
        hash = "sha256-Lv0ikCNKSjSePevZC+LTWG6jOJnn3d9Ar6eEax6lbOk=";
      };

      # Helper: copy a fetched source into a subproject dir
      placeSubproject = dest: src: ''
        rm -rf $sourceRoot/${dest}
        cp -r ${src} $sourceRoot/${dest}
        chmod -R u+w $sourceRoot/${dest}
      '';

      gamescope-kbm = pkgs.stdenv.mkDerivation {
        pname = "gamescope-kbm";
        version = "35b04f1";
        src = gamescope-kbm-main;

        postUnpack = ''
          # Git submodules
          ${placeSubproject "subprojects/wlroots" wlroots-src}
          ${placeSubproject "subprojects/libliftoff" libliftoff-src}
          ${placeSubproject "subprojects/vkroots" vkroots-src}
          ${placeSubproject "subprojects/libdisplay-info" libdisplay-info-src}
          ${placeSubproject "subprojects/openvr" openvr-src}
          ${placeSubproject "src/reshade" reshade-src}
          ${placeSubproject "thirdparty/SPIRV-Headers" spirv-headers-src}

          # Meson wraps (with packagefiles patches applied)
          ${placeSubproject "subprojects/glm" glm-src}
          cp $sourceRoot/subprojects/packagefiles/glm/meson.build $sourceRoot/subprojects/glm/
          ${placeSubproject "subprojects/stb" stb-src}
          cp $sourceRoot/subprojects/packagefiles/stb/meson.build $sourceRoot/subprojects/stb/
          ${placeSubproject "subprojects/edid-decode" edid-decode-src}

          # Fix shebangs for Nix sandbox
          patchShebangs $sourceRoot
        '';

        nativeBuildInputs = with pkgs; [
          meson ninja pkg-config cmake glslang makeBinaryWrapper python3 git
        ];

        buildInputs = with pkgs; [
          libxkbcommon libGL vulkan-headers vulkan-loader libdrm
          xorg.libX11 xorg.libXdamage xorg.libXcomposite xorg.libXrender
          xorg.libXext xorg.libXfixes xorg.libXxf86vm xorg.libXtst
          xorg.libXres xorg.libXmu xorg.libXcursor xorg.libXrandr
          xorg.libXi xorg.libxcb xorg.xcbutilwm xorg.xcbutilimage
          xorg.xcbutilerrors xwayland libinput libei seatd pixman libcap
          libdecor pipewire SDL2 hwdata luajit wayland wayland-protocols
          wayland-scanner openssl openvr libavif lcms2 gbenchmark
        ];

        mesonFlags = [
          (lib.mesonBool "enable_gamescope_wsi_layer" false)
        ];
        mesonInstallFlags = [ "--skip-subprojects" ];

        postInstall = ''
          mv $out/bin/gamescope $out/bin/gamescope-kbm
          patchelf --add-rpath ${lib.makeLibraryPath [
            pkgs.vulkan-loader pkgs.libGL pkgs.wayland pkgs.libxkbcommon
          ]} $out/bin/gamescope-kbm
        '';
      };

      # ---------------------------------------------------------------
      # partydeck – Rust application
      # ---------------------------------------------------------------
      partydeck = pkgs.rustPlatform.buildRustPackage {
        pname = "partydeck";
        version = "0.8.5";
        src = lib.cleanSource self;

        cargoHash = "sha256-wqpGq7glWFxizMdM725DzCEnmoE8NjYaTWWIpuWkUJo=";

        nativeBuildInputs = with pkgs; [ pkg-config makeBinaryWrapper ];
        buildInputs = with pkgs; [
          libxkbcommon libGL xorg.libX11 xorg.libXcursor xorg.libXrandr
          xorg.libXi xorg.libxcb wayland openssl
        ];

        postInstall = ''
          mkdir -p $out/share/partydeck/goldberg
          cp res/splitscreen_kwin.js $out/share/partydeck/
          cp res/splitscreen_kwin_vertical.js $out/share/partydeck/
          cp res/GamingModeLauncher.sh $out/share/partydeck/

          ln -s ${goldberg-emu}/share/goldberg/linux32 $out/share/partydeck/goldberg/linux32
          ln -s ${goldberg-emu}/share/goldberg/linux64 $out/share/partydeck/goldberg/linux64
          ln -s ${goldberg-emu}/share/goldberg/win     $out/share/partydeck/goldberg/win

            # Symlink so exe_dir/res/ resolves to share/partydeck/
            ln -s $out/share/partydeck $out/bin/res

          wrapProgram $out/bin/partydeck \
            --prefix PATH : ${lib.makeBinPath [ gamescope-kbm pkgs.umu-launcher ]} \
            --prefix LD_LIBRARY_PATH : ${lib.makeLibraryPath [
              pkgs.libGL pkgs.vulkan-loader pkgs.wayland pkgs.libxkbcommon
              pkgs.xorg.libX11 pkgs.xorg.libXcursor pkgs.xorg.libXrandr pkgs.xorg.libXi
            ]}
        '';

        meta = {
          description = "Split-screen game launcher for Linux";
          homepage = "https://github.com/cseelhoff/partydeck";
          mainProgram = "partydeck";
          platforms = [ "x86_64-linux" ];
        };
      };

    in {
      packages.${system} = {
        inherit partydeck gamescope-kbm goldberg-emu;
        default = partydeck;
      };

      devShells.${system}.default = pkgs.mkShell {
        hardeningDisable = [ "fortify" ];
        nativeBuildInputs = with pkgs; [
          rustc cargo pkg-config cmake
          meson ninja glslang python3
        ];
        buildInputs = gamescope-kbm.buildInputs ++ (with pkgs; [
          libxkbcommon libGL
          xorg.libX11 xorg.libXcursor xorg.libXrandr xorg.libXi xorg.libxcb
          wayland openssl
        ]);
        LD_LIBRARY_PATH = lib.makeLibraryPath [
          pkgs.libGL pkgs.vulkan-loader pkgs.wayland pkgs.libxkbcommon
          pkgs.xorg.libX11 pkgs.xorg.libXcursor pkgs.xorg.libXrandr pkgs.xorg.libXi
        ];
        shellHook = ''
          echo ""
          echo "PartyDeck dev shell (for hacking on the source)"
          echo ""
          echo "  nix build   — build the full package (recommended)"
          echo "  nix run     — build and launch PartyDeck"
          echo ""
          echo "  cargo build — compile just the Rust code (iterative dev)"
          echo "  cargo run   — compile and run (needs gamescope-kbm in PATH)"
        '';
      };
    };
}
