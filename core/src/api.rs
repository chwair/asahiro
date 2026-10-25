use std::path::PathBuf;
use std::sync::Mutex;
use std::time::{Duration, Instant};

use serde::{Deserialize, Serialize};
use serde_json::Value;

use crate::util::{cache_dir, err, md5_str, Result};

const API: &str = "https://sg-hyp-api.hoyoverse.com/hyp/hyp-connect/api";
const LAUNCHER_ID: &str = "VYTpXlbWo8";
pub const BIZ: &str = "nap_global";

#[derive(Serialize, Deserialize, Clone, Debug, Default)]
#[serde(default)]
pub struct Package {
    pub url: String,
    pub md5: String,
    pub size: String,
    pub decompressed_size: String,
    pub language: String,
}

impl Package {
    pub fn size(&self) -> u64 {
        self.size.parse().unwrap_or(0)
    }

    pub fn decompressed_size(&self) -> u64 {
        self.decompressed_size.parse().unwrap_or(0)
    }
}

#[derive(Serialize, Deserialize, Clone, Debug, Default)]
#[serde(default)]
pub struct PackageSet {
    pub version: String,
    pub game_pkgs: Vec<Package>,
    pub audio_pkgs: Vec<Package>,
    pub res_list_url: String,
}

#[derive(Serialize, Deserialize, Clone, Debug, Default)]
#[serde(default)]
pub struct Channel {
    pub major: Option<PackageSet>,
    pub patches: Vec<PackageSet>,
}

#[derive(Serialize, Deserialize, Clone, Debug, Default)]
#[serde(default)]
pub struct Manifest {
    pub main: Channel,
    pub pre_download: Channel,
}

impl Manifest {
    pub fn latest(&self) -> Result<&PackageSet> {
        match &self.main.major {
            Some(m) => Ok(m),
            None => err("the server did not return a game package"),
        }
    }

    pub fn predownload_version(&self) -> Option<&str> {
        self.pre_download.major.as_ref().map(|m| m.version.as_str()).filter(|v| !v.is_empty())
    }
}

#[derive(Serialize, Deserialize, Clone, Debug, Default)]
pub struct Art {
    pub background: String,
    pub video: Option<String>,
    pub theme: Option<String>,
    pub logo: String,
    pub icon: Option<String>,
    pub icon_hover: Option<String>,
    pub icon_link: Option<String>,
    pub title: String,
    #[serde(default)]
    pub shortcut_icon: Option<String>,
    pub local: ArtFiles,
}

#[derive(Serialize, Deserialize, Clone, Debug, Default)]
pub struct ArtFiles {
    pub background: Option<String>,
    pub video: Option<String>,
    pub theme: Option<String>,
    pub logo: Option<String>,
    pub icon: Option<String>,
    pub icon_hover: Option<String>,
    #[serde(default)]
    pub shortcut_icon: Option<String>,
}

pub fn agent() -> ureq::Agent {
    ureq::AgentBuilder::new()
        .timeout_connect(Duration::from_secs(15))
        .timeout_read(Duration::from_secs(60))
        .user_agent("Mozilla/5.0 (Windows NT 10.0; Win64; x64) HYPContainer/1.0")
        .build()
}

fn get_json(url: &str) -> Result<Value> {
    let v: Value = agent().get(url).call()?.into_json()?;
    if v["retcode"].as_i64().unwrap_or(-1) != 0 {
        return err(format!("api error: {}", v["message"].as_str().unwrap_or("unknown")));
    }
    Ok(v)
}

static MANIFEST: Mutex<Option<(Instant, Manifest)>> = Mutex::new(None);

pub fn manifest(force: bool) -> Result<Manifest> {
    let mut cached = MANIFEST.lock().unwrap();
    if !force {
        if let Some((at, m)) = cached.as_ref() {
            if at.elapsed() < Duration::from_secs(300) {
                return Ok(m.clone());
            }
        }
    }
    let v = get_json(&format!("{API}/getGamePackages?launcher_id={LAUNCHER_ID}"))?;
    let entry = v["data"]["game_packages"]
        .as_array()
        .and_then(|a| a.iter().find(|x| x["game"]["biz"] == BIZ))
        .cloned();
    let Some(entry) = entry else {
        return err("zenless zone zero is missing from the package list");
    };
    let mut m: Manifest = serde_json::from_value(entry)?;
    // the zip package list lags behind since hoyoplay moved to sophon downloads, so a released version can
    // still sit in pre_download. the branch list is current, so its tag decides which one is live
    if let Some(live) = live_version() {
        let stale = m.main.major.as_ref().is_some_and(|p| p.version != live);
        if stale && m.predownload_version() == Some(live.as_str()) {
            m.main = std::mem::take(&mut m.pre_download);
        }
    }
    *cached = Some((Instant::now(), m.clone()));
    Ok(m)
}

fn live_version() -> Option<String> {
    let v = get_json(&format!("{API}/getGameBranches?launcher_id={LAUNCHER_ID}")).ok()?;
    let branch = v["data"]["game_branches"].as_array()?.iter().find(|x| x["game"]["biz"] == BIZ)?;
    branch["main"]["tag"].as_str().filter(|t| !t.is_empty()).map(String::from)
}

