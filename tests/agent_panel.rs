use codestrike::agent_adapter::ApprovalDecision;
use codestrike::agent_panel::LocalAgentPanel;
use std::ffi::OsString;
use std::path::PathBuf;
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

fn pump_until(panel: &mut LocalAgentPanel, predicate: impl Fn(&LocalAgentPanel) -> bool) {
    let start = Instant::now();
    while !predicate(panel) {
        panel.poll();
        assert!(
            start.elapsed() < Duration::from_secs(5),
            "mock panel timed out: {:?}",
            panel.snapshot()
        );
        std::thread::sleep(Duration::from_millis(10));
    }
}

#[test]
fn panel_declines_stale_edit_and_reconnect_clears_old_approval() {
    let nonce = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap()
        .as_nanos();
    let root =
        std::env::temp_dir().join(format!("codestrike-panel-{}-{nonce}", std::process::id()));
    std::fs::create_dir(&root).unwrap();
    let source = root.join("fixture.rs");
    std::fs::write(&source, b"fn original() {}\n").unwrap();
    let script =
        PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("tests/fixtures/mock_app_server.py");
    let args = [
        OsString::from("-u"),
        script.into_os_string(),
        root.as_os_str().to_owned(),
    ];
    let python = if cfg!(windows) { "python" } else { "python3" };
    let mut panel = LocalAgentPanel::new(root.clone());
    panel
        .start(PathBuf::from(python).as_path(), &args, "fixture-model")
        .unwrap();
    pump_until(&mut panel, |panel| panel.ready());
    panel.send_prompt("Edit fixture").unwrap();
    pump_until(&mut panel, |panel| !panel.snapshot().pending.is_empty());
    let pending = panel.snapshot().pending[0].clone();
    assert!(pending.can_accept);
    assert!(pending.preview.contains("+changed"));
    std::fs::write(&source, b"fn external() {}\n").unwrap();
    assert!(
        panel
            .decide(&pending.request_id, ApprovalDecision::Accept)
            .is_err()
    );
    assert_eq!(std::fs::read(&source).unwrap(), b"fn external() {}\n");
    panel
        .decide(&pending.request_id, ApprovalDecision::Decline)
        .unwrap();
    pump_until(&mut panel, |panel| panel.ready());
    panel
        .start(PathBuf::from(python).as_path(), &args, "fixture-model")
        .unwrap();
    assert!(
        panel
            .decide(&pending.request_id, ApprovalDecision::Accept)
            .is_err()
    );
    pump_until(&mut panel, |panel| panel.ready());
    assert!(panel.snapshot().pending.is_empty());
    panel.disconnect();
    std::fs::remove_file(source).unwrap();
    std::fs::remove_dir(root).unwrap();
}

#[test]
fn repeated_start_and_disconnect_drop_pending_turn_without_a_write() {
    let nonce = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap()
        .as_nanos();
    let root = std::env::temp_dir().join(format!(
        "codestrike-panel-restart-{}-{nonce}",
        std::process::id()
    ));
    std::fs::create_dir(&root).unwrap();
    let source = root.join("fixture.rs");
    std::fs::write(&source, b"fn original() {}\n").unwrap();
    let script =
        PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("tests/fixtures/mock_app_server.py");
    let args = [
        OsString::from("-u"),
        script.into_os_string(),
        root.as_os_str().to_owned(),
    ];
    let python = PathBuf::from(if cfg!(windows) { "python" } else { "python3" });
    let mut panel = LocalAgentPanel::new(root.clone());
    panel.start(&python, &args, "fixture-model").unwrap();
    pump_until(&mut panel, |panel| panel.ready());
    panel.send_prompt("Edit fixture").unwrap();
    pump_until(&mut panel, |panel| !panel.snapshot().pending.is_empty());
    let old_id = panel.snapshot().pending[0].request_id.clone();
    panel.start(&python, &args, "fixture-model").unwrap();
    assert!(panel.snapshot().pending.is_empty());
    assert!(panel.decide(&old_id, ApprovalDecision::Accept).is_err());
    pump_until(&mut panel, |panel| panel.ready());
    panel.disconnect();
    panel.disconnect();
    assert_eq!(std::fs::read(&source).unwrap(), b"fn original() {}\n");
    std::fs::remove_file(source).unwrap();
    std::fs::remove_dir(root).unwrap();
}
