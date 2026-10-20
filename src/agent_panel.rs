//! UI-independent state for one local agent panel. All process and approval
//! state belongs to the selected workspace and is discarded on reconnect.

use crate::agent_adapter::{AgentEvent, ApprovalDecision, TurnOutcome};
use crate::agent_review::{ReviewError, ReviewedFileChange};
use crate::agent_session::{LocalAgentSession, SessionEvent};
use serde_json::Value;
use std::collections::HashMap;
use std::ffi::OsString;
use std::io;
use std::path::{Path, PathBuf};

const MAX_TEXT_BYTES: usize = 64 * 1024;
const MAX_DIFF_BYTES: usize = 256 * 1024;
const MAX_ITEMS: usize = 32;

#[derive(Debug, Clone, PartialEq)]
pub struct PendingView {
    pub request_id: Value,
    pub method: String,
    pub preview: String,
    pub can_accept: bool,
    pub reason: String,
}

#[derive(Debug, Clone, PartialEq)]
pub struct PanelSnapshot {
    pub status: String,
    pub transcript: String,
    pub diff: String,
    pub pending: Vec<PendingView>,
}

struct PendingApproval {
    request_id: Value,
    method: String,
    params: Value,
    review: Option<ReviewedFileChange>,
    preview: String,
    reason: String,
}

pub struct LocalAgentPanel {
    workspace: PathBuf,
    session: Option<LocalAgentSession>,
    active_turn: Option<String>,
    proposed: HashMap<String, Result<ReviewedFileChange, ReviewError>>,
    pending: Vec<PendingApproval>,
    status: String,
    transcript: String,
    diff: String,
}

impl LocalAgentPanel {
    pub fn new(workspace: PathBuf) -> Self {
        Self {
            workspace,
            session: None,
            active_turn: None,
            proposed: HashMap::new(),
            pending: Vec::new(),
            status: "Start a local agent for this workspace".into(),
            transcript: String::new(),
            diff: String::new(),
        }
    }

    pub fn start(
        &mut self,
        executable: &Path,
        args: &[OsString],
        model: &str,
    ) -> io::Result<()> {
        self.disconnect();
        self.transcript.clear();
        self.diff.clear();
        let session =
            LocalAgentSession::spawn(executable, args, &self.workspace, model)?;
        self.session = Some(session);
        self.status = "Connecting to local agent".into();
        Ok(())
    }

    pub fn disconnect(&mut self) {
        self.session = None;
        self.active_turn = None;
        self.proposed.clear();
        self.pending.clear();
        self.status = "Local agent stopped".into();
    }

    pub fn ready(&self) -> bool {
        self.session
            .as_ref()
            .is_some_and(LocalAgentSession::ready_for_turn)
    }

    pub fn send_prompt(&mut self, prompt: &str) -> io::Result<()> {
        self.session
            .as_mut()
            .ok_or_else(|| {
                io::Error::new(
                    io::ErrorKind::NotConnected,
                    "start a local agent first",
                )
            })?
            .send_prompt(prompt)?;
        self.status = "Agent working".into();
        Ok(())
    }

    pub fn interrupt(&mut self) -> io::Result<()> {
        self.session
            .as_mut()
            .ok_or_else(|| {
                io::Error::new(
                    io::ErrorKind::NotConnected,
                    "start a local agent first",
                )
            })?
            .interrupt_turn()?;
        self.status = "Stopping current turn".into();
        Ok(())
    }

    pub fn decide(
        &mut self,
        request_id: &Value,
        decision: ApprovalDecision,
    ) -> Result<(), String> {
        let index = self
            .pending
            .iter()
            .position(|pending| &pending.request_id == request_id)
            .ok_or_else(|| {
                "Approval no longer belongs to this session".to_owned()
            })?;
        let pending = &self.pending[index];
        if decision == ApprovalDecision::Accept {
            let review = pending.review.as_ref().ok_or_else(|| {
                "This request has no reviewable workspace edit".to_owned()
            })?;
            review
                .validate_approval(&pending.params)
                .map_err(|error| format!("Edit review: {error:?}"))?;
        }
        self.session
            .as_mut()
            .ok_or_else(|| "Local agent disconnected".to_owned())?
            .respond_approval(request_id, decision)
            .map_err(|error| error.to_string())?;
        self.pending.remove(index);
        self.status = match decision {
            ApprovalDecision::Accept => "Reviewed edit approved".into(),
            ApprovalDecision::Decline => "Request declined".into(),
            ApprovalDecision::Cancel => "Request cancelled".into(),
        };
        Ok(())
    }

