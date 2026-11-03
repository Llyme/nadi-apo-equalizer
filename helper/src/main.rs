//! The equalizer plugin's helper: what the plugin cannot do in its sandbox. It reads Equalizer APO's configuration, writes the plugin's
//! own configuration file, points Equalizer APO's config.txt at it (and back at what it named before), lists the playback devices, and
//! keeps the plugin's state.
//!
//! It talks in lines of JSON: one command a line on its input (`{ "cmd": ... }`), one answer a line on its output (`{ "type": ... }`).
//!
//! - `hello`: everything the plugin needs at its start: whether Equalizer APO is there, the curve it plays now, the devices, the
//!   plugin's saved state, and which file Equalizer APO reads now.
//! - `apply` `{ text }`: the plugin's curve written (Equalizer APO hears it a moment later) and config.txt pointed at it.
//! - `release`: config.txt pointed back at what it read before (another app's file, or none).
//! - `save` `{ state }`: the plugin's state kept.

use serde_json::{json, Value};
use std::fs;
use std::io::{BufRead, Write};
use std::path::{Path, PathBuf};

/// the plugin's own file, in Equalizer APO's config folder
const OURS: &str = "nadi-eq.txt";

fn main() {
    let stdin = std::io::stdin();
    let mut out = std::io::stdout();
    for line in stdin.lock().lines() {
        let Ok(line) = line else { break };
        let Ok(cmd) = serde_json::from_str::<Value>(line.trim()) else { continue };
        let reply = match cmd["cmd"].as_str().unwrap_or("") {
            "hello" => hello(),
            "apply" => apply(cmd["text"].as_str().unwrap_or("")),
            "release" => release(),
            "save" => save(&cmd["state"]),
            other => json!({ "type": "error", "error": format!("unknown command: {other}") }),
        };
        let _ = writeln!(out, "{reply}");
        let _ = out.flush();
    }
}

/// Equalizer APO's config folder (from its registry key, else where it installs).
fn config_dir() -> Option<PathBuf> {
    let from_reg = reg_string(r"SOFTWARE\EqualizerAPO", "ConfigPath").map(PathBuf::from);
    let default = std::env::var_os("ProgramFiles").map(|p| PathBuf::from(p).join("EqualizerAPO").join("config"));
    from_reg.into_iter().chain(default).find(|d| d.join("config.txt").is_file())
}

/// The plugin's own folder for what it keeps.
fn data_dir() -> PathBuf {
    std::env::var_os("NADI_PLUGIN_DATA").map(PathBuf::from).unwrap_or_else(|| PathBuf::from("."))
}

fn hello() -> Value {
    let Some(dir) = config_dir() else {
        return json!({ "type": "hello", "apo": false, "devices": devices(), "state": load_state() });
    };
    let config = fs::read_to_string(dir.join("config.txt")).unwrap_or_default();
    let includes: Vec<String> = config.lines().filter_map(include_of).collect();
    // (what Equalizer APO reads now besides the plugin's own: another app's file, most often)
    let theirs = includes.iter().find(|i| !i.eq_ignore_ascii_case(OURS)).cloned().or_else(|| remembered_include());
    let current = theirs.as_ref().and_then(|f| fs::read_to_string(dir.join(f)).ok()).map(|t| parse_apo(&t));
    json!({
        "type": "hello",
        "apo": true,
        "dir": dir.to_string_lossy(),
        "writable": writable(&dir),
        "ours": includes.iter().any(|i| i.eq_ignore_ascii_case(OURS)),
        "theirs": theirs,
        "current": current,
        "devices": devices(),
        "state": load_state(),
    })
}

/// The file an `Include:` line names.
fn include_of(line: &str) -> Option<String> {
    let l = line.trim();
    let rest = l.strip_prefix("Include:").or_else(|| l.strip_prefix("include:"))?;
    let f = rest.trim();
    (!f.is_empty()).then(|| f.to_string())
}

fn writable(dir: &Path) -> bool {
    let probe = dir.join(".nadi-write-test");
    let ok = fs::write(&probe, b"").is_ok();
    let _ = fs::remove_file(&probe);
    ok
}

