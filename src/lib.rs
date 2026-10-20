//! CodeStrike's local text, search, and explicit Cargo core.

use regex::RegexBuilder;
use ropey::Rope;
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use std::fs;
use std::io::{Read, Write};
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

mod process_scope;
use process_scope::ProcessScope;

/// Offline protocol boundary for a future per-user local agent panel.
pub mod agent_adapter;
/// Bounded local app-server process and event transport.
pub mod agent_session;
/// Read-only snapshot gate for a reviewed agent file change.
pub mod agent_review;
/// Session state and reviewed approval flow for a local agent panel.
pub mod agent_panel;
/// Local Unity MCP mutation coordination contract.
pub mod unity_writer;
/// Source-only Unity snapshot and typed action contract.
pub mod unity_action;
/// Local Unity project detection and read-only MCP capability discovery.
pub mod unity_connection;

const MAX_FILE: u64 = 20 * 1024 * 1024;
const MAX_SEARCH_BYTES: u64 = 100 * 1024 * 1024;
const MAX_HITS: usize = 500;
const MAX_CAPTURE_PER_STREAM: usize = 4 * 1024 * 1024;
static NEXT_TRANSACTION_ID: AtomicU64 = AtomicU64::new(0);

struct PendingFile { path: PathBuf, owned: bool }
impl PendingFile {
    fn create(target: &Path, tag: &str) -> Result<(Self, fs::File)> {
        let name = target.file_name().ok_or_else(|| Error("transaction target has no file name".into()))?.to_string_lossy();
        let nonce = SystemTime::now().duration_since(UNIX_EPOCH).map_err(err)?.as_nanos();
        for _ in 0..32 {
            let id = NEXT_TRANSACTION_ID.fetch_add(1, Ordering::Relaxed);
            let path = target.with_file_name(format!("{name}.codestrike-{tag}-{}-{nonce}-{id}.tmp", std::process::id()));
            match fs::OpenOptions::new().write(true).create_new(true).open(&path) {
                Ok(file) => return Ok((Self { path, owned: true }, file)),
                Err(e) if e.kind() == std::io::ErrorKind::AlreadyExists => continue,
                Err(e) => return Err(err(e)),
            }
        }
        Err(Error("could not allocate a unique transaction file".into()))
    }
    fn disarm(&mut self) { self.owned = false; }
}
impl Drop for PendingFile {
    fn drop(&mut self) { if self.owned { let _ = fs::remove_file(&self.path); } }
}

#[derive(Debug)]
pub struct Error(String);
impl std::fmt::Display for Error {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str(&self.0)
    }
}
impl std::error::Error for Error {}
type Result<T> = std::result::Result<T, Error>;
fn err(e: impl std::fmt::Display) -> Error {
    Error(e.to_string())
}
fn digest(bytes: &[u8]) -> String {
    format!("{:x}", Sha256::digest(bytes))
}
fn optional_digest(path: &Path) -> Result<Option<String>> {
    match fs::read(path) {
        Ok(bytes) => Ok(Some(digest(&bytes))),
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => Ok(None),
        Err(e) => Err(err(e)),
    }
}

#[derive(Serialize, Deserialize)]
struct Recovery {
    original_sha256: String,
    bom: bool,
    text: String,
}

