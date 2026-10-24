use std::collections::{BTreeMap, BTreeSet};
use std::path::{Path, PathBuf};
use std::time::{Duration, SystemTime};

use serde::{Deserialize, Serialize};
use serde_json::Value;

use crate::config::Config;
use crate::download::{fetch, Meter};
use crate::util::{cache_dir, data_dir, err, Result, Task};

// zzmi is the zzz model importer: the xxmi build of 3dmigoto (d3d11.dll and its loader) plus the
// zzmi package (shaders, core inis, d3dx.ini). both are signed by their authors, see verify()
const LIBS_REPO: &str = "SpectrumQT/XXMI-Libs-Package";
const ZZMI_REPO: &str = "leotorrez/ZZMI-Package";
// public keys from xxmi launcher's migoto_package.py and zzmi_package.py
const LIBS_KEY: &str = "MHYwEAYHKoZIzj0CAQYFK4EEACIDYgAEYac352uRGKZh6LOwK0fVDW/TpyECEfnRtUp+bP2PJPP63SWOkJ3a/d9pAnPfYezRVJ1hWjZtpRTT8HEAN/b4mWpJvqO43SAEV/1Q6vz9Rk/VvRV3jZ6B/tmqVnIeHKEb";
const ZZMI_KEY: &str = "MHYwEAYHKoZIzj0CAQYFK4EEACIDYgAEb11GjbKQS6SmRe8TcIc5VMu5Ob3moo5v2YeD+s53xEe4bVPGcToUNLu3Jgqo0OwWZ4RsNy1nR0HId6pR09HedyEMifxebsyPT3T5PH82QozEXHQlTDySklWUfGItoOdf";
const LIB_FILES: [&str; 3] = ["d3d11.dll", "3dmloader.dll", "d3dcompiler_47.dll"];
const CHECK_INTERVAL: Duration = Duration::from_secs(6 * 3600);

pub const HELPER_NAME: &str = "asahiro-inject.exe";
static HELPER: &[u8] = include_bytes!("../../app/Resources/bin/asahiro-inject.exe");

pub fn zzmi_dir() -> PathBuf {
    data_dir().join("zzmi")
}

pub fn mods_dir() -> PathBuf {
    zzmi_dir().join("Mods")
}

#[derive(Serialize, Deserialize, Default, Clone, Debug)]
struct Versions {
    libs: String,
    zzmi: String,
}

fn read_versions() -> Versions {
    std::fs::read(zzmi_dir().join(".versions.json"))
        .ok()
        .and_then(|b| serde_json::from_slice(&b).ok())
        .unwrap_or_default()
}

fn write_versions(v: &Versions) -> Result<()> {
    std::fs::write(zzmi_dir().join(".versions.json"), serde_json::to_vec_pretty(v)?)?;
    Ok(())
}

#[derive(Serialize, Deserialize, Clone, Debug)]
struct Release {
    version: String,
    asset_url: String,
    asset_name: String,
    asset_size: u64,
    signature: String,
    manifest_url: Option<String>,
    published: String,
}

#[derive(Serialize, Deserialize, Default, Clone, Debug)]
struct ReleaseCache {
    checked: u64,
    libs: Option<Release>,
    zzmi: Option<Release>,
}

fn now() -> u64 {
    SystemTime::now().duration_since(SystemTime::UNIX_EPOCH).map(|d| d.as_secs()).unwrap_or(0)
}

fn version_of(tag: &str) -> String {
    tag.trim_start_matches(|c: char| !c.is_ascii_digit()).to_string()
}

