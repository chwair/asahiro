use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::time::Duration;

use serde::Serialize;
use serde_json::json;

use crate::config::{BottleConfig, Config, GraphicsBackend, RunnerKind};
use crate::game::{self, DATA_DIR, EXECUTABLE};
use crate::runner;
use crate::util::{err, home, logs_dir, Result, Task};

// the security handshake on this host crashes the client under wine in most regions (yaagl issue 551)
const LAUNCH_FIX_HOST: &str = "globaldp-prod-os01.zenlesszonezero.com";
const LAUNCH_FIX_SECONDS: u32 = 25;

const ENV_BEGIN: &str = ";; asahiro managed begin";
const ENV_END: &str = ";; asahiro managed end";
const MANAGED_KEYS: [&str; 10] = [
    "CX_GRAPHICS_BACKEND",
    "WINEMSYNC",
    "WINEESYNC",
    "MTL_HUD_ENABLED",
    "D3DM_ENABLE_METALFX",
    "D3DM_SUPPORT_DXR",
    "D3DM_DEVICE_ID",
    "D3DM_DEVICE_DESCRIPTION",
    "DXMT_ENABLE_NVEXT",
    "WINEDLLOVERRIDES",
];

#[derive(Serialize)]
pub struct WineInfo {
    pub crossover_found: bool,
    pub crossover_version: Option<String>,
    pub runner: RunnerKind,
    pub runner_name: String,
    pub runner_installed: bool,
    pub rosetta: bool,
    pub bottle_exists: bool,
    pub bottle_path: String,
    pub game_running: bool,
}

// the wine build a command runs on, both use the same crossover-style bottle
pub enum Runner {
    CrossOver(PathBuf),
    Bundled(PathBuf),
}

impl Runner {
    // resolves the configured runner, downloading the bundled one when a task is available
    pub fn resolve(cfg: &Config, task: Option<&Task>) -> Result<Runner> {
        match cfg.runner {
            RunnerKind::Crossover => match crossover_root(cfg) {
                Some(r) => Ok(Runner::CrossOver(r)),
                None => err("CrossOver was not found. Install it or switch the runner in settings."),
            },
            RunnerKind::Bundled => match task {
                Some(t) => Ok(Runner::Bundled(runner::ensure(t)?)),
                None if runner::installed() => Ok(Runner::Bundled(runner::runner_dir())),
                None => err("the wine runner is not downloaded yet, start the game once first"),
            },
        }
    }

    // a wine invocation for the bottle, arguments are passed through as windows paths
    fn wine(&self, cfg: &Config, workdir: Option<&Path>) -> Command {
        let b = &cfg.bottle;
        let mut c = match self {
            Runner::CrossOver(root) => {
                let mut c = Command::new(root.join("bin/wine"));
                c.arg("--bottle").arg(&b.name);
                if let Some(w) = workdir {
                    c.arg("--workdir").arg(w);
                }
                c.arg("--no-convert");
                c
            }
            Runner::Bundled(dir) => {
                let mut c = Command::new(dir.join("bin/wine"));
                c.env("WINEPREFIX", bottle_path(b));
                if let Some(w) = workdir {
                    c.current_dir(w);
                }
                c
            }
        };
        // the default lives in the purgeable darwin cache folder, which macos empties when disk space runs low
        if !b.env.contains_key("DXMT_SHADER_CACHE_PATH") {
            c.env("DXMT_SHADER_CACHE_PATH", dxmt_cache_dir());
        }
        for (k, v) in bottle_env(b) {
            c.env(k, v);
        }
        if matches!(self, Runner::Bundled(_)) {
            if !b.msync {
                c.env("WINEESYNC", "1");
            }
            c.env("GST_PLUGIN_FEATURE_RANK", "atdec:MAX,avdec_h264:MAX");
            // crossover's ntdll preloads this for d3dmetal, its wine script sets it the same way
            let d3dshared = runner::d3dshared_path();
            if d3dshared.exists() {
                c.env("CX_APPLEGPTK_LIBD3DSHARED_PATH", d3dshared);
            }
        }
        c.env("WINEDEBUG", "-all");
        c
    }

    // crossover's wine script drops WINEDLLOVERRIDES from the environment and only takes --dll
    fn dll_overrides(&self, c: &mut Command, overrides: &str) {
        match self {
            Runner::CrossOver(_) => {
                c.arg("--dll").arg(overrides);
            }
            Runner::Bundled(_) => {
                c.env("WINEDLLOVERRIDES", overrides);
            }
        }
    }

    // the game has to be the process that boots the wineserver, an already running one makes the
    // anti-cheat abort, so every launch waits for the setup commands' server to go away first
    fn wait_idle(&self, cfg: &Config) {
        let _ = Command::new(self.wineserver()).env("WINEPREFIX", bottle_path(&cfg.bottle)).arg("-w").status();
    }