pub struct Document {
    path: PathBuf,
    rope: Rope,
    bom: bool,
    newline: &'static str,
    disk_hash: String,
    recovery_hash: Option<String>,
    recovery_owned: bool,
    read_only_reason: Option<String>,
    undo: Vec<Rope>,
    redo: Vec<Rope>,
}
impl Document {
    pub fn open(path: &Path) -> Result<Self> {
        let len = fs::metadata(path).map_err(err)?.len();
        if len > MAX_FILE {
            return Ok(Self {
                path: path.into(),
                rope: Rope::new(),
                bom: false,
                newline: "\n",
                disk_hash: String::new(),
                recovery_hash: None,
                recovery_owned: false,
                read_only_reason: Some("file exceeds 20 MiB".into()),
                undo: Vec::new(),
                redo: Vec::new(),
            });
        }
        let bytes = fs::read(path).map_err(err)?;
        let hash = digest(&bytes);
        let bom = bytes.starts_with(b"\xef\xbb\xbf");
        let content = if bom { &bytes[3..] } else { &bytes };
        let text = std::str::from_utf8(content);
        let (rope, newline, read_only_reason) = match text {
            Err(_) => (
                Rope::new(),
                "\n",
                Some("invalid UTF-8; source remains byte-for-byte untouched".into()),
            ),
            Ok(value) if value.contains('\0') => (
                Rope::new(),
                "\n",
                Some("binary/NUL source is read-only".into()),
            ),
            Ok(value) => {
                let contains_crlf = value.contains("\r\n");
                let without_crlf = value.replace("\r\n", "");
                let mixed =
                    without_crlf.contains('\r') || (contains_crlf && without_crlf.contains('\n'));
                let newline = if contains_crlf { "\r\n" } else { "\n" };
                (
                    Rope::from_str(value),
                    newline,
                    mixed.then(|| "mixed/CR-only line endings are read-only".into()),
                )
            }
        };
        let recovery_path = path.with_file_name(format!("{}.codestrike-recovery", path.file_name().unwrap_or_default().to_string_lossy()));
        let recovery_hash = if recovery_path.exists() { Some(digest(&fs::read(&recovery_path).map_err(err)?)) } else { None };
        Ok(Self {
            path: path.into(),
            rope,
            bom,
            newline,
            disk_hash: hash,
            recovery_hash,
            recovery_owned: false,
            read_only_reason,
            undo: Vec::new(),
            redo: Vec::new(),
        })
    }
    pub fn editable(&self) -> bool {
        self.read_only_reason.is_none()
    }
    pub fn read_only_reason(&self) -> Option<&str> {
        self.read_only_reason.as_deref()
    }
    pub fn text(&self) -> String {
        self.rope.to_string()
    }
    pub fn len_chars(&self) -> usize {
        self.rope.len_chars()
    }
    pub fn recovery_path(&self) -> PathBuf {
        let name = self.path.file_name().unwrap_or_default().to_string_lossy();
        self.path
            .with_file_name(format!("{name}.codestrike-recovery"))
    }
    pub fn recover(&mut self) -> Result<()> {
        self.ensure_editable()?;
        let recovery_bytes = fs::read(self.recovery_path()).map_err(err)?;
        if self.recovery_hash.as_deref() != Some(digest(&recovery_bytes).as_str()) {
            return Err(Error("recovery changed since open; source left untouched".into()));
        }
        let recovery: Recovery = serde_json::from_slice(&recovery_bytes).map_err(err)?;
        if recovery.original_sha256 != self.disk_hash || recovery.bom != self.bom {
            return Err(Error(
                "recovery was based on another disk version; source left untouched".into(),
            ));
        }
        self.validate_editable_text(&recovery.text)?;
        let before = std::mem::replace(&mut self.rope, Rope::from_str(&recovery.text));
        self.undo.push(before);
        self.redo.clear();
        self.recovery_owned = true;
        Ok(())
    }
    fn ensure_editable(&self) -> Result<()> {
        if let Some(reason) = &self.read_only_reason {
            Err(Error(reason.clone()))
        } else {
            Ok(())
        }
    }
    fn validate_editable_text(&self, text: &str) -> Result<()> {
        let encoded_len = text.len() as u64 + if self.bom { 3 } else { 0 };
        if encoded_len > MAX_FILE || text.contains('\0') {
            return Err(Error("edit exceeds 20 MiB or contains NUL; source left untouched".into()));
        }
        let without_crlf = text.replace("\r\n", "");
        if without_crlf.contains('\r')
            || (self.newline == "\r\n" && without_crlf.contains('\n'))
            || (self.newline == "\n" && text.contains("\r\n"))
        {
            return Err(Error("edit would introduce unsupported line endings; source left untouched".into()));
        }
        Ok(())
    }
    fn write_recovery(&mut self) -> Result<()> {
        self.validate_editable_text(&self.text())?;
        let data = Recovery {
            original_sha256: self.disk_hash.clone(),
            bom: self.bom,
            text: self.text(),
        };
        let path = self.recovery_path();
        let backup = path.with_extension("codestrike-recovery.bak");
        if backup.exists() {
            return Err(Error(
                "recover existing edit backup before writing new edits".into(),
            ));
        }
        let existing = if path.exists() { Some(fs::read(&path).map_err(err)?) } else { None };
        if existing.as_deref().map(digest) != self.recovery_hash || (existing.is_some() && !self.recovery_owned) {
            return Err(Error("recovery changed or has not been recovered; existing edits preserved".into()));
        }
        let encoded = serde_json::to_vec(&data).map_err(err)?;
        let (mut temp, mut file) = PendingFile::create(&path, "recovery")?;
        file.write_all(&encoded).map_err(err)?;
        file.sync_all().map_err(err)?;
        drop(file);
        if optional_digest(&path)? != self.recovery_hash {
            return Err(Error("recovery changed during save; existing edits preserved".into()));
        }
        if path.exists() {
            fs::rename(&path, &backup).map_err(err)?;
        }
        if let Err(e) = fs::rename(&temp.path, &path) {
            if backup.exists() {
                let _ = fs::rename(&backup, &path);
            }
            return Err(err(e));
        }
        temp.disarm();
        self.recovery_hash = Some(digest(&encoded));
        self.recovery_owned = true;
        if backup.exists() {
            fs::remove_file(backup).map_err(err)?;
        }
        Ok(())
    }
    fn commit_edit(&mut self, before: Rope) -> Result<()> {
        if let Err(e) = self.validate_editable_text(&self.text()) {
            self.rope = before;
            return Err(e);
        }
        if let Err(e) = self.write_recovery() {
            self.rope = before;
            return Err(e);
        }
        self.undo.push(before);
        if self.undo.len() > 100 {
            self.undo.remove(0);
        }
        self.redo.clear();
        Ok(())
    }
    pub fn insert(&mut self, at_char: usize, text: &str) -> Result<()> {
        self.ensure_editable()?;
        if at_char > self.rope.len_chars() {
            return Err(Error("character index is beyond end of file".into()));
        }
        let before = self.rope.clone();
        let normalized = text.replace("\r\n", "\n").replace('\n', self.newline);
        self.rope.insert(at_char, &normalized);
        self.commit_edit(before)
    }
    pub fn replace(&mut self, start_char: usize, end_char: usize, replacement: &str) -> Result<()> {
        self.ensure_editable()?;
        if start_char > end_char || end_char > self.rope.len_chars() {
            return Err(Error("invalid character range".into()));
        }
        let before = self.rope.clone();
        self.rope.remove(start_char..end_char);
        let normalized = replacement
            .replace("\r\n", "\n")
            .replace('\n', self.newline);
        self.rope.insert(start_char, &normalized);
        self.commit_edit(before)
    }
    pub fn undo(&mut self) -> Result<()> {
        self.ensure_editable()?;
        let previous = self
            .undo
            .pop()
            .ok_or_else(|| Error("nothing to undo".into()))?;
        let current = std::mem::replace(&mut self.rope, previous);
        if let Err(e) = self.write_recovery() {
            self.rope = current;
            return Err(e);
        }
        self.redo.push(current);
        Ok(())
    }
    pub fn redo(&mut self) -> Result<()> {
        self.ensure_editable()?;
        let next = self
            .redo
            .pop()
            .ok_or_else(|| Error("nothing to redo".into()))?;
        let current = std::mem::replace(&mut self.rope, next);
        if let Err(e) = self.write_recovery() {
            self.rope = current;
            return Err(e);
        }
        self.undo.push(current);
        Ok(())
    }
    pub fn save(&mut self) -> Result<()> {
        self.ensure_editable()?;
        self.validate_editable_text(&self.text())?;
        let current = fs::read(&self.path).map_err(err)?;
        if digest(&current) != self.disk_hash {
            return Err(Error(
                "file changed on disk; save copy or reload before overwriting".into(),
            ));
        }
        let mut encoded = Vec::new();
        if self.bom {
            encoded.extend_from_slice(b"\xef\xbb\xbf");
        }
        encoded.extend_from_slice(self.text().as_bytes());
        let backup = self.path.with_extension("codestrike-save.bak");
        if backup.exists() {
            return Err(Error("existing save backup must be recovered first".into()));
        }
        let recovery = self.recovery_path();
        if self.recovery_owned && optional_digest(&recovery)? != self.recovery_hash {
            return Err(Error("recovery changed before source save; existing edits preserved".into()));
        }
        let (mut temp, mut file) = PendingFile::create(&self.path, "save")?;
        file.write_all(&encoded).map_err(err)?;
        file.sync_all().map_err(err)?;
        drop(file);
        if digest(&fs::read(&self.path).map_err(err)?) != self.disk_hash {
            return Err(Error("source changed during save; existing source preserved".into()));
        }
        fs::rename(&self.path, &backup).map_err(err)?;
        if let Err(e) = fs::rename(&temp.path, &self.path) {
            let _ = fs::rename(&backup, &self.path);
            return Err(err(e));
        }
        temp.disarm();
        self.disk_hash = digest(&encoded);
        fs::remove_file(&backup).map_err(err)?;
        if self.recovery_owned && recovery.exists() {
            fs::remove_file(&recovery).map_err(err)?;
            self.recovery_hash = None;
            self.recovery_owned = false;
        }
        Ok(())
    }
}

