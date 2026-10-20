use codestrike::agent_adapter::{
    AdapterEffect, AdapterError, AgentEvent, ApprovalDecision, LocalCodexAdapter,
    MAX_WIRE_LINE_BYTES, TurnOutcome,
};
use serde_json::{Value, json};
use std::path::Path;

fn decoded(frame: &str) -> Value {
    assert!(
        frame.ends_with('\n'),
        "stdio messages need a newline boundary"
    );
    serde_json::from_str(frame).unwrap()
}

fn ready() -> LocalCodexAdapter {
    let mut adapter = LocalCodexAdapter::new();
    let initialize = decoded(&adapter.initialize().unwrap());
    assert_eq!(initialize["method"], "initialize");
    assert_eq!(initialize["params"]["clientInfo"]["name"], "codestrike");
    assert!(initialize.get("jsonrpc").is_none());
    let effects = adapter.receive_line(r#"{"id":1,"result":{}}"#).unwrap();
    assert_eq!(effects.len(), 2);
    assert_eq!(
        effects[0],
        AdapterEffect::Send("{\"method\":\"initialized\",\"params\":{}}\n".into())
    );
    assert_eq!(effects[1], AdapterEffect::Show(AgentEvent::Ready));
    adapter
}

fn thread_ready() -> LocalCodexAdapter {
    let mut adapter = ready();
    let cwd = std::env::temp_dir();
    let request = decoded(&adapter.start_thread(&cwd, "user-selected-model").unwrap());
    assert_eq!(request["method"], "thread/start");
    assert_eq!(request["params"]["cwd"], cwd.to_str().unwrap());
    assert_eq!(request["params"]["sandbox"], "readOnly");
    assert_eq!(request["params"]["approvalPolicy"], "onRequest");
    assert_eq!(request["params"]["model"], "user-selected-model");
    assert_eq!(
        adapter
            .receive_line(r#"{"id":2,"result":{"thread":{"id":"thread-1"}}}"#)
            .unwrap(),
        vec![AdapterEffect::Show(AgentEvent::ThreadStarted(
            "thread-1".into()
        ))]
    );
    adapter
}

#[test]
fn local_turn_starts_read_only_and_streams_until_success() {
    let mut adapter = thread_ready();
    let request = decoded(&adapter.start_turn("Inspect this project").unwrap());
    assert_eq!(request["method"], "turn/start");
    assert_eq!(request["params"]["threadId"], "thread-1");
    assert_eq!(request["params"]["sandboxPolicy"]["type"], "readOnly");
    assert!(
        request["params"]["sandboxPolicy"]
            .get("writableRoots")
            .is_none()
    );
    assert!(!request.to_string().contains("ACCESS_TOKEN"));

    assert_eq!(
        adapter
            .receive_line(r#"{"id":3,"result":{"turn":{"id":"turn-1"}}}"#)
            .unwrap(),
        vec![AdapterEffect::Show(AgentEvent::TurnStarted(
            "turn-1".into()
        ))]
    );
    assert_eq!(
        adapter
            .receive_line(r#"{"method":"item/agentMessage/delta","params":{"delta":"Working"}}"#)
            .unwrap(),
        vec![AdapterEffect::Show(AgentEvent::MessageDelta(
            "Working".into()
        ))]
    );
    assert_eq!(
        adapter.receive_line(r#"{"method":"turn/diff/updated","params":{"threadId":"thread-1","turnId":"turn-1","diff":"diff --git a/x b/x"}}"#).unwrap(),
        vec![AdapterEffect::Show(AgentEvent::DiffUpdated("diff --git a/x b/x".into()))]
    );
    assert_eq!(
        adapter.receive_line(r#"{"method":"turn/completed","params":{"turn":{"id":"turn-1","status":"completed"}}}"#).unwrap(),
        vec![AdapterEffect::Show(AgentEvent::TurnFinished(TurnOutcome::Completed))]
    );
    assert!(adapter.start_turn("Next task").is_ok());
}

#[test]
fn approval_request_is_exposed_without_an_automatic_reply() {
    let mut adapter = thread_ready();
    adapter.start_turn("Inspect the fixture").unwrap();
    adapter
        .receive_line(r#"{"id":3,"result":{"turn":{"id":"turn-1"}}}"#)
        .unwrap();
    let request = json!({
        "id": "approval-7", "method": "item/commandExecution/requestApproval",
        "params": {"threadId": "thread-1", "turnId": "turn-1", "command": ["git", "status"]}
    });
    assert_eq!(
        adapter.receive_line(&request.to_string()).unwrap(),
        vec![AdapterEffect::Show(AgentEvent::ActionRequired {
            method: "item/commandExecution/requestApproval".into(),
            request_id: json!("approval-7"),
            params: json!({"threadId": "thread-1", "turnId": "turn-1", "command": ["git", "status"]}),
        })]
    );
    let response = decoded(
        &adapter
            .answer_approval(&json!("approval-7"), ApprovalDecision::Decline)
            .unwrap(),
    );
    assert_eq!(
        response,
        json!({"id": "approval-7", "result": {"decision": "decline"}})
    );
    assert_eq!(
        adapter
            .answer_approval(&json!("approval-7"), ApprovalDecision::Accept)
            .unwrap_err(),
        AdapterError::UnknownApproval
    );
    assert_eq!(
        adapter.receive_line(r#"{"id":"approval-8","method":"item/fileChange/requestApproval","params":{"threadId":"other-thread"}}"#).unwrap_err(),
        AdapterError::InvalidFrame
    );
    assert_eq!(
        adapter.receive_line(r#"{"id":"approval-8","method":"item/fileChange/requestApproval","params":{"threadId":"thread-1"}}"#).unwrap_err(),
        AdapterError::InvalidFrame
    );
}

#[test]
fn file_change_events_and_one_time_approval_are_scoped_to_the_turn() {
    let mut adapter = thread_ready();
    adapter.start_turn("Edit the fixture").unwrap();
    adapter
        .receive_line(r#"{"id":3,"result":{"turn":{"id":"turn-1"}}}"#)
        .unwrap();
    let item = json!({"id":"change-1","type":"fileChange","status":"inProgress","changes":[{"path":"fixture.rs","kind":"update","diff":"+new"}]});
    let notification = json!({"method":"item/started","params":{"threadId":"thread-1","turnId":"turn-1","item":item}});
    assert_eq!(
        adapter.receive_line(&notification.to_string()).unwrap(),
        vec![AdapterEffect::Show(AgentEvent::FileChange(item))]
    );
    let approval = json!({"id":23,"method":"item/fileChange/requestApproval","params":{"threadId":"thread-1","turnId":"turn-1","itemId":"change-1"}});
    adapter.receive_line(&approval.to_string()).unwrap();
    assert_eq!(
        adapter.receive_line(&approval.to_string()).unwrap_err(),
        AdapterError::DuplicateApproval
    );
    let response = decoded(
        &adapter
            .answer_approval(&json!(23), ApprovalDecision::Accept)
            .unwrap(),
    );
    assert_eq!(response, json!({"id":23,"result":{"decision":"accept"}}));
    assert_eq!(
        adapter.receive_line(r#"{"method":"serverRequest/resolved","params":{"threadId":"thread-1","requestId":23}}"#).unwrap(),
        vec![AdapterEffect::Show(AgentEvent::ApprovalResolved(json!(23)))]
    );
    adapter.receive_line(r#"{"method":"turn/completed","params":{"threadId":"thread-1","turn":{"id":"turn-1","status":"completed"}}}"#).unwrap();
    assert_eq!(
        adapter
            .answer_approval(&json!(23), ApprovalDecision::Decline)
            .unwrap_err(),
        AdapterError::UnknownApproval
    );
}

#[test]
fn interruption_is_scoped_and_waits_for_terminal_status() {
    let mut adapter = thread_ready();
    assert_eq!(
        adapter.interrupt_turn().unwrap_err(),
        AdapterError::InvalidState
    );
    adapter.start_turn("Inspect fixture").unwrap();
    adapter
        .receive_line(r#"{"id":3,"result":{"turn":{"id":"turn-1"}}}"#)
        .unwrap();
    let interrupt = decoded(&adapter.interrupt_turn().unwrap());
    assert_eq!(interrupt["method"], "turn/interrupt");
    assert_eq!(
        interrupt["params"],
        json!({"threadId":"thread-1","turnId":"turn-1"})
    );
    assert_eq!(
        adapter.interrupt_turn().unwrap_err(),
        AdapterError::InvalidState
    );
    assert_eq!(
        adapter.receive_line(r#"{"id":4,"result":{}}"#).unwrap(),
        vec![]
    );
    assert!(!adapter.ready_for_turn());
    assert_eq!(
        adapter.receive_line(r#"{"method":"turn/completed","params":{"threadId":"thread-1","turn":{"id":"turn-1","status":"interrupted"}}}"#).unwrap(),
        vec![AdapterEffect::Show(AgentEvent::TurnFinished(TurnOutcome::Interrupted))]
    );
    assert!(adapter.ready_for_turn());
}

#[test]
fn rejects_out_of_order_or_oversized_input_and_invalid_project() {
    let mut adapter = LocalCodexAdapter::new();
    assert_eq!(
        adapter.start_turn("early").unwrap_err(),
        AdapterError::InvalidState
    );
    adapter.initialize().unwrap();
    assert_eq!(
        adapter
            .receive_line(r#"{"id":99,"result":{}}"#)
            .unwrap_err(),
        AdapterError::UnexpectedResponse
    );
    assert_eq!(
        adapter
            .receive_line(&"x".repeat(MAX_WIRE_LINE_BYTES + 1))
            .unwrap_err(),
        AdapterError::FrameTooLarge
    );
    adapter.receive_line(r#"{"id":1,"result":{}}"#).unwrap();
    assert_eq!(
        adapter
            .start_thread(Path::new("relative"), "model")
            .unwrap_err(),
        AdapterError::InvalidProject
    );
    assert_eq!(
        adapter
            .start_thread(Path::new("relative/../other"), "model")
            .unwrap_err(),
        AdapterError::InvalidProject
    );
    assert_eq!(
        adapter
            .start_thread(&std::env::temp_dir(), " ")
            .unwrap_err(),
        AdapterError::EmptyInput
    );
}

#[test]
fn failed_turn_is_not_reported_as_success() {
    let mut adapter = thread_ready();
    adapter.start_turn("try").unwrap();
    adapter
        .receive_line(r#"{"id":3,"result":{"turn":{"id":"turn-1"}}}"#)
        .unwrap();
    assert_eq!(
        adapter.receive_line(r#"{"method":"turn/completed","params":{"turn":{"id":"turn-1","status":"failed","error":{"message":"offline"}}}}"#).unwrap(),
        vec![AdapterEffect::Show(AgentEvent::TurnFinished(TurnOutcome::Failed))]
    );
}
