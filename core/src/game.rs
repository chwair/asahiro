use std::io::Read;
use std::path::{Path, PathBuf};
use std::process::Command;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, Mutex};

use serde::{Deserialize, Serialize};

use crate::api::{Manifest, Package};
use crate::archive;
use crate::config::Config;
use crate::download::{self, fetch, fetch_simple, Meter};
use crate::util::{data_dir, err, free_space, human_size, md5_file, Result, Task};

pub const EXECUTABLE: &str = "ZenlessZoneZero.exe";
pub const DATA_DIR: &str = "ZenlessZoneZero_Data";
const CHANNEL: u32 = 1;
const SUB_CHANNEL: u32 = 0;
const CPS: &str = "mihoyo";
const HPATCHZ_URL: &str = "https://github.com/sisong/HDiffPatch/releases/download/v5.1.3/hdiffpatch_v5.1.3_bin_macos.zip";

const VOICE_PACKS: [(&str, &str); 4] =
    [("zh-cn", "Chinese"), ("en-us", "English(US)"), ("ja-jp", "Japanese"), ("ko-kr", "Korean")];

#[derive(Serialize, Debug)]
pub struct GameState {
    pub game_dir: String,
    pub installed: bool,
    pub version: Option<String>,
    pub latest: String,
    pub update_available: bool,
    pub can_update: bool,
    pub predownload: Option<String>,
    pub predownload_ready: bool,
    pub voice_packs: Vec<String>,
    pub download_size: u64,
    pub install_size: u64,
    pub free_space: u64,
    pub partial_download: bool,
}

fn tmp_dir(dir: &Path) -> PathBuf {
    dir.join(".ariatmp")
}

fn file_name(url: &str) -> &str {
    url.rsplit('/').next().unwrap_or(url)
}

pub fn installed_version(dir: &Path) -> Option<String> {
    if !dir.join(EXECUTABLE).exists() {
        return None;
    }
    if let Ok(ini) = std::fs::read_to_string(dir.join("config.ini")) {
        for line in ini.lines() {
            if let Some(v) = line.trim().strip_prefix("game_version=") {
                if !v.trim().is_empty() {
                    return Some(v.trim().to_string());
                }
            }
        }
    }
    version_from_unity(&dir.join(DATA_DIR)).ok()
}

// same trick yaagl uses: the version string sits at a fixed offset after "ic.app-category."
fn version_from_unity(data_dir: &Path) -> Result<String> {
    let mut buf = Vec::new();
    std::fs::File::open(data_dir.join("globalgamemanagers"))?.read_to_end(&mut buf)?;
    let pat = b"ic.app-category.";
    let Some(idx) = buf.windows(pat.len()).position(|w| w == pat) else {
        return err("version pattern not found");
    };
    let at = idx + 0xc4;
    if at + 4 > buf.len() {
        return err("version offset out of range");
    }
    let len = u32::from_le_bytes(buf[at..at + 4].try_into().unwrap()) as usize;
    let s = buf.get(at + 4..at + 4 + len).ok_or("version string out of range")?;
    let s = String::from_utf8_lossy(s);
    Ok(s.split('_').next().unwrap_or("").to_string())
}

pub fn installed_voice_packs(dir: &Path) -> Vec<String> {
    VOICE_PACKS
        .iter()
        .filter(|(_, name)| dir.join(format!("Audio_{}_pkg_version", name)).exists())
        .map(|(code, _)| code.to_string())
        .collect()
}

fn write_config_ini(dir: &Path, version: &str) -> Result<()> {
    let ini = format!(
        "[General]\r\ngame_version={}\r\nchannel={}\r\nsub_channel={}\r\ncps={}\r\n",
        version, CHANNEL, SUB_CHANNEL, CPS
    );
    std::fs::write(dir.join("config.ini"), ini)?;
    Ok(())
}

fn cmp_version(a: &str, b: &str) -> std::cmp::Ordering {
    let parse = |s: &str| s.split('.').map(|x| x.parse::<u64>().unwrap_or(0)).collect::<Vec<_>>();
    parse(a).cmp(&parse(b))
}

