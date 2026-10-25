pub mod api;
pub mod archive;
pub mod config;
pub mod download;
pub mod game;
pub mod mods;
pub mod runner;
pub mod util;
pub mod wine;

use std::collections::HashMap;
use std::ffi::{c_char, c_void, CStr, CString};
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::{Arc, Mutex};

use serde_json::{json, Value};

use crate::config::Config;
use crate::util::{err, Emitter, Result, Task};

static NEXT_TASK: AtomicU64 = AtomicU64::new(1);
// cancel and pause flags per running task
static TASKS: Mutex<Option<HashMap<u64, (Arc<AtomicBool>, Arc<AtomicBool>)>>> = Mutex::new(None);

// quick request/response commands
pub fn call(req: &Value) -> Result<Value> {
    let cmd = req["cmd"].as_str().unwrap_or("");
    match cmd {
        "get_config" => Ok(serde_json::to_value(Config::load())?),
        "set_config" => {
            let cfg: Config = serde_json::from_value(req["config"].clone())?;
            cfg.save()?;
            Ok(serde_json::to_value(cfg)?)
        }
        "get_state" => {
            let cfg = Config::load();
            let m = api::manifest(req["refresh"].as_bool().unwrap_or(false))?;
            Ok(serde_json::to_value(game::state(&cfg, &m)?)?)
        }
        "get_art" => Ok(serde_json::to_value(api::art(req["language"].as_str().unwrap_or("en-us"))?)?),
        "wine_info" => Ok(serde_json::to_value(wine::info(&Config::load()))?),
        "open_tool" => {
            wine::open_tool(&Config::load(), req["tool"].as_str().unwrap_or(""))?;
            Ok(Value::Null)
        }
        "stop_game" => {
            wine::stop_game(&Config::load());
            Ok(Value::Null)
        }
        "zzmi_status" => Ok(serde_json::to_value(mods::status(&Config::load(), req["refresh"].as_bool().unwrap_or(false)))?),
        "list_mods" => Ok(serde_json::to_value(mods::list()?)?),
        "set_mod_enabled" => Ok(Value::String(mods::set_enabled(
            req["id"].as_str().unwrap_or(""),
            req["enabled"].as_bool().unwrap_or(true),
        )?)),
        "set_mods_enabled" => {
            let ids: Vec<String> = serde_json::from_value(req["ids"].clone())?;
            Ok(serde_json::to_value(mods::set_enabled_many(&ids, req["enabled"].as_bool().unwrap_or(true))?)?)
        }
        "delete_bottle" => {
            wine::delete_bottle(&Config::load())?;
            Ok(Value::Null)
        }
        _ => err(format!("unknown command {}", cmd)),
    }
}

// long running commands that report progress through the task
pub fn run_task(task: &Task, req: &Value) -> Result<()> {
    let cfg = Config::load();
    let cmd = req["cmd"].as_str().unwrap_or("");
    match cmd {
        "install" => game::install(task, &cfg, &api::manifest(true)?),
        "update" => game::update(task, &cfg, &api::manifest(true)?, false),
        "apply_predownload" => {
            wine::restore_vulkan(&cfg.game_path());
            game::update(task, &cfg, &api::manifest(true)?, true)
        }
        "predownload" => game::predownload(task, &cfg, &api::manifest(true)?),
        "verify" => {
            wine::restore_vulkan(&cfg.game_path());
            game::verify(task, &cfg, &api::manifest(false)?)
        }
        "create_bottle" => wine::create_bottle(task, &cfg),
        "apply_bottle" => wine::apply_bottle(task, &cfg),
        "launch" => wine::launch(task, &cfg),
        "zzmi_install" => mods::install(task, &cfg),
        "import_mod" => {
            let added = mods::import(task, std::path::Path::new(req["path"].as_str().unwrap_or("")))?;
            task.event(json!({ "type": "mods_added", "ids": added }));
            Ok(())
        }
        _ => err(format!("unknown task {}", cmd)),
    }
}

