use std::os::unix::process::CommandExt;
use std::path::{Path, PathBuf};
use std::process::Command;

use crate::app::{PartyConfig, PadFilterType};
use crate::handler::*;
use crate::input::*;
use crate::instance::*;
use crate::paths::*;
use crate::profiles::{create_profile, create_profile_gamesave};
use crate::util::*;

/// Legacy /dev/input/jsN nodes belonging to the same physical device as an evdev node.
fn js_siblings(evdev_path: &str) -> Vec<String> {
    let Some(name) = Path::new(evdev_path).file_name().and_then(|s| s.to_str()) else {
        return Vec::new();
    };
    std::fs::read_dir(format!("/sys/class/input/{name}/device"))
        .into_iter()
        .flatten()
        .flatten()
        .filter_map(|e| e.file_name().to_str().map(str::to_string))
        .filter(|n| n.starts_with("js"))
        .map(|n| format!("/dev/input/{n}"))
        .collect()
}

/// First bwrap in PATH that isn't inside the AppImage, if present.
fn host_bwrap() -> Option<PathBuf> {
    // $APPDIR from within AppImage, None otherwise.
    let appdir: Option<PathBuf> = std::env::var_os("APPDIR").map(PathBuf::from);
    std::env::split_paths(&std::env::var_os("PATH")?)
        .filter(|d| appdir.as_ref().is_none_or(|a| !d.starts_with(a)))
        .map(|d| d.join("bwrap"))
        .find(|p| p.is_file())
}

pub fn setup_profiles(
    h: &Handler,
    instances: &Vec<Instance>,
) -> Result<(), Box<dyn std::error::Error>> {
    println!("\n[partydeck] Instances:");
    for instance in instances {
        if instance.profname.starts_with(".") {
            create_profile(&instance.profname)?;
        }
        if h.is_saved_handler() {
            create_profile_gamesave(&instance.profname, h)?;
        }
        println!(
            "[partydeck] - Profile: {}, Monitor: {}, Resolution: {}x{}",
            instance.profname, instance.monitor, instance.width, instance.height
        );
    }

    Ok(())
}

pub fn launch_game(
    h: &Handler,
    input_devices: &[DeviceInfo],
    instances: &Vec<Instance>,
    cfg: &PartyConfig,
) -> Result<(), Box<dyn std::error::Error>> {
    let new_cmds = launch_cmds(h, input_devices, instances, cfg)?;
    print_launch_cmds(&new_cmds);

    if cfg.enable_kwin_script {
        let script = match cfg.vertical_two_player {
            true => "splitscreen_kwin_vertical.js",
            false => "splitscreen_kwin.js",
        };

        kwin_dbus_start_script(PATH_RES.join(script)).map_err(|e| format!("Failed to start KWin script: {}", e))?;
    }

    let sleep_time = match h.pause_between_starts {
        Some(f) => f,
        None => 0.5,
    };

    // If the handler requests AAAA filtering and no DNS shim is already
    // listening on 127.0.0.1:53, start our own forwarder. The preferred setup
    // is the privileged guard (res/dns_shim_guard.sh) which owns both the shim
    // and the egress UDP:53 redirect and auto-reverts on exit; if it's already
    // running we must NOT spawn a second shim (port conflict). A shim alone is
    // ineffective without the redirect because Wine's winhttp queries the real
    // nameserver directly, ignoring the sandbox resolv.conf — so if nothing is
    // listening we just warn rather than rely on the bound resolv.conf.
    let mut dns_shim = if h.dns_filter_aaaa.is_empty() {
        None
    } else if dns_shim_already_listening() {
        println!("[partydeck] DNS shim already listening on :53 (guard); not starting another.");
        None
    } else {
        match spawn_dns_filter(&h.dns_filter_aaaa) {
            Ok(child) => Some(child),
            Err(e) => {
                eprintln!("[partydeck] WARNING: could not start AAAA DNS filter: {e}");
                eprintln!("[partydeck] Games needing IPv4 fallback may fail to connect.");
                None
            }
        }
    };
    if h.dns_filter_aaaa.is_empty() == false && dns_shim.is_none() && !dns_shim_already_listening() {
        eprintln!(
            "[partydeck] NOTE: a DNS shim alone won't help unless egress UDP:53 is redirected to it."
        );
        eprintln!(
            "[partydeck] For backends with a dead IPv6 record, run (in a separate terminal):"
        );
        eprintln!(
            "[partydeck]   sudo {}",
            PATH_RES.join("dns_shim_guard.sh").to_string_lossy()
        );
    }

    let mut handles = Vec::new();

    // Started after launch_cmds validated the game files, so a bad handler never
    // leaves a server behind; dropped (killed) on every exit path below.
    let companion = start_companion(h, &PATH_PARTY.join("companion.log"))?;

    let mut i = 0;
    for mut cmd in new_cmds {
        // Ask the kernel to deliver SIGTERM to this child when partydeck
        // exits, so gamescope (and its bwrap/wine subtree) shuts down
        // promptly. Without this, children survive partydeck's exit
        // until something else (systemd cgroup, user) reaps them.
        unsafe {
            cmd.pre_exec(|| {
                libc::prctl(libc::PR_SET_PDEATHSIG, libc::SIGTERM as libc::c_ulong);
                Ok(())
            });
        }

        let handle = cmd.spawn().map_err(|e| {
            format!("Failed to start '{}': {}", cmd.get_program().to_string_lossy(), e)
        })?;
        handles.push(handle);

        if i < instances.len() - 1 {
            std::thread::sleep(std::time::Duration::from_secs_f64(sleep_time));
        }
        i += 1;
    }

    // The cold client loader path can leave gamescope-kbm hung after the game
    // closes: gamescope logs "Primary child shut down!" but does not exit (it
    // even ignores SIGTERM), so handle.wait() below blocks forever, the
    // after-close prefix scrub never runs, and the compositor leaks. Start a
    // guarded watchdog that SIGKILLs a gamescope only once its game process
    // tree has been seen at least once and then absent for a sustained grace
    // period. Restricted to the drm_loader path (where the hang occurs) so it
    // can never misfire on the normal goldberg path.
    let watchdog = if h.win() && h.use_goldberg && h.use_drm_loader {
        let gs_pids: Vec<u32> = handles.iter().map(|hd| hd.id()).collect();
        Some(spawn_gamescope_watchdog(gs_pids))
    } else {
        None
    };

    for mut handle in handles {
        handle.wait()?;
    }

    if let Some(w) = watchdog {
        let _ = w.join();
    }

    drop(companion);

    if let Some(mut child) = dns_shim.take() {
        let _ = child.kill();
        let _ = child.wait();
    }

    // The gbe cold client loader rewrites this prefix's Steam registry keys to
    // point at its throwaway tmp/ccloader-{i} staging dir (wiped next launch).
    // Once the game exits, scrub those keys back to the canonical
    // C:\Program Files (x86)\Steam locations so a later non-loader goldberg game
    // sharing the prefix (e.g. V Rising) doesn't read a dead steamclient path
    // and fail with "Steam not running". Run after handle.wait() (game/proton
    // torn down) and re-run once after a short settle to win the wineserver
    // registry-flush race.
    if h.win() && h.use_goldberg && h.use_drm_loader {
        let pfx_ids: Vec<String> = if cfg.proton_separate_pfxs {
            (0..instances.len()).map(|i| (i + 1).to_string()).collect()
        } else {
            vec!["1".to_string()]
        };
        for id in &pfx_ids {
            let pfx = PATH_PARTY.join("prefixes").join(id);
            cleanup_drm_loader_prefix(&pfx);
        }
        std::thread::sleep(std::time::Duration::from_millis(1500));
        for id in &pfx_ids {
            let pfx = PATH_PARTY.join("prefixes").join(id);
            cleanup_drm_loader_prefix(&pfx);
        }
    }

    Ok(())
}

/// Kills the handler's companion process when dropped, so every exit path of
/// launch_game (including `?` errors) stops it.
struct Companion(Option<std::process::Child>);

impl Drop for Companion {
    fn drop(&mut self) {
        if let Some(child) = &mut self.0 {
            let _ = child.kill();
            let _ = child.wait();
        }
    }
}

fn local_port_open(port: u16) -> bool {
    let address = std::net::SocketAddr::from(([127, 0, 0, 1], port));
    std::net::TcpStream::connect_timeout(&address, std::time::Duration::from_millis(200)).is_ok()
}