    pub fn poll(&mut self) {
        let events = self
            .session
            .as_mut()
            .map(|session| session.poll(64))
            .unwrap_or_default();
        for event in events {
            self.apply(event);
            if self.session.is_none() {
                break;
            }
        }
    }

    pub fn snapshot(&self) -> PanelSnapshot {
        PanelSnapshot {
            status: self.status.clone(),
            transcript: self.transcript.clone(),
            diff: self.diff.clone(),
            pending: self
                .pending
                .iter()
                .map(|pending| PendingView {
                    request_id: pending.request_id.clone(),
                    method: pending.method.clone(),
                    preview: pending.preview.clone(),
                    can_accept: pending.review.is_some(),
                    reason: pending.reason.clone(),
                })
                .collect(),
        }
    }

    fn apply(&mut self, event: SessionEvent) {
        match event {
            SessionEvent::Disconnected(reason) => {
                self.pending.clear();
                self.proposed.clear();
                self.active_turn = None;
                self.status = format!("Local agent disconnected: {reason}");
            }
            SessionEvent::Agent(event) => match event {
                AgentEvent::Ready => self.status = "Starting local thread".into(),
                AgentEvent::ThreadStarted(_) => {
                    self.status = "Local agent ready".into()
                }
                AgentEvent::TurnStarted(id) => {
                    self.active_turn = Some(id);
                    self.proposed.clear();
                    self.pending.clear();
                    self.diff.clear();
                    self.status = "Agent working".into();
                }
                AgentEvent::MessageDelta(delta) => {
                    append_bounded(&mut self.transcript, &delta, MAX_TEXT_BYTES)
                }
                AgentEvent::DiffUpdated(diff) => {
                    self.diff.clear();
                    append_bounded(&mut self.diff, &diff, MAX_DIFF_BYTES);
                }
                AgentEvent::FileChange(item) => {
                    if let Some(id) = item.get("id").and_then(Value::as_str) {
                        if item.get("status").and_then(Value::as_str)
                            == Some("inProgress")
                        {
                            if self.proposed.len() >= MAX_ITEMS {
                                self.disconnect();
                                self.status =
                                    "Too many proposed file changes".into();
                            } else {
                                self.proposed.insert(
                                    id.to_owned(),
                                    ReviewedFileChange::capture(
                                        &self.workspace,
                                        &item,
                                    ),
                                );
                            }
                        } else {
                            self.proposed.remove(id);
                        }
                    }
                }
                AgentEvent::ActionRequired {
                    method,
                    request_id,
                    params,
                } => {
                    if self.pending.len() >= MAX_ITEMS {
                        self.disconnect();
                        self.status = "Too many approval requests".into();
                        return;
                    }
                    let review = if method == "item/fileChange/requestApproval" {
                        params
                            .get("itemId")
                            .and_then(Value::as_str)
                            .and_then(|id| self.proposed.get(id))
                            .and_then(|result| result.as_ref().ok())
                            .cloned()
                    } else {
                        None
                    };
                    let preview = review
                        .as_ref()
                        .map(|review| {
                            review
                                .changes()
                                .iter()
                                .map(|change| format!("{}\n{}", change.path.display(), change.diff))
                                .collect::<Vec<_>>()
                                .join("\n\n")
                        })
                        .unwrap_or_else(|| {
                            "No supported file edit preview is available; decline this request."
                                .into()
                        });
                    let reason = params
                        .get("reason")
                        .and_then(Value::as_str)
                        .unwrap_or("Review this request")
                        .to_owned();
                    self.pending.push(PendingApproval {
                        request_id,
                        method,
                        params,
                        review,
                        preview,
                        reason,
                    });
                    self.status = "Approval required".into();
                }
                AgentEvent::ApprovalResolved(id) => {
                    self.pending.retain(|pending| pending.request_id != id);
                }
                AgentEvent::TurnFinished(outcome) => {
                    self.active_turn = None;
                    self.proposed.clear();
                    self.pending.clear();
                    self.status = match outcome {
                        TurnOutcome::Completed => "Turn completed".into(),
                        TurnOutcome::Failed => "Turn failed".into(),
                        TurnOutcome::Interrupted => "Turn interrupted".into(),
                    };
                }
                AgentEvent::OtherNotification(_) => {}
            },
        }
    }
}

fn append_bounded(target: &mut String, delta: &str, limit: usize) {
    if target.len() >= limit {
        return;
    }
    let remaining = limit - target.len();
    if delta.len() <= remaining {
        target.push_str(delta);
    } else {
        for character in delta.chars() {
            if target.len() + character.len_utf8() > limit {
                break;
            }
            target.push(character);
        }
    }
}
