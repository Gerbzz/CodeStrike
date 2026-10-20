//! Source-only Codex app-server JSONL boundary. The caller owns the local
//! process, credentials, transport, approvals, and reviewed file application.
//! This module never starts a process, opens a socket, or reads auth state.

use serde_json::{Value, json};
use std::collections::HashMap;
use std::path::{Component, Path};

pub const MAX_WIRE_LINE_BYTES: usize = 1024 * 1024;
const MAX_PROMPT_BYTES: usize = 64 * 1024;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum AdapterError {
    InvalidState,
    InvalidProject,
    EmptyInput,
    InputTooLarge,
    InvalidFrame,
    FrameTooLarge,
    UnexpectedResponse,
    ServerRejected(i64),
    UnknownApproval,
    UnsupportedApproval,
    DuplicateApproval,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum TurnOutcome {
    Completed,
    Failed,
    Interrupted,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ApprovalDecision {
    Accept,
    Decline,
    Cancel,
}

/// A server request is surfaced to the UI. Nothing here grants it approval.
#[derive(Debug, PartialEq)]
pub enum AgentEvent {
    Ready,
    ThreadStarted(String),
    TurnStarted(String),
    MessageDelta(String),
    DiffUpdated(String),
    FileChange(Value),
    ApprovalResolved(Value),
    TurnFinished(TurnOutcome),
    ActionRequired {
        method: String,
        request_id: Value,
        params: Value,
    },
    OtherNotification(String),
}

#[derive(Debug, PartialEq)]
pub enum AdapterEffect {
    /// A JSONL frame for the caller's private, local app-server stdin.
    Send(String),
    Show(AgentEvent),
}

#[derive(Clone, Copy, PartialEq, Eq)]
enum Phase {
    New,
    Initializing(u64),
    Ready,
    StartingThread(u64),
    ThreadReady,
    StartingTurn(u64),
    Running,
}

pub struct LocalCodexAdapter {
    phase: Phase,
    next_request_id: u64,
    project: Option<String>,
    thread_id: Option<String>,
    turn_id: Option<String>,
    pending_interrupt: Option<u64>,
    pending_approvals: HashMap<String, String>,
}

impl Default for LocalCodexAdapter {
    fn default() -> Self {
        Self {
            phase: Phase::New,
            next_request_id: 1,
            project: None,
            thread_id: None,
            turn_id: None,
            pending_interrupt: None,
            pending_approvals: HashMap::new(),
        }
    }
}

impl LocalCodexAdapter {
    pub fn new() -> Self {
        Self::default()
    }

    pub fn thread_id(&self) -> Option<&str> {
        self.thread_id.as_deref()
    }

    pub fn ready_for_turn(&self) -> bool {
        self.phase == Phase::ThreadReady
    }

    pub fn answer_approval(
        &mut self,
        request_id: &Value,
        decision: ApprovalDecision,
    ) -> Result<String, AdapterError> {
        let key = approval_key(request_id)?;
        let method = self
            .pending_approvals
            .get(&key)
            .ok_or(AdapterError::UnknownApproval)?;
        if !matches!(
            method.as_str(),
            "item/commandExecution/requestApproval"
                | "item/fileChange/requestApproval"
        ) {
            return Err(AdapterError::UnsupportedApproval);
        }
        let decision = match decision {
            ApprovalDecision::Accept => "accept",
            ApprovalDecision::Decline => "decline",
            ApprovalDecision::Cancel => "cancel",
        };
        self.pending_approvals.remove(&key);
        Ok(frame(
            json!({"id": request_id, "result": {"decision": decision}}),
        ))
    }

    pub fn interrupt_turn(&mut self) -> Result<String, AdapterError> {
        if self.phase != Phase::Running || self.pending_interrupt.is_some() {
            return Err(AdapterError::InvalidState);
        }
        let thread_id = self
            .thread_id
            .as_ref()
            .ok_or(AdapterError::InvalidState)?
            .clone();
        let turn_id = self
            .turn_id
            .as_ref()
            .ok_or(AdapterError::InvalidState)?
            .clone();
        let id = self.allocate_id();
        self.pending_interrupt = Some(id);
        Ok(frame(
            json!({"id": id, "method": "turn/interrupt", "params": {"threadId": thread_id, "turnId": turn_id}}),
        ))
    }

    pub fn initialize(&mut self) -> Result<String, AdapterError> {
        if self.phase != Phase::New {
            return Err(AdapterError::InvalidState);
        }
        let id = self.allocate_id();
        self.phase = Phase::Initializing(id);
        Ok(frame(json!({
            "id": id,
            "method": "initialize",
            "params": {
                "clientInfo": {
                    "name": "codestrike",
                    "title": "CodeStrike",
                    "version": env!("CARGO_PKG_VERSION")
                }
            }
        })))
    }

    /// Model selection is supplied by the user's local UI. No entitlement is inferred.
    pub fn start_thread(
        &mut self,
        project: &Path,
        model: &str,
    ) -> Result<String, AdapterError> {
        if self.phase != Phase::Ready {
            return Err(AdapterError::InvalidState);
        }
        let project = valid_project(project)?;
        if model.trim().is_empty() {
            return Err(AdapterError::EmptyInput);
        }
        let id = self.allocate_id();
        self.project = Some(project.clone());
        self.phase = Phase::StartingThread(id);
        Ok(frame(json!({
            "id": id,
            "method": "thread/start",
            "params": {
                "cwd": project,
                "model": model,
                "approvalPolicy": "onRequest",
                "sandbox": "readOnly"
            }
        })))
    }

    /// This only describes a proposed local turn. The host must show its
    /// workspace scope and enforce its own edit review before sharing patches.
    pub fn start_turn(&mut self, prompt: &str) -> Result<String, AdapterError> {
        if self.phase != Phase::ThreadReady {
            return Err(AdapterError::InvalidState);
        }
        if prompt.trim().is_empty() {
            return Err(AdapterError::EmptyInput);
        }
        if prompt.len() > MAX_PROMPT_BYTES {
            return Err(AdapterError::InputTooLarge);
        }
        let project = self
            .project
            .as_ref()
            .ok_or(AdapterError::InvalidState)?
            .clone();
        let thread_id = self
            .thread_id
            .as_ref()
            .ok_or(AdapterError::InvalidState)?
            .clone();
        let id = self.allocate_id();
        self.phase = Phase::StartingTurn(id);
        Ok(frame(json!({
            "id": id,
            "method": "turn/start",
            "params": {
                "threadId": thread_id,
                "input": [{ "type": "text", "text": prompt }],
                "cwd": project,
                "approvalPolicy": "onRequest",
                "sandboxPolicy": { "type": "readOnly" }
            }
        })))
    }

    /// Accepts one bounded JSONL frame. Server requests are surfaced, never
    /// answered automatically. Only a completed turn counts as success.
    pub fn receive_line(
        &mut self,
        line: &str,
    ) -> Result<Vec<AdapterEffect>, AdapterError> {
        if line.len() > MAX_WIRE_LINE_BYTES {
            return Err(AdapterError::FrameTooLarge);
        }
        let message: Value =
            serde_json::from_str(line.trim_end_matches(['\r', '\n']))
                .map_err(|_| AdapterError::InvalidFrame)?;
        let object = message.as_object().ok_or(AdapterError::InvalidFrame)?;
        if let Some(method) = object.get("method").and_then(Value::as_str) {
            if let Some(request_id) = object.get("id").filter(|id| !id.is_null()) {
                let params =
                    object.get("params").ok_or(AdapterError::InvalidFrame)?;
                self.check_scope_if_present(params)?;
                if matches!(
                    method,
                    "item/commandExecution/requestApproval"
                        | "item/fileChange/requestApproval"
                ) && (self.phase != Phase::Running
                    || params.get("threadId").and_then(Value::as_str)
                        != self.thread_id.as_deref()
                    || params.get("turnId").and_then(Value::as_str)
                        != self.turn_id.as_deref())
                {
                    return Err(AdapterError::InvalidFrame);
                }
                let key = approval_key(request_id)?;
                if self.pending_approvals.contains_key(&key) {
                    return Err(AdapterError::DuplicateApproval);
                }
                self.pending_approvals.insert(key, method.to_owned());
                return Ok(vec![AdapterEffect::Show(AgentEvent::ActionRequired {
                    method: method.to_owned(),
                    request_id: request_id.clone(),
                    params: params.clone(),
                })]);
            }
            return self.notification(method, object.get("params"));
        }
        let id = object
            .get("id")
            .and_then(Value::as_u64)
            .ok_or(AdapterError::InvalidFrame)?;
        if self.pending_interrupt == Some(id) {
            self.pending_interrupt = None;
            if let Some(error) = object.get("error") {
                return Err(AdapterError::ServerRejected(
                    error.get("code").and_then(Value::as_i64).unwrap_or(-1),
                ));
            }
            if object.get("result").is_none() {
                return Err(AdapterError::InvalidFrame);
            }
            return Ok(Vec::new());
        }
        let expected = match self.phase {
            Phase::Initializing(p)
            | Phase::StartingThread(p)
            | Phase::StartingTurn(p) => p,
            _ => return Err(AdapterError::UnexpectedResponse),
        };
        if id != expected {
            return Err(AdapterError::UnexpectedResponse);
        }
        if let Some(error) = object.get("error") {
            let code = error.get("code").and_then(Value::as_i64).unwrap_or(-1);
            self.phase = match self.phase {
                Phase::Initializing(_) => Phase::New,
                Phase::StartingThread(_) => Phase::Ready,
                Phase::StartingTurn(_) => Phase::ThreadReady,
                _ => unreachable!(),
            };
            return Err(AdapterError::ServerRejected(code));
        }
        let result = object.get("result").ok_or(AdapterError::InvalidFrame)?;
        match self.phase {
            Phase::Initializing(_) => {
                self.phase = Phase::Ready;
                Ok(vec![
                    AdapterEffect::Send(frame(
                        json!({"method": "initialized", "params": {}}),
                    )),
                    AdapterEffect::Show(AgentEvent::Ready),
                ])
            }
            Phase::StartingThread(_) => {
                let thread = result
                    .pointer("/thread/id")
                    .and_then(Value::as_str)
                    .filter(|s| !s.is_empty())
                    .ok_or(AdapterError::InvalidFrame)?;
                self.thread_id = Some(thread.to_owned());
                self.phase = Phase::ThreadReady;
                Ok(vec![AdapterEffect::Show(AgentEvent::ThreadStarted(
                    thread.to_owned(),
                ))])
            }
            Phase::StartingTurn(_) => {
                let turn = result
                    .pointer("/turn/id")
                    .and_then(Value::as_str)
                    .filter(|s| !s.is_empty())
                    .ok_or(AdapterError::InvalidFrame)?;
                self.turn_id = Some(turn.to_owned());
                self.phase = Phase::Running;
                Ok(vec![AdapterEffect::Show(AgentEvent::TurnStarted(
                    turn.to_owned(),
                ))])
            }
            _ => Err(AdapterError::UnexpectedResponse),
        }
    }

    fn notification(
        &mut self,
        method: &str,
        params: Option<&Value>,
    ) -> Result<Vec<AdapterEffect>, AdapterError> {
        let params = params.ok_or(AdapterError::InvalidFrame)?;
        self.check_scope_if_present(params)?;
        let event = match method {
            "item/started" | "item/completed"
                if params.pointer("/item/type").and_then(Value::as_str)
                    == Some("fileChange") =>
            {
                AgentEvent::FileChange(
                    params
                        .get("item")
                        .cloned()
                        .ok_or(AdapterError::InvalidFrame)?,
                )
            }
            "item/agentMessage/delta" if self.phase == Phase::Running => {
                let delta = params
                    .get("delta")
                    .and_then(Value::as_str)
                    .ok_or(AdapterError::InvalidFrame)?;
                AgentEvent::MessageDelta(delta.to_owned())
            }
            "turn/diff/updated" if self.phase == Phase::Running => {
                let diff = params
                    .get("diff")
                    .and_then(Value::as_str)
                    .ok_or(AdapterError::InvalidFrame)?;
                AgentEvent::DiffUpdated(diff.to_owned())
            }
            "turn/completed" if self.phase == Phase::Running => {
                let turn = params.get("turn").ok_or(AdapterError::InvalidFrame)?;
                if turn.get("id").and_then(Value::as_str) != self.turn_id.as_deref()
                {
                    return Err(AdapterError::InvalidFrame);
                }
                let outcome = match turn.get("status").and_then(Value::as_str) {
                    Some("completed") => TurnOutcome::Completed,
                    Some("failed") => TurnOutcome::Failed,
                    Some("interrupted") => TurnOutcome::Interrupted,
                    _ => return Err(AdapterError::InvalidFrame),
                };
                self.turn_id = None;
                self.pending_approvals.clear();
                self.phase = Phase::ThreadReady;
                AgentEvent::TurnFinished(outcome)
            }
            "serverRequest/resolved" => {
                if let Some(id) = params.get("requestId") {
                    if let Ok(key) = approval_key(id) {
                        self.pending_approvals.remove(&key);
                    }
                    AgentEvent::ApprovalResolved(id.clone())
                } else {
                    return Err(AdapterError::InvalidFrame);
                }
            }
            _ => AgentEvent::OtherNotification(method.to_owned()),
        };
        Ok(vec![AdapterEffect::Show(event)])
    }

    fn allocate_id(&mut self) -> u64 {
        let id = self.next_request_id;
        self.next_request_id += 1;
        id
    }

    fn check_scope_if_present(&self, params: &Value) -> Result<(), AdapterError> {
        if let Some(thread) = params.get("threadId").and_then(Value::as_str) {
            if Some(thread) != self.thread_id.as_deref() {
                return Err(AdapterError::InvalidFrame);
            }
        }
        if let Some(turn) = params.get("turnId").and_then(Value::as_str) {
            if Some(turn) != self.turn_id.as_deref() {
                return Err(AdapterError::InvalidFrame);
            }
        }
        Ok(())
    }
}

fn approval_key(id: &Value) -> Result<String, AdapterError> {
    match id {
        Value::String(value) if !value.is_empty() => Ok(format!("s:{value}")),
        Value::Number(value) => Ok(format!("n:{value}")),
        _ => Err(AdapterError::InvalidFrame),
    }
}

fn frame(value: Value) -> String {
    // JSON values cannot contain non-finite numbers; this serialization of a
    // constructed Value is infallible. The newline is the stdio frame boundary.
    format!("{}\n", serde_json::to_string(&value).expect("JSON value"))
}

fn valid_project(project: &Path) -> Result<String, AdapterError> {
    if !project.is_absolute()
        || project
            .components()
            .any(|c| matches!(c, Component::ParentDir))
    {
        return Err(AdapterError::InvalidProject);
    }
    let value = project.to_str().ok_or(AdapterError::InvalidProject)?;
    if value.is_empty() {
        return Err(AdapterError::InvalidProject);
    }
    Ok(value.to_owned())
}