    fn wineserver(&self) -> PathBuf {
        match self {
            Runner::CrossOver(root) => root.join("bin/wineserver"),
            Runner::Bundled(dir) => dir.join("bin/wineserver"),
        }
    }
}

pub fn crossover_root(cfg: &Config) -> Option<PathBuf> {
    let candidates = [
        PathBuf::from(&cfg.crossover_path),
        PathBuf::from("/Applications/CrossOver.app"),
        home().join("Applications/CrossOver.app"),
    ];
    candidates
        .into_iter()
        .map(|app| app.join("Contents/SharedSupport/CrossOver"))
        .find(|root| root.join("bin/wine").exists())
}

fn dxmt_cache_dir() -> PathBuf {
    let p = crate::util::data_dir().join("shadercache/dxmt");
    if !p.exists() {
        let _ = std::fs::create_dir_all(&p);
        import_dxmt_cache(&p);
    }
    p
}

// carries over the cache dxmt built in its default location, so moving it costs no recompiles
fn import_dxmt_cache(to: &Path) {
    let Ok(out) = Command::new("/usr/bin/getconf").arg("DARWIN_USER_CACHE_DIR").output() else { return };
    let old = PathBuf::from(String::from_utf8_lossy(&out.stdout).trim()).join("dxmt").join(EXECUTABLE);
    let Ok(entries) = std::fs::read_dir(&old) else { return };
    for e in entries.filter_map(|e| e.ok()) {
        let name = e.file_name().to_string_lossy().into_owned();
        // the write-ahead log holds entries not yet merged into the database
        if name.starts_with("shaders_") && (name.ends_with(".db") || name.ends_with(".db-wal")) {
            let _ = std::fs::copy(e.path(), to.join(&name));
        }
    }
}

fn d3dmetal_available(cfg: &Config) -> bool {
    crossover_root(cfg).is_some_and(|r| r.join("lib64/apple_gptk/external/D3DMetal.framework").exists())
}

pub fn bottle_path(b: &BottleConfig) -> PathBuf {
    home().join("Library/Application Support/CrossOver/Bottles").join(&b.name)
}

fn bottle_exists(b: &BottleConfig) -> bool {
    bottle_path(b).join("drive_c").exists()
}

fn crossover_version(cfg: &Config) -> Option<String> {
    let root = crossover_root(cfg)?;
    let plist = root.parent()?.parent()?.join("Info.plist");
    let out = Command::new("/usr/bin/defaults")
        .arg("read")
        .arg(plist)
        .arg("CFBundleShortVersionString")
        .output()
        .ok()?;
    Some(String::from_utf8_lossy(&out.stdout).trim().to_string()).filter(|s| !s.is_empty())
}

pub fn info(cfg: &Config) -> WineInfo {
    let rosetta = Command::new("/usr/bin/arch")
        .args(["-x86_64", "/usr/bin/true"])
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .status()
        .map(|s| s.success())
        .unwrap_or(false);
    let bottle = bottle_path(&cfg.bottle);
    WineInfo {
        crossover_found: crossover_root(cfg).is_some(),
        crossover_version: crossover_version(cfg),
        runner: cfg.runner,
        runner_name: match cfg.runner {
            RunnerKind::Bundled => runner::RUNNER_NAME.to_string(),
            RunnerKind::Crossover => format!("CrossOver {}", crossover_version(cfg).unwrap_or_default()),
        },
        runner_installed: match cfg.runner {
            RunnerKind::Bundled => runner::installed(),
            RunnerKind::Crossover => crossover_root(cfg).is_some(),
        },
        rosetta,
        bottle_exists: bottle_exists(&cfg.bottle),
        bottle_path: bottle.to_string_lossy().into_owned(),
        game_running: game_running(),
    }
}

// wine shows the windows command line for its processes, so only count those and skip
// the crossover wrapper and steam shim which carry the exe path as an argument
pub fn game_running() -> bool {
    let Ok(out) = Command::new("/bin/ps").args(["-axo", "args="]).output() else { return false };
    String::from_utf8_lossy(&out.stdout).lines().any(|l| {
        let l = l.trim_start();
        l.len() > 3
            && l.as_bytes()[1] == b':'
            && l.as_bytes()[2] == b'\\'
            && l.split_whitespace().next().is_some_and(|exe| exe.ends_with(EXECUTABLE))
    })
}

fn process_lines() -> Vec<String> {
    let Ok(out) = Command::new("/bin/ps").args(["-axo", "args="]).output() else { return Vec::new() };
    String::from_utf8_lossy(&out.stdout).lines().map(|l| l.trim_start().to_string()).collect()
}