pub fn spawn(req: Value, emit: Emitter) -> u64 {
    let id = NEXT_TASK.fetch_add(1, Ordering::Relaxed);
    let cancel = Arc::new(AtomicBool::new(false));
    let pause = Arc::new(AtomicBool::new(false));
    TASKS.lock().unwrap().get_or_insert_with(HashMap::new).insert(id, (cancel.clone(), pause.clone()));
    std::thread::spawn(move || {
        let task = Task::new(emit.clone(), cancel, pause);
        let res = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| run_task(&task, &req)));
        let done = match res {
            Ok(Ok(())) => json!({ "type": "finished", "ok": true }),
            Ok(Err(e)) => json!({ "type": "finished", "ok": false, "error": e.0, "cancelled": e.0 == "cancelled" }),
            Err(_) => json!({ "type": "finished", "ok": false, "error": "internal error (panic)" }),
        };
        if let Some(map) = TASKS.lock().unwrap().as_mut() {
            map.remove(&id);
        }
        emit(done);
    });
    id
}

pub fn cancel(id: u64) {
    if let Some((flag, _)) = TASKS.lock().unwrap().as_ref().and_then(|m| m.get(&id)) {
        flag.store(true, Ordering::Relaxed);
    }
}

pub fn pause(id: u64, paused: bool) {
    if let Some((_, flag)) = TASKS.lock().unwrap().as_ref().and_then(|m| m.get(&id)) {
        flag.store(paused, Ordering::Relaxed);
    }
}

fn to_c(s: String) -> *mut c_char {
    CString::new(s.replace('\0', "")).unwrap().into_raw()
}

unsafe fn from_c(p: *const c_char) -> Value {
    if p.is_null() {
        return Value::Null;
    }
    serde_json::from_slice(CStr::from_ptr(p).to_bytes()).unwrap_or(Value::Null)
}

/// # Safety
/// `request` must be a valid nul terminated utf-8 string. free the result with `asahiro_free`.
#[no_mangle]
pub unsafe extern "C" fn asahiro_call(request: *const c_char) -> *mut c_char {
    let req = from_c(request);
    let res = std::panic::catch_unwind(|| call(&req));
    let v = match res {
        Ok(Ok(data)) => json!({ "ok": true, "data": data }),
        Ok(Err(e)) => json!({ "ok": false, "error": e.0 }),
        Err(_) => json!({ "ok": false, "error": "internal error (panic)" }),
    };
    to_c(v.to_string())
}

struct Ctx(*mut c_void);
unsafe impl Send for Ctx {}
unsafe impl Sync for Ctx {}

pub type EventCallback = extern "C" fn(ctx: *mut c_void, event: *const c_char);

/// # Safety
/// `callback` is invoked from a background thread until an event with type "finished" arrives.
/// the json string passed to it is only valid during the call.
#[no_mangle]
pub unsafe extern "C" fn asahiro_spawn(request: *const c_char, callback: EventCallback, ctx: *mut c_void) -> u64 {
    let req = from_c(request);
    let ctx = Arc::new(Ctx(ctx));
    let emit: Emitter = Arc::new(move |v: Value| {
        let s = CString::new(v.to_string().replace('\0', "")).unwrap();
        callback(ctx.0, s.as_ptr());
    });
    spawn(req, emit)
}

#[no_mangle]
pub extern "C" fn asahiro_cancel(task: u64) {
    cancel(task)
}

#[no_mangle]
pub extern "C" fn asahiro_pause(task: u64, paused: bool) {
    pause(task, paused)
}

/// # Safety
/// `s` must come from `asahiro_call`.
#[no_mangle]
pub unsafe extern "C" fn asahiro_free(s: *mut c_char) {
    if !s.is_null() {
        drop(CString::from_raw(s));
    }
}