fn fetch_release(repo: &str) -> Result<Release> {
    let v: Value = crate::api::agent()
        .get(&format!("https://api.github.com/repos/{}/releases/latest", repo))
        .set("Accept", "application/vnd.github+json")
        .call()?
        .into_json()?;
    let body = v["body"].as_str().unwrap_or("");
    // the release notes end with "## Signature" followed by "- <base64>"
    let signature = body
        .split("## Signature")
        .nth(1)
        .and_then(|rest| rest.lines().map(str::trim).find(|l| l.starts_with("- ")))
        .map(|l| l[2..].trim().to_string())
        .ok_or_else(|| crate::util::Error(format!("{} release has no signature", repo)))?;
    let assets = v["assets"].as_array().cloned().unwrap_or_default();
    let zip = assets
        .iter()
        .find(|a| a["name"].as_str().is_some_and(|n| n.ends_with(".zip")))
        .ok_or_else(|| crate::util::Error(format!("{} release has no zip", repo)))?;
    let manifest = assets
        .iter()
        .find(|a| a["name"] == "Manifest.json")
        .and_then(|a| a["browser_download_url"].as_str().map(String::from));
    Ok(Release {
        version: version_of(v["tag_name"].as_str().unwrap_or("")),
        asset_url: zip["browser_download_url"].as_str().unwrap_or("").to_string(),
        asset_name: zip["name"].as_str().unwrap_or("").to_string(),
        asset_size: zip["size"].as_u64().unwrap_or(0),
        signature,
        manifest_url: manifest,
        published: v["published_at"].as_str().unwrap_or("").to_string(),
    })
}

fn releases(force: bool) -> Result<ReleaseCache> {
    let path = cache_dir().join("zzmi-releases.json");
    let cached: Option<ReleaseCache> = std::fs::read(&path).ok().and_then(|b| serde_json::from_slice(&b).ok());
    if let Some(c) = &cached {
        if !force && now().saturating_sub(c.checked) < CHECK_INTERVAL.as_secs() {
            return Ok(c.clone());
        }
    }
    match (fetch_release(LIBS_REPO), fetch_release(ZZMI_REPO)) {
        (Ok(libs), Ok(zzmi)) => {
            let fresh = ReleaseCache { checked: now(), libs: Some(libs), zzmi: Some(zzmi) };
            std::fs::write(&path, serde_json::to_vec(&fresh)?)?;
            Ok(fresh)
        }
        (Err(e), _) | (_, Err(e)) => cached.ok_or(e),
    }
}

// ecdsa p-384 over sha-256 with a der encoded signature, the same scheme xxmi launcher verifies
fn verify(key_b64: &str, signature_b64: &str, data: &[u8]) -> Result<()> {
    use base64::Engine;
    use p384::ecdsa::signature::hazmat::PrehashVerifier;
    use p384::ecdsa::{Signature, VerifyingKey};
    use p384::pkcs8::DecodePublicKey;
    use sha2::{Digest, Sha256};
    let b64 = base64::engine::general_purpose::STANDARD;
    let key = VerifyingKey::from_public_key_der(&b64.decode(key_b64).map_err(|e| e.to_string())?)
        .map_err(|e| e.to_string())?;
    let sig = Signature::from_der(&b64.decode(signature_b64.trim()).map_err(|e| e.to_string())?)
        .map_err(|e| e.to_string())?;
    key.verify_prehash(&Sha256::digest(data), &sig).map_err(|_| "signature verification failed".into())
}

#[derive(Serialize)]
pub struct Status {
    pub installed: bool,
    pub enabled: bool,
    pub libs_version: Option<String>,
    pub zzmi_version: Option<String>,
    pub latest_libs: Option<String>,
    pub latest_zzmi: Option<String>,
    pub zzmi_published: Option<String>,
    pub update_available: bool,
    pub mods_path: String,
    pub mod_count: usize,
}

pub fn installed() -> bool {
    let dir = zzmi_dir();
    LIB_FILES.iter().all(|f| dir.join(f).exists()) && dir.join("d3dx.ini").exists() && dir.join("Core").exists()
}

pub fn status(cfg: &Config, force: bool) -> Status {
    let v = read_versions();
    let rel = releases(force).ok();
    let latest_libs = rel.as_ref().and_then(|r| r.libs.as_ref().map(|l| l.version.clone()));
    let latest_zzmi = rel.as_ref().and_then(|r| r.zzmi.as_ref().map(|l| l.version.clone()));
    let is_installed = installed();
    let update_available = is_installed
        && (latest_libs.as_deref().is_some_and(|l| l != v.libs) || latest_zzmi.as_deref().is_some_and(|l| l != v.zzmi));
    Status {
        installed: is_installed,
        enabled: cfg.mods_enabled,
        libs_version: Some(v.libs).filter(|s| !s.is_empty() && is_installed),
        zzmi_version: Some(v.zzmi).filter(|s| !s.is_empty() && is_installed),
        latest_libs,
        latest_zzmi,
        zzmi_published: rel.and_then(|r| r.zzmi.map(|z| z.published)),
        update_available,
        mods_path: mods_dir().to_string_lossy().into_owned(),
        mod_count: list().map(|m| m.len()).unwrap_or(0),
    }
}

