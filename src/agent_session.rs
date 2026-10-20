//! Local, user-started app-server process. No account or model call occurs
//! unless the host explicitly starts a configured executable and sends a turn.

use crate::agent_adapter::{
    AdapterEffect, AgentEvent, ApprovalDecision, LocalCodexAdapter, MAX_WIRE_LINE_BYTES,
};
use serde_json::Value;
use std::ffi::OsString;
use std::fs;
use std::io::{self, BufRead, BufReader, Write};
use std::path::{Path, PathBuf};
use std::process::{Child, ChildStdin, Command, Stdio};
use std::sync::mpsc::{self, Receiver, TryRecvError};
use std::thread::{self, JoinHandle};

#[derive(Debug, PartialEq)]
pub enum SessionEvent {
    Agent(AgentEvent),
    Disconnected(String),
}

enum Incoming {
    Line(String),
    Closed,
    Error(String),
}

pub struct LocalAgentSession {
    adapter: LocalCodexAdapter,
    child: Child,
    stdin: ChildStdin,
    inbox: Receiver<Incoming>,
    reader: Option<JoinHandle<()>>,
    project: PathBuf,
    model: String,
    disconnected: bool,
}

impl LocalAgentSession {
    /// The caller selects a trusted local app-server executable and fixed args.
    /// This method does not read, create, or alter authentication state.
    pub fn spawn(
        executable: &Path,
        args: &[OsString],
        project: &Path,
        model: &str,
    ) -> io::Result<Self> {
        let project = fs::canonicalize(project)?;
        if !project.is_dir() || model.trim().is_empty() {
            return Err(io::Error::new(
                io::ErrorKind::InvalidInput,
                "project or model is invalid",
            ));
        }
        let mut child = Command::new(executable)
            .args(args)
            .current_dir(&project)
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::null())
            .spawn()?;
        let stdin = child
            .stdin
            .take()
            .ok_or_else(|| io::Error::other("missing child stdin"))?;
        let stdout = child
            .stdout
            .take()
            .ok_or_else(|| io::Error::other("missing child stdout"))?;
        // Backpressure prevents a noisy child from growing the UI queue without bound.
        let (sender, inbox) = mpsc::sync_channel(256);
        let reader = thread::spawn(move || {
            let mut reader = BufReader::new(stdout);
            loop {
                let incoming = match read_line_bounded(&mut reader) {
                    Ok(Some(line)) => Incoming::Line(line),
                    Ok(None) => Incoming::Closed,
                    Err(error) => Incoming::Error(error.to_string()),
                };
                let terminal = !matches!(incoming, Incoming::Line(_));
                if sender.try_send(incoming).is_err() || terminal {
                    break;
                }
            }
        });
        let mut session = Self {
            adapter: LocalCodexAdapter::new(),
            child,
            stdin,
            inbox,
            reader: Some(reader),
            project,
            model: model.to_owned(),
            disconnected: false,
        };
        let frame = session.adapter.initialize().map_err(protocol_error)?;
        session.write(&frame)?;
        Ok(session)
    }

    pub fn ready_for_turn(&self) -> bool {
        !self.disconnected && self.adapter.ready_for_turn()
    }

    pub fn send_prompt(&mut self, prompt: &str) -> io::Result<()> {
        if self.disconnected {
            return Err(io::Error::new(
                io::ErrorKind::BrokenPipe,
                "app-server disconnected",
            ));
        }
        let frame = self.adapter.start_turn(prompt).map_err(protocol_error)?;
        self.write(&frame)
    }

    pub fn respond_approval(
        &mut self,
        request_id: &Value,
        decision: ApprovalDecision,
    ) -> io::Result<()> {
        if self.disconnected {
            return Err(io::Error::new(
                io::ErrorKind::BrokenPipe,
                "app-server disconnected",
            ));
        }
        let frame = self
            .adapter
            .answer_approval(request_id, decision)
            .map_err(protocol_error)?;
        self.write(&frame)
    }

    pub fn interrupt_turn(&mut self) -> io::Result<()> {
        if self.disconnected {
            return Err(io::Error::new(
                io::ErrorKind::BrokenPipe,
                "app-server disconnected",
            ));
        }
        let frame = self.adapter.interrupt_turn().map_err(protocol_error)?;
        self.write(&frame)
    }

    /// Drain at most `limit` events, keeping UI work bounded per frame.
    pub fn poll(&mut self, limit: usize) -> Vec<SessionEvent> {
        let mut events = Vec::new();
        for _ in 0..limit.min(64) {
            match self.inbox.try_recv() {
                Ok(Incoming::Line(line)) => match self.adapter.receive_line(&line) {
                    Ok(effects) => {
                        for effect in effects {
                            match effect {
                                AdapterEffect::Send(frame) => {
                                    if let Err(error) = self.write(&frame) {
                                        self.disconnect(error.to_string(), &mut events);
                                    }
                                }
                                AdapterEffect::Show(AgentEvent::Ready) => {
                                    events.push(SessionEvent::Agent(AgentEvent::Ready));
                                    match self.adapter.start_thread(&self.project, &self.model) {
                                        Ok(frame) => {
                                            if let Err(error) = self.write(&frame) {
                                                self.disconnect(error.to_string(), &mut events);
                                            }
                                        }
                                        Err(error) => self.disconnect(
                                            format!("thread start: {error:?}"),
                                            &mut events,
                                        ),
                                    }
                                }
                                AdapterEffect::Show(event) => {
                                    events.push(SessionEvent::Agent(event))
                                }
                            }
                        }
                    }
                    Err(error) => {
                        self.disconnect(format!("app-server protocol: {error:?}"), &mut events)
                    }
                },
                Ok(Incoming::Closed) => {
                    self.disconnect("app-server closed stdout".into(), &mut events)
                }
                Ok(Incoming::Error(error)) => self.disconnect(error, &mut events),
                Err(TryRecvError::Empty) => break,
                Err(TryRecvError::Disconnected) => {
                    self.disconnect("app-server reader stopped".into(), &mut events);
                    break;
                }
            }
            if self.disconnected {
                break;
            }
        }
        events
    }

    fn write(&mut self, frame: &str) -> io::Result<()> {
        if frame.len() > MAX_WIRE_LINE_BYTES || !frame.ends_with('\n') {
            return Err(io::Error::new(
                io::ErrorKind::InvalidData,
                "invalid outgoing frame",
            ));
        }
        self.stdin.write_all(frame.as_bytes())?;
        self.stdin.flush()
    }

    fn disconnect(&mut self, reason: String, events: &mut Vec<SessionEvent>) {
        if !self.disconnected {
            self.disconnected = true;
            // Stop a child that sent an invalid frame or lost the transport.
            let _ = self.child.kill();
            events.push(SessionEvent::Disconnected(reason));
        }
    }
}