fn template(b: &BottleConfig) -> &'static str {
    match b.windows_version.as_str() {
        "win11" => "win11_64",
        _ => "win10_64",
    }
}

// environment shared by the bottle config and the launch command
fn bottle_env(b: &BottleConfig) -> Vec<(String, String)> {
    let mut env = vec![("CX_GRAPHICS_BACKEND".to_string(), b.graphics_backend.as_str().to_string())];
    if b.msync && b.graphics_backend != GraphicsBackend::Dxvk {
        env.push(("WINEMSYNC".into(), "1".into()));
    }
    if b.metal_hud {
        env.push(("MTL_HUD_ENABLED".into(), "1".into()));
    }
    let d3dmetal = b.graphics_backend == GraphicsBackend::D3dmetal;
    // d3dmetal runs dlss through metalfx, so dlss needs it on too
    if (b.metalfx || b.dlss) && d3dmetal {
        env.push(("D3DM_ENABLE_METALFX".into(), "1".into()));
    }
    if b.raytracing && d3dmetal {
        env.push(("D3DM_SUPPORT_DXR".into(), "1".into()));
    }
    // d3dmetal names the gpu "AMD Compatibility Mode", which zzz does not recognize, so it hides its
    // super resolution and ray tracing settings. an rtx name gets them shown
    if (b.dlss || b.raytracing) && d3dmetal {
        env.push(("D3DM_DEVICE_ID".into(), "0x2684".into()));
        env.push(("D3DM_DEVICE_DESCRIPTION".into(), "NVIDIA GeForce RTX 4090".into()));
    }
    if b.dlss {
        env.push(("DXMT_ENABLE_NVEXT".into(), "1".into()));
    }
    if !b.dll_overrides.trim().is_empty() {
        env.push(("WINEDLLOVERRIDES".into(), b.dll_overrides.trim().to_string()));
    }
    for (k, v) in &b.env {
        if !k.trim().is_empty() {
            env.push((k.trim().to_string(), v.clone()));
        }
    }
    env
}

// rewrites our block inside [EnvironmentVariables] so the crossover gui reflects the same settings
fn write_bottle_env(b: &BottleConfig) -> Result<()> {
    let conf = bottle_path(b).join("cxbottle.conf");
    let Ok(text) = std::fs::read_to_string(&conf) else { return Ok(()) };
    let env = bottle_env(b);
    let user_keys: Vec<&str> = env.iter().map(|(k, _)| k.as_str()).collect();
    let mut out = Vec::new();
    let mut in_section = false;
    let mut in_block = false;
    let mut wrote = false;
    let block: Vec<String> = std::iter::once(ENV_BEGIN.to_string())
        .chain(env.iter().map(|(k, v)| format!("\"{}\" = \"{}\"", k, v.replace('"', "\\\""))))
        .chain(std::iter::once(ENV_END.to_string()))
        .collect();
    for line in text.lines() {
        let t = line.trim();
        if t == ENV_BEGIN {
            in_block = true;
            continue;
        }
        if t == ENV_END {
            in_block = false;
            continue;
        }
        if in_block {
            continue;
        }
        if t.starts_with('[') {
            in_section = t == "[EnvironmentVariables]";
            out.push(line.to_string());
            if in_section && !wrote {
                out.extend(block.iter().cloned());
                wrote = true;
            }
            continue;
        }
        if in_section {
            let key = t.strip_prefix('"').and_then(|r| r.split('"').next()).unwrap_or("");
            if MANAGED_KEYS.contains(&key) || user_keys.contains(&key) {
                continue;
            }
        }
        out.push(line.to_string());
    }
    if !wrote {
        out.push("[EnvironmentVariables]".into());
        out.extend(block);
    }
    std::fs::write(conf, out.join("\n") + "\n")?;
    Ok(())
}

fn run_logged(task: &Task, mut c: Command, what: &str) -> Result<()> {
    let out = c.output()?;
    if !out.status.success() {
        task.log(String::from_utf8_lossy(&out.stderr).to_string());
        return err(format!("{} failed ({})", what, out.status));
    }
    Ok(())
}

// crossover's cxbottle is used when available so the bottle shows up in the crossover app,
// otherwise the bundled runner initialises a plain prefix at the same location
pub fn create_bottle(task: &Task, cfg: &Config) -> Result<()> {
    let b = &cfg.bottle;
    if bottle_exists(b) {
        task.status("Bottle already exists, applying settings");
    } else if let Some(root) = crossover_root(cfg) {
        task.status(format!("Creating CrossOver bottle \"{}\"", b.name));
        task.progress(None, "This can take a minute");
        let mut c = Command::new(root.join("bin/cxbottle"));
        c.arg("--bottle")
            .arg(&b.name)
            .arg("--create")
            .arg("--template")
            .arg(template(b))
            .arg("--description")
            .arg("Zenless Zone Zero (managed by Asahiro)");
        run_logged(task, c, "bottle creation")?;
    } else {
        let rn = Runner::resolve(cfg, Some(task))?;
        task.status(format!("Creating bottle \"{}\"", b.name));
        task.progress(None, "This can take a minute");
        std::fs::create_dir_all(bottle_path(b))?;
        let mut c = rn.wine(cfg, None);
        c.arg("wineboot").arg("-u");
        run_logged(task, c, "bottle creation")?;
    }
    apply_bottle(task, cfg)
}

