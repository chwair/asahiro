use std::fs::File;
use std::io::{self, BufReader, Read, Seek, SeekFrom, Write};
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, Mutex};

use crate::util::{err, human_size, Result, Speed, Task};

// presents split volumes (.zip.001, .zip.002, ...) as one seekable stream so they never need to be concatenated
pub struct MultiReader {
    parts: Vec<(File, u64)>,
    total: u64,
    pos: u64,
}

impl MultiReader {
    pub fn open(paths: &[PathBuf]) -> io::Result<Self> {
        let mut parts = Vec::new();
        let mut total = 0;
        for p in paths {
            let f = File::open(p)?;
            let len = f.metadata()?.len();
            total += len;
            parts.push((f, len));
        }
        Ok(MultiReader { parts, total, pos: 0 })
    }
}

impl Read for MultiReader {
    fn read(&mut self, buf: &mut [u8]) -> io::Result<usize> {
        let mut offset = self.pos;
        for (f, len) in self.parts.iter_mut() {
            if offset < *len {
                f.seek(SeekFrom::Start(offset))?;
                let want = buf.len().min((*len - offset) as usize);
                let n = f.read(&mut buf[..want])?;
                self.pos += n as u64;
                return Ok(n);
            }
            offset -= *len;
        }
        Ok(0)
    }
}

impl Seek for MultiReader {
    fn seek(&mut self, to: SeekFrom) -> io::Result<u64> {
        let next = match to {
            SeekFrom::Start(n) => n as i64,
            SeekFrom::End(n) => self.total as i64 + n,
            SeekFrom::Current(n) => self.pos as i64 + n,
        };
        if next < 0 {
            return Err(io::Error::new(io::ErrorKind::InvalidInput, "seek before start"));
        }
        self.pos = next as u64;
        Ok(self.pos)
    }
}

fn open_archive(parts: &[PathBuf]) -> Result<zip::ZipArchive<BufReader<MultiReader>>> {
    let reader = BufReader::with_capacity(1 << 20, MultiReader::open(parts)?);
    Ok(zip::ZipArchive::new(reader)?)
}

// extracts the archive into dest using several worker threads, reporting uncompressed bytes written
pub fn extract(task: &Task, parts: &[PathBuf], dest: &Path, label: &str) -> Result<Vec<String>> {
    let mut archive = open_archive(parts)?;
    let mut names = Vec::with_capacity(archive.len());
    let mut total = 0u64;
    let mut jobs = Vec::new();
    for i in 0..archive.len() {
        let entry = archive.by_index_raw(i)?;
        let Some(rel) = entry.enclosed_name() else {
            return err(format!("unsafe path in archive: {}", entry.name()));
        };
        total += entry.size();
        names.push(entry.name().to_string());
        jobs.push((i, rel, entry.is_dir(), entry.size()));
    }
    drop(archive);

    // biggest files first keeps the workers balanced
    jobs.sort_by(|a, b| b.3.cmp(&a.3));
    let jobs = Arc::new(Mutex::new(jobs));
    let written = Arc::new(AtomicU64::new(0));
    let failure: Arc<Mutex<Option<String>>> = Arc::new(Mutex::new(None));
    let workers = std::thread::available_parallelism().map(|n| n.get()).unwrap_or(4).clamp(2, 6);

    std::thread::scope(|s| {
        for _ in 0..workers {
            let jobs = jobs.clone();
            let written = written.clone();
            let failure = failure.clone();
            s.spawn(move || {
                let run = || -> Result<()> {
                    let mut archive = open_archive(parts)?;
                    let mut buf = vec![0u8; 1 << 20];
                    loop {
                        if failure.lock().unwrap().is_some() {
                            return Ok(());
                        }
                        task.check()?;
                        let Some((i, rel, is_dir, _)) = jobs.lock().unwrap().pop() else { return Ok(()) };
                        let out = dest.join(&rel);
                        if is_dir {
                            std::fs::create_dir_all(&out)?;
                            continue;
                        }
                        if let Some(p) = out.parent() {
                            std::fs::create_dir_all(p)?;
                        }
                        let mut entry = archive.by_index(i)?;
                        let mut f = File::create(&out)?;
                        loop {
                            let n = entry.read(&mut buf)?;
                            if n == 0 {
                                break;
                            }
                            f.write_all(&buf[..n])?;
                            written.fetch_add(n as u64, Ordering::Relaxed);
                        }
                    }
                };
                if let Err(e) = run() {
                    let mut f = failure.lock().unwrap();
                    if f.is_none() {
                        *f = Some(e.0);
                    }
                }
            });
        }

        // progress reporter on the calling thread
        let mut speed = Speed::new();
        loop {
            let done = written.load(Ordering::Relaxed);
            let bps = speed.push(done);
            task.progress(
                Some(if total > 0 { done as f64 / total as f64 } else { 0.0 }),
                format!("{}  {} / {}  ·  {}/s", label, human_size(done), human_size(total), human_size(bps as u64)),
            );
            let finished = jobs.lock().unwrap().is_empty() && Arc::strong_count(&written) == 1;
            if finished || failure.lock().unwrap().is_some() {
                break;
            }
            std::thread::sleep(std::time::Duration::from_millis(150));
        }
    });

    if let Some(e) = failure.lock().unwrap().take() {
        return Err(e.into());
    }
    task.check()?;
    Ok(names)
}