fn art_cache_file() -> PathBuf {
    cache_dir().join("art.json")
}

// fetches the current launcher artwork, falling back to the last cached copy when offline
pub fn art(language: &str) -> Result<Art> {
    match fetch_art(language) {
        Ok(a) => {
            let _ = std::fs::write(art_cache_file(), serde_json::to_vec(&a)?);
            Ok(a)
        }
        Err(e) => match std::fs::read(art_cache_file()).ok().and_then(|b| serde_json::from_slice::<Art>(&b).ok()) {
            Some(mut a) => {
                a.local = local_files(&a, false);
                Ok(a)
            }
            None => Err(e),
        },
    }
}

fn fetch_art(language: &str) -> Result<Art> {
    let basic = get_json(&format!("{API}/getAllGameBasicInfo?launcher_id={LAUNCHER_ID}&language={language}"))?;
    let games = get_json(&format!("{API}/getGames?launcher_id={LAUNCHER_ID}&language={language}"))?;
    let game = basic["data"]["game_info_list"]
        .as_array()
        .and_then(|a| a.iter().find(|x| x["game"]["biz"] == BIZ))
        .cloned()
        .unwrap_or(Value::Null);
    let display = games["data"]["games"]
        .as_array()
        .and_then(|a| a.iter().find(|x| x["biz"] == BIZ))
        .map(|g| g["display"].clone())
        .unwrap_or(Value::Null);

    let s = |v: &Value| v.as_str().filter(|s| !s.is_empty()).map(String::from);
    // video backgrounds take priority, matching the official launcher
    let bgs = game["backgrounds"].as_array().cloned().unwrap_or_default();
    let bg = bgs
        .iter()
        .find(|b| b["type"] == "BACKGROUND_TYPE_VIDEO")
        .or_else(|| bgs.first())
        .cloned()
        .unwrap_or(Value::Null);

    let mut a = Art {
        background: s(&bg["background"]["url"]).or_else(|| s(&display["background"]["url"])).unwrap_or_default(),
        video: if bg["type"] == "BACKGROUND_TYPE_VIDEO" { s(&bg["video"]["url"]) } else { None },
        theme: s(&bg["theme"]["url"]),
        logo: s(&display["logo"]["url"]).unwrap_or_default(),
        icon: s(&bg["icon"]["url"]),
        icon_hover: s(&bg["icon"]["hover_url"]),
        icon_link: s(&bg["icon"]["link"]),
        title: s(&display["name"]).unwrap_or_else(|| "Zenless Zone Zero".into()),
        // the windows desktop shortcut icon, used for the macos game shortcut
        shortcut_icon: s(&display["shortcut"]["url"]),
        local: ArtFiles::default(),
    };
    a.local = local_files(&a, true);
    Ok(a)
}

static IN_FLIGHT: Mutex<std::collections::BTreeSet<String>> = Mutex::new(std::collections::BTreeSet::new());

fn cached_path(url: &str) -> PathBuf {
    let ext = url.rsplit('.').next().filter(|e| e.len() <= 5).unwrap_or("bin");
    let dir = cache_dir().join("art");
    let _ = std::fs::create_dir_all(&dir);
    dir.join(format!("{}.{}", md5_str(url), ext))
}

pub fn cache_url(url: &str) -> Result<PathBuf> {
    let p = cached_path(url);
    if p.exists() {
        return Ok(p);
    }
    let resp = agent().get(url).call()?;
    let tmp = p.with_extension("part");
    let mut f = std::fs::File::create(&tmp)?;
    std::io::copy(&mut resp.into_reader(), &mut f)?;
    std::fs::rename(&tmp, &p)?;
    Ok(p)
}

// images are fetched inline since they are small, the video is cached in the background
fn local_files(a: &Art, download: bool) -> ArtFiles {
    let get = |u: &Option<String>| -> Option<String> {
        let u = u.as_ref()?;
        let p = if download { cache_url(u).ok()? } else { cached_path(u) };
        p.exists().then(|| p.to_string_lossy().into_owned())
    };
    let video = a.video.as_ref().and_then(|u| {
        let p = cached_path(u);
        if p.exists() {
            Some(p.to_string_lossy().into_owned())
        } else {
            if download && IN_FLIGHT.lock().unwrap().insert(u.clone()) {
                let u = u.clone();
                std::thread::spawn(move || {
                    let _ = cache_url(&u);
                    IN_FLIGHT.lock().unwrap().remove(&u);
                });
            }
            None
        }
    });
    ArtFiles {
        background: get(&Some(a.background.clone()).filter(|s| !s.is_empty())),
        video,
        theme: get(&a.theme),
        logo: get(&Some(a.logo.clone()).filter(|s| !s.is_empty())),
        icon: get(&a.icon),
        icon_hover: get(&a.icon_hover),
        shortcut_icon: get(&a.shortcut_icon),
    }
}