/// Start the handler's companion and, when `companion_port` is set, wait until it
/// accepts connections. A port that is already open means the user started the
/// companion themselves, so nothing is spawned.
fn start_companion(h: &Handler, log_path: &Path) -> Result<Companion, Box<dyn std::error::Error>> {
    const READY_TIMEOUT: std::time::Duration = std::time::Duration::from_secs(10);
    let mut words = h.companion.split_whitespace();
    let Some(program) = words.next() else {
        return Ok(Companion(None));
    };
    if h.companion_port != 0 && local_port_open(h.companion_port) {
        println!(
            "[partydeck] port {} already open; not starting companion '{program}'",
            h.companion_port
        );
        return Ok(Companion(None));
    }

    let log = std::fs::File::create(log_path)?;
    let mut command = Command::new(program);
    command.args(words).stdout(log.try_clone()?).stderr(log);
    // Like the games: if PartyDeck dies without running Drop, the helper still stops.
    unsafe {
        command.pre_exec(|| {
            libc::prctl(libc::PR_SET_PDEATHSIG, libc::SIGTERM as libc::c_ulong);
            Ok(())
        });
    }
    let child = command
        .spawn()
        .map_err(|e| format!("Failed to start companion '{program}': {e}"))?;
    let mut companion = Companion(Some(child));
    println!("[partydeck] Started companion '{}' (log {})", h.companion, log_path.display());
    if h.companion_port == 0 {
        return Ok(companion);
    }

    let started = std::time::Instant::now();
    loop {
        if local_port_open(h.companion_port) {
            return Ok(companion);
        }
        if let Some(status) = companion.0.as_mut().unwrap().try_wait()? {
            return Err(format!("companion '{program}' exited early ({status}); see {}", log_path.display()).into());
        }
        if started.elapsed() > READY_TIMEOUT {
            return Err(format!(
                "companion '{program}' did not open port {} within {}s; see {}",
                h.companion_port,
                READY_TIMEOUT.as_secs(),
                log_path.display()
            )
            .into());
        }
        std::thread::sleep(std::time::Duration::from_millis(50));
    }
}

/// Start the bundled AAAA-stripping DNS forwarder on 127.0.0.1:53, forwarding to
/// the host's real upstream nameserver and suppressing AAAA only for `domains`.
/// Uses a TCP upstream so it is safe behind an egress UDP:53 redirect (the
/// redirect would otherwise loop our own upstream UDP query back to us).
fn spawn_dns_filter(domains: &[String]) -> std::io::Result<std::process::Child> {
    let upstream = host_upstream_nameserver().unwrap_or_else(|| "1.1.1.1".to_string());
    let script = PATH_RES.join("dns_aaaa_filter.py");
    let mut cmd = Command::new("python3");
    cmd.arg(&script)
        .args(["--listen", "127.0.0.1:53"])
        .args(["--upstream", &format!("{upstream}:53")])
        .arg("--tcp-upstream");
    for d in domains {
        cmd.args(["--domain", d]);
    }
    println!(
        "[partydeck] Starting AAAA DNS filter on 127.0.0.1:53 (upstream {upstream}) for {domains:?}"
    );
    cmd.spawn()
}

/// True if something is already bound to UDP 127.0.0.1:53 (e.g. the privileged
/// guard's shim), in which case partydeck must not start a second one.
fn dns_shim_already_listening() -> bool {
    std::fs::read_to_string("/proc/net/udp")
        .map(|s| {
            // /proc/net/udp local_address column is hex "IP:PORT"; loopback
            // 127.0.0.1:53 == "0100007F:0035". Also match wildcard 0.0.0.0:53.
            s.lines()
                .any(|l| l.contains(" 0100007F:0035 ") || l.contains(" 00000000:0035 "))
        })
        .unwrap_or(false)
}

/// Read the first `nameserver` entry from the host's /etc/resolv.conf so the
/// forwarder relays real queries upstream. Skips our own 127.0.0.1 entry.
fn host_upstream_nameserver() -> Option<String> {
    let contents = std::fs::read_to_string("/etc/resolv.conf").ok()?;
    for line in contents.lines() {
        let line = line.trim();
        if let Some(rest) = line.strip_prefix("nameserver ") {
            let addr = rest.trim();
            if addr != "127.0.0.1" && !addr.is_empty() {
                return Some(addr.to_string());
            }
        }
    }
    None
}


