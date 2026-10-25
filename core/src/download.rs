use std::fs::OpenOptions;
use std::io::{Read, Write};
use std::path::{Path, PathBuf};
use std::time::Duration;

use crate::api::agent;
use crate::util::{err, human_size, md5_file, Result, Speed, Task};

// overall byte accounting so several files can share one progress bar
pub struct Meter<'a> {
    pub task: &'a Task,
    pub label: String,
    pub done: u64,
    pub total: u64,
    speed: Speed,
}

impl<'a> Meter<'a> {
    pub fn new(task: &'a Task, label: impl Into<String>, total: u64) -> Self {
        Meter { task, label: label.into(), done: 0, total, speed: Speed::new() }
    }

    pub fn add(&mut self, n: u64) {
        self.done += n;
        let bps = self.speed.push(self.done);
        let frac = if self.total > 0 { (self.done as f64 / self.total as f64).min(1.0) } else { 0.0 };
        let mut detail = format!("{}  {} / {}", self.label, human_size(self.done), human_size(self.total));
        if bps > 0.0 {
            detail.push_str(&format!("  ·  {}/s", human_size(bps as u64)));
        }
        self.task.progress(Some(frac), detail);
    }

    // a pause leaves a gap that would drag the speed average down for a while
    pub fn reset_speed(&mut self) {
        self.speed = Speed::new();
    }
}

fn ok_marker(dest: &Path) -> PathBuf {
    let mut s = dest.as_os_str().to_owned();
    s.push(".ok");
    PathBuf::from(s)
}

// true when the file is already complete and verified
pub fn is_complete(dest: &Path, size: u64, md5: &str) -> bool {
    let Ok(meta) = std::fs::metadata(dest) else { return false };
    if size > 0 && meta.len() != size {
        return false;
    }
    match std::fs::read_to_string(ok_marker(dest)) {
        Ok(m) => md5.is_empty() || m.trim().eq_ignore_ascii_case(md5),
        Err(_) => false,
    }
}

pub fn remove(dest: &Path) {
    let _ = std::fs::remove_file(dest);
    let _ = std::fs::remove_file(ok_marker(dest));
}

// resumable download with md5 verification. bytes are reported to the meter as they arrive
pub fn fetch(meter: &mut Meter, url: &str, dest: &Path, size: u64, md5: &str) -> Result<()> {
    if is_complete(dest, size, md5) {
        meter.add(size);
        return Ok(());
    }
    if let Some(parent) = dest.parent() {
        std::fs::create_dir_all(parent)?;
    }
    let name = url.rsplit('/').next().unwrap_or(url).to_string();
    let start_done = meter.done;
    let mut attempts = 0;
    loop {
        meter.task.check()?;
        let have = std::fs::metadata(dest).map(|m| m.len()).unwrap_or(0);
        // the size can already match when a previous run (or another launcher) finished the file
        if size > 0 && have >= size {
            break;
        }
        meter.done = start_done + have;
        meter.task.phase("download");
        meter.task.status(format!("Downloading {}", name));
        match stream(meter, url, dest, have) {
            Ok(()) => break,
            Err(e) if e.0 == "cancelled" => return Err(e),
            // the connection was dropped on purpose, the next round picks up from the partial file
            Err(e) if e.0 == "paused" => {
                meter.task.wait_resumed()?;
                meter.reset_speed();
            }
            Err(e) => {
                attempts += 1;
                meter.task.log(format!("download error ({}), retry {}: {}", name, attempts, e));
                if attempts >= 8 {
                    return Err(e);
                }
                std::thread::sleep(Duration::from_secs(2u64.pow(attempts.min(4))));
            }
        }
    }
    meter.done = start_done + size;

    if !md5.is_empty() {
        meter.task.phase("verify");
        meter.task.status(format!("Verifying {}", name));
        let task = meter.task;
        let mut seen = 0u64;
        let got = md5_file(dest, |n| {
            seen += n;
            task.progress(Some(seen as f64 / size.max(1) as f64), format!("Verifying {}  {}", name, human_size(seen)));
            task.check()
        })?;
        if !got.eq_ignore_ascii_case(md5) {
            remove(dest);
            return err(format!("checksum mismatch for {}, it was deleted so the next attempt starts clean", name));
        }
    }
    std::fs::write(ok_marker(dest), md5)?;
    Ok(())
}

fn stream(meter: &mut Meter, url: &str, dest: &Path, have: u64) -> Result<()> {
    let mut req = agent().get(url);
    if have > 0 {
        req = req.set("Range", &format!("bytes={}-", have));
    }
    let resp = req.call()?;
    let append = have > 0 && resp.status() == 206;
    let mut file = if append {
        OpenOptions::new().append(true).open(dest)?
    } else {
        meter.done -= have;
        OpenOptions::new().create(true).write(true).truncate(true).open(dest)?
    };
    let mut reader = resp.into_reader();
    let mut buf = vec![0u8; 1 << 20];
    loop {
        meter.task.check_cancel()?;
        if meter.task.paused() {
            file.flush()?;
            return err("paused");
        }
        let n = reader.read(&mut buf)?;
        if n == 0 {
            break;
        }
        file.write_all(&buf[..n])?;
        meter.add(n as u64);
    }
    file.flush()?;
    Ok(())
}

// plain download for small files, used for repairs and tools
pub fn fetch_simple(task: &Task, url: &str, dest: &Path) -> Result<()> {
    if let Some(parent) = dest.parent() {
        std::fs::create_dir_all(parent)?;
    }
    let tmp = dest.with_extension("asahiro-part");
    let mut attempts = 0;
    loop {
        task.check()?;
        let res = (|| -> Result<()> {
            let resp = agent().get(url).call()?;
            let mut f = std::fs::File::create(&tmp)?;
            std::io::copy(&mut resp.into_reader(), &mut f)?;
            Ok(())
        })();
        match res {
            Ok(()) => break,
            Err(e) => {
                attempts += 1;
                if attempts >= 5 {
                    return Err(e);
                }
                std::thread::sleep(Duration::from_secs(2));
            }
        }
    }
    std::fs::rename(&tmp, dest)?;
    Ok(())
}