fn install_packages<'a>(cfg: &Config, m: &'a Manifest) -> Result<Vec<&'a Package>> {
    let latest = m.latest()?;
    let mut pkgs: Vec<&Package> = latest.game_pkgs.iter().collect();
    pkgs.extend(latest.audio_pkgs.iter().filter(|p| cfg.voice_packs.contains(&p.language)));
    Ok(pkgs)
}

fn predownload_packages<'a>(dir: &Path, m: &'a Manifest, current: &str) -> Vec<&'a Package> {
    let langs = installed_voice_packs(dir);
    match m.pre_download.patches.iter().find(|p| p.version == current) {
        Some(p) => p.game_pkgs.iter().chain(p.audio_pkgs.iter().filter(|a| langs.contains(&a.language))).collect(),
        None => Vec::new(),
    }
}

pub fn state(cfg: &Config, m: &Manifest) -> Result<GameState> {
    let dir = cfg.game_path();
    let latest = m.latest()?;
    let version = installed_version(&dir);
    let installed = version.is_some();
    let update_available = version.as_deref().map(|v| cmp_version(v, &latest.version).is_lt()).unwrap_or(false);
    let can_update = version.as_deref().map(|v| m.main.patches.iter().any(|p| p.version == v)).unwrap_or(false);
    let tmp = tmp_dir(&dir);

    let predownload = m.predownload_version().map(String::from).filter(|pv| {
        version.as_deref().map(|v| cmp_version(v, pv).is_lt()).unwrap_or(false)
    });
    let predownload_ready = match (&predownload, &version) {
        (Some(_), Some(v)) => {
            let pkgs = predownload_packages(&dir, m, v);
            !pkgs.is_empty() && pkgs.iter().all(|p| download::is_complete(&tmp.join(file_name(&p.url)), p.size(), &p.md5))
        }
        _ => false,
    };

    let pkgs = install_packages(cfg, m)?;
    Ok(GameState {
        game_dir: dir.to_string_lossy().into_owned(),
        installed,
        version,
        latest: latest.version.clone(),
        update_available,
        can_update,
        predownload,
        predownload_ready,
        voice_packs: installed_voice_packs(&dir),
        download_size: pkgs.iter().map(|p| p.size()).sum(),
        install_size: pkgs.iter().map(|p| p.unpacked_size()).sum(),
        free_space: free_space(&dir).unwrap_or(0),
        partial_download: std::fs::read_dir(&tmp).map(|mut d| d.next().is_some()).unwrap_or(false),
    })
}

fn download_all(task: &Task, dir: &Path, pkgs: &[&Package], label: &str) -> Result<Vec<PathBuf>> {
    let tmp = tmp_dir(dir);
    std::fs::create_dir_all(&tmp)?;
    let total = pkgs.iter().map(|p| p.size()).sum();
    let mut meter = Meter::new(task, label, total);
    let mut out = Vec::new();
    for p in pkgs {
        let dest = tmp.join(file_name(&p.url));
        fetch(&mut meter, &p.url, &dest, p.size(), &p.md5)?;
        out.push(dest);
    }
    Ok(out)
}

fn check_space(dir: &Path, needed: u64) -> Result<()> {
    if let Some(free) = free_space(dir) {
        if free < needed {
            return err(format!(
                "not enough disk space: {} needed, {} free",
                human_size(needed),
                human_size(free)
            ));
        }
    }
    Ok(())
}