pub fn launch_cmds(
    h: &Handler,
    input_devices: &[DeviceInfo],
    instances: &Vec<Instance>,
    cfg: &PartyConfig,
) -> Result<Vec<std::process::Command>, Box<dyn std::error::Error>> {
    let win = h.win();
    let exec = Path::new(&h.exec);
    let runtime = h.runtime.as_str();
    let gamescope = match cfg.kbm_support {
        true => BIN_GSC_KBM.as_path(),
        false => Path::new("gamescope"),
    };

    if cfg.kbm_support && !gamescope.exists() {
        return Err("gamescope-kbm is missing. Please reinstall partydeck or disable KBM support.".into());
    }

    if !cfg.kbm_support && pathsearch::find_executable_in_path("gamescope").is_none() {
        return Err("gamescope not found in PATH. Please install gamescope through your distro's package manager.".into());
    }

    if (runtime == "scout" && !PATH_STEAM.join("bin32/steam-runtime/run.sh").exists())
        || (runtime == "soldier"
            && !PATH_STEAM
                .join("steam/steamapps/common/SteamLinuxRuntime_soldier")
                .exists())
        || (runtime == "sniper"
            && !PATH_STEAM.join("steam/steamapps/common/SteamLinuxRuntime_sniper").exists()
            && !PATH_STEAM.join("steam/steamapps/common/SteamLinuxRuntime_sniper-arm64").exists())
        || (runtime == "steamrt4"
            && !PATH_STEAM.join("steam/steamapps/common/SteamLinuxRuntime_4").exists())
    {
        return Err(format!("Steam Runtime {runtime} not found! Runtime must be installed on the same drive that the Steam client is installed on.").into());
    }

    let mut cmds: Vec<Command> = (0..instances.len())
        .map(|_| Command::new(gamescope))
        .collect();

    for (i, instance) in instances.iter().enumerate() {
        let gamedir = if h.is_saved_handler() && !cfg.disable_mount_gamedirs && cfg.profile_unique_dirs {
            PATH_PARTY.join("tmp").join(format!("game-{}", i))
        } else {
            PathBuf::from(h.get_game_rootpath()?)
        };

        if !gamedir.join(exec).exists() {
            return Err(format!("Executable not found: {}", gamedir.join(exec).display()).into());
        }

        let path_exec = gamedir.join(exec);
        let cwd = path_exec.parent().ok_or_else(|| "couldn't get parent")?;

        // Resolve the handler's per-instance game arguments up front so they can
        // be appended to the command directly or, for the cold client loader,
        // written into ColdClientLoader.ini's ExeCommandLine (the loader does not
        // forward CLI args to the game and would treat them as its target exe).
        let vars = [
            ("$PROFILE", instance.profname.clone()),
            ("$WIDTH", instance.width.to_string()),
            ("$HEIGHT", instance.height.to_string()),
            ("$RESOLUTION", format!("{}x{}", instance.width, instance.height)),
            ("$INSTANCECOUNT", instances.len().to_string()),
            ("$INSTANCENUM", i.to_string()),
            ("$GAMEDIR", gamedir.os_fmt(win)),
            ("$HANDLERDIR", h.path_handler.os_fmt(win)),
        ];

        // Substitute variables anywhere in an arg.
        // Non-variable text is sanitized, including $s that aren't part of known variable names
        let game_args: Vec<String> = h
            .args
            .split_whitespace()
            .map(|arg| {
                let mut processed_arg = String::new();
                let mut rest = arg;
                // Scan for $ marker, then try to replace with a known variable
                while let Some(pos) = rest.find('$') {
                    processed_arg.push_str(&rest[..pos].to_string().sanitize_path());
                    rest = &rest[pos..];
                    match vars.iter().find(|(name, _)| rest.starts_with(name)) {
                        Some((name, val)) => {
                            processed_arg.push_str(val);
                            rest = &rest[name.len()..];
                        }
                        None => rest = &rest[1..],
                    }
                }
                processed_arg.push_str(&rest.to_string().sanitize_path());
                processed_arg
            })
            .collect();

        // SteamStub-DRM games are launched via the gbe_fork cold client loader
        // (injects the Stub DRM patcher + force-injects steamclient) instead of
        // running the exe directly.
        let drm_loader = if win && h.use_goldberg && h.use_drm_loader {
            Some(stage_drm_loader(i, &gamedir, &path_exec, &game_args, h)?)
        } else {
            None
        };

        let path_prof = PATH_PARTY.join("profiles").join(&instance.profname);
        let path_pfx = PATH_PARTY
            .join("prefixes")
            .join(match cfg.proton_separate_pfxs {
                true => (i + 1).to_string(),
                false => "1".to_string(),
            });

        // Self-heal the prefix BEFORE launch: a previous cold-loader run may have
        // left this prefix's Steam registry pointing at a now-deleted
        // tmp/ccloader dir (the after-close scrub can be skipped if gamescope's
        // teardown hangs and is force-killed). Scrubbing here guarantees any
        // goldberg game starts from a clean steamclient path regardless of how
        // the previous session ended. Idempotent: only rewrites stale ccloader
        // lines, no-op on an already-clean prefix.
        if win && h.use_goldberg {
            cleanup_drm_loader_prefix(&path_pfx);
        }

        let cmd = &mut cmds[i];

        cmd.current_dir(match &drm_loader {
            Some(l) => l.dir.as_path(),
            None => cwd,
        });

        cmd.env("SDL_VIDEODRIVER", "x11");
        cmd.env("SDL_JOYSTICK_HIDAPI", "0");
        cmd.env("ENABLE_GAMESCOPE_WSI", "0");
        if h.sdl2_override != SDL2Override::No {
            let path_sdl = match h.sdl2_override {
                SDL2Override::Srt => {
                    PATH_STEAM.join("bin32/steam-runtime/usr/lib/i386-linux-gnu/libSDL2-2.0.so.0")
                }
                SDL2Override::Sys => PathBuf::from("/usr/lib/libSDL2.so"),
                _ => PathBuf::new(),
            };
            cmd.env("SDL_DYNAMIC_API", path_sdl);
        }
        if win {
            let protonpath = match cfg.proton_version.is_empty() {
                true => "GE-Proton",
                false => &cfg.proton_version,
            };

            cmd.env("WINEPREFIX", &path_pfx);
            cmd.env("PROTON_VERB", "run");
            cmd.env("PROTONPATH", protonpath);
            cmd.env("PROTON_ENABLE_HIDRAW", "1");
            if h.ps_xinput {
                cmd.env("PROTON_SONY_HIDRAW_XINPUT", "1");
            }
            if cfg.proton_wow64 {
                cmd.env("PROTON_USE_WOW64", "1");
            }
        }
        if cfg.pad_filter_type != PadFilterType::NoSteamInput {
            cmd.env("SDL_GAMECONTROLLER_ALLOW_STEAM_VIRTUAL_GAMEPAD", "1");
        }
        if cfg.pad_filter_type == PadFilterType::OnlySteamInput {
            cmd.env("SDL_GAMECONTROLLER_IGNORE_DEVICES", SDL_GAMECONTROLLER_IGNORE_DEVICES);
        }
        if !h.env.is_empty() {
            for env_var in h.env.split_whitespace() {
                if let Some((key, value)) = env_var.split_once('=') {
                    if value.contains("$INSTANCENUM") {
                        cmd.env(key, value.replace("$INSTANCENUM", &i.to_string()));
                    } else {
                        cmd.env(key, value);
                    }
                }
            }
        }

        // Gamescope args
        if h.use_mangohud {
            cmd.arg("--mangoapp");
        }
        cmd.args([
            "-W",
            &instance.width.to_string(),
            "-H",
            &instance.height.to_string(),
        ]);
        if cfg.gamescope_force_grab_cursor {
            cmd.arg("--force-grab-cursor");
        }
        if cfg.gamescope_sdl_backend {
            cmd.arg("--backend=sdl");
            cmd.arg(format!("--display-index={}", instance.monitor));
        }
        if cfg.kbm_support {
            let mut instance_has_keyboard = false;
            let mut instance_has_mouse = false;
            let mut kbms = String::new();

            for &d in &instance.devices {
                let dev = &input_devices[d];
                if dev.device_type == DeviceType::Keyboard {
                    instance_has_keyboard = true;
                } else if dev.device_type == DeviceType::Mouse {
                    instance_has_mouse = true;
                }
                if dev.device_type == DeviceType::Keyboard || dev.device_type == DeviceType::Mouse {
                    kbms.push_str(&format!("{},", &dev.path));
                }
            }

            if instance_has_keyboard {
                cmd.arg("--backend-disable-keyboard");
            }
            if instance_has_mouse {
                cmd.arg("--backend-disable-mouse");
            }
            if !kbms.is_empty() {
                cmd.arg(format!("--libinput-hold-dev={}", kbms));
                cmd.arg("--grab");
            }
        }
        cmd.arg("--");

        // The AppImage's bundled bwrap is a wrapper that un-isolates /tmp by re-binding the host /tmp
        // so we need to explicitly use the host's bwrap when there is one.
        let is_appimage = std::env::var("APPIMAGE").is_ok();
        let (bwrap, appdir) = if !is_appimage {
            (PathBuf::from("bwrap"), None)
        } else if let Some(host) = host_bwrap() {
            (host, std::env::var_os("APPDIR"))
        } else {
            println!("[partydeck] WARNING: no bwrap found in host PATH; instances will share /tmp");
            (PathBuf::from("bwrap"), None)
        };

        // Bwrap args
        cmd.arg(&bwrap);
        // Cold-loader path: omit --die-with-parent. The ColdClientLoader runs
        // with [Persistence] Mode=0, so steamclient_loader exits immediately
        // after spawning the game; Proton then keeps the container alive and
        // waits on the game's wineserver. Empirically, keeping --die-with-parent
        // here tears the container down too early and the game dies with
        // "Primary child shut down" during startup, so it is omitted only for
        // the cold loader.
        if drm_loader.is_none() {
            cmd.arg("--die-with-parent");
        }
        cmd.args(["--dev-bind", "/", "/"]);
        cmd.args(["--tmpfs", "/tmp"]);

        // Bind AppImage mount from /tmp to keep it visible for bundled binaries like umu-run
        if let Some(appdir) = &appdir {
            cmd.arg("--bind").args([appdir, appdir]);
        }

        // Pin hostnames to specific IPs inside the sandbox by binding a custom
        // /etc/hosts. Needed for games whose backend has a dead IPv6 (AAAA)
        // record: Wine's winhttp resolves the AAAA, tries IPv6, and won't fall
        // back to the working IPv4, failing with WinHttp 12029. Writing the
        // host's /etc/hosts plus the handler's aliases (IPv4-only) forces IPv4.
        if !h.host_aliases.is_empty() {
            let hosts_path = PATH_PARTY.join(format!("tmp/hosts-{i}"));
            let mut hosts_content =
                std::fs::read_to_string("/etc/hosts").unwrap_or_default();
            if !hosts_content.ends_with('\n') {
                hosts_content.push('\n');
            }
            hosts_content.push_str("# partydeck host_aliases\n");
            for alias in &h.host_aliases {
                hosts_content.push_str(alias);
                hosts_content.push('\n');
            }
            std::fs::write(&hosts_path, hosts_content)?;
            // /etc/hosts is often a symlink (e.g. NixOS: /etc/hosts ->
            // /etc/static/hosts -> /nix/store/...). bwrap can't bind-mount over
            // a symlink target, so resolve to the canonical real path. The bind
            // is namespaced and does not affect the host's (read-only) file.
            let hosts_target = std::fs::canonicalize("/etc/hosts")
                .map(|p| p.to_string_lossy().into_owned())
                .unwrap_or_else(|_| "/etc/hosts".to_string());
            cmd.args([
                "--bind",
                &hosts_path.to_string_lossy(),
                &hosts_target,
            ]);
            // On systems running a name-service cache daemon (NixOS enables
            // nscd/nsncd by default), glibc proxies hostname lookups to that
            // daemon over /run/nscd/socket. The daemon runs on the host, OUTSIDE
            // this namespace, so it reads the host's real /etc/hosts and our
            // bind above is silently ignored. Mask the socket with a tmpfs so
            // glibc's `files` module falls back to reading /etc/hosts directly
            // and our host_aliases actually take effect.
            if std::path::Path::new("/run/nscd").exists() {
                cmd.args(["--tmpfs", "/run/nscd"]);
            }
        }

        // Force IPv4 for backends with a dead AAAA record by pointing the
        // sandbox's resolv.conf at our local AAAA-stripping forwarder (spawned
        // in launch_game on 127.0.0.1:53). Wine's winhttp resolves via
        // res_query reading resolv.conf, so this reaches it where /etc/hosts
        // (host_aliases) cannot. The forwarder strips AAAA only for the
        // handler's dns_filter_aaaa domains and passes everything else through.
        if !h.dns_filter_aaaa.is_empty() {
            let resolv_path = PATH_PARTY.join(format!("tmp/resolv-{i}.conf"));
            std::fs::write(
                &resolv_path,
                "# partydeck dns_filter_aaaa\nnameserver 127.0.0.1\noptions edns0\n",
            )?;
            let resolv_target = std::fs::canonicalize("/etc/resolv.conf")
                .map(|p| p.to_string_lossy().into_owned())
                .unwrap_or_else(|_| "/etc/resolv.conf".to_string());
            cmd.args([
                "--bind",
                &resolv_path.to_string_lossy(),
                &resolv_target,
            ]);
        }

        // Only expose this instance to the input devices specifically associated with it
        cmd.args(["--tmpfs", "/dev/input"]);
        for (d, dev) in input_devices.iter().enumerate() {
            if !dev.enabled
                || (!instance.devices.contains(&d) && dev.device_type == DeviceType::Gamepad)
            {
                // hidraw is not under /dev/input, so it still has to be masked rather than omitted.
                for hp in &dev.hidraw_paths {
                    cmd.args(["--bind", "/dev/null", hp]);
                }
                continue;
            }
            if Path::new(&dev.path).exists() {
                cmd.args(["--dev-bind", &dev.path, &dev.path]);
            }
            // Also expose the device's js sibling for games that use the legacy Joystick API
            for js in js_siblings(&dev.path) {
                cmd.args(["--dev-bind", &js, &js]);
            }
        }

        if cfg.profile_unique_dirs {
            if win {
                let path_pfx_user = path_pfx.join("drive_c/users/steamuser");
                cmd.arg("--bind")
                    .args([&path_prof.join("windata"), &path_pfx_user]);
            } else {
                let path_prof_home = path_prof.join("home");
                cmd.env("HOME", &path_prof_home);
                // Also bind the Steam directory as the Steam runtimes look for HOME/.steam
                if !runtime.is_empty() || h.steam_appid.is_some() {
                    cmd.args([
                        "--bind",
                        &PATH_STEAM.to_string_lossy(),
                        &path_prof_home.join(".steam").to_string_lossy(),
                    ]);
                }
            }
        }

        for subpath in &h.game_null_paths {
            let game_subpath = gamedir.join(subpath);
            if game_subpath.is_file() {
                cmd.args(["--bind", "/dev/null", &game_subpath.to_string_lossy()]);
            } else if game_subpath.is_dir() {
                cmd.args([
                    "--bind",
                    &PATH_PARTY.join("tmp/null").to_string_lossy(),
                    &game_subpath.to_string_lossy(),
                ]);
            }
        }

        if is_appimage {
            // Because we are faking temp directory, this makes the system use the real vulkan directory for games
            // Used here because the env var is set durring bwrap and gamescope process starting so env cant be cleared at this stage.
            cmd.args(["--unsetenv","VK_DRIVER_FILES"]); 
        }

        if h.use_goldberg {
            cmd.env("GseAppPath", PATH_PARTY.join("goldberg_data"));
            cmd.env("GseSavePath", path_prof.join("steam"));
            cmd.env("SteamAppUser", instance.profname.clone());
            cmd.env("SteamUser", instance.profname.clone());
            cmd.env("SteamClientLaunch", "1");
            cmd.env("SteamEnv", "1");
            if let Some(appid) = h.steam_appid {
                cmd.env("SteamAppId", &appid.to_string());
                cmd.env("SteamGameId", &appid.to_string());
                cmd.env("SteamOverlayGameId", &appid.to_string());
            }

            // The cold client loader provides its own steamclient + emu config,
            // so point GseAppPath at it and let UMU's Proton hand off steamclient
            // loading to the injected dll instead of lsteamclient.
            if let Some(l) = &drm_loader {
                cmd.env("GseAppPath", &l.dir);
                cmd.env("PROTON_DISABLE_LSTEAMCLIENT", "1");
            }

            let sdk32_link = std::fs::read_link(PATH_STEAM.join("sdk32")).map_err(|e| format!("Failed to read sdk32 link: {}", e))?;
            let sdk64_link = std::fs::read_link(PATH_STEAM.join("sdk64")).map_err(|e| format!("Failed to read sdk64 link: {}", e))?;

            cmd.arg("--bind").args([
                PATH_RES.join("goldberg/linux32"),
                sdk32_link,
            ]);

            cmd.arg("--bind").args([
                PATH_RES.join("goldberg/linux64"),
                sdk64_link,
            ]);

            if win {
                cmd.env("UMU_USE_STEAM", "1");
            }
            // When using the cold client loader, it force-injects steamclient
            // from its own directory, so we don't bind goldberg/win over the
            // prefix's Steam dir.
            if win && drm_loader.is_none() {
                cmd.arg("--bind").args([
                    PATH_RES.join("goldberg/win"),
                    path_pfx.join("drive_c/Program Files (x86)/Steam"),
                ]);
            }
        }

        // Runtime
        if win {
            cmd.arg(&*BIN_UMU_RUN);
        } else {
            match runtime {
                "scout" => {
                    cmd.arg(PATH_STEAM.join("bin32/steam-runtime/run.sh"));
                }
                "soldier" => {
                    cmd.arg(
                        PATH_STEAM.join(
                            "steam/steamapps/common/SteamLinuxRuntime_soldier/_v2-entry-point",
                        ),
                    );
                    cmd.arg("--");
                }
                "sniper" => {
                    let sniper_path = PATH_STEAM.join(
                        "steam/steamapps/common/SteamLinuxRuntime_sniper/_v2-entry-point",
                    );
                    // old installations of sniper go in a folder named -arm64 even though it is x86_64?
                    let sniper_arm_path = PATH_STEAM.join(
                        "steam/steamapps/common/SteamLinuxRuntime_sniper-arm64/_v2-entry-point",
                    );
                    if sniper_path.exists() {
                        cmd.arg(sniper_path);
                    } else if sniper_arm_path.exists() {
                        cmd.arg(sniper_arm_path);
                    }
                    cmd.arg("--");
                }
                "steamrt4" => {
                    cmd.arg(
                        PATH_STEAM.join(
                            "steam/steamapps/common/SteamLinuxRuntime_4/_v2-entry-point",
                        ),
                    );
                    cmd.arg("--");
                }
                _ => {}
            };
        }


        cmd.arg(match &drm_loader {
            Some(l) => l.exe.as_path(),
            None => path_exec.as_path(),
        });

        // The cold client loader takes no game args (they live in
        // ColdClientLoader.ini's ExeCommandLine); only append args when running
        // the game executable directly.
        if drm_loader.is_none() {
            for arg in &game_args {
                cmd.arg(arg);
            }
        }
    }

    Ok(cmds)
}