#[derive(Debug, Clone)]
pub struct SearchQuery {
    pub pattern: String,
    pub regex: bool,
}
#[derive(Debug, Clone, PartialEq)]
pub struct SearchHit {
    pub path: PathBuf,
    pub line: usize,
    pub column: usize,
    pub snippet: String,
}
pub fn search_workspace(root: &Path, query: &SearchQuery) -> Result<Vec<SearchHit>> {
    if query.pattern.is_empty() || query.pattern.len() > 4096 {
        return Err(Error("search pattern must contain 1..4096 bytes".into()));
    }
    let expression = if query.regex {
        query.pattern.clone()
    } else {
        regex::escape(&query.pattern)
    };
    let regex = RegexBuilder::new(&expression)
        .size_limit(2 * 1024 * 1024)
        .build()
        .map_err(err)?;
    let root = root.canonicalize().map_err(err)?;
    let mut dirs = vec![root];
    let mut hits = Vec::new();
    let mut bytes_examined = 0_u64;
    while let Some(dir) = dirs.pop() {
        let entries = fs::read_dir(dir).map_err(err)?;
        for entry in entries {
            let entry = entry.map_err(err)?;
            let name = entry.file_name().to_string_lossy().to_string();
            if name.starts_with('.') || name == "target" {
                continue;
            }
            let path = entry.path();
            let file_type = entry.file_type().map_err(err)?;
            if file_type.is_symlink() {
                continue;
            }
            if file_type.is_dir() {
                dirs.push(path);
                continue;
            }
            if !file_type.is_file() {
                continue;
            }
            let size = entry.metadata().map_err(err)?.len();
            if size > MAX_FILE {
                continue;
            }
            bytes_examined = bytes_examined.saturating_add(size);
            if bytes_examined > MAX_SEARCH_BYTES {
                return Err(Error("workspace search exceeded 100 MiB cap".into()));
            }
            let data = fs::read(&path).map_err(err)?;
            let Ok(text) = std::str::from_utf8(&data) else {
                continue;
            };
            let text = text.strip_prefix('\u{feff}').unwrap_or(text);
            if text.contains('\0') {
                continue;
            }
            for (line_index, line) in text.lines().enumerate() {
                for matched in regex.find_iter(line) {
                    hits.push(SearchHit {
                        path: path.clone(),
                        line: line_index + 1,
                        column: line[..matched.start()].chars().count() + 1,
                        snippet: line.chars().take(200).collect(),
                    });
                    if hits.len() >= MAX_HITS {
                        return Ok(hits);
                    }
                }
            }
        }
    }
    hits.sort_by(|a, b| (&a.path, a.line, a.column).cmp(&(&b.path, b.line, b.column)));
    Ok(hits)
}