fn download_verified(task: &Task, rel: &Release, key: &str, staging: &Path) -> Result<PathBuf> {
    let dest = staging.join(&rel.asset_name);
    let mut meter = Meter::new(task, &rel.asset_name, rel.asset_size);
    fetch(&mut meter, &rel.asset_url, &dest, rel.asset_size, "")?;
    let bytes = std::fs::read(&dest)?;
    if let Err(e) = verify(key, &rel.signature, &bytes) {
        crate::download::remove(&dest);
        return err(format!("{}: {}", rel.asset_name, e));
    }
    Ok(dest)
}

// extracts a zip below dest, refusing entries that would escape it
fn unzip(path: &Path, dest: &Path) -> Result<()> {
    let mut z = zip::ZipArchive::new(std::fs::File::open(path)?)?;
    for i in 0..z.len() {
        let mut entry = z.by_index(i)?;
        let Some(rel) = entry.enclosed_name() else { return err(format!("unsafe path in {}", path.display())) };
        let out = dest.join(rel);
        if entry.is_dir() {
            std::fs::create_dir_all(&out)?;
            continue;
        }
        if let Some(p) = out.parent() {
            std::fs::create_dir_all(p)?;
        }
        let mut f = std::fs::File::create(&out)?;
        std::io::copy(&mut entry, &mut f)?;
    }
    Ok(())
}

fn replace_dir(from: &Path, to: &Path) -> Result<()> {
    if to.exists() {
        std::fs::remove_dir_all(to)?;
    }
    std::fs::rename(from, to)?;
    Ok(())
}

// installs or updates both packages. Mods and d3dx_user.ini are never touched
pub fn install(task: &Task, cfg: &Config) -> Result<()> {
    let rel = releases(true)?;
    let (Some(libs), Some(zzmi)) = (rel.libs, rel.zzmi) else { return err("could not reach github for zzmi releases") };
    let dir = zzmi_dir();
    let staging = dir.join(".staging");
    let _ = std::fs::remove_dir_all(&staging);
    std::fs::create_dir_all(&staging)?;
    let mut versions = read_versions();

    if versions.libs != libs.version || !LIB_FILES.iter().all(|f| dir.join(f).exists()) {
        task.status(format!("Downloading XXMI libraries {}", libs.version));
        let zip = download_verified(task, &libs, LIBS_KEY, &staging)?;
        let out = staging.join("libs");
        unzip(&zip, &out)?;
        // the manifest signs every dll individually, check them before they go anywhere near the game
        if let Some(url) = &libs.manifest_url {
            let manifest: Value = crate::api::agent().get(url).call()?.into_json()?;
            for f in LIB_FILES {
                let sig = manifest["signatures"][f].as_str().ok_or_else(|| crate::util::Error(format!("manifest has no signature for {}", f)))?;
                verify(LIBS_KEY, sig, &std::fs::read(out.join(f))?).map_err(|e| crate::util::Error(format!("{}: {}", f, e)))?;
            }
        }
        std::fs::create_dir_all(&dir)?;
        for f in LIB_FILES {
            std::fs::rename(out.join(f), dir.join(f))?;
        }
        versions.libs = libs.version.clone();
        write_versions(&versions)?;
    }

    if versions.zzmi != zzmi.version || !dir.join("Core").exists() {
        task.status(format!("Downloading ZZMI {}", zzmi.version));
        let zip = download_verified(task, &zzmi, ZZMI_KEY, &staging)?;
        let out = staging.join("zzmi");
        unzip(&zip, &out)?;
        task.status("Installing ZZMI");
        replace_dir(&out.join("Core"), &dir.join("Core"))?;
        replace_dir(&out.join("ShaderFixes"), &dir.join("ShaderFixes"))?;
        std::fs::rename(out.join("d3dx.ini"), dir.join("d3dx.ini"))?;
        versions.zzmi = zzmi.version.clone();
        write_versions(&versions)?;
    }

    std::fs::create_dir_all(mods_dir())?;
    let _ = std::fs::remove_dir_all(&staging);
    prepare(cfg)?;
    task.status("ZZMI is ready");
    Ok(())
}