pub fn install(task: &Task, cfg: &Config, m: &Manifest) -> Result<()> {
    let dir = cfg.game_path();
    std::fs::create_dir_all(&dir)?;
    let latest = m.latest()?;
    let pkgs = install_packages(cfg, m)?;
    let tmp = tmp_dir(&dir);
    let pending: u64 = pkgs
        .iter()
        .filter(|p| !download::is_complete(&tmp.join(file_name(&p.url)), p.size(), &p.md5))
        .map(|p| p.size())
        .sum();
    let unpacked: u64 = pkgs.iter().map(|p| p.unpacked_size()).sum();
    check_space(&dir, pending + unpacked + (1 << 30))?;

    task.status(format!("Downloading Zenless Zone Zero {}", latest.version));
    let files = download_all(task, &dir, &pkgs, "Downloading")?;

    // game volumes form one archive, audio packs are standalone zips
    let game_count = latest.game_pkgs.len();
    let (game_parts, audio_parts) = files.split_at(game_count);
    task.phase("install");
    task.status("Extracting game files");
    archive::extract(task, game_parts, &dir, "Extracting")?;
    for p in game_parts {
        download::remove(p);
    }
    for p in audio_parts {
        task.status(format!("Extracting {}", file_name(&p.to_string_lossy())));
        archive::extract(task, std::slice::from_ref(p), &dir, "Extracting voice pack")?;
        download::remove(p);
    }
    write_config_ini(&dir, &latest.version)?;
    let _ = std::fs::remove_dir(&tmp);
    task.status("Installed");
    Ok(())
}

// with use_predownload the pre-download patch is applied right away. the servers often switch to the
// new version before the launcher api does, so this lets an already downloaded update go in early
pub fn update(task: &Task, cfg: &Config, m: &Manifest, use_predownload: bool) -> Result<()> {
    let dir = cfg.game_path();
    let Some(current) = installed_version(&dir) else { return err("the game is not installed") };
    let (channel, target) = if use_predownload {
        let Some(v) = m.predownload_version() else { return err("there is no pre-download to apply") };
        (&m.pre_download, v.to_string())
    } else {
        (&m.main, m.latest()?.version.clone())
    };
    let Some(patch) = channel.patches.iter().find(|p| p.version == current) else {
        return err(format!("no update path from {} to {}, a fresh install is needed", current, target));
    };
    let langs = installed_voice_packs(&dir);
    let pkgs: Vec<&Package> =
        patch.game_pkgs.iter().chain(patch.audio_pkgs.iter().filter(|a| langs.contains(&a.language))).collect();
    let tmp = tmp_dir(&dir);
    let pending: u64 = pkgs
        .iter()
        .map(|p| {
            let downloaded = download::is_complete(&tmp.join(file_name(&p.url)), p.size(), &p.md5);
            p.unpacked_size() + if downloaded { 0 } else { p.size() }
        })
        .sum();
    check_space(&dir, pending)?;

    let hpatchz = ensure_hpatchz(task)?;
    task.status(format!("Updating {} → {}", current, target));
    let files = download_all(task, &dir, &pkgs, "Downloading update")?;
    for f in &files {
        task.phase("install");
        task.status(format!("Applying {}", file_name(&f.to_string_lossy())));
        archive::extract(task, std::slice::from_ref(f), &dir, "Extracting update")?;
        apply_patch_lists(task, &dir, &hpatchz)?;
        download::remove(f);
    }
    write_config_ini(&dir, &target)?;
    let _ = std::fs::remove_dir(tmp_dir(&dir));
    task.status(format!("Updated to {}", target));
    Ok(())
}

pub fn predownload(task: &Task, cfg: &Config, m: &Manifest) -> Result<()> {
    let dir = cfg.game_path();
    let Some(current) = installed_version(&dir) else { return err("the game is not installed") };
    let pkgs = predownload_packages(&dir, m, &current);
    if pkgs.is_empty() {
        return err("no pre-download is available for this version");
    }
    check_space(&dir, pkgs.iter().map(|p| p.size()).sum())?;
    task.status(format!("Pre-downloading {}", m.predownload_version().unwrap_or("")));
    download_all(task, &dir, &pkgs, "Pre-downloading")?;
    task.status("Pre-download complete");
    Ok(())
}

#[derive(Deserialize)]
struct HdiffEntry {
    #[serde(rename = "remoteName")]
    remote_name: String,
}

#[derive(Deserialize)]
struct HdiffMap {
    diff_map: Vec<HdiffMapEntry>,
}

#[derive(Deserialize)]
struct HdiffMapEntry {
    source_file_name: String,
    target_file_name: String,
    patch_file_name: String,
}

