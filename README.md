> [!IMPORTANT]
> ### NixOS Fork
> This is a NixOS-compatible fork of [PartyDeck](https://github.com/partydeck).
> It includes a Nix flake that builds PartyDeck and all its dependencies (gamescope-kbm, Goldberg Steam Emu) from source — no manual setup required.
>
> For the upstream project, see: https://github.com/partydeck

<img src=".github/assets/icon.png" align="left" width="100" height="100">

### `PartyDeck`

A split-screen game launcher for Linux/SteamOS

---

<p align="center">
    <img src=".github/assets/launcher.png" width="49%" />
    <img src=".github/assets/gameplay1.png" width="49%" />
</p>

## NixOS Installation

### Flake-based NixOS config (recommended)

Add this fork as a flake input and install the package:

```nix
# flake.nix
{
  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixos-25.11";
    partydeck = {
      url = "github:cseelhoff/partydeck";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = { nixpkgs, partydeck, ... }: {
    nixosConfigurations.myhost = nixpkgs.lib.nixosSystem {
      modules = [ ./configuration.nix ];
      specialArgs = { inherit partydeck; };
    };
  };
}
```

Then in your NixOS module:

```nix
# configuration.nix (or a gaming module)
{ pkgs, partydeck, ... }:
{
  environment.systemPackages = [
    partydeck.packages.x86_64-linux.default
  ];

  # Required dependencies
  services.desktopManager.plasma6.enable = true;  # KWin tiling script
  networking.firewall.allowedUDPPorts = [ 47584 ]; # Goldberg LAN multiplayer
  networking.firewall.allowedTCPPorts = [ 47584 ];
}
```

Run `sudo nixos-rebuild switch` and `partydeck` will be on your PATH.

### Try without installing

```sh
nix run github:cseelhoff/partydeck
```

### What the flake provides

| Package | Description |
|---------|-------------|
| `partydeck` (default) | The launcher, wrapped with all runtime deps |
| `gamescope-kbm` | Gamescope fork with keyboard/mouse support |
| `goldberg-emu` | Goldberg Steam Emu binaries for LAN multiplayer |

All three are built automatically — `gamescope-kbm` and `goldberg-emu` are bundled into the `partydeck` package via `PATH` and symlinks.

### Requirements

- **NixOS 25.11** (or compatible nixpkgs)
- **KDE Plasma 6** — required for the KWin splitscreen tiling script
- **Steam** — with Proton-GE for Windows game support
- **Game controllers** — most work without extra setup

## Features

- Runs multiple instances of a game at a time and automatically tiles up to 4 game windows per monitor
- Supports native Linux games as well as Windows games through Proton-GE/UMU Launcher
- Handler system that tells the launcher how to handle game files, meaning very little manual setup is required
- Steam multiplayer API is emulated, allowing for multiple instances of Steam games
- Works with most game controllers without any additional setup, drivers, or third-party software
- Now works with multiple keyboards and mice!
- Now supports launching the instances across multiple monitors when using the SDL gamescope backend!
- Uses sandboxing software to mask out controllers so that each game instance only detects the controller assigned to it, preventing input interference
- Profile support allows each player to have their own persistent save data, settings, and stats for games
- Works out of the box on SteamOS

## Non-NixOS Installation

For SteamOS and other desktop Linux distros, see the [upstream project](https://github.com/partydeck) for installation instructions.

## Building from source (dev shell)

```sh
git clone --recurse-submodules https://github.com/cseelhoff/partydeck.git
cd partydeck
nix develop   # enters a shell with all build deps
sh build.sh   # cargo build + assemble
cd build && ./partydeck
```

## How it Works

PartyDeck uses a few software layers to provide a console-like split-screen gaming experience:

- **KWin Session:** Displays all running game instances and runs a script to automatically resize and reposition each Gamescope window.
- **Gamescope:** Contains each instance of the game in its own window. Also receives controller input even when the window is not currently active, meaning multiple instances can all receive input simultaneously.
- **Bubblewrap:** Uses bindings to mask out evdev input files from the instances, so each instance only receives input from one specific controller. Also uses directory binding to give each player their own save data and settings.
- **Runtime (Steam Runtime/Proton):** Runs native Linux games through a Steam Runtime for better compatibility. Windows games are launched through UMU Launcher.
- **Goldberg Steam Emu:** On games that use the Steam API for multiplayer, Goldberg allows game instances to connect to each other and other devices on the same LAN.

## Known Issues

- AppImages and Flatpaks are not supported yet for native Linux games
- Controller navigation in the launcher is basic
- Games using Goldberg might have trouble discovering LAN games from other devices — try adding a firewall rule for port 47584

## Credits

- [@wunnr](https://github.com/wunnr) for starting PartyDeck
- [@Blahkaey](https://github.com/blahkaey) for helping maintain PartyDeck and the community
- [@davidawesome02-backup](https://github.com/davidawesome02-backup) for the [Gamescope keyboard/mouse fork](https://github.com/davidawesome02-backup/gamescope), and Valve for Gamescope
- [@blckink](https://github.com/blckink) for contributions
- MrGoldberg & Detanup01 for [Goldberg Steam Emu](https://github.com/Detanup01/gbe_fork/)
- GloriousEggroll and the rest of the contributors for [UMU Launcher](https://github.com/Open-Wine-Components/umu-launcher)
- Inspired by [Tau5's Coop-on-Linux](https://github.com/Tau5/Co-op-on-Linux) and [Syntrait's Splinux](https://github.com/Syntrait/splinux)
- Talos91 and the rest of the Splitscreen.me team for [Nucleus Coop](https://github.com/SplitScreen-Me/splitscreenme-nucleus)

## Disclaimer

This software has been created purely for the purposes of academic research. It is not intended to be used to attack other systems. Project maintainers are not responsible or liable for misuse of the software. Use responsibly.