/// Staged cold-client-loader directory used to launch SteamStub-DRM games.
struct DrmLoader {
    dir: PathBuf,
    exe: PathBuf,
}

/// Stage a gbe_fork "cold client loader" directory that injects the Stub DRM
/// v3.1 patcher and force-injects steamclient before spawning the game. This is
/// required for newer SteamStub-wrapped executables (e.g. Ravenswatch) which
/// otherwise fail with "Application load error 3:0000065432".
fn stage_drm_loader(
    index: usize,
    gamedir: &Path,
    path_exec: &Path,
    game_args: &[String],
    h: &Handler,
) -> Result<DrmLoader, Box<dyn std::error::Error>> {
    let dir = PATH_PARTY.join("tmp").join(format!("ccloader-{index}"));
    let _ = std::fs::remove_dir_all(&dir);
    std::fs::create_dir_all(dir.join("extra_dlls"))?;

    let win_res = PATH_RES.join("goldberg/win");
    let loader_exe = win_res.join("steamclient_loader_x64.exe");
    let patcher = win_res.join("extra_dlls/steamclient_extra_x64.dll");
    if !loader_exe.exists() || !patcher.exists() {
        return Err(format!(
            "DRM loader files missing under {}. Rebuild partydeck to deploy them.",
            win_res.display()
        )
        .into());
    }

    for f in [
        "steamclient_loader_x64.exe",
        "steamclient.dll",
        "steamclient64.dll",
        "GameOverlayRenderer.dll",
        "GameOverlayRenderer64.dll",
    ] {
        let from = win_res.join(f);
        if from.exists() {
            std::fs::copy(&from, dir.join(f))?;
        }
    }
    std::fs::copy(&patcher, dir.join("extra_dlls/steamclient_extra_x64.dll"))?;
    std::fs::write(
        dir.join("extra_dlls/load_order.txt"),
        "steamclient_extra_x64.dll\n",
    )?;

    // gbe_fork reads emu config from steam_settings beside steamclient64.dll
    let steam_settings = dir.join("steam_settings");
    std::fs::create_dir_all(&steam_settings)?;
    let steam_settings_src = PATH_PARTY.join("goldberg_data/steam_settings");
    if steam_settings_src.is_dir() {
        for entry in std::fs::read_dir(&steam_settings_src)?.flatten() {
            if entry.path().is_file() {
                std::fs::copy(entry.path(), steam_settings.join(entry.file_name()))?;
            }
        }
    }
    if let Some(appid) = h.steam_appid {
        std::fs::write(steam_settings.join("steam_appid.txt"), appid.to_string())?;
    }

    let appid = h.steam_appid.map(|a| a.to_string()).unwrap_or_default();
    let cmdline = game_args.join(" ");
    let ini = format!(
        "[SteamClient]\n\
         Exe={exe}\n\
         ExeRunDir={rundir}\n\
         ExeCommandLine={cmdline}\n\
         AppId={appid}\n\
         SteamClientDll=steamclient.dll\n\
         SteamClient64Dll=steamclient64.dll\n\
         [Injection]\n\
         ForceInjectSteamClient=1\n\
         ForceInjectGameOverlayRenderer=0\n\
         DllsToInjectFolder=extra_dlls\n\
         IgnoreInjectionError=1\n\
         IgnoreLoaderArchDifference=0\n\
         [Persistence]\n\
         Mode=0\n\
         [Debug]\n\
         ResumeByDebugger=0\n",
        exe = path_exec.to_path_buf().os_fmt(true),
        rundir = gamedir.to_path_buf().os_fmt(true),
        cmdline = cmdline,
        appid = appid,
    );
    std::fs::write(dir.join("ColdClientLoader.ini"), ini)?;

    Ok(DrmLoader {
        exe: dir.join("steamclient_loader_x64.exe"),
        dir,
    })
}