// sets one key inside an ini section, replacing an active line or inserting after the header
fn set_ini(lines: &mut Vec<String>, section: &str, key: &str, value: &str) {
    let header = format!("[{}]", section);
    let Some(start) = lines.iter().position(|l| l.trim().eq_ignore_ascii_case(&header)) else {
        lines.push(String::new());
        lines.push(header);
        lines.push(format!("{} = {}", key, value));
        return;
    };
    let end = lines[start + 1..].iter().position(|l| l.trim_start().starts_with('[')).map(|p| start + 1 + p).unwrap_or(lines.len());
    for l in &mut lines[start + 1..end] {
        let t = l.trim_start();
        if t.starts_with(';') {
            continue;
        }
        if let Some((k, _)) = t.split_once('=') {
            if k.trim().eq_ignore_ascii_case(key) {
                *l = format!("{} = {}", key, value);
                return;
            }
        }
    }
    lines.insert(start + 1, format!("{} = {}", key, value));
}

// writes the managed d3dx.ini keys and drops the injector next to the dlls, run before every modded launch
pub fn prepare(cfg: &Config) -> Result<()> {
    let dir = zzmi_dir();
    let ini_path = dir.join("d3dx.ini");
    let raw = std::fs::read(&ini_path)?;
    let text = String::from_utf8_lossy(&raw);
    let crlf = text.contains("\r\n");
    let mut lines: Vec<String> = text.lines().map(String::from).collect();
    set_ini(&mut lines, "Loader", "target", crate::game::EXECUTABLE);
    set_ini(&mut lines, "Loader", "loader", HELPER_NAME);
    set_ini(&mut lines, "Rendering", "texture_hash", "0");
    set_ini(&mut lines, "Rendering", "track_texture_updates", "0");
    set_ini(&mut lines, "Rendering", "track_region_hashes", "0");
    set_ini(&mut lines, "Rendering", "allow_buffer_resize", "1");
    set_ini(&mut lines, "Hunting", "hunting", if cfg.mods_hunting { "2" } else { "0" });
    let sep = if crlf { "\r\n" } else { "\n" };
    std::fs::write(&ini_path, lines.join(sep) + sep)?;

    let helper = dir.join(HELPER_NAME);
    if std::fs::read(&helper).ok().as_deref() != Some(HELPER) {
        std::fs::write(&helper, HELPER)?;
    }
    std::fs::create_dir_all(mods_dir())?;
    Ok(())
}

pub fn update_if_needed(task: &Task, cfg: &Config) -> Result<()> {
    if !installed() || (cfg.mods_auto_update && status(cfg, false).update_available) {
        install(task, cfg)?;
    }
    Ok(())
}

#[derive(Serialize)]
pub struct ModInfo {
    pub id: String,
    pub name: String,
    pub enabled: bool,
    pub path: String,
    pub size: u64,
    pub ini_count: usize,
    pub preview: Option<String>,
    pub character: Option<String>,
    pub conflicts: Vec<String>,
    pub modified: u64,
}

// agents through the 2.x versions, newer ones simply go undetected
const AGENTS: [&str; 40] = [
    "Anby", "Nicole", "Billy", "Nekomata", "Soldier 11", "Corin", "Anton", "Ben", "Koleda", "Grace",
    "Lycaon", "Ellen", "Rina", "Soukaku", "Zhu Yuan", "Lucy", "Piper", "Qingyi", "Jane", "Seth",
    "Caesar", "Burnice", "Yanagi", "Lighter", "Miyabi", "Harumasa", "Astra", "Evelyn", "Soldier 0", "Pulchra",
    "Trigger", "Vivian", "Hugo", "Yixuan", "Pan Yinhu", "Ju Fufu", "Yuzuha", "Alice", "Belle", "Wise",
];

fn strip_disabled(name: &str) -> (bool, String) {
    let lower = name.to_ascii_lowercase();
    if lower.starts_with("disabled") {
        let rest = name[8..].trim_start_matches(|c: char| c == '_' || c == ' ' || c == '-');
        (false, rest.to_string())
    } else {
        (true, name.to_string())
    }
}