#[derive(Debug, Clone, Copy)]
pub enum CargoAction {
    Check,
    Build,
    Test,
}
#[derive(Debug, Clone)]
pub struct Diagnostic {
    pub level: String,
    pub message: String,
    pub file: Option<PathBuf>,
    pub line: Option<u64>,
    pub column: Option<u64>,
}
#[derive(Debug, Clone)]
pub struct BuildReport {
    pub success: bool,
    pub diagnostics: Vec<Diagnostic>,
    pub raw_output: String,
    pub output_truncated: bool,
}
pub fn run_cargo(root: &Path, action: CargoAction) -> Result<BuildReport> {
    run_cargo_with_control(root, action, &AtomicBool::new(false), Duration::from_secs(600))
}
fn read_bounded(mut reader: impl Read, limit: usize) -> std::io::Result<(Vec<u8>, bool)> {
    let mut captured = Vec::new();
    let mut truncated = false;
    let mut chunk = [0_u8; 8192];
    loop {
        let len = reader.read(&mut chunk)?;
        if len == 0 { break; }
        let keep = len.min(limit.saturating_sub(captured.len()));
        captured.extend_from_slice(&chunk[..keep]);
        truncated |= keep < len;
    }
    Ok((captured, truncated))
}
pub fn run_cargo_with_control(
    root: &Path,
    action: CargoAction,
    cancel: &AtomicBool,
    timeout: Duration,
) -> Result<BuildReport> {
    run_cargo_program_with_control(root, action, cancel, timeout, Path::new("cargo"))
}
fn run_cargo_program_with_control(
    root: &Path,
    action: CargoAction,
    cancel: &AtomicBool,
    timeout: Duration,
    cargo_program: &Path,
) -> Result<BuildReport> {
    let root = root.canonicalize().map_err(err)?;
    if !root.join("Cargo.toml").is_file() {
        return Err(Error("Cargo.toml not found in selected workspace".into()));
    }
    let command = match action {
        CargoAction::Check => "check",
        CargoAction::Build => "build",
        CargoAction::Test => "test",
    };
    // Explicit argv and cwd; source paths never pass through a shell.
    let mut command_line = Command::new(cargo_program);
    command_line.arg(command).arg("--offline").arg("--message-format=json")
        .current_dir(&root).stdout(Stdio::piped()).stderr(Stdio::piped());
    let (mut child, scope) = ProcessScope::spawn(command_line).map_err(err)?;
    let stdout_pipe = child.stdout.take().ok_or_else(|| Error("Cargo stdout unavailable".into()))?;
    let stderr_pipe = child.stderr.take().ok_or_else(|| Error("Cargo stderr unavailable".into()))?;
    let (sender, receiver) = std::sync::mpsc::channel();
    let stdout_sender = sender.clone();
    std::thread::spawn(move || { let _ = stdout_sender.send((0, read_bounded(stdout_pipe, MAX_CAPTURE_PER_STREAM))); });
    std::thread::spawn(move || { let _ = sender.send((1, read_bounded(stderr_pipe, MAX_CAPTURE_PER_STREAM))); });
    let started = Instant::now();
    let status = loop {
        if cancel.load(Ordering::Acquire) {
            scope.stop(&mut child);
            return Err(Error("Cargo command cancelled".into()));
        }
        if started.elapsed() >= timeout {
            scope.stop(&mut child);
            return Err(Error("Cargo command timed out".into()));
        }
        match child.try_wait().map_err(err)? {
            Some(status) => break status,
            None => std::thread::sleep(Duration::from_millis(50)),
        }
    };
    // Cargo may have exited while a descendant still owns its stdout pipe.
    // Closing the scope terminates only this command's descendants.
    drop(scope);
    let mut outputs = [None, None];
    for _ in 0..2 {
        let (stream, result) = receiver.recv_timeout(Duration::from_secs(3))
            .map_err(|_| Error("Cargo output reader did not finish after process exit".into()))?;
        outputs[stream] = Some(result.map_err(err)?);
    }
    let (stdout_bytes, stdout_truncated) = outputs[0].take().unwrap();
    let (stderr_bytes, stderr_truncated) = outputs[1].take().unwrap();
    let stdout = String::from_utf8_lossy(&stdout_bytes);
    let stderr = String::from_utf8_lossy(&stderr_bytes);
    let mut diagnostics = Vec::new();
    for line in stdout.lines() {
        let Ok(value) = serde_json::from_str::<serde_json::Value>(line) else {
            continue;
        };
        if value["reason"] != "compiler-message" {
            continue;
        }
        let message = &value["message"];
        let span = message["spans"]
            .as_array()
            .and_then(|a| a.iter().find(|s| s["is_primary"] == true));
        diagnostics.push(Diagnostic {
            level: message["level"].as_str().unwrap_or("unknown").into(),
            message: message["message"]
                .as_str()
                .unwrap_or("unknown compiler message")
                .into(),
            file: span
                .and_then(|s| s["file_name"].as_str())
                .map(PathBuf::from),
            line: span.and_then(|s| s["line_start"].as_u64()),
            column: span.and_then(|s| s["column_start"].as_u64()),
        });
    }
    let output_truncated = stdout_truncated || stderr_truncated;
    let raw_output = format!("{stdout}\n{stderr}{}", if output_truncated { "\n[Cargo output truncated at the capture limit]" } else { "" });
    Ok(BuildReport {
        success: status.success(),
        diagnostics,
        raw_output: raw_output.chars().take(1_000_000).collect(),
        output_truncated,
    })
}