/// What config.txt included before the plugin took its place (kept, so it can be given back).
fn remembered_include() -> Option<String> {
    fs::read_to_string(data_dir().join("their-include.txt")).ok().map(|s| s.trim().to_string()).filter(|s| !s.is_empty())
}

fn apply(text: &str) -> Value {
    let Some(dir) = config_dir() else { return json!({ "type": "applied", "ok": false, "error": "Equalizer APO is not installed." }) };
    let tmp = dir.join(format!("{OURS}.tmp"));
    let body = format!("# Written by NADI's equalizer plugin. Changes made here are overwritten.\r\n{}", text.replace("\r\n", "\n").replace('\n', "\r\n"));
    if let Err(e) = fs::write(&tmp, body).and_then(|_| fs::rename(&tmp, dir.join(OURS))) {
        return json!({ "type": "applied", "ok": false, "error": e.to_string() });
    }
    // (config.txt: the plugin's file in place of what it read; that kept, to give back)
    let cfg = dir.join("config.txt");
    let config = fs::read_to_string(&cfg).unwrap_or_default();
    let lines: Vec<&str> = config.lines().collect();
    if lines.iter().any(|l| include_of(l).is_some_and(|f| f.eq_ignore_ascii_case(OURS))) && !lines.iter().any(|l| include_of(l).is_some_and(|f| !f.eq_ignore_ascii_case(OURS))) {
        return json!({ "type": "applied", "ok": true });
    }
    let _ = fs::create_dir_all(data_dir());
    if !data_dir().join("config.before.txt").is_file() {
        let _ = fs::write(data_dir().join("config.before.txt"), &config);
    }
    let mut theirs = None;
    let mut out: Vec<String> = Vec::new();
    let mut placed = false;
    for l in &lines {
        match include_of(l) {
            Some(f) if f.eq_ignore_ascii_case(OURS) => {
                if !placed {
                    out.push(format!("Include: {OURS}"));
                    placed = true;
                }
            }
            Some(f) => {
                theirs.get_or_insert(f);
                if !placed {
                    out.push(format!("Include: {OURS}"));
                    placed = true;
                }
            }
            None => out.push(l.to_string()),
        }
    }
    if !placed {
        out.push(format!("Include: {OURS}"));
    }
    if let Some(t) = &theirs {
        let _ = fs::write(data_dir().join("their-include.txt"), t);
    }
    match fs::write(&cfg, out.join("\r\n") + "\r\n") {
        Ok(_) => json!({ "type": "applied", "ok": true }),
        Err(e) => json!({ "type": "applied", "ok": false, "error": e.to_string() }),
    }
}

fn release() -> Value {
    let Some(dir) = config_dir() else { return json!({ "type": "released", "ok": false }) };
    let cfg = dir.join("config.txt");
    let config = fs::read_to_string(&cfg).unwrap_or_default();
    let theirs = remembered_include();
    let mut out: Vec<String> = Vec::new();
    for l in config.lines() {
        match include_of(l) {
            Some(f) if f.eq_ignore_ascii_case(OURS) => {
                if let Some(t) = &theirs {
                    out.push(format!("Include: {t}"));
                }
            }
            _ => out.push(l.to_string()),
        }
    }
    let ok = fs::write(&cfg, out.join("\r\n") + "\r\n").is_ok();
    json!({ "type": "released", "ok": ok, "theirs": theirs })
}

fn save(state: &Value) -> Value {
    let _ = fs::create_dir_all(data_dir());
    let tmp = data_dir().join("state.json.tmp");
    let ok = fs::write(&tmp, state.to_string()).and_then(|_| fs::rename(&tmp, data_dir().join("state.json"))).is_ok();
    json!({ "type": "saved", "ok": ok })
}

fn load_state() -> Value {
    fs::read_to_string(data_dir().join("state.json")).ok().and_then(|t| serde_json::from_str(&t).ok()).unwrap_or(Value::Null)
}

// ------------------------------------------------------------------------------------------------------------- reading the curves

