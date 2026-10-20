use codestrike::agent_adapter::{AgentEvent, ApprovalDecision, TurnOutcome};
use codestrike::agent_session::{LocalAgentSession, SessionEvent};
use serde_json::Value;
use std::ffi::OsString;
use std::path::PathBuf;
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

fn wait_for(
    session: &mut LocalAgentSession,
    seen: &mut Vec<SessionEvent>,
    predicate: impl Fn(&SessionEvent) -> bool,
) {
    let start = Instant::now();
    loop {
        let mut found = false;
        for event in session.poll(32) {
            found |= predicate(&event);
            seen.push(event);
        }
        if found {
            return;
        }
        if let Some(SessionEvent::Disconnected(reason)) = seen.last() {
            panic!("mock server disconnected: {reason}");
        }
        assert!(
            start.elapsed() < Duration::from_secs(5),
            "timed out waiting for mock app-server"
        );
        std::thread::sleep(Duration::from_millis(10));
    }
}

#[test]
fn local_process_decline_then_accept_has_real_file_lifecycle() {
    let nonce = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap()
        .as_nanos();
    let root = std::env::temp_dir().join(format!(
        "codestrike-agent-fixture-{}-{nonce}",
        std::process::id()
    ));
    std::fs::create_dir(&root).unwrap();
    let source = root.join("fixture.rs");
    std::fs::write(&source, b"fn original() {}\n").unwrap();
    let script =
        PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("tests/fixtures/mock_app_server.py");
    let python = if cfg!(windows) { "python" } else { "python3" };
    let mut session = LocalAgentSession::spawn(
        PathBuf::from(python).as_path(),
        &[
            OsString::from("-u"),
            script.into_os_string(),
            root.as_os_str().to_owned(),
        ],
        &root,
        "fixture-model",
    )
    .unwrap();
    let mut seen = Vec::new();
    wait_for(&mut session, &mut seen, |event| {
        matches!(event, SessionEvent::Agent(AgentEvent::ThreadStarted(_)))
    });
    assert!(session.ready_for_turn());

    for (index, decision) in [
        (1, ApprovalDecision::Decline),
        (2, ApprovalDecision::Accept),
    ] {
        session.send_prompt("Edit fixture source").unwrap();
        let mut turn_events = Vec::new();
        wait_for(&mut session, &mut turn_events, |event| {
            matches!(
                event,
                SessionEvent::Agent(AgentEvent::ActionRequired { .. })
            )
        });
        let request_id = turn_events
            .iter()
            .find_map(|event| match event {
                SessionEvent::Agent(AgentEvent::ActionRequired { request_id, .. }) => {
                    Some(request_id.clone())
                }
                _ => None,
            })
            .unwrap();
        assert_eq!(request_id, Value::String(format!("approval-{index}")));
        session.respond_approval(&request_id, decision).unwrap();
        wait_for(&mut session, &mut turn_events, |event| {
            matches!(
                event,
                SessionEvent::Agent(AgentEvent::TurnFinished(TurnOutcome::Completed))
            )
        });
        let file_events: Vec<&Value> = turn_events
            .iter()
            .filter_map(|event| match event {
                SessionEvent::Agent(AgentEvent::FileChange(item)) => Some(item),
                _ => None,
            })
            .collect();
        assert_eq!(
            file_events.len(),
            2,
            "file change start and completion must be visible"
        );
        assert_eq!(file_events[0]["status"], "inProgress");
        assert_eq!(
            file_events[1]["status"],
            if index == 1 { "declined" } else { "completed" }
        );
        assert_eq!(
            turn_events
                .iter()
                .filter(|event| matches!(event, SessionEvent::Agent(AgentEvent::DiffUpdated(_))))
                .count(),
            if index == 1 { 0 } else { 1 }
        );
        let expected = if index == 1 {
            b"fn original() {}\n".as_slice()
        } else {
            b"fn changed() {}\n".as_slice()
        };
        assert_eq!(std::fs::read(&source).unwrap(), expected);
    }
    session.send_prompt("Inspect fixture and stop").unwrap();
    let mut interrupted_events = Vec::new();
    wait_for(&mut session, &mut interrupted_events, |event| {
        matches!(event, SessionEvent::Agent(AgentEvent::TurnStarted(_)))
    });
    session.interrupt_turn().unwrap();
    wait_for(&mut session, &mut interrupted_events, |event| {
        matches!(
            event,
            SessionEvent::Agent(AgentEvent::TurnFinished(TurnOutcome::Interrupted))
        )
    });
    assert_eq!(std::fs::read(&source).unwrap(), b"fn changed() {}\n");
    drop(session);
    std::fs::remove_file(source).unwrap();
    std::fs::remove_dir(root).unwrap();
}