pub fn delete_bottle(cfg: &Config) -> Result<()> {
    let b = &cfg.bottle;
    if let Some(root) = crossover_root(cfg).filter(|_| bottle_path(b).join("cxbottle.conf").exists()) {
        let out = Command::new(root.join("bin/cxbottle"))
            .arg("--bottle")
            .arg(&b.name)
            .args(["--delete", "--force"])
            .output()?;
        if !out.status.success() {
            return err(String::from_utf8_lossy(&out.stderr).to_string());
        }
    } else if bottle_exists(b) {
        std::fs::remove_dir_all(bottle_path(b))?;
    }
    Ok(())
}

// zzz stores webview render experiments in the registry which break the in-game browser under wine
fn webview_fix_lines(bottle: &Path) -> Vec<String> {
    let key = "HKEY_CURRENT_USER\\Software\\miHoYo\\ZenlessZoneZero";
    let mut lines = vec![format!("reg delete \"{}\" /v MIHOYOSDK_WEBVIEW_RENDER_METHOD_h1573598267 /f >nul 2>&1", key)];
    if let Ok(bytes) = std::fs::read(bottle.join("user.reg")) {
        let text = String::from_utf8_lossy(&bytes);
        for l in text.lines() {
            if let Some(rest) = l.strip_prefix("\"HOYO_WEBVIEW_RENDER_METHOD_ABTEST_") {
                if let Some(name) = rest.split('"').next() {
                    lines.push(format!(
                        "reg delete \"{}\" /v HOYO_WEBVIEW_RENDER_METHOD_ABTEST_{} /f >nul 2>&1",
                        key, name
                    ));
                }
            }
        }
    }
    lines
}

// reads user.reg directly, the wineserver is not running between launches so the file is what wine will load
fn registry_current(bottle: &Path, b: &BottleConfig) -> bool {
    let Ok(bytes) = std::fs::read(bottle.join("user.reg")) else { return false };
    let text = String::from_utf8_lossy(&bytes);
    if text.contains("\"MIHOYOSDK_WEBVIEW_RENDER_METHOD_h1573598267\"") || text.contains("\"HOYO_WEBVIEW_RENDER_METHOD_ABTEST_") {
        return false;
    }
    let mut section = false;
    let mut values = std::collections::HashMap::new();
    for l in text.lines() {
        if l.starts_with('[') {
            section = l.starts_with("[Software\\\\Wine\\\\Mac Driver]");
        } else if section {
            if let Some((k, v)) = l.split_once('=') {
                values.insert(k.trim_matches('"').to_string(), v.trim_matches('"').to_string());
            }
        }
    }
    let yn = |v: bool| if v { "y" } else { "n" };
    [
        ("RetinaMode", b.retina),
        ("LeftCommandIsCtrl", b.left_cmd_is_ctrl),
        ("LeftOptionIsAlt", b.left_option_is_alt),
        ("RightOptionIsAlt", b.right_option_is_alt),
    ]
    .iter()
    .all(|(k, v)| values.get(*k).map(String::as_str) == Some(yn(*v)))
}

