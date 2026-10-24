use std::path::{Path, PathBuf};
use std::process::Command;

use crate::download::{fetch, Meter};
use crate::util::{data_dir, err, Result, Task};

// crossover's open source wine tree built by the yaagl project, it gets the game past the
// anti-cheat where the wine inside crossover 26 does not
pub const RUNNER_NAME: &str = "CrossOver 11.0-1";
const RUNNER_ID: &str = "wine-crossover-11.0-1";
const RUNNER_URL: &str = "https://github.com/yaagl/anime-game-wine/releases/download/wine-crossover-11.0-1-signed/wine-crossover-11.0-1-osx64-signed.tar.xz";
const RUNNER_SHA256: &str = "89fa7e90fb626523a90d5867a03c6be785d017176739c6320a3b86c7838c3a35";
const RUNNER_SIZE: u64 = 456021524;

const DXMT_ID: &str = "dxmt-654f547";
const DXMT_URL: &str = "https://github.com/yaagl/anime-game-wine/releases/download/dxmt-654f547/dxmt-654f547ffab4e0c395ee368aad52bb4586b04576.zip";
const DXMT_SHA256: &str = "fbc0721fb72ebafd2bad0dbdd3d13a52056fd10c4a9a699cee2689363823255b";
const DXMT_SIZE: u64 = 32603639;

const ADDED_LIST: &str = ".asahiro-added";
const ACTIVE_GRAPHICS: &str = ".asahiro-graphics";

// d3dmetal is apple's and only ships inside crossover, so it is copied from the user's install.
// libd3dshared and the framework sit next to the unix libraries, which find them through @loader_path
const GPTK_FILES: [(&str, &str); 3] = [
    ("wine/x86_64-windows", "x86_64-windows"),
    ("wine/x86_64-unix", "x86_64-unix"),
    ("external", "x86_64-unix"),
];
pub const LIBD3DSHARED: &str = "lib/wine/x86_64-unix/libd3dshared.dylib";

#[derive(Clone, Copy, PartialEq, Eq)]
pub enum Graphics {
    Builtin,
    Dxmt,
    D3dmetal,
}

impl Graphics {
    fn name(self) -> &'static str {
        match self {
            Graphics::Builtin => "builtin",
            Graphics::Dxmt => "dxmt",
            Graphics::D3dmetal => "d3dmetal",
        }
    }
}

pub fn runners_dir() -> PathBuf {
    let p = data_dir().join("runners");
    let _ = std::fs::create_dir_all(&p);
    p
}

pub fn runner_dir() -> PathBuf {
    runners_dir().join(RUNNER_ID)
}

fn dxmt_dir() -> PathBuf {
    runners_dir().join(DXMT_ID)
}

pub fn installed() -> bool {
    runner_dir().join("bin/wine").exists() && runner_dir().join(".asahiro-ok").exists()
}

pub fn d3dshared_path() -> PathBuf {
    runner_dir().join(LIBD3DSHARED)
}

// copies only when the bytes differ. rewriting an identical library still makes macOS re-validate it
// and rosetta re-translate it on the next load, which delays the game enough that 3dmigoto misses
// the d3d device on that launch
pub fn copy_if_changed(from: &Path, to: &Path) -> std::io::Result<()> {
    if let (Ok(a), Ok(b)) = (std::fs::metadata(from), std::fs::metadata(to)) {
        if a.len() == b.len() && std::fs::read(from)? == std::fs::read(to)? {
            return Ok(());
        }
    }
    std::fs::copy(from, to).map(|_| ())
}

pub fn sha256_file(p: &Path) -> Option<String> {
    use sha2::{Digest, Sha256};
    use std::io::Read;
    let mut f = std::fs::File::open(p).ok()?;
    let mut h = Sha256::new();
    let mut buf = vec![0u8; 4 << 20];
    loop {
        let n = f.read(&mut buf).ok()?;
        if n == 0 {
            break;
        }
        h.update(&buf[..n]);
    }
    Some(hex::encode(h.finalize()))
}