/// Undo the wine-prefix registry pollution left by the gbe cold client loader.
///
/// `steamclient_loader_x64.exe` rewrites several Steam keys to point at its
/// throwaway `tmp/ccloader-{i}` staging dir, which is deleted on the next
/// launch. Any other goldberg game that later shares the same prefix and runs
/// via the normal experimental-steamclient path (V Rising, Palworld) then reads
/// a dead `steamclient64.dll` path and fails with "Steam not running". This
/// rewrites those keys back to the canonical `C:\Program Files (x86)\Steam`
/// locations where the bound goldberg steamclient lives.
///
/// Only lines that are a known Steam key AND still point at a `ccloader` path
/// are touched, so it is idempotent and safe to run on an already-clean prefix.
fn cleanup_drm_loader_prefix(pfx: &Path) {
    // Canonical Steam install root as written in .reg files (escaped backslashes).
    const STEAM: &str = r"C:\\Program Files (x86)\\Steam";

    let canonical_line = |line: &str| -> Option<String> {
        if !line.contains("ccloader") {
            return None;
        }
        let t = line.trim_start();
        if t.starts_with("\"SteamExe\"=") {
            Some(format!(r#""SteamExe"="{STEAM}\\Steam.exe""#))
        } else if t.starts_with("\"SteamPath\"=") {
            Some(format!(r#""SteamPath"="{STEAM}""#))
        } else if t.starts_with("\"SourceModInstallPath\"=") {
            Some(format!(r#""SourceModInstallPath"="{STEAM}\\steamapps\\sourcemods""#))
        } else if t.starts_with("\"SteamClientDll\"=") {
            Some(format!(r#""SteamClientDll"="{STEAM}\\steamclient.dll""#))
        } else if t.starts_with("\"SteamClientDll64\"=") {
            Some(format!(r#""SteamClientDll64"="{STEAM}\\steamclient64.dll""#))
        } else if t.starts_with("\"InstallPath\"=") {
            Some(format!(r#""InstallPath"="{STEAM}""#))
        } else if t.starts_with("@=") {
            // [Software\Classes\steam\shell\open\command] default value.
            Some(format!(r#"@="\"{STEAM}\\Steam.exe\" -- \"%1\"""#))
        } else {
            None
        }
    };

    for fname in ["user.reg", "system.reg"] {
        let path = pfx.join(fname);
        let content = match std::fs::read_to_string(&path) {
            Ok(c) => c,
            Err(_) => continue,
        };
        if !content.contains("ccloader") {
            continue;
        }

        let mut changed = false;
        // split('\n') preserves the trailing newline as a final empty element,
        // which join('\n') restores, so the file's line endings are unchanged.
        let rebuilt = content
            .split('\n')
            .map(|line| match canonical_line(line) {
                Some(fixed) => {
                    changed = true;
                    fixed
                }
                None => line.to_string(),
            })
            .collect::<Vec<_>>()
            .join("\n");

        if changed {
            match std::fs::write(&path, rebuilt) {
                Ok(()) => println!(
                    "[partydeck] Scrubbed cold-loader registry pollution in {}",
                    path.display()
                ),
                Err(e) => eprintln!(
                    "[partydeck] WARNING: failed to scrub {}: {e}",
                    path.display()
                ),
            }
        }
    }
}

/// Count processes that are descendants of `root` (excluding `root` itself) by
/// walking /proc PPid links. Cheap enough to poll every couple of seconds.
fn count_proc_descendants(root: u32) -> usize {
    use std::collections::HashMap;
    let mut children: HashMap<u32, Vec<u32>> = HashMap::new();
    if let Ok(entries) = std::fs::read_dir("/proc") {
        for e in entries.flatten() {
            let name = e.file_name();
            let pid: u32 = match name.to_string_lossy().parse() {
                Ok(p) => p,
                Err(_) => continue,
            };
            let status = match std::fs::read_to_string(format!("/proc/{pid}/status")) {
                Ok(s) => s,
                Err(_) => continue,
            };
            if let Some(ppid) = status
                .lines()
                .find_map(|l| l.strip_prefix("PPid:"))
                .and_then(|v| v.trim().parse::<u32>().ok())
            {
                children.entry(ppid).or_default().push(pid);
            }
        }
    }
    let mut count = 0usize;
    let mut stack = vec![root];
    while let Some(p) = stack.pop() {
        if let Some(kids) = children.get(&p) {
            for &k in kids {
                count += 1;
                stack.push(k);
            }
        }
    }
    count
}

/// True if `pid` no longer exists or is a reaped-pending zombie (state 'Z').
fn proc_gone_or_zombie(pid: u32) -> bool {
    match std::fs::read_to_string(format!("/proc/{pid}/stat")) {
        Err(_) => true,
        Ok(stat) => {
            // /proc/<pid>/stat: "pid (comm) STATE ...". comm may contain spaces
            // and ')', so locate the last ')' and read the state char after it.
            match stat.rfind(')') {
                Some(idx) => stat[idx + 1..].trim_start().starts_with('Z'),
                None => false,
            }
        }
    }
}

/// Watchdog for the cold-loader gamescope teardown hang. For each gamescope pid,
/// once its game process tree has been observed at least once and then stays
/// absent for `GRACE`, SIGKILL the compositor so the launcher's handle.wait()
/// returns (and the after-close prefix scrub can run). The "seen at least once"
/// guard means a gamescope that is still bringing the game up is never killed,
/// and the sustained-absence grace avoids killing on a transient gap.
fn spawn_gamescope_watchdog(pids: Vec<u32>) -> std::thread::JoinHandle<()> {
    std::thread::spawn(move || {
        const GRACE: std::time::Duration = std::time::Duration::from_secs(8);
        const POLL: std::time::Duration = std::time::Duration::from_secs(2);

        struct Watch {
            pid: u32,
            saw_children: bool,
            last_had_children: std::time::Instant,
            done: bool,
        }
        let mut watches: Vec<Watch> = pids
            .into_iter()
            .map(|pid| Watch {
                pid,
                saw_children: false,
                last_had_children: std::time::Instant::now(),
                done: false,
            })
            .collect();

        loop {
            for w in watches.iter_mut() {
                if w.done {
                    continue;
                }
                if proc_gone_or_zombie(w.pid) {
                    // Exited normally (or already killed and now reaping).
                    w.done = true;
                    continue;
                }
                if count_proc_descendants(w.pid) > 0 {
                    w.saw_children = true;
                    w.last_had_children = std::time::Instant::now();
                } else if w.saw_children && w.last_had_children.elapsed() >= GRACE {
                    eprintln!(
                        "[partydeck] gamescope {} has had no game process for {}s after close; \
                         terminating hung compositor.",
                        w.pid,
                        GRACE.as_secs()
                    );
                    let _ = Command::new("kill")
                        .args(["-9", &w.pid.to_string()])
                        .status();
                    w.done = true;
                }
            }
            if watches.iter().all(|w| w.done) {
                break;
            }
            std::thread::sleep(POLL);
        }
    })
}

fn print_launch_cmds(cmds: &Vec<Command>) {
    for (i, cmd) in cmds.iter().enumerate() {
        println!("[partydeck] INSTANCE {}:", i + 1);

        let cwd = cmd.get_current_dir().unwrap_or_else(|| Path::new(""));
        println!("[partydeck] CWD={}", cwd.display());

        for var in cmd.get_envs() {
            let value = var.1.ok_or_else(|| "").unwrap_or_default();
            println!(
                "[partydeck] {}={}",
                var.0.to_string_lossy(),
                value.display()
            );
        }

        println!("[partydeck] \"{}\"", cmd.get_program().display());

        print!("[partydeck] ");
        for arg in cmd.get_args() {
            let fmtarg = arg.to_string_lossy();
            if fmtarg == "--bind"
                || fmtarg == "bwrap"
                || (fmtarg.starts_with("/") && fmtarg.len() > 1)
            {
                print!("\n[partydeck] ");
            } else {
                print!(" ");
            }
            print!("\"{}\"", fmtarg);
        }

        println!("\n[partydeck] ---------------------");
    }
}

pub fn fuse_overlayfs_mount_gamedirs(
    h: &Handler,
    instances: &Vec<Instance>,
) -> Result<(), Box<dyn std::error::Error>> {
    let tmp_dir = PATH_PARTY.join("tmp");
    let mut path_lowerdir = h.get_game_rootpath()?;

    let overlay_path = h.path_handler.join("overlay");
    if overlay_path.exists() {
        path_lowerdir = format!("{}:{}", overlay_path.display(), path_lowerdir);
    }

    let gamename = h.handler_dir_name().to_string();

    let mut cmds: Vec<Command> = (0..instances.len())
        .map(|_| Command::new("fuse-overlayfs"))
        .collect();

    for (i, instance) in instances.iter().enumerate() {
        let cmd = &mut cmds[i];

        let path_game_mnt = tmp_dir.join(format!("game-{}", i));
        let path_workdir = tmp_dir.join(format!("work-{}", i));
        let path_prof = PATH_PARTY.join("profiles").join(&instance.profname);
        let path_upperdir = path_prof.join("gamesaves").join(&gamename);

        std::fs::create_dir_all(&path_game_mnt)?;
        std::fs::create_dir_all(&path_workdir)?;

        cmd.arg("-o");
        cmd.arg(format!("lowerdir={}", path_lowerdir));
        cmd.arg("-o");
        cmd.arg(format!("upperdir={}", path_upperdir.display()));
        cmd.arg("-o");
        cmd.arg(format!("workdir={}", path_workdir.display()));
        cmd.arg(&path_game_mnt);
    }

    for cmd in &mut cmds {
        let status = cmd
            .status()
            .map_err(|_| "Fuse-overlayfs executable not found; Please install fuse-overlayfs through your distro's package manager. If you already have it installed (or are on SteamOS, where it should be pre-installed), open up an issue on the GitHub.")?;
        if !status.success() {
            return Err("fuse-overlayfs mount failed.".into());
        }
    }

    Ok(())
}

#[cfg(test)]
mod companion_tests {
    use super::*;
    use std::sync::{Mutex, MutexGuard};

    // free_port() releases its port, so a sibling test could grab it before the
    // helper binds. Tests that use ports run one at a time.
    static PORT_LOCK: Mutex<()> = Mutex::new(());

    fn port_lock() -> MutexGuard<'static, ()> {
        PORT_LOCK.lock().unwrap_or_else(|poisoned| poisoned.into_inner())
    }

    fn handler(companion: &str, port: u16) -> Handler {
        Handler { companion: companion.into(), companion_port: port, ..Handler::default() }
    }

    fn scratch(name: &str) -> PathBuf {
        let dir = std::env::temp_dir().join(format!("partydeck-companion-{}-{name}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        dir
    }

    fn free_port() -> u16 {
        std::net::TcpListener::bind("127.0.0.1:0").unwrap().local_addr().unwrap().port()
    }

    fn wait_until(mut condition: impl FnMut() -> bool) -> bool {
        for _ in 0..100 {
            if condition() {
                return true;
            }
            std::thread::sleep(std::time::Duration::from_millis(50));
        }
        false
    }

    fn listener_script(dir: &Path) -> String {
        let script = dir.join("listen.py");
        std::fs::write(
            &script,
            "import socket, sys, time\ns = socket.socket()\ns.bind(('127.0.0.1', int(sys.argv[1])))\ns.listen()\ntime.sleep(60)\n",
        )
        .unwrap();
        script.to_string_lossy().into_owned()
    }

    #[test]
    fn empty_companion_starts_nothing() {
        let dir = scratch("empty");
        let companion = start_companion(&handler("", 0), &dir.join("log")).unwrap();
        assert!(companion.0.is_none());
    }

    #[test]
    fn open_port_means_user_already_runs_it() {
        let _lock = port_lock();
        let listener = std::net::TcpListener::bind("127.0.0.1:0").unwrap();
        let port = listener.local_addr().unwrap().port();
        let dir = scratch("open");
        // Would fail to spawn if it were attempted.
        let companion = start_companion(&handler("/nonexistent/program", port), &dir.join("log")).unwrap();
        assert!(companion.0.is_none());
    }

    #[test]
    fn waits_for_port_and_kills_on_drop() {
        let _lock = port_lock();
        let dir = scratch("listen");
        let port = free_port();
        let command = format!("python3 {} {port}", listener_script(&dir));
        let companion = start_companion(&handler(&command, port), &dir.join("log")).unwrap();
        assert!(local_port_open(port));
        drop(companion);
        assert!(wait_until(|| !local_port_open(port)), "companion survived drop");
    }

    #[test]
    fn early_exit_is_an_error() {
        let _lock = port_lock();
        let dir = scratch("exit");
        let error = start_companion(&handler("true", free_port()), &dir.join("log")).err().unwrap();
        assert!(error.to_string().contains("exited early"), "{error}");
    }

    #[test]
    fn missing_program_is_an_error() {
        let dir = scratch("missing");
        let error = start_companion(&handler("/nonexistent/program", 0), &dir.join("log")).err().unwrap();
        assert!(error.to_string().contains("Failed to start companion"), "{error}");
    }

    #[test]
    fn port_zero_does_not_wait() {
        let dir = scratch("nowait");
        let companion = start_companion(&handler("sleep 60", 0), &dir.join("log")).unwrap();
        assert!(companion.0.is_some());
    }
}

const SDL_GAMECONTROLLER_IGNORE_DEVICES: &str = "0x054c/0x0df2,0x054c/0x0df2,0x045e/0x02e3,0x045e/0x0b00,0x045e/0x0b05,0x2dc8/0x6000,0x2dc8/0x6100,0x2dc8/0x6001,0x2dc8/0x6101,0x2dc8/0x6003,0x2dc8/0x6006,0x2dc8/0x6009,0x2dc8/0x6012,0x28de/0x1002,0x28de/0x1003,0x28de/0x1071,0x28de/0x1052,0x28de/0x1042,0x28de/0x1203,0x28de/0x1204,0x28de/0x1205,0x28de/0x1206,0x28de/0x1302,0x28de/0x1303,0x28de/0x1304,0x28de/0x1305,0x0f0d/0x01ab,0x0f0d/0x0196,0x28de/0x12ff,0x28de/0x12fe,0x28de/0x12fd,0x28de/0x12fc,0x28de/0x12fb,0x28de/0x12fa,0x28de/0x12f9,0x28de/0x12f8,0x28de/0x12f7,0x28de/0x12f6,0x28de/0x12f5,0x28de/0x12f4,0x28de/0x12f3,0x28de/0x12f2,0x28de/0x12f1,0x28de/0x12f0,0x0079/0x181a,0x044f/0xb315,0x044f/0xd007,0x046d/0xcad1,0x054c/0x0268,0x056e/0x200f,0x056e/0x2013,0x05b8/0x1004,0x05b8/0x1006,0x06a3/0xf622,0x0738/0x3180,0x0738/0x3250,0x0738/0x3481,0x0738/0x8180,0x0738/0x8838,0x0810/0x0001,0x0810/0x0003,0x0925/0x0005,0x0925/0x8866,0x0925/0x8888,0x0e6f/0x0109,0x0e6f/0x011e,0x0e6f/0x0128,0x0e6f/0x0214,0x0e6f/0x1314,0x0e6f/0x6302,0x0e8f/0x0008,0x0e8f/0x3075,0x0e8f/0x310d,0x0f0d/0x0009,0x0f0d/0x004d,0x0f0d/0x005f,0x0f0d/0x006a,0x0f0d/0x006e,0x0f0d/0x0085,0x0f0d/0x0086,0x0f0d/0x0088,0x0f30/0x1100,0x11ff/0x3331,0x1345/0x1000,0x1345/0x6005,0x146b/0x5500,0x1a34/0x0836,0x20bc/0x5500,0x20d6/0x576d,0x20d6/0xca6d,0x2563/0x0523,0x2563/0x0575,0x25f0/0x83c3,0x25f0/0xc121,0x2c22/0x2003,0x2c22/0x2302,0x2c22/0x2502,0x8380/0x0003,0x8888/0x0308,0x0079/0x181b,0x044f/0xd00e,0x054c/0x05c4,0x054c/0x05c5,0x054c/0x09cc,0x054c/0x0ba0,0x0738/0x8250,0x0738/0x8384,0x0738/0x8480,0x0738/0x8481,0x0c12/0x0e10,0x0c12/0x0e13,0x0c12/0x0e15,0x0c12/0x0e20,0x0c12/0x0ef6,0x0c12/0x1cf6,0x0c12/0x1e10,0x0c12/0x2e18,0x0e6f/0x0203,0x0e6f/0x0207,0x0e6f/0x020a,0x0f0d/0x0055,0x0f0d/0x005e,0x0f0d/0x0066,0x0f0d/0x0084,0x0f0d/0x0087,0x0f0d/0x008a,0x0f0d/0x009c,0x0f0d/0x00a0,0x0f0d/0x00ee,0x0f0d/0x011c,0x0f0d/0x0123,0x0f0d/0x0162,0x11c0/0x4001,0x146b/0x0d01,0x146b/0x0d02,0x146b/0x0d06,0x146b/0x0d08,0x146b/0x0d09,0x146b/0x0d10,0x146b/0x0d10,0x146b/0x0d13,0x146b/0x1103,0x1532/0x0401,0x1532/0x1000,0x1532/0x1004,0x1532/0x1007,0x1532/0x1008,0x1532/0x1009,0x1532/0x100a,0x1532/0x1100,0x20d6/0x792a,0x2c22/0x2000,0x2c22/0x2300,0x2c22/0x2500,0x3285/0x0d16,0x3285/0x0d17,0x7545/0x0104,0x9886/0x0025,0x054c/0x0ce6,0x054c/0x0df2,0x054c/0x0e5f,0x0e6f/0x0209,0x0f0d/0x0163,0x0f0d/0x0184,0x1532/0x100b,0x1532/0x100c,0x1532/0x1012,0x3285/0x0d18,0x3285/0x0d19,0x358a/0x0104,0x0079/0x18d4,0x03eb/0xff02,0x044f/0xb326,0x045e/0x028e,0x045e/0x028f,0x045e/0x0291,0x045e/0x02a0,0x045e/0x02a1,0x045e/0x02a9,0x045e/0x0719,0x046d/0xc21d,0x046d/0xc21e,0x046d/0xc21f,0x046d/0xc242,0x056e/0x2004,0x0738/0x4716,0x0738/0x4718,0x0738/0x4726,0x0738/0x4728,0x0738/0x4736,0x0738/0x4738,0x0738/0x4740,0x0738/0xb726,0x0738/0xbeef,0x0738/0xcb02,0x0738/0xcb03,0x0738/0xf738,0x0955/0x7210,0x0955/0xb400,0x0b05/0x1b4c,0x0e6f/0x0105,0x0e6f/0x0113,0x0e6f/0x011f,0x0e6f/0x0125,0x0e6f/0x0127,0x0e6f/0x0131,0x0e6f/0x0133,0x0e6f/0x0143,0x0e6f/0x0147,0x0e6f/0x0201,0x0e6f/0x0213,0x0e6f/0x021f,0x0e6f/0x0301,0x0e6f/0x0313,0x0e6f/0x0314,0x0e6f/0x0401,0x0e6f/0x0413,0x0e6f/0x0501,0x0e6f/0xf900,0x0f0d/0x000a,0x0f0d/0x000c,0x0f0d/0x000d,0x0f0d/0x0016,0x0f0d/0x001b,0x0f0d/0x008c,0x0f0d/0x00db,0x0f0d/0x011e,0x1038/0x1430,0x1038/0x1431,0x1038/0xb360,0x11c9/0x55f0,0x12ab/0x0004,0x12ab/0x0301,0x12ab/0x0303,0x1430/0x02a0,0x1430/0x4748,0x1430/0xf801,0x146b/0x0601,0x15e4/0x3f00,0x15e4/0x3f0a,0x15e4/0x3f10,0x162e/0xbeef,0x1689/0xfd00,0x1689/0xfd01,0x1689/0xfe00,0x1949/0x041a,0x1bad/0x0002,0x1bad/0x0003,0x1bad/0xf016,0x1bad/0xf018,0x1bad/0xf019,0x1bad/0xf021,0x1bad/0xf023,0x1bad/0xf025,0x1bad/0xf027,0x1bad/0xf028,0x1bad/0xf02e,0x1bad/0xf036,0x1bad/0xf038,0x1bad/0xf039,0x1bad/0xf03a,0x1bad/0xf03d,0x1bad/0xf03e,0x1bad/0xf03f,0x1bad/0xf042,0x1bad/0xf080,0x1bad/0xf501,0x1bad/0xf502,0x1bad/0xf503,0x1bad/0xf504,0x1bad/0xf505,0x1bad/0xf506,0x1bad/0xf900,0x1bad/0xf901,0x1bad/0xf902,0x1bad/0xf903,0x1bad/0xf904,0x1bad/0xf906,0x1bad/0xfa01,0x1bad/0xfd00,0x1bad/0xfd01,0x24c6/0x5000,0x24c6/0x5300,0x24c6/0x5303,0x24c6/0x530a,0x24c6/0x531a,0x24c6/0x5397,0x24c6/0x5500,0x24c6/0x5501,0x24c6/0x5502,0x24c6/0x5503,0x24c6/0x5506,0x24c6/0x550d,0x24c6/0x550e,0x24c6/0x5508,0x24c6/0x5510,0x24c6/0x5b00,0x24c6/0x5b02,0x24c6/0x5b03,0x24c6/0x5d04,0x24c6/0xfafa,0x24c6/0xfafb,0x24c6/0xfafc,0x24c6/0xfafd,0x24c6/0xfafe,0x03f0/0x0495,0x044f/0xd012,0x045e/0x02d1,0x045e/0x02dd,0x045e/0x02e0,0x045e/0x02e3,0x045e/0x02ea,0x045e/0x02fd,0x045e/0x02ff,0x045e/0x0b00,0x045e/0x0b05,0x045e/0x0b0a,0x045e/0x0b0c,0x045e/0x0b12,0x045e/0x0b13,0x045e/0x0b20,0x045e/0x0b21,0x045e/0x0b22,0x0738/0x4a01,0x0e6f/0x0139,0x0e6f/0x013b,0x0e6f/0x013a,0x0e6f/0x0145,0x0e6f/0x0146,0x0e6f/0x015b,0x0e6f/0x015c,0x0e6f/0x015d,0x0e6f/0x015f,0x0e6f/0x0160,0x0e6f/0x0161,0x0e6f/0x0162,0x0e6f/0x0163,0x0e6f/0x0164,0x0e6f/0x0165,0x0e6f/0x0166,0x0e6f/0x0167,0x0e6f/0x0205,0x0e6f/0x0206,0x0e6f/0x0246,0x0e6f/0x0261,0x0e6f/0x0262,0x0e6f/0x02a0,0x0e6f/0x02a1,0x0e6f/0x02a2,0x0e6f/0x02a3,0x0e6f/0x02a4,0x0e6f/0x02a5,0x0e6f/0x02a6,0x0e6f/0x02a7,0x0e6f/0x02a8,0x0e6f/0x02a9,0x0e6f/0x02aa,0x0e6f/0x02ab,0x0e6f/0x02ac,0x0e6f/0x02ad,0x0e6f/0x02ae,0x0e6f/0x02af,0x0e6f/0x02b0,0x0e6f/0x02b1,0x0e6f/0x02b3,0x0e6f/0x02b5,0x0e6f/0x02b6,0x0e6f/0x02bd,0x0e6f/0x02be,0x0e6f/0x02bf,0x0e6f/0x02c0,0x0e6f/0x02c1,0x0e6f/0x02c2,0x0e6f/0x02c3,0x0e6f/0x02c4,0x0e6f/0x02c5,0x0e6f/0x02c6,0x0e6f/0x02c7,0x0e6f/0x02c8,0x0e6f/0x02c9,0x0e6f/0x02ca,0x0e6f/0x02cb,0x0e6f/0x02cd,0x0e6f/0x02ce,0x0e6f/0x02cf,0x0e6f/0x02d5,0x0e6f/0x0346,0x0e6f/0x0446,0x0e6f/0x02da,0x0e6f/0x02d6,0x0e6f/0x02d9,0x0f0d/0x0063,0x0f0d/0x0067,0x0f0d/0x0078,0x0f0d/0x00c5,0x0f0d/0x0150,0x10f5/0x7009,0x10f5/0x7013,0x1532/0x0a00,0x1532/0x0a03,0x1532/0x0a14,0x1532/0x0a15,0x20d6/0x2001,0x20d6/0x2002,0x20d6/0x2003,0x20d6/0x2004,0x20d6/0x2005,0x20d6/0x2006,0x20d6/0x2009,0x20d6/0x200a,0x20d6/0x200b,0x20d6/0x200c,0x20d6/0x200d,0x20d6/0x200e,0x20d6/0x200f,0x20d6/0x2011,0x20d6/0x2012,0x20d6/0x2015,0x20d6/0x2016,0x20d6/0x2017,0x20d6/0x2018,0x20d6/0x2019,0x20d6/0x201a,0x20d6/0x4001,0x20d6/0x4002,0x20d6/0x890b,0x24c6/0x541a,0x24c6/0x542a,0x24c6/0x543a,0x24c6/0x551a,0x24c6/0x561a,0x24c6/0x581a,0x24c6/0x591a,0x24c6/0x592a,0x24c6/0x791a,0x2dc8/0x2002,0x2dc8/0x3106,0x2e24/0x0652,0x2e24/0x1618,0x2e24/0x1688,0x146b/0x0611,0x0000/0x0000,0x045e/0x02a2,0x0e6f/0x1414,0x0e6f/0x0159,0x24c6/0xfaff,0x0f0d/0x006d,0x0f0d/0x00a4,0x0079/0x1832,0x0079/0x187f,0x0079/0x1883,0x03eb/0xff01,0x0c12/0x0ef8,0x046d/0x1000,0x11ff/0x0511,0x1345/0x6006,0x056e/0x2012,0x146b/0x0602,0x0f0d/0x00ae,0x046d/0x0401,0x046d/0x0301,0x046d/0xcaa3,0x046d/0xc261,0x046d/0x0291,0x0079/0x18d3,0x0f0d/0x00b1,0x0001/0x0001,0x0079/0x188e,0x0079/0x187c,0x0079/0x189c,0x0079/0x1874,0x2f24/0x0050,0x2f24/0x002e,0x2f24/0x0091,0x1430/0x0719,0x0f0d/0x00ed,0x0f0d/0x00c0,0x0e6f/0x0152,0x046d/0x1007,0x0e6f/0x02b8,0x0079/0x18a1,0x0000/0x6686,0x12ab/0x0304,0x1430/0x0291,0x1430/0x02a9,0x1430/0x070b,0x1bad/0x028e,0x1bad/0x02a0,0x1bad/0x5500,0x20ab/0x55ef,0x24c6/0x5509,0x2516/0x0069,0x25b1/0x0360,0x2c22/0x2203,0x2f24/0x0011,0x2f24/0x0053,0x2f24/0x00b7,0x046d/0x0000,0x046d/0x1004,0x046d/0x1008,0x046d/0xf301,0x0738/0x02a0,0x0738/0x7263,0x0738/0xb738,0x0738/0xcb29,0x0738/0xf401,0x0079/0x18c2,0x0079/0x18c8,0x0079/0x18cf,0x0c12/0x0e17,0x0c12/0x0e1c,0x0c12/0x0e22,0x0c12/0x0e30,0xd2d2/0xd2d2,0x0d62/0x9a1a,0x0d62/0x9a1b,0x0e00/0x0e00,0x0e6f/0x012a,0x0e6f/0x02b2,0x0f0d/0x0097,0x0f0d/0x00ba,0x0f0d/0x00d8,0x0fff/0x02a1,0x045e/0x0867,0x16d0/0x0f3f,0x2f24/0x008f,0x0e6f/0xf501,0x057e/0x2006,0x057e/0x2067,0x057e/0x2007,0x057e/0x2066,0x057e/0x2008,0x057e/0x2068,0x057e/0x2009,0x057e/0x2069,0x0f0d/0x00c1,0x0f0d/0x0092,0x0f0d/0x00f6,0x0e6f/0x0180,0x0e6f/0x0181,0x0e6f/0x0184,0x0e6f/0x0185,0x0e6f/0x0186,0x0e6f/0x0187,0x0e6f/0x0188,0x0e6f/0x018c,0x0f0d/0x00aa,0x20d6/0xa711,0x20d6/0xa712,0x20d6/0xa713,0x20d6/0xa714,0x20d6/0xa715,0x20d6/0xa716,0x20d6/0xa718,0x33dd/0x0001,0x33dd/0x0002,0x33dd/0x0003,0x0f0d/0x00f0,0x0000/0x11fb,0x28de/0x1101,0x28de/0x1102,0x28de/0x1105,0x28de/0x1106,0x28de/0x1142,0x28de/0x1201,0x28de/0x1202,0x28de/0x1205,0x28de/0x1302,0x28de/0x1303,0x28de/0x1304,0x2dc8/0x9000,0x2dc8/0x3810,0x2dc8/0x0651,0x2dc8/0x9020,0x2dc8/0x9015,0x2dc8/0x2865,0x1235/0xab12,0x2002/0x9000,0x2dc8/0x9001,0x3820/0x0009,0x2dc8/0x3820,0x2dc8/0x2000,0x2dc8/0x2000,0x2810/0x0009,0x2dc8/0x2830,0x2dc8/0x6002,0x2dc8/0x6102,0x1235/0xab20,0x2820/0x0009,0x2dc8/0x301b,0x2dc8/0x3011,0x2dc8/0x3013,0x2dc8/0x9018,0x2dc8/0x3230,0x05a0/0x3232,0x05a0/0x3232,0x2dc8/0x3100,0x2dc8/0x9012,0x2dc8/0x2862,0x0b05/0x4500,0x0b05/0x4500,0x0b05/0x7905,0x0b05/0x7906,0x0010/0x0082,0x1949/0x0402,0x1949/0x0419,0x0171/0x0419,0x0079/0x1830,0x3250/0x1001,0x3250/0x1001,0x3250/0x1002,0x3250/0x1002,0x24c6/0x891b,0x0c12/0x0ef7,0x04b4/0x010a,0xffff/0xffff,0x20e8/0x5860,0x0926/0x8888,0x0e6f/0x0130,0x0079/0x0011,0x1a34/0xf705,0x1949/0x0402,0x3537/0x1097,0x05ac/0x061a,0x25f0/0x83c1,0x18d1/0x9400,0x18d1/0x9400,0x0428/0x4001,0x0e8f/0x1006,0x0e8f/0x0012,0x0f0d/0x0010,0x0f0d/0x0022,0x0f0d/0x006b,0xdead/0xbeef,0x14d8/0x6208,0x0e8f/0x3013,0x04d8/0x0082,0x05fd/0x3000,0x1949/0x0402,0x056e/0x2003,0x0f30/0x0110,0x22ba/0x1020,0x046d/0xc219,0x046d/0xc216,0x046d/0xc216,0x046d/0xc219,0x046d/0xc218,0x046d/0xc211,0x24c6/0x892b,0x24c6/0x892a,0x24c6/0x891a,0x0738/0x5266,0x0738/0x3384,0x0738/0x3480,0x0738/0x8818,0x0078/0x0006,0x045e/0x000e,0x045e/0x0285,0x045e/0x0289,0x045e/0x0289,0x20d6/0x0dad,0x146b/0x0c01,0x0810/0xe501,0x0955/0x7214,0x0955/0x7214,0x124b/0x4d01,0x1345/0x3008,0x0079/0x1843,0x0079/0x1844,0x057e/0x2019,0x057e/0x2019,0x057e/0x201e,0x057e/0x2017,0x057e/0x2017,0x057e/0x2017,0x057e/0x0306,0x057e/0x0330,0x057e/0x0306,0x050d/0x0803,0x2836/0x0001,0x2836/0x0001,0x045e/0x0202,0x11ff/0x3341,0x0e8f/0x0003,0x054c/0x0cda,0x0f30/0x1112,0x2c22/0x2012,0x2c22/0x2010,0x1532/0x0402,0x1532/0x0705,0x1532/0x0900,0x1532/0x0900,0xf000/0x0003,0x0079/0x0011,0x1a34/0x0809,0x7545/0x1122,0x06a3/0xf623,0x06a3/0xff0c,0x06a3/0x040c,0x06a3/0x0109,0x06a3/0x040b,0x06a3/0xf518,0x16c0/0x0487,0x28de/0x11fc,0x0111/0x1431,0x0111/0x1419,0x6666/0x8804,0xf000/0x00f1,0x044f/0xb320,0x044f/0xb323,0x044f/0xb300,0x044f/0xd009,0x044f/0xd008,0x12bd/0xd015,0x14d8/0xcd07,0x0079/0x0011,0x05ac/0x3232,0x0c45/0x4320,0x2717/0x3144,0x16c0/0x05e1,0x6666/0x0667,0x0583/0x2060,0x07b5/0x0315,0x289b/0x0080,0x289b/0x0003,0x289b/0x0060,";