impl Drop for LocalAgentSession {
    fn drop(&mut self) {
        let _ = self.child.kill();
        let _ = self.child.wait();
        if let Some(reader) = self.reader.take() {
            let _ = reader.join();
        }
    }
}

fn protocol_error(error: crate::agent_adapter::AdapterError) -> io::Error {
    io::Error::new(
        io::ErrorKind::InvalidData,
        format!("app-server protocol: {error:?}"),
    )
}

fn read_line_bounded(reader: &mut impl BufRead) -> io::Result<Option<String>> {
    let mut bytes = Vec::new();
    loop {
        let chunk = reader.fill_buf()?;
        if chunk.is_empty() {
            return if bytes.is_empty() {
                Ok(None)
            } else {
                Err(io::Error::new(
                    io::ErrorKind::UnexpectedEof,
                    "partial app-server frame",
                ))
            };
        }
        let count = chunk
            .iter()
            .position(|byte| *byte == b'\n')
            .map_or(chunk.len(), |i| i + 1);
        if bytes.len() + count > MAX_WIRE_LINE_BYTES {
            return Err(io::Error::new(
                io::ErrorKind::InvalidData,
                "app-server frame too large",
            ));
        }
        bytes.extend_from_slice(&chunk[..count]);
        reader.consume(count);
        if bytes.last() == Some(&b'\n') {
            return String::from_utf8(bytes).map(Some).map_err(|_| {
                io::Error::new(io::ErrorKind::InvalidData, "app-server frame is not UTF-8")
            });
        }
    }
}