fn download_verified(task: &Task, label: &str, url: &str, size: u64, sha: &str, dest: &Path) -> Result<()> {
    let mut meter = Meter::new(task, label, size);
    fetch(&mut meter, url, dest, size, "")?;
    task.status(format!("Verifying {}", label.to_lowercase()));
    task.progress(None, "");
    if sha256_file(dest).as_deref() != Some(sha) {
        crate::download::remove(dest);
        return err(format!("{} failed checksum verification", label));
    }
    Ok(())
}

fn run(mut c: Command, what: &str) -> Result<()> {
    let out = c.output()?;
    if !out.status.success() {
        return err(format!("{} failed: {}", what, String::from_utf8_lossy(&out.stderr).trim()));
    }
    Ok(())
}

// finds the directory holding bin/wine inside an extracted archive
fn find_wine_root(dir: &Path, depth: u32) -> Option<PathBuf> {
    if dir.join("bin/wine").exists() {
        return Some(dir.to_path_buf());
    }
    if depth == 0 {
        return None;
    }
    std::fs::read_dir(dir).ok()?.filter_map(|e| e.ok()).filter(|e| e.path().is_dir()).find_map(|e| find_wine_root(&e.path(), depth - 1))
}

pub fn ensure(task: &Task) -> Result<PathBuf> {
    if installed() {
        return Ok(runner_dir());
    }
    let archive = runners_dir().join(format!("{}.tar.xz", RUNNER_ID));
    task.status(format!("Downloading the {} runner", RUNNER_NAME));
    download_verified(task, "Wine runner", RUNNER_URL, RUNNER_SIZE, RUNNER_SHA256, &archive)?;

    task.status("Extracting the wine runner");
    task.progress(None, "");
    let staging = runners_dir().join(format!("{}.staging", RUNNER_ID));
    let _ = std::fs::remove_dir_all(&staging);
    std::fs::create_dir_all(&staging)?;
    let mut c = Command::new("/usr/bin/tar");
    c.arg("-xJf").arg(&archive).arg("-C").arg(&staging);
    run(c, "extracting the runner")?;
    let Some(root) = find_wine_root(&staging, 4) else {
        return err("the runner archive has an unexpected layout");
    };
    let _ = std::fs::remove_dir_all(runner_dir());
    std::fs::rename(&root, runner_dir())?;
    let _ = std::fs::remove_dir_all(&staging);
    crate::download::remove(&archive);
    std::fs::write(runner_dir().join(".asahiro-ok"), RUNNER_SHA256)?;
    Ok(runner_dir())
}

const GAME_APP: &str = "Zenless Zone Zero.app";
const GAME_BUNDLE_ID: &str = "com.chair.asahiro.game";
const LOADER: &str = "lib/wine/x86_64-unix/wine";

// macos only applies game mode to the main executable of a bundle with a games category, the plist
// embedded in the loader is ignored. every wine process runs this loader, so it moves into a small app
// and its old path becomes a symlink, which the kernel resolves so the process path ends up in the bundle
pub fn ensure_game_app() -> Result<()> {
    let loader = runner_dir().join(LOADER);
    let app = runner_dir().join(GAME_APP);
    let exe = app.join("Contents/MacOS/wine");
    let plist = format!(
        r#"<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key><string>wine</string>
    <key>CFBundleIdentifier</key><string>{}</string>
    <key>CFBundleName</key><string>Zenless Zone Zero</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
    <key>LSApplicationCategoryType</key><string>public.app-category.games</string>
    <key>LSSupportsGameMode</key><true/>
    <key>LSUIElement</key><true/>
    <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
"#,
        GAME_BUNDLE_ID
    );
    let plist_path = app.join("Contents/Info.plist");
    let linked = std::fs::read_link(&loader).ok().as_deref() == Some(exe.as_path());
    if linked && exe.exists() && std::fs::read_to_string(&plist_path).ok().as_deref() == Some(plist.as_str()) {
        return Ok(());
    }
    std::fs::create_dir_all(exe.parent().ok_or("bad bundle path")?)?;
    if !linked {
        if !loader.is_file() {
            return err("the runner's wine loader is missing");
        }
        std::fs::rename(&loader, &exe)?;
    }
    std::fs::write(&plist_path, plist)?;
    // the loader looks for ntdll next to wherever it runs from
    let ntdll = exe.with_file_name("ntdll.so");
    let _ = std::fs::remove_file(&ntdll);
    std::os::unix::fs::symlink(runner_dir().join("lib/wine/x86_64-unix/ntdll.so"), &ntdll)?;
    let mut c = Command::new("/usr/bin/codesign");
    c.args(["--sign", "-", "--force"]).arg(&app);
    if let Err(e) = run(c, "signing the game bundle") {
        // leave the runner as it came rather than half moved
        let _ = std::fs::rename(&exe, &loader);
        return Err(e);
    }
    if !linked {
        std::os::unix::fs::symlink(&exe, &loader)?;
    }
    Ok(())
}