fn walk(dir: &Path, depth: u32, f: &mut dyn FnMut(&Path, &std::fs::Metadata)) {
    let Ok(entries) = std::fs::read_dir(dir) else { return };
    for e in entries.filter_map(|e| e.ok()) {
        let p = e.path();
        let Ok(meta) = e.metadata() else { continue };
        if meta.is_dir() {
            if depth > 0 {
                walk(&p, depth - 1, f);
            }
        } else {
            f(&p, &meta);
        }
    }
}

// the folder name is what the author called the mod, so only it is trusted: known agents are matched
// in it, anyone else is grouped by the name's first word (AriaSkin and Aria-BottomHeavy both give Aria)
fn detect_character(name: &str) -> Option<String> {
    let lower = name.to_lowercase();
    if let Some(a) = AGENTS.iter().find(|a| {
        let needle = a.to_lowercase();
        lower.contains(&needle) || lower.contains(&needle.replace(' ', ""))
    }) {
        return Some(a.to_string());
    }
    let mut first = String::new();
    for (i, c) in name.chars().enumerate() {
        if !c.is_alphabetic() || (i > 0 && c.is_uppercase()) {
            break;
        }
        first.push(c);
    }
    (first.chars().count() >= 3).then(|| {
        let mut chars = first.chars();
        chars.next().map(|c| c.to_uppercase().collect::<String>() + chars.as_str()).unwrap_or_default()
    })
}

// one entry per top level folder in Mods, disabled ones carry 3dmigoto's DISABLED prefix
pub fn list() -> Result<Vec<ModInfo>> {
    let root = mods_dir();
    std::fs::create_dir_all(&root)?;
    let mut mods = Vec::new();
    let mut hashes: BTreeMap<String, Vec<String>> = BTreeMap::new();
    let mut per_mod_hashes: Vec<BTreeSet<String>> = Vec::new();
    let mut entries: Vec<_> = std::fs::read_dir(&root)?.filter_map(|e| e.ok()).filter(|e| e.path().is_dir()).collect();
    // sort by display name so toggling (which renames the folder) does not move the card
    entries.sort_by_key(|e| strip_disabled(&e.file_name().to_string_lossy()).1.to_lowercase());
    for e in entries {
        let id = e.file_name().to_string_lossy().into_owned();
        if id.starts_with('.') {
            continue;
        }
        let (enabled, name) = strip_disabled(&id);
        let path = e.path();
        let mut size = 0;
        let mut ini_count = 0;
        let mut preview: Option<PathBuf> = None;
        let mut mod_hashes = BTreeSet::new();
        walk(&path, 6, &mut |p, meta| {
            size += meta.len();
            let file = p.file_name().map(|n| n.to_string_lossy().to_lowercase()).unwrap_or_default();
            let ext = p.extension().map(|x| x.to_string_lossy().to_lowercase()).unwrap_or_default();
            if ext == "ini" && !file.starts_with("disabled") {
                ini_count += 1;
                if let Ok(text) = std::fs::read(p) {
                    let mut in_override = false;
                    for line in String::from_utf8_lossy(&text).lines() {
                        let t = line.trim();
                        if t.starts_with('[') {
                            in_override = t.to_lowercase().starts_with("[textureoverride");
                        } else if in_override {
                            if let Some(v) = t.strip_prefix("hash").and_then(|r| r.trim_start().strip_prefix('=')) {
                                mod_hashes.insert(v.trim().to_lowercase());
                            }
                        }
                    }
                }
            }
            let is_image = ["png", "jpg", "jpeg", "webp", "gif"].contains(&ext.as_str());
            let depth_ok = p.parent() == Some(path.as_path());
            if is_image && depth_ok && (preview.is_none() || file.starts_with("preview")) {
                preview = Some(p.to_path_buf());
            }
        });
        if enabled {
            for h in &mod_hashes {
                hashes.entry(h.clone()).or_default().push(id.clone());
            }
        }
        per_mod_hashes.push(mod_hashes);
        let modified = e
            .metadata()
            .and_then(|m| m.created().or_else(|_| m.modified()))
            .ok()
            .and_then(|t| t.duration_since(std::time::UNIX_EPOCH).ok())
            .map(|d| d.as_secs())
            .unwrap_or(0);
        mods.push(ModInfo {
            modified,
            // folders without any ini (shared resources, themes) are not character mods
            character: if ini_count > 0 { detect_character(&name) } else { None },
            id,
            name,
            enabled,
            path: path.to_string_lossy().into_owned(),
            size,
            ini_count,
            preview: preview.map(|p| p.to_string_lossy().into_owned()),
            conflicts: Vec::new(),
        });
    }
    // two enabled mods overriding the same hash fight over it, which usually means one of them does nothing
    for (m, own) in mods.iter_mut().zip(per_mod_hashes.iter()) {
        if !m.enabled {
            continue;
        }
        let mut others = BTreeSet::new();
        for h in own {
            for other in hashes.get(h).into_iter().flatten() {
                if other != &m.id {
                    others.insert(strip_disabled(other).1);
                }
            }
        }
        m.conflicts = others.into_iter().collect();
    }
    Ok(mods)
}

