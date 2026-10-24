use std::fmt;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};
use std::time::Instant;

use serde_json::{json, Value};

#[derive(Debug)]
pub struct Error(pub String);

pub type Result<T> = std::result::Result<T, Error>;

impl fmt::Display for Error {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(&self.0)
    }
}

macro_rules! impl_from {
    ($($t:ty),*) => {
        $(impl From<$t> for Error {
            fn from(e: $t) -> Self { Error(e.to_string()) }
        })*
    };
}

impl_from!(std::io::Error, serde_json::Error, zip::result::ZipError, String, &str);

impl From<ureq::Error> for Error {
    fn from(e: ureq::Error) -> Self {
        match e {
            ureq::Error::Status(code, resp) => Error(format!("http {} for {}", code, resp.get_url())),
            other => Error(other.to_string()),
        }
    }
}

pub fn err<T>(msg: impl Into<String>) -> Result<T> {
    Err(Error(msg.into()))
}

pub fn home() -> PathBuf {
    PathBuf::from(std::env::var("HOME").unwrap_or_else(|_| "/tmp".into()))
}

pub fn data_dir() -> PathBuf {
    let p = home().join("Library/Application Support/Asahiro");
    let _ = std::fs::create_dir_all(&p);
    p
}

pub fn cache_dir() -> PathBuf {
    let p = home().join("Library/Caches/Asahiro");
    let _ = std::fs::create_dir_all(&p);
    p
}

pub fn logs_dir() -> PathBuf {
    let p = data_dir().join("logs");
    let _ = std::fs::create_dir_all(&p);
    p
}

// expands a leading ~ to the home directory
pub fn expand(p: &str) -> PathBuf {
    if p == "~" {
        home()
    } else if let Some(rest) = p.strip_prefix("~/") {
        home().join(rest)
    } else {
        PathBuf::from(p)
    }
}

pub fn free_space(path: &Path) -> Option<u64> {
    let mut probe = path.to_path_buf();
    while !probe.exists() {
        probe = probe.parent()?.to_path_buf();
    }
    let c = std::ffi::CString::new(probe.to_string_lossy().as_bytes()).ok()?;
    unsafe {
        let mut st: libc::statvfs = std::mem::zeroed();
        if libc::statvfs(c.as_ptr(), &mut st) == 0 {
            Some(st.f_bavail as u64 * st.f_frsize as u64)
        } else {
            None
        }
    }
}

pub fn human_size(bytes: u64) -> String {
    let units = ["B", "KB", "MB", "GB", "TB"];
    let mut v = bytes as f64;
    let mut i = 0;
    while v >= 1024.0 && i < units.len() - 1 {
        v /= 1024.0;
        i += 1;
    }
    if i == 0 {
        format!("{} B", bytes)
    } else {
        format!("{:.1} {}", v, units[i])
    }
}

pub fn md5_file(path: &Path, mut on_bytes: impl FnMut(u64) -> Result<()>) -> Result<String> {
    use md5::{Digest, Md5};
    use std::io::Read;
    let mut f = std::fs::File::open(path)?;
    let mut h = Md5::new();
    let mut buf = vec![0u8; 4 << 20];
    loop {
        let n = f.read(&mut buf)?;
        if n == 0 {
            break;
        }
        h.update(&buf[..n]);
        on_bytes(n as u64)?;
    }
    Ok(hex::encode(h.finalize()))
}

pub fn md5_str(s: &str) -> String {
    use md5::{Digest, Md5};
    hex::encode(Md5::digest(s.as_bytes()))
}

pub type Emitter = Arc<dyn Fn(Value) + Send + Sync>;

// handle passed to long running jobs for reporting progress and checking cancellation
#[derive(Clone)]
pub struct Task {
    emit: Emitter,
    cancel: Arc<AtomicBool>,
    last_progress: Arc<Mutex<Option<Instant>>>,
}

impl Task {
    pub fn new(emit: Emitter, cancel: Arc<AtomicBool>) -> Self {
        Task { emit, cancel, last_progress: Arc::new(Mutex::new(None)) }
    }

    pub fn status(&self, text: impl Into<String>) {
        (self.emit)(json!({ "type": "status", "text": text.into() }));
    }

    pub fn log(&self, text: impl Into<String>) {
        (self.emit)(json!({ "type": "log", "text": text.into() }));
    }

    // fraction of None means indeterminate. throttled to ~12 updates per second
    pub fn progress(&self, fraction: Option<f64>, detail: impl Into<String>) {
        let mut last = self.last_progress.lock().unwrap();
        let now = Instant::now();
        let force = matches!(fraction, Some(f) if f >= 1.0) || fraction.is_none();
        if !force {
            if let Some(t) = *last {
                if now.duration_since(t).as_millis() < 80 {
                    return;
                }
            }
        }
        *last = Some(now);
        drop(last);
        (self.emit)(json!({ "type": "progress", "fraction": fraction, "detail": detail.into() }));
    }

    pub fn event(&self, v: Value) {
        (self.emit)(v);
    }

    pub fn cancelled(&self) -> bool {
        self.cancel.load(Ordering::Relaxed)
    }

    pub fn check(&self) -> Result<()> {
        if self.cancelled() {
            err("cancelled")
        } else {
            Ok(())
        }
    }
}

// tracks transfer speed with a sliding window
pub struct Speed {
    samples: std::collections::VecDeque<(Instant, u64)>,
}

impl Speed {
    pub fn new() -> Self {
        Speed { samples: Default::default() }
    }

    pub fn push(&mut self, total: u64) -> f64 {
        let now = Instant::now();
        self.samples.push_back((now, total));
        while self.samples.len() > 2 && now.duration_since(self.samples[0].0).as_secs_f64() > 3.0 {
            self.samples.pop_front();
        }
        let (t0, b0) = self.samples[0];
        let dt = now.duration_since(t0).as_secs_f64();
        if dt <= 0.0 {
            0.0
        } else {
            (total - b0) as f64 / dt
        }
    }
}