// writes registry tweaks through a batch file so the bottle only boots once
pub fn apply_bottle(task: &Task, cfg: &Config) -> Result<()> {
    let b = &cfg.bottle;
    let bottle = bottle_path(b);
    if !bottle_exists(b) {
        return err("the bottle does not exist yet");
    }
    let rn = Runner::resolve(cfg, Some(task))?;
    task.status("Configuring bottle");
    write_bottle_env(b)?;
    let marker = bottle.join(".asahiro-winver");
    let winver_current = std::fs::read_to_string(&marker).ok().as_deref() == Some(b.windows_version.as_str());
    // booting wine for the batch file costs seconds on every launch, skip it when the registry already matches
    if winver_current && registry_current(&bottle, b) {
        return Ok(());
    }
    let yn = |v: bool| if v { "y" } else { "n" };
    let mut bat = vec![
        "@echo off".to_string(),
        format!("reg add \"HKEY_CURRENT_USER\\Software\\Wine\\Mac Driver\" /v RetinaMode /t REG_SZ /d {} /f >nul", yn(b.retina)),
        format!(
            "reg add \"HKEY_CURRENT_USER\\Software\\Wine\\Mac Driver\" /v LeftCommandIsCtrl /t REG_SZ /d {} /f >nul",
            yn(b.left_cmd_is_ctrl)
        ),
        // games and mod hotkeys expect alt, macos would otherwise turn option into a dead key
        format!(
            "reg add \"HKEY_CURRENT_USER\\Software\\Wine\\Mac Driver\" /v LeftOptionIsAlt /t REG_SZ /d {} /f >nul",
            yn(b.left_option_is_alt)
        ),
        format!(
            "reg add \"HKEY_CURRENT_USER\\Software\\Wine\\Mac Driver\" /v RightOptionIsAlt /t REG_SZ /d {} /f >nul",
            yn(b.right_option_is_alt)
        ),
    ];
    bat.extend(webview_fix_lines(&bottle));
    // a missing value makes reg delete fail, which is expected
    bat.push("exit /b 0".into());
    let bat_path = bottle.join("drive_c/asahiro-setup.bat");
    std::fs::write(&bat_path, bat.join("\r\n") + "\r\n")?;
    let mut c = rn.wine(cfg, None);
    c.arg("cmd").arg("/c").arg("C:\\asahiro-setup.bat");
    run_logged(task, c, "bottle configuration")?;
    let _ = std::fs::remove_file(bat_path);

    if !winver_current {
        let mut c = rn.wine(cfg, None);
        c.arg("winecfg").arg("-v").arg(&b.windows_version);
        run_logged(task, c, "setting the windows version")?;
        std::fs::write(marker, &b.windows_version)?;
    }
    Ok(())
}

fn vulkan_dll(game_dir: &Path) -> PathBuf {
    game_dir.join(DATA_DIR).join("Plugins/x86_64/vulkan-1.dll")
}

// yaagl hides the bundled vulkan loader while the game runs since it breaks under wine on macos
pub fn hide_vulkan(game_dir: &Path) {
    let dll = vulkan_dll(game_dir);
    if dll.exists() {
        let _ = std::fs::rename(&dll, dll.with_extension("dll.bak"));
    }
}

pub fn restore_vulkan(game_dir: &Path) {
    let dll = vulkan_dll(game_dir);
    let bak = dll.with_extension("dll.bak");
    if bak.exists() && !dll.exists() {
        let _ = std::fs::rename(bak, dll);
    }
}

fn launch_args(cfg: &Config) -> Vec<String> {
    let mut args = Vec::new();
    if cfg.custom_resolution {
        args.extend([
            "-screen-width".to_string(),
            cfg.resolution_width.to_string(),
            "-screen-height".to_string(),
            cfg.resolution_height.to_string(),
            "-screen-fullscreen".to_string(),
            if cfg.fullscreen { "1" } else { "0" }.to_string(),
        ]);
    }
    if cfg.use_d3d12 && cfg.bottle.graphics_backend == GraphicsBackend::D3dmetal {
        args.push("-use-d3d12".into());
    }
    args.extend(cfg.launch_args.split_whitespace().map(String::from));
    args
}

// dxmt paces presents itself, d3dmetal gets the same from our hooks swapping in presentDrawable:afterMinimumDuration:.
// the hooks also put the game bundle's icon in the dock and can move the game into a macos fullscreen space. crossover's wine is a perl script, and macos strips DYLD_ variables
// from system binaries, so they only load on the bundled runner
fn apply_hooks(task: &Task, cfg: &Config, rn: &Runner, c: &mut Command) {
    let b = &cfg.bottle;
    if cfg.frame_cap > 0 && b.graphics_backend == GraphicsBackend::Dxmt && !b.env.contains_key("DXMT_CONFIG") {
        c.env("DXMT_CONFIG", format!("d3d11.preferredMaxFrameRate={}", cfg.frame_cap));
    }
    if !matches!(rn, Runner::Bundled(_)) {
        return;
    }
    let pace = cfg.frame_cap > 0 && b.graphics_backend == GraphicsBackend::D3dmetal;
    let icon = runner::game_app_icon();
    if !pace && icon.is_none() && !cfg.native_fullscreen {
        return;
    }
    let p = match runner::hooks_path() {
        Ok(p) => p,
        Err(e) => return task.log(format!("hooks skipped: {}", e)),
    };
    let mut libs = p.to_string_lossy().into_owned();
    if let Some(user) = b.env.get("DYLD_INSERT_LIBRARIES").filter(|v| !v.trim().is_empty()) {
        libs = format!("{}:{}", libs, user.trim());
    }
    c.env("DYLD_INSERT_LIBRARIES", libs);
    if pace {
        c.env("ASAHIRO_FRAME_CAP", cfg.frame_cap.to_string());
    }
    if let Some(icon) = icon {
        c.env("ASAHIRO_DOCK_ICON", icon);
    }
    if cfg.native_fullscreen {
        c.env("ASAHIRO_NATIVE_FULLSCREEN", "1");
    }
}