fn hpatch(hpatchz: &Path, old: &Path, diff: &Path, out: &Path) -> Result<()> {
    let o = Command::new(hpatchz).arg("-f").arg(old).arg(diff).arg(out).output()?;
    if !o.status.success() {
        return err(format!("hpatchz failed on {}: {}", old.display(), String::from_utf8_lossy(&o.stderr)));
    }
    Ok(())
}

// applies deletefiles.txt, hdifffiles.txt and hdiffmap.json left behind by an update archive
fn apply_patch_lists(task: &Task, dir: &Path, hpatchz: &Path) -> Result<()> {
    let deletes: Vec<String> = std::fs::read_to_string(dir.join("deletefiles.txt"))
        .map(|s| s.lines().map(|l| l.trim().to_string()).filter(|l| !l.is_empty()).collect())
        .unwrap_or_default();
    let diffs: Vec<HdiffEntry> = std::fs::read_to_string(dir.join("hdifffiles.txt"))
        .map(|s| s.lines().filter(|l| !l.trim().is_empty()).filter_map(|l| serde_json::from_str(l).ok()).collect())
        .unwrap_or_default();
    let map: Vec<HdiffMapEntry> = std::fs::read(dir.join("hdiffmap.json"))
        .ok()
        .and_then(|b| serde_json::from_slice::<HdiffMap>(&b).ok())
        .map(|m| m.diff_map)
        .unwrap_or_default();

    let total = (deletes.len() + diffs.len() + map.len()).max(1);
    let mut done = 0;
    for f in &deletes {
        let _ = std::fs::remove_file(dir.join(f));
        done += 1;
    }
    task.phase("patch");
    task.status("Patching files");
    for d in &diffs {
        task.check()?;
        let target = dir.join(&d.remote_name);
        let diff = dir.join(format!("{}.hdiff", d.remote_name));
        if diff.exists() {
            let out = dir.join(format!("{}.patched", d.remote_name));
            hpatch(hpatchz, &target, &diff, &out)?;
            std::fs::rename(&out, &target)?;
            let _ = std::fs::remove_file(&diff);
        }
        done += 1;
        task.progress(Some(done as f64 / total as f64), format!("Patching  {} / {}", done, total));
    }
    for e in &map {
        task.check()?;
        let src = dir.join(&e.source_file_name);
        let patch = dir.join(&e.patch_file_name);
        let target = dir.join(&e.target_file_name);
        if patch.exists() {
            let out = target.with_extension("asahiro-patched");
            hpatch(hpatchz, &src, &patch, &out)?;
            if src != target {
                let _ = std::fs::remove_file(&src);
            }
            std::fs::rename(&out, &target)?;
            let _ = std::fs::remove_file(&patch);
        }
        done += 1;
        task.progress(Some(done as f64 / total as f64), format!("Patching  {} / {}", done, total));
    }
    for f in ["deletefiles.txt", "hdifffiles.txt", "hdiffmap.json"] {
        let _ = std::fs::remove_file(dir.join(f));
    }
    Ok(())
}

pub fn ensure_hpatchz(task: &Task) -> Result<PathBuf> {
    let bin = data_dir().join("tools/hpatchz");
    if bin.exists() {
        return Ok(bin);
    }
    task.phase("download");
    task.status("Downloading patch tool");
    let zip_path = data_dir().join("tools/hdiffpatch.zip");
    fetch_simple(task, HPATCHZ_URL, &zip_path)?;
    let mut z = zip::ZipArchive::new(std::fs::File::open(&zip_path)?)?;
    let idx = (0..z.len())
        .find(|&i| z.by_index_raw(i).map(|e| !e.is_dir() && e.name().ends_with("/hpatchz")).unwrap_or(false))
        .ok_or("hpatchz missing from archive")?;
    let mut out = std::fs::File::create(&bin)?;
    std::io::copy(&mut z.by_index(idx)?, &mut out)?;
    drop(out);
    use std::os::unix::fs::PermissionsExt;
    std::fs::set_permissions(&bin, std::fs::Permissions::from_mode(0o755))?;
    let _ = std::fs::remove_file(zip_path);
    Ok(bin)
}

