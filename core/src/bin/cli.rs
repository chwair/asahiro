// debugging front end: asahiro-cli '{"cmd":"get_state"}'
use std::sync::mpsc;
use std::sync::Arc;

use serde_json::Value;

const TASKS: [&str; 10] = ["install", "update", "apply_predownload", "predownload", "verify", "create_bottle", "apply_bottle", "launch", "zzmi_install", "import_mod"];

fn main() {
    let arg = std::env::args().nth(1).unwrap_or_else(|| r#"{"cmd":"get_state"}"#.into());
    let req: Value = match serde_json::from_str(&arg) {
        Ok(v) => v,
        Err(_) => serde_json::json!({ "cmd": arg }),
    };
    let cmd = req["cmd"].as_str().unwrap_or("").to_string();
    if !TASKS.contains(&cmd.as_str()) {
        match asahiro_core::call(&req) {
            Ok(v) => println!("{}", serde_json::to_string_pretty(&v).unwrap()),
            Err(e) => {
                eprintln!("error: {}", e);
                std::process::exit(1);
            }
        }
        return;
    }
    let (tx, rx) = mpsc::channel::<Value>();
    let tx = std::sync::Mutex::new(tx);
    asahiro_core::spawn(req, Arc::new(move |v| {
        let _ = tx.lock().unwrap().send(v);
    }));
    for ev in rx {
        println!("{}", ev);
        if ev["type"] == "finished" {
            std::process::exit(if ev["ok"] == true { 0 } else { 1 });
        }
    }
}