// zzmi needs native d3d11 so the 3dmigoto dll loaded by path is not swapped for the builtin one
fn dll_overrides(cfg: &Config, mods: bool) -> Option<String> {
    let user = cfg.bottle.dll_overrides.trim();
    let mut parts: Vec<String> = user.split(';').map(str::trim).filter(|p| !p.is_empty()).map(String::from).collect();
    if mods && !parts.iter().any(|p| p.split('=').next().is_some_and(|k| k.split(',').any(|d| d.trim() == "d3d11"))) {
        parts.push("d3d11=n,b".into());
    }
    (!parts.is_empty()).then(|| parts.join(";"))
}

fn windows_path(p: &Path) -> String {
    format!("Z:{}", p.to_string_lossy().replace('/', "\\"))
}

pub fn launch(task: &Task, cfg: &Config) -> Result<()> {
    // 3dmigoto hooks d3d11 in ways d3dmetal does not handle well, so modded launches always use dxmt,
    // as do launches where crossover (and with it d3dmetal) has gone missing
    let mut cfg = cfg.clone();
    if cfg.bottle.graphics_backend == GraphicsBackend::D3dmetal {
        let reason = if cfg.mods_enabled {
            Some("mods are enabled")
        } else if !d3dmetal_available(&cfg) {
            Some("D3DMetal was not found in CrossOver")
        } else {
            None
        };
        if let Some(r) = reason {
            task.log(format!("{}, using DXMT instead of D3DMetal for this launch", r));
            cfg.bottle.graphics_backend = GraphicsBackend::Dxmt;
        }
    }
    let cfg = &cfg;
    let dir = cfg.game_path();
    if game::installed_version(&dir).is_none() {
        return err("the game is not installed");
    }
    if game_running() {
        return err("the game is already running");
    }
    let rn = Runner::resolve(cfg, Some(task))?;
    let bottle = bottle_path(&cfg.bottle);
    if !bottle_exists(&cfg.bottle) {
        create_bottle(task, cfg)?;
    } else {
        apply_bottle(task, cfg)?;
    }

    task.status("Preparing game files");
    if let Runner::Bundled(_) = rn {
        // the bundled runner carries dxmt, d3dmetal is borrowed from crossover, dxvk falls back to wine's own d3d
        let graphics = match cfg.bottle.graphics_backend {
            GraphicsBackend::Dxmt => runner::Graphics::Dxmt,
            GraphicsBackend::D3dmetal => runner::Graphics::D3dmetal,
            _ => runner::Graphics::Builtin,
        };
        let gptk = crossover_root(cfg).map(|r| r.join("lib64/apple_gptk"));
        runner::select_graphics(task, graphics, gptk.as_deref(), &bottle)?;
        if let Err(e) = runner::ensure_game_app() {
            task.log(format!("game mode bundle skipped: {}", e));
        }
    }
    let protect = dir.join("HoYoKProtect.sys");
    if protect.exists() {
        let sys32 = bottle.join("drive_c/windows/system32");
        std::fs::create_dir_all(&sys32)?;
        runner::copy_if_changed(&protect, &sys32.join("HoYoKProtect.sys"))?;
    }
    hide_vulkan(&dir);
    let mods = cfg.mods_enabled;
    if mods {
        task.status("Preparing ZZMI");
        if let Err(e) = crate::mods::update_if_needed(task, cfg) {
            if !crate::mods::installed() {
                restore_vulkan(&dir);
                return Err(e);
            }
            task.log(format!("zzmi update skipped: {}", e));
        }
        crate::mods::prepare(cfg)?;
    }
    if cfg.launch_fix {
        task.status("Applying launch fix");
        if let Err(e) = launch_fix() {
            task.log(format!("launch fix skipped: {}", e));
        }
    }

    let log_path = logs_dir().join(format!(
        "game-{}.log",
        std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).map(|d| d.as_secs()).unwrap_or(0)
    ));
    let log = std::fs::File::create(&log_path)?;
    rn.wait_idle(cfg);
    let mut c = rn.wine(cfg, Some(&dir));
    apply_hooks(task, cfg, &rn, &mut c);
    // d3dmetal's d3d12 path corrupts unity's glyph atlas now and then, keeping resources alive until the gpu is done fixes it
    if cfg.use_d3d12 && cfg.bottle.graphics_backend == GraphicsBackend::D3dmetal && !cfg.bottle.env.contains_key("D3DM_RETAIN_REFERENCES") {
        c.env("D3DM_RETAIN_REFERENCES", "1");
    }
    if let Some(o) = dll_overrides(cfg, mods) {
        rn.dll_overrides(&mut c, &o);
    }
    if cfg.steam_patch {
        install_steam_shim(task, &bottle)?;
        c.arg("C:\\windows\\system32\\steam.exe");
    }
    c.arg(windows_path(&dir.join(EXECUTABLE)));
    c.args(launch_args(cfg));
    c.stdout(log.try_clone()?).stderr(log);
    task.log(format!("log: {}", log_path.display()));
    task.status("Starting Zenless Zone Zero");
    task.progress(None, "");

    let result = (|| -> Result<()> {
        let mut child = c.spawn()?;
        let mut announced = false;
        let mut injector: Option<std::process::Child> = None;
        // 3dmigoto has to be in the game before it creates its d3d device, which 3.3 does almost at once.
        // wine only renames its processes to their windows command line after a while, so instead of
        // waiting for the game to show up the hook goes up as soon as our launch has booted the wineserver.
        // the setup commands' server is gone by now (wait_idle), so this one belongs to the steam shim,
        // which keeps the game part of the launch that starts the server, as the anti-cheat requires
        if mods {
            // wine starts it as <root>/lib/wine/../../bin/wineserver, so match on the runner's root
            let server = rn.wineserver();
            let root = server.parent().and_then(|p| p.parent()).map(|p| p.to_string_lossy().into_owned()).unwrap_or_default();
            let ready = || process_lines().iter().any(|l| {
                let first = l.split_whitespace().next().unwrap_or("");
                (l.starts_with(&root) && l.trim_end().ends_with("wineserver"))
                    || first.ends_with(EXECUTABLE)
                    || first.eq_ignore_ascii_case("C:\\windows\\system32\\steam.exe")
            });
            let deadline = std::time::Instant::now() + Duration::from_secs(90);
            while !ready() && std::time::Instant::now() < deadline && child.try_wait()?.is_none() && !task.cancelled() {
                std::thread::sleep(Duration::from_millis(10));
            }
            // let the shim register as the server's first client before the injector connects
            std::thread::sleep(Duration::from_millis(250));
            if child.try_wait()?.is_none() {
                injector = start_injector(task, &rn, cfg).map_err(|e| task.log(format!("zzmi injector: {}", e))).ok();
            }
        }
        // wine returns once the exe exits, but the game can hand off to a child so also watch the process table
        loop {
            if task.cancelled() {
                stop_game(cfg);
            }
            if !announced && game_running() {
                announced = true;
                task.event(json!({ "type": "game_started" }));
                task.status("Playing");
            }
            if let Some(status) = child.try_wait()? {
                if !game_running() {
                    if !announced && !status.success() {
                        return err(format!("the game exited early ({}). see {}", status, log_path.display()));
                    }
                    break;
                }
            }
            std::thread::sleep(Duration::from_millis(500));
        }
        // the helper exits on its own after injecting, this only reaps it or stops a stuck one
        if let Some(mut helper) = injector {
            let _ = helper.kill();
            let _ = helper.wait();
        }
        Ok(())
    })();
    restore_vulkan(&dir);
    result?;
    task.status("Game closed");
    Ok(())
}

