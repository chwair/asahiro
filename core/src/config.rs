use std::collections::BTreeMap;

use serde::{Deserialize, Serialize};

use crate::util::{data_dir, expand, home, Result};

#[derive(Serialize, Deserialize, Clone, Copy, Debug, PartialEq, Eq)]
#[serde(rename_all = "lowercase")]
pub enum GraphicsBackend {
    Dxmt,
    D3dmetal,
    Dxvk,
    Wined3d,
}

impl GraphicsBackend {
    pub fn as_str(&self) -> &'static str {
        match self {
            GraphicsBackend::Dxmt => "dxmt",
            GraphicsBackend::D3dmetal => "d3dmetal",
            GraphicsBackend::Dxvk => "dxvk",
            GraphicsBackend::Wined3d => "wined3d",
        }
    }
}

#[derive(Serialize, Deserialize, Clone, Copy, Debug, PartialEq, Eq)]
#[serde(rename_all = "lowercase")]
pub enum RunnerKind {
    Bundled,
    Crossover,
}

#[derive(Serialize, Deserialize, Clone, Debug)]
#[serde(default)]
pub struct BottleConfig {
    pub name: String,
    pub windows_version: String,
    pub graphics_backend: GraphicsBackend,
    pub msync: bool,
    pub metal_hud: bool,
    pub metalfx: bool,
    pub dlss: bool,
    pub retina: bool,
    pub left_cmd_is_ctrl: bool,
    pub left_option_is_alt: bool,
    pub right_option_is_alt: bool,
    pub env: BTreeMap<String, String>,
    pub dll_overrides: String,
}

impl Default for BottleConfig {
    fn default() -> Self {
        BottleConfig {
            name: "Asahiro".into(),
            windows_version: "win10".into(),
            graphics_backend: default_backend(),
            msync: true,
            metal_hud: false,
            metalfx: false,
            dlss: false,
            retina: false,
            left_cmd_is_ctrl: true,
            left_option_is_alt: true,
            right_option_is_alt: true,
            env: BTreeMap::new(),
            dll_overrides: String::new(),
        }
    }
}

#[derive(Serialize, Deserialize, Clone, Debug)]
#[serde(default)]
pub struct Config {
    pub game_dir: String,
    pub crossover_path: String,
    pub runner: RunnerKind,
    pub voice_packs: Vec<String>,
    pub bottle: BottleConfig,
    pub custom_resolution: bool,
    pub resolution_width: u32,
    pub resolution_height: u32,
    pub fullscreen: bool,
    pub use_d3d12: bool,
    pub launch_args: String,
    pub hide_launcher_while_playing: bool,
    pub launch_fix: bool,
    pub steam_patch: bool,
    pub mods_enabled: bool,
    pub mods_auto_update: bool,
    pub mods_hunting: bool,
}

impl Default for Config {
    fn default() -> Self {
        Config {
            game_dir: default_game_dir(),
            crossover_path: "/Applications/CrossOver.app".into(),
            runner: RunnerKind::Bundled,
            voice_packs: vec!["en-us".into()],
            bottle: BottleConfig::default(),
            custom_resolution: false,
            resolution_width: 1920,
            resolution_height: 1080,
            fullscreen: false,
            use_d3d12: false,
            launch_args: String::new(),
            hide_launcher_while_playing: true,
            launch_fix: false,
            steam_patch: true,
            mods_enabled: false,
            mods_auto_update: true,
            mods_hunting: false,
        }
    }
}

// d3dmetal runs zzz best but only ships inside crossover, so dxmt is the default without it
fn default_backend() -> GraphicsBackend {
    let gptk = "Contents/SharedSupport/CrossOver/lib64/apple_gptk/external/D3DMetal.framework";
    let found = [std::path::PathBuf::from("/Applications/CrossOver.app"), home().join("Applications/CrossOver.app")]
        .iter()
        .any(|app| app.join(gptk).exists());
    if found { GraphicsBackend::D3dmetal } else { GraphicsBackend::Dxmt }
}

// prefer an existing install over the stock location
fn default_game_dir() -> String {
    for candidate in ["~/ZZZ", "~/Games/ZenlessZoneZero"] {
        let p = expand(candidate);
        if p.join("ZenlessZoneZero.exe").exists() || p.join(".ariatmp").exists() {
            return p.to_string_lossy().into_owned();
        }
    }
    home().join("Games/ZenlessZoneZero").to_string_lossy().into_owned()
}

impl Config {
    pub fn path() -> std::path::PathBuf {
        data_dir().join("config.json")
    }

    pub fn load() -> Config {
        std::fs::read(Self::path())
            .ok()
            .and_then(|b| serde_json::from_slice(&b).ok())
            .unwrap_or_default()
    }

    pub fn save(&self) -> Result<()> {
        let tmp = Self::path().with_extension("json.tmp");
        std::fs::write(&tmp, serde_json::to_vec_pretty(self)?)?;
        std::fs::rename(tmp, Self::path())?;
        Ok(())
    }

    pub fn game_path(&self) -> std::path::PathBuf {
        expand(&self.game_dir)
    }
}