fn ensure_dxmt(task: &Task) -> Result<PathBuf> {
    let dir = dxmt_dir();
    if dir.join("x86_64-windows/d3d11.dll").exists() {
        return Ok(dir);
    }
    let zip = runners_dir().join(format!("{}.zip", DXMT_ID));
    task.status("Downloading DXMT");
    download_verified(task, "DXMT", DXMT_URL, DXMT_SIZE, DXMT_SHA256, &zip)?;
    let staging = runners_dir().join(format!("{}.staging", DXMT_ID));
    let _ = std::fs::remove_dir_all(&staging);
    std::fs::create_dir_all(&staging)?;
    let mut c = Command::new("/usr/bin/unzip");
    c.arg("-o").arg("-q").arg(&zip).arg("-d").arg(&staging);
    run(c, "extracting dxmt")?;
    // the zip wraps a tarball holding x86_64-windows and x86_64-unix
    for e in std::fs::read_dir(&staging)?.filter_map(|e| e.ok()) {
        let name = e.file_name().to_string_lossy().into_owned();
        if name.ends_with(".tar.gz") {
            let mut c = Command::new("/usr/bin/tar");
            c.arg("-xzf").arg(e.path()).arg("-C").arg(&staging);
            run(c, "extracting dxmt")?;
        }
    }
    let inner = walk_for(&staging, "x86_64-windows", 3).ok_or("dxmt archive has an unexpected layout")?;
    let parent = inner.parent().ok_or("dxmt archive has an unexpected layout")?.to_path_buf();
    let _ = std::fs::remove_dir_all(&dir);
    std::fs::rename(parent, &dir)?;
    let _ = std::fs::remove_dir_all(&staging);
    crate::download::remove(&zip);
    Ok(dir)
}

fn walk_for(dir: &Path, name: &str, depth: u32) -> Option<PathBuf> {
    let candidate = dir.join(name);
    if candidate.is_dir() {
        return Some(candidate);
    }
    if depth == 0 {
        return None;
    }
    std::fs::read_dir(dir).ok()?.filter_map(|e| e.ok()).filter(|e| e.path().is_dir()).find_map(|e| walk_for(&e.path(), name, depth - 1))
}

// copies a framework or other folder file by file, recreating its symlinks
fn copy_tree_if_changed(from: &Path, to: &Path) -> std::io::Result<()> {
    let meta = std::fs::symlink_metadata(from)?;
    if meta.file_type().is_symlink() {
        let link = std::fs::read_link(from)?;
        if std::fs::read_link(to).ok().as_ref() != Some(&link) {
            let _ = std::fs::remove_file(to);
            std::os::unix::fs::symlink(link, to)?;
        }
    } else if meta.is_dir() {
        std::fs::create_dir_all(to)?;
        for e in std::fs::read_dir(from)?.filter_map(|e| e.ok()) {
            copy_tree_if_changed(&e.path(), &to.join(e.file_name()))?;
        }
    } else {
        copy_if_changed(from, to)?;
    }
    Ok(())
}