// starts the hook right after the game appears, it injects before the game creates its window and device
fn start_injector(task: &Task, rn: &Runner, cfg: &Config) -> Result<std::process::Child> {
    use std::io::BufRead;
    let zzmi = crate::mods::zzmi_dir();
    let mut c = rn.wine(cfg, None);
    if let Some(o) = dll_overrides(cfg, true) {
        rn.dll_overrides(&mut c, &o);
    }
    c.arg(windows_path(&zzmi.join(crate::mods::HELPER_NAME)))
        .arg(windows_path(&zzmi.join("3dmloader.dll")))
        .arg(windows_path(&zzmi.join("d3d11.dll")))
        .arg(EXECUTABLE)
        .arg("30")
        .stdout(Stdio::piped())
        .stderr(Stdio::null());
    task.log("zzmi injector: starting");
    let mut child = c.spawn()?;
    let out = child.stdout.take().ok_or("injector has no stdout")?;
    let task = task.clone();
    std::thread::spawn(move || {
        for line in std::io::BufReader::new(out).lines().map_while(|l| l.ok()) {
            let line = line.trim().to_string();
            if !line.is_empty() {
                task.log(format!("zzmi injector: {}", line));
            }
            match line.as_str() {
                "injected" => task.event(json!({ "type": "mods_injected", "ok": true })),
                "inject_timeout" => task.event(json!({ "type": "mods_injected", "ok": false })),
                l if l.starts_with("error") => {
                    task.log(format!("zzmi injector {}", l));
                    task.event(json!({ "type": "mods_injected", "ok": false, "error": l }));
                }
                _ => {}
            }
        }
    });
    Ok(child)
}

