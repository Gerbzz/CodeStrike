//! Read-only local Unity project detection and MCP capability discovery.
//! This source boundary does not spawn a server or invoke any MCP tool.

use serde_json::{Value, json};
use std::collections::HashSet;
use std::fs;
use std::io::Read;
use std::path::{Path, PathBuf};

const MAX_FRAME: usize = 1024 * 1024;
const MAX_PAGES: usize = 8;
const MAX_TOOLS: usize = 256;

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct UnityProjectInfo {
    pub root: PathBuf,
    pub editor_version: String,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ProjectError {
    NotUnityProject,
    OutsideProject,
    InvalidVersion,
    Io,
}

/// Inspect only two known Unity project markers. The host must separately
/// verify a live editor instance before treating a project as connected.
pub fn inspect_unity_project(path: &Path) -> Result<UnityProjectInfo, ProjectError> {
    let root = fs::canonicalize(path).map_err(|_| ProjectError::Io)?;
    if !root.is_dir() {
        return Err(ProjectError::NotUnityProject);
    }
    #[cfg(windows)]
    {
        use std::path::{Component, Prefix};
        let local_disk = matches!(
            root.components().next(),
            Some(Component::Prefix(prefix))
                if matches!(prefix.kind(), Prefix::Disk(_) | Prefix::VerbatimDisk(_))
        );
        if !local_disk {
            return Err(ProjectError::OutsideProject);
        }
    }
    let assets =
        fs::canonicalize(root.join("Assets")).map_err(|_| ProjectError::NotUnityProject)?;
    let settings = fs::canonicalize(root.join("ProjectSettings/ProjectVersion.txt"))
        .map_err(|_| ProjectError::NotUnityProject)?;
    if !assets.starts_with(&root) || !settings.starts_with(&root) {
        return Err(ProjectError::OutsideProject);
    }
    if !assets.is_dir() || !settings.is_file() {
        return Err(ProjectError::NotUnityProject);
    }
    if fs::metadata(&settings).map_err(|_| ProjectError::Io)?.len() > 4096 {
        return Err(ProjectError::InvalidVersion);
    }
    let mut bytes = Vec::new();
    fs::File::open(settings)
        .map_err(|_| ProjectError::Io)?
        .take(4097)
        .read_to_end(&mut bytes)
        .map_err(|_| ProjectError::Io)?;
    if bytes.len() > 4096 {
        return Err(ProjectError::InvalidVersion);
    }
    let content = std::str::from_utf8(&bytes).map_err(|_| ProjectError::InvalidVersion)?;
    let editor_version = content
        .lines()
        .find_map(|line| line.strip_prefix("m_EditorVersion: "))
        .filter(|value| !value.is_empty() && value.len() <= 80)
        .ok_or(ProjectError::InvalidVersion)?
        .to_owned();
    Ok(UnityProjectInfo {
        root,
        editor_version,
    })
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum DiscoveryError {
    InvalidState,
    InvalidFrame,
    FrameTooLarge,
    UnsupportedVersion,
    ToolsUnavailable,
    ServerRequest,
    ServerRejected,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum DiscoveryEffect {
    Send(String),
    Completed(Vec<String>),
}

#[derive(Clone, Copy, Default)]
enum Phase {
    #[default]
    New,
    Initializing,
    Listing(u64),
    Complete,
}

#[derive(Default)]
pub struct UnityMcpDiscovery {
    phase: Phase,
    pages: usize,
    tools: Vec<String>,
    seen_names: HashSet<String>,
    seen_cursors: HashSet<String>,
}

impl UnityMcpDiscovery {
    pub fn new() -> Self {
        Self::default()
    }

    pub fn is_complete(&self) -> bool {
        matches!(self.phase, Phase::Complete)
    }

    pub fn initialize(&mut self) -> Result<String, DiscoveryError> {
        if !matches!(self.phase, Phase::New) {
            return Err(DiscoveryError::InvalidState);
        }
        self.phase = Phase::Initializing;
        Ok(frame(json!({
            "jsonrpc":"2.0", "id":1, "method":"initialize",
            "params":{"protocolVersion":"2025-06-18","capabilities":{},
                "clientInfo":{"name":"codestrike-unity-discovery","version":env!("CARGO_PKG_VERSION")}}
        })))
    }

    pub fn receive(&mut self, line: &str) -> Result<Vec<DiscoveryEffect>, DiscoveryError> {
        if line.len() > MAX_FRAME {
            return Err(DiscoveryError::FrameTooLarge);
        }
        let value: Value = serde_json::from_str(line.trim_end_matches(['\r', '\n']))
            .map_err(|_| DiscoveryError::InvalidFrame)?;
        if value.get("jsonrpc").and_then(Value::as_str) != Some("2.0") {
            return Err(DiscoveryError::InvalidFrame);
        }
        if value.get("method").is_some() {
            return if value.get("id").is_some() {
                Err(DiscoveryError::ServerRequest)
            } else {
                Ok(Vec::new())
            };
        }
        let expected = match self.phase {
            Phase::Initializing => 1,
            Phase::Listing(id) => id,
            _ => return Err(DiscoveryError::InvalidState),
        };
        if value.get("id").and_then(Value::as_u64) != Some(expected) {
            return Err(DiscoveryError::InvalidFrame);
        }
        if value.get("error").is_some() {
            return Err(DiscoveryError::ServerRejected);
        }
        let result = value.get("result").ok_or(DiscoveryError::InvalidFrame)?;
        match self.phase {
            Phase::Initializing => {
                let version = result.get("protocolVersion").and_then(Value::as_str);
                if !matches!(version, Some("2024-11-05" | "2025-03-26" | "2025-06-18")) {
                    return Err(DiscoveryError::UnsupportedVersion);
                }
                if !result
                    .pointer("/capabilities/tools")
                    .is_some_and(Value::is_object)
                {
                    return Err(DiscoveryError::ToolsUnavailable);
                }
                if result
                    .pointer("/serverInfo/name")
                    .and_then(Value::as_str)
                    .is_none_or(str::is_empty)
                {
                    return Err(DiscoveryError::InvalidFrame);
                }
                self.phase = Phase::Listing(2);
                Ok(vec![
                    DiscoveryEffect::Send(frame(
                        json!({"jsonrpc":"2.0","method":"notifications/initialized"}),
                    )),
                    DiscoveryEffect::Send(tool_list_request(2, None)),
                ])
            }
            Phase::Listing(id) => {
                let listed = result
                    .get("tools")
                    .and_then(Value::as_array)
                    .ok_or(DiscoveryError::InvalidFrame)?;
                if listed.len() > MAX_TOOLS || self.tools.len() + listed.len() > MAX_TOOLS {
                    return Err(DiscoveryError::FrameTooLarge);
                }
                for tool in listed {
                    let name = tool
                        .get("name")
                        .and_then(Value::as_str)
                        .filter(|name| !name.is_empty() && name.len() <= 128)
                        .ok_or(DiscoveryError::InvalidFrame)?;
                    if !self.seen_names.insert(name.to_owned()) {
                        return Err(DiscoveryError::InvalidFrame);
                    }
                    self.tools.push(name.to_owned());
                }
                self.pages += 1;
                match result.get("nextCursor") {
                    None | Some(Value::Null) => {
                        self.phase = Phase::Complete;
                        Ok(vec![DiscoveryEffect::Completed(self.tools.clone())])
                    }
                    Some(Value::String(cursor))
                        if !cursor.is_empty()
                            && cursor.len() <= 512
                            && self.pages < MAX_PAGES
                            && self.seen_cursors.insert(cursor.clone()) =>
                    {
                        let next_id = id + 1;
                        self.phase = Phase::Listing(next_id);
                        Ok(vec![DiscoveryEffect::Send(tool_list_request(
                            next_id,
                            Some(cursor),
                        ))])
                    }
                    _ => Err(DiscoveryError::InvalidFrame),
                }
            }
            _ => Err(DiscoveryError::InvalidState),
        }
    }
}

fn tool_list_request(id: u64, cursor: Option<&str>) -> String {
    match cursor {
        Some(cursor) => {
            frame(json!({"jsonrpc":"2.0","id":id,"method":"tools/list","params":{"cursor":cursor}}))
        }
        None => frame(json!({"jsonrpc":"2.0","id":id,"method":"tools/list","params":{}})),
    }
}

fn frame(value: Value) -> String {
    format!("{}\n", value)
}