#[derive(Deserialize)]
struct PkgEntry {
    #[serde(rename = "remoteName")]
    remote_name: String,
    md5: String,
    #[serde(rename = "fileSize")]
    file_size: u64,
}

// checks every file listed in pkg_version and re-downloads the broken ones
pub fn verify(task: &Task, cfg: &Config, m: &Manifest) -> Result<()> {
    let dir = cfg.game_path();
    if installed_version(&dir).is_none() {
        return err("the game is not installed");
    }
    let latest = m.latest()?;
    let mut entries = Vec::new();
    for name in std::fs::read_dir(&dir)?.filter_map(|e| e.ok()).map(|e| e.file_name().to_string_lossy().into_owned()) {
        if name == "pkg_version" || (name.starts_with("Audio_") && name.ends_with("_pkg_version")) {
            for line in std::fs::read_to_string(dir.join(&name))?.lines() {
                if let Ok(e) = serde_json::from_str::<PkgEntry>(line) {
                    entries.push(e);
                }
            }
        }
    }
    if entries.is_empty() {
        return err("pkg_version is missing, the install can not be verified");
    }
    let total: u64 = entries.iter().map(|e| e.file_size).sum();
    let checked = AtomicU64::new(0);
    let broken = Mutex::new(Vec::new());
    let queue = Mutex::new(entries.iter().collect::<Vec<_>>());
    task.phase("verify");
    task.status(format!("Verifying {} files", entries.len()));

    std::thread::scope(|s| {
        let workers = std::thread::available_parallelism().map(|n| n.get()).unwrap_or(4).clamp(2, 8);
        let running = Arc::new(());
        for _ in 0..workers {
            let guard = running.clone();
            let (queue, broken, checked, dir) = (&queue, &broken, &checked, &dir);
            s.spawn(move || {
                let _guard = guard;
                while let Some(e) = queue.lock().unwrap().pop() {
                    if task.cancelled() {
                        return;
                    }
                    let path = dir.join(&e.remote_name);
                    let ok = std::fs::metadata(&path).map(|m| m.len() == e.file_size).unwrap_or(false)
                        && md5_file(&path, |n| {
                            checked.fetch_add(n, Ordering::Relaxed);
                            task.check()
                        })
                        .map(|h| h.eq_ignore_ascii_case(&e.md5))
                        .unwrap_or(false);
                    if !ok {
                        broken.lock().unwrap().push(e);
                    }
                }
            });
        }
        while Arc::strong_count(&running) > 1 {
            let done = checked.load(Ordering::Relaxed);
            task.progress(
                Some(done as f64 / total.max(1) as f64),
                format!("Verifying  {} / {}", human_size(done), human_size(total)),
            );
            std::thread::sleep(std::time::Duration::from_millis(150));
        }
    });
    task.check()?;

    let broken = broken.into_inner().unwrap();
    if broken.is_empty() {
        task.status("All files are intact");
        return Ok(());
    }
    task.log(format!("{} files need repair", broken.len()));
    task.phase("repair");
    // an early applied pre-download is newer than the live release, repair from its own file list
    let installed = installed_version(&dir).unwrap_or_default();
    let source = m.pre_download.major.as_ref().filter(|p| p.version == installed).unwrap_or(latest);
    let base = source.res_list_url.trim_end_matches('/');
    for (i, e) in broken.iter().enumerate() {
        task.status(format!("Repairing {} ({}/{})", e.remote_name, i + 1, broken.len()));
        task.progress(Some(i as f64 / broken.len() as f64), format!("Repairing  {} / {}", i + 1, broken.len()));
        let dest = dir.join(&e.remote_name);
        fetch_simple(task, &format!("{}/{}", base, e.remote_name), &dest)?;
        let got = md5_file(&dest, |_| Ok(()))?;
        if !got.eq_ignore_ascii_case(&e.md5) {
            return err(format!("repaired file {} still fails verification", e.remote_name));
        }
    }
    task.status(format!("Repaired {} files", broken.len()));
    Ok(())
}