// puts the runner's own d3d libraries back and drops everything a layer added
fn restore_builtin(wine_lib: &Path) -> Result<()> {
    for arch in ["x86_64-windows", "x86_64-unix"] {
        let Ok(entries) = std::fs::read_dir(wine_lib.join(arch)) else { continue };
        for e in entries.filter_map(|e| e.ok()) {
            let name = e.file_name().to_string_lossy().into_owned();
            if let Some(base) = name.strip_suffix(".orig") {
                std::fs::rename(e.path(), wine_lib.join(arch).join(base))?;
            }
        }
    }
    let added_path = runner_dir().join(ADDED_LIST);
    for rel in std::fs::read_to_string(&added_path).unwrap_or_default().lines().filter(|l| !l.is_empty()) {
        let p = wine_lib.join(rel);
        if p.is_dir() && !p.is_symlink() {
            let _ = std::fs::remove_dir_all(p);
        } else {
            let _ = std::fs::remove_file(p);
        }
    }
    let _ = std::fs::remove_file(added_path);
    Ok(())
}

// swaps a translation layer in or out of the runner's builtin libraries, keeping the originals beside them.
// switching layers restores the builtins first, staying on one only rewrites files that changed
pub fn select_graphics(task: &Task, want: Graphics, gptk: Option<&Path>, bottle: &Path) -> Result<()> {
    let wine_lib = runner_dir().join("lib/wine");
    let marker = runner_dir().join(ACTIVE_GRAPHICS);
    let added_path = runner_dir().join(ADDED_LIST);
    // installs from before the marker only ever swapped in dxmt
    let active = std::fs::read_to_string(&marker).map(|s| s.trim().to_string()).unwrap_or_else(|_| {
        if added_path.exists() { Graphics::Dxmt } else { Graphics::Builtin }.name().to_string()
    });
    if active != want.name() {
        restore_builtin(&wine_lib)?;
        let _ = std::fs::remove_file(&marker);
    }

    let sources: Vec<(PathBuf, &str)> = match want {
        Graphics::Builtin => return Ok(()),
        Graphics::Dxmt => {
            let src = ensure_dxmt(task)?;
            ["x86_64-windows", "x86_64-unix"].into_iter().map(|a| (src.join(a), a)).collect()
        }
        Graphics::D3dmetal => {
            let Some(g) = gptk.filter(|g| g.join("external/D3DMetal.framework").exists()) else {
                return err("D3DMetal comes from the CrossOver app. Install CrossOver or switch the graphics backend to DXMT.");
            };
            GPTK_FILES.iter().map(|(from, arch)| (g.join(from), *arch)).collect()
        }
    };

    let mut added: Vec<String> = std::fs::read_to_string(&added_path)
        .map(|s| s.lines().map(String::from).collect())
        .unwrap_or_default();
    for (src, arch) in &sources {
        let entries = std::fs::read_dir(src).map_err(|e| format!("{}: {}", src.display(), e))?;
        for e in entries.filter_map(|e| e.ok()) {
            let name = e.file_name().to_string_lossy().into_owned();
            let target = wine_lib.join(arch).join(&name);
            let orig = wine_lib.join(arch).join(format!("{}.orig", name));
            let rel = format!("{}/{}", arch, name);
            if target.exists() && !orig.exists() && !added.contains(&rel) {
                std::fs::rename(&target, &orig)?;
            } else if !target.exists() && !orig.exists() && !added.contains(&rel) {
                added.push(rel);
            }
            // gptk's unix libraries are relative links into its external folder, which lands next to them here
            let real = std::fs::canonicalize(e.path())?;
            let real_name = real.file_name().unwrap_or_default();
            if e.path().is_symlink() && sources.iter().any(|(s, a)| a == arch && s.join(real_name).is_file()) {
                if std::fs::read_link(&target).ok().as_deref() != Some(Path::new(real_name)) {
                    let _ = std::fs::remove_file(&target);
                    std::os::unix::fs::symlink(real_name, &target)?;
                }
            } else {
                copy_tree_if_changed(&real, &target)?;
            }
        }
    }
    std::fs::write(&added_path, added.join("\n"))?;
    std::fs::write(&marker, want.name())?;

    if want == Graphics::Dxmt {
        // the prefix copy of winemetal must match the unix side, yaagl places it the same way
        let metal = sources[0].0.join("winemetal.dll");
        if metal.exists() {
            let sys32 = bottle.join("drive_c/windows/system32");
            std::fs::create_dir_all(&sys32)?;
            copy_if_changed(&metal, &sys32.join("winemetal.dll"))?;
        }
    }
    Ok(())
}