// proton's steam.exe makes the client take the steam channel path, which skips loading HoYoKProtect.sys.
// wine can not load that driver (WDFLDR.SYS is missing) and the anti-cheat then aborts (yaagl issue 734)
const STEAM_SHIM_BASE: &str =
    "https://raw.githubusercontent.com/yaagl/yet-another-anime-game-launcher/784dda385c536286ef75f92e990514ac81509784/sidecar/protonextras";
const STEAM_SHIM: [(&str, &str, &str); 4] = [
    ("steam64.exe", "system32/steam.exe", "0424339444c54bf1f9fdbadf12e4e2c90ceef41d987fe573b93f5f2ebfd8a657"),
    ("steam32.exe", "syswow64/steam.exe", "d3b17fda25217165f5f5198ac179bb0645d4fcc61381bfeb0ba3c73ea029a433"),
    ("lsteamclient64.dll", "system32/lsteamclient.dll", "af50ed0d952ef98d99d4d3ff67b4836b545c9403894430fca31969f9f630637b"),
    ("lsteamclient32.dll", "syswow64/lsteamclient.dll", "608eece6672369db539211fd04eb95b9fb5ddd077e76aa87c28c04c25c1e2fe2"),
];

fn install_steam_shim(task: &Task, bottle: &Path) -> Result<()> {
    let cache = crate::util::data_dir().join("tools/protonextras");
    for (name, dest, sum) in STEAM_SHIM {
        let local = cache.join(name);
        if runner::sha256_file(&local).as_deref() != Some(sum) {
            task.status("Downloading Steam compatibility shim");
            crate::download::fetch_simple(task, &format!("{}/{}", STEAM_SHIM_BASE, name), &local)?;
            if runner::sha256_file(&local).as_deref() != Some(sum) {
                let _ = std::fs::remove_file(&local);
                return err(format!("{} failed checksum verification", name));
            }
        }
        let target = bottle.join("drive_c/windows").join(dest);
        if runner::sha256_file(&target).as_deref() != Some(sum) {
            if let Some(p) = target.parent() {
                std::fs::create_dir_all(p)?;
            }
            std::fs::copy(&local, &target)?;
        }
    }
    Ok(())
}

// blocks the host for a short window through an admin prompt, a detached root script removes it again
fn launch_fix() -> Result<()> {
    let entry = format!("0.0.0.0 {}", LAUNCH_FIX_HOST);
    let has_entry = || std::fs::read_to_string("/etc/hosts").map(|h| h.lines().any(|l| l.trim() == entry)).unwrap_or(false);
    if has_entry() {
        return Ok(());
    }
    let script = crate::util::data_dir().join("launch-fix.sh");
    let body = [
        "#!/bin/sh".to_string(),
        "H=/etc/hosts".to_string(),
        format!("printf '\\n# asahiro launch fix\\n{}\\n# asahiro end\\n' >> $H", entry),
        "dscacheutil -flushcache; killall -HUP mDNSResponder".to_string(),
        format!("sleep {}", LAUNCH_FIX_SECONDS),
        "sed -i '' '/# asahiro launch fix/,/# asahiro end/d' $H".to_string(),
        "dscacheutil -flushcache; killall -HUP mDNSResponder".to_string(),
    ];
    std::fs::write(&script, body.join("\n") + "\n")?;
    let apple = format!(
        "do shell script \"/bin/sh '{}' > /dev/null 2>&1 &\" with prompt \"Asahiro needs to briefly block one HoYoverse host so the game can start.\" with administrator privileges",
        script.display()
    );
    let out = Command::new("/usr/bin/osascript").arg("-e").arg(apple).output()?;
    if !out.status.success() {
        return err(String::from_utf8_lossy(&out.stderr).trim().to_string());
    }
    // the root script runs detached, wait until the entry is live before starting the game
    for _ in 0..50 {
        if has_entry() {
            return Ok(());
        }
        std::thread::sleep(Duration::from_millis(100));
    }
    err("hosts entry did not appear")
}

pub fn stop_game(cfg: &Config) {
    if let Ok(rn) = Runner::resolve(cfg, None) {
        let _ = Command::new(rn.wineserver()).env("WINEPREFIX", bottle_path(&cfg.bottle)).arg("-k").status();
    }
}

pub fn open_tool(cfg: &Config, tool: &str) -> Result<()> {
    let allowed = ["winecfg", "regedit", "taskmgr", "explorer", "control"];
    if !allowed.contains(&tool) {
        return err(format!("unknown tool {}", tool));
    }
    if !bottle_exists(&cfg.bottle) {
        return err("create the bottle first");
    }
    let rn = Runner::resolve(cfg, None)?;
    let mut c = rn.wine(cfg, None);
    c.arg(tool).stdout(Stdio::null()).stderr(Stdio::null());
    c.spawn()?;
    Ok(())
}