fn mod_path(id: &str) -> Result<PathBuf> {
    if id.is_empty() || id.contains('/') || id.contains("..") {
        return err("invalid mod id");
    }
    let p = mods_dir().join(id);
    if !p.is_dir() {
        return err(format!("mod {} not found", id));
    }
    Ok(p)
}

pub fn set_enabled(id: &str, enabled: bool) -> Result<String> {
    let from = mod_path(id)?;
    let (_, name) = strip_disabled(id);
    let target = if enabled { name } else { format!("DISABLED {}", name) };
    if target == id {
        return Ok(target);
    }
    let to = mods_dir().join(&target);
    if to.exists() {
        return err(format!("{} already exists", target));
    }
    std::fs::rename(from, to)?;
    Ok(target)
}

// enables or disables several mods at once, returning the new folder names
pub fn set_enabled_many(ids: &[String], enabled: bool) -> Result<Vec<String>> {
    let mut renamed = Vec::new();
    let mut failures = Vec::new();
    for id in ids {
        match set_enabled(id, enabled) {
            Ok(n) => renamed.push(n),
            Err(e) => failures.push(format!("{}: {}", strip_disabled(id).1, e)),
        }
    }
    if !failures.is_empty() {
        return err(failures.join("\n"));
    }
    Ok(renamed)
}

fn copy_dir(from: &Path, to: &Path) -> Result<()> {
    std::fs::create_dir_all(to)?;
    for e in std::fs::read_dir(from)?.filter_map(|e| e.ok()) {
        let dest = to.join(e.file_name());
        if e.path().is_dir() {
            copy_dir(&e.path(), &dest)?;
        } else {
            std::fs::copy(e.path(), dest)?;
        }
    }
    Ok(())
}

fn unique_name(base: &str) -> String {
    let mut name = base.to_string();
    let mut n = 2;
    while mods_dir().join(&name).exists() || mods_dir().join(format!("DISABLED {}", name)).exists() {
        name = format!("{} {}", base, n);
        n += 1;
    }
    name
}

// archives often wrap everything in one folder, or several mod folders side by side
fn place_extracted(staging: &Path, base: &str) -> Result<Vec<String>> {
    let entries: Vec<_> = std::fs::read_dir(staging)?
        .filter_map(|e| e.ok())
        .filter(|e| !e.file_name().to_string_lossy().starts_with("__MACOSX") && !e.file_name().to_string_lossy().starts_with('.'))
        .collect();
    let has_ini_here = entries.iter().any(|e| e.path().extension().is_some_and(|x| x.eq_ignore_ascii_case("ini")));
    let dirs: Vec<_> = entries.iter().filter(|e| e.path().is_dir()).collect();
    let mut added = Vec::new();
    if !has_ini_here && !dirs.is_empty() && dirs.len() == entries.len() {
        for d in dirs {
            let name = unique_name(&d.file_name().to_string_lossy());
            std::fs::rename(d.path(), mods_dir().join(&name))?;
            added.push(name);
        }
    } else {
        let name = unique_name(base);
        std::fs::rename(staging, mods_dir().join(&name))?;
        added.push(name);
    }
    Ok(added)
}