#[cfg(test)]
mod process_tests {
    #[test]
    fn output_reader_caps_memory_while_draining_remaining_bytes() {
        let source = vec![b'x'; 100_000];
        let (captured, truncated) = super::read_bounded(source.as_slice(), 1024).unwrap();
        assert_eq!(captured.len(), 1024);
        assert!(truncated);
    }

    #[cfg(windows)]
    #[test]
    fn cancellation_stops_fake_cargo_descendant_and_returns_before_its_marker() {
        use super::*;
        let root = std::env::temp_dir().join(format!("codestrike-fake-tree-{}-{}", std::process::id(), NEXT_TRANSACTION_ID.fetch_add(1, Ordering::Relaxed)));
        fs::create_dir_all(&root).unwrap();
        fs::write(root.join("Cargo.toml"), "[package]\nname='fake-tree'\nversion='0.1.0'\nedition='2024'\n").unwrap();
        let source = root.join("fake_cargo.rs");
        fs::write(&source, include_str!("../tests/fixtures/fake_cargo.rs")).unwrap();
        let binary = root.join("fake_cargo.exe");
        assert!(Command::new("rustc").arg(&source).arg("-o").arg(&binary).status().unwrap().success());
        let cancel = AtomicBool::new(false);
        std::thread::scope(|scope| {
            let worker = scope.spawn(|| run_cargo_program_with_control(&root, CargoAction::Check, &cancel, Duration::from_secs(10), &binary));
            let ready = root.join("fake-child-ready.txt");
            let start = Instant::now();
            while !ready.exists() && start.elapsed() < Duration::from_secs(5) {
                std::thread::sleep(Duration::from_millis(10));
            }
            cancel.store(true, Ordering::Release);
            let stop_started = Instant::now();
            let result = worker.join().unwrap();
            assert!(ready.exists(), "fixture child did not start: {result:?}");
            assert!(result.unwrap_err().to_string().contains("cancelled"));
            assert!(stop_started.elapsed() < Duration::from_secs(2));
        });
        std::thread::sleep(Duration::from_millis(2300));
        assert!(!root.join("fake-grandchild-survived.txt").exists());
    }
}