/// A band: its frequency, gain, Q and type (Equalizer APO's: PK, LS, HS, LP, HP, BP, NO, AP).
fn band(f: f64, g: f64, q: f64, t: &str) -> Value {
    json!({ "f": f, "g": g, "q": q, "t": t })
}

/// Equalizer APO's own lines: its preamp and its filters (each `Filter n: ON PK Fc 100 Hz Gain 3 dB Q 1.41`).
fn parse_apo(text: &str) -> Value {
    let mut preamp = 0.0;
    let mut bands = Vec::new();
    for l in text.lines() {
        let l = l.trim();
        if let Some(r) = l.strip_prefix("Preamp:") {
            preamp = r.trim().trim_end_matches("dB").trim().parse().unwrap_or(0.0);
            continue;
        }
        let Some((head, rest)) = l.split_once(':') else { continue };
        if !head.trim_start().starts_with("Filter") {
            continue;
        }
        let w: Vec<&str> = rest.split_whitespace().collect();
        if w.first() != Some(&"ON") || w.len() < 2 {
            continue;
        }
        let t = match w[1] {
            "LSC" | "LS" => "LS",
            "HSC" | "HS" => "HS",
            "LP" | "LPQ" => "LP",
            "HP" | "HPQ" => "HP",
            "BP" => "BP",
            "NO" => "NO",
            "AP" => "AP",
            _ => "PK",
        };
        let after = |key: &str| w.iter().position(|x| *x == key).and_then(|i| w.get(i + 1)).and_then(|v| v.parse::<f64>().ok());
        bands.push(band(after("Fc").unwrap_or(1000.0), after("Gain").unwrap_or(0.0), after("Q").unwrap_or(1.41), t));
    }
    json!({ "preamp": preamp, "bands": bands })
}

// ------------------------------------------------------------------------------------------------------------- Windows

fn reg_string(key: &str, name: &str) -> Option<String> {
    use windows::core::HSTRING;
    use windows::Win32::System::Registry::{RegGetValueW, HKEY_LOCAL_MACHINE, RRF_RT_REG_SZ};
    let mut buf = vec![0u16; 1024];
    let mut len = (buf.len() * 2) as u32;
    unsafe {
        RegGetValueW(HKEY_LOCAL_MACHINE, &HSTRING::from(key), &HSTRING::from(name), RRF_RT_REG_SZ, None, Some(buf.as_mut_ptr() as *mut _), Some(&mut len)).ok().ok()?;
    }
    let n = (len as usize / 2).saturating_sub(1);
    Some(String::from_utf16_lossy(&buf[..n.min(buf.len())]))
}

/// The playback devices in use (their names, as Equalizer APO's `Device:` lines can name them).
fn devices() -> Vec<String> {
    use windows::Win32::Devices::FunctionDiscovery::PKEY_Device_FriendlyName;
    use windows::Win32::Media::Audio::{eRender, IMMDeviceEnumerator, MMDeviceEnumerator, DEVICE_STATE_ACTIVE};
    use windows::Win32::System::Com::{CoCreateInstance, CoInitializeEx, CLSCTX_ALL, COINIT_MULTITHREADED, STGM_READ};
    let mut out = Vec::new();
    unsafe {
        let _ = CoInitializeEx(None, COINIT_MULTITHREADED);
        let Ok(en) = CoCreateInstance::<_, IMMDeviceEnumerator>(&MMDeviceEnumerator, None, CLSCTX_ALL) else { return out };
        let Ok(list) = en.EnumAudioEndpoints(eRender, DEVICE_STATE_ACTIVE) else { return out };
        let n = list.GetCount().unwrap_or(0);
        for i in 0..n {
            let Ok(d) = list.Item(i) else { continue };
            let Ok(store) = d.OpenPropertyStore(STGM_READ) else { continue };
            let Ok(v) = store.GetValue(&PKEY_Device_FriendlyName) else { continue };
            let name = v.to_string();
            if !name.is_empty() {
                out.push(name);
            }
        }
    }
    out
}