pub fn import(task: &Task, source: &Path) -> Result<Vec<String>> {
    std::fs::create_dir_all(mods_dir())?;
    let base = source
        .file_stem()
        .map(|s| s.to_string_lossy().into_owned())
        .unwrap_or_else(|| "Mod".into());
    let staging = mods_dir().join(format!(".import-{}", now()));
    let _ = std::fs::remove_dir_all(&staging);
    task.status(format!("Importing {}", base));
    if source.is_dir() {
        copy_dir(source, &staging)?;
    } else {
        let ext = source.extension().map(|e| e.to_string_lossy().to_lowercase()).unwrap_or_default();
        match ext.as_str() {
            "zip" => unzip(source, &staging)?,
            // the system bsdtar is libarchive, which reads 7z and rar
            "7z" | "rar" => {
                std::fs::create_dir_all(&staging)?;
                let out = std::process::Command::new("/usr/bin/tar").arg("-xf").arg(source).arg("-C").arg(&staging).output()?;
                if !out.status.success() {
                    let _ = std::fs::remove_dir_all(&staging);
                    return err(format!("could not extract {}: {}", base, String::from_utf8_lossy(&out.stderr).trim()));
                }
            }
            _ => return err(format!(".{} files are not supported, use a zip, 7z, rar or folder", ext)),
        }
    }
    let added = place_extracted(&staging, &base);
    let _ = std::fs::remove_dir_all(&staging);
    let added = added?;
    task.status(format!("Added {}", added.join(", ")));
    Ok(added)
}

pub fn check_due() -> bool {
    std::fs::read(cache_dir().join("zzmi-releases.json"))
        .ok()
        .and_then(|b| serde_json::from_slice::<ReleaseCache>(&b).ok())
        .map(|c| now().saturating_sub(c.checked) >= CHECK_INTERVAL.as_secs())
        .unwrap_or(true)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn ini_keys_are_replaced_or_inserted() {
        let mut lines: Vec<String> = ["[Loader]", "target = x.exe", "loader = XXMI Launcher.exe", "[Rendering]", "; texture_hash = 1"]
            .iter()
            .map(|s| s.to_string())
            .collect();
        set_ini(&mut lines, "Loader", "loader", "asahiro-inject.exe");
        set_ini(&mut lines, "Rendering", "texture_hash", "0");
        assert_eq!(lines[2], "loader = asahiro-inject.exe");
        assert_eq!(lines[4], "texture_hash = 0");
        assert_eq!(lines[5], "; texture_hash = 1");
    }

    #[test]
    fn signatures_reject_tampered_data() {
        // signature of the real ZZMI-PACKAGE-v1.5.0.zip, which "hello" obviously is not
        let sig = "MGUCMQC9baiLUEWwucRK8MEXphcjGDXa+aSEd8G+DJuHZRBAIII45JVLpJu3MykdfoMwksMCMDq40ZE1JTgXCC0eARELa3ltkIyZiiR5IRw5CFWH6d38v4x7RfbVueQxf+DSysT9+A==";
        assert!(verify(ZZMI_KEY, sig, b"hello").is_err());
        assert!(verify(LIBS_KEY, sig, b"hello").is_err());
    }

    #[test]
    fn characters_come_from_the_folder_name() {
        assert_eq!(detect_character("Yuzuha-BottomHeavy(NSFW)").as_deref(), Some("Yuzuha"));
        assert_eq!(detect_character("AriaSkin-BottomHeavy").as_deref(), Some("Aria"));
        assert_eq!(detect_character("NangongGothSkin-BottomHeavy").as_deref(), Some("Nangong"));
        assert_eq!(detect_character("ZhuYuan-BottomHeavy").as_deref(), Some("Zhu Yuan"));
        assert_eq!(detect_character("3D").as_deref(), None);
    }

    #[test]
    fn disabled_prefix_variants() {
        assert_eq!(strip_disabled("DISABLED Ellen Maid"), (false, "Ellen Maid".into()));
        assert_eq!(strip_disabled("DISABLED_Ellen"), (false, "Ellen".into()));
        assert_eq!(strip_disabled("Ellen"), (true, "Ellen".into()));
    }
}
