use codestrike::unity_connection::{
    DiscoveryEffect, DiscoveryError, UnityMcpDiscovery, inspect_unity_project,
};
use serde_json::{Value, json};
use std::time::{SystemTime, UNIX_EPOCH};

fn frame(value: Value) -> String {
    value.to_string()
}

#[test]
fn discovers_local_project_without_changing_files() {
    let nonce = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap()
        .as_nanos();
    let root = std::env::temp_dir().join(format!("codestrike-unity-project-{nonce}"));
    std::fs::create_dir_all(root.join("Assets")).unwrap();
    std::fs::create_dir_all(root.join("ProjectSettings")).unwrap();
    let version = root.join("ProjectSettings/ProjectVersion.txt");
    let original = b"m_EditorVersion: 6000.2.0f1\n";
    std::fs::write(&version, original).unwrap();
    let project = inspect_unity_project(&root).unwrap();
    assert_eq!(project.root, std::fs::canonicalize(&root).unwrap());
    assert_eq!(project.editor_version, "6000.2.0f1");
    assert_eq!(std::fs::read(&version).unwrap(), original);
    std::fs::remove_file(version).unwrap();
    std::fs::remove_dir(root.join("ProjectSettings")).unwrap();
    std::fs::remove_dir(root.join("Assets")).unwrap();
    std::fs::remove_dir(root).unwrap();
}

#[test]
fn mcp_discovery_only_emits_initialize_notification_and_tool_listing() {
    let mut client = UnityMcpDiscovery::new();
    let initialize: Value = serde_json::from_str(&client.initialize().unwrap()).unwrap();
    assert_eq!(initialize["method"], "initialize");
    assert_eq!(initialize["params"]["capabilities"], json!({}));
    let effects = client.receive(&frame(json!({
        "jsonrpc":"2.0", "id":1,
        "result":{"protocolVersion":"2025-06-18","capabilities":{"tools":{}},"serverInfo":{"name":"fixture","version":"1"}}
    }))).unwrap();
    assert_eq!(effects.len(), 2);
    assert!(
        matches!(&effects[0], DiscoveryEffect::Send(value) if serde_json::from_str::<Value>(value).unwrap()["method"] == "notifications/initialized")
    );
    assert!(
        matches!(&effects[1], DiscoveryEffect::Send(value) if serde_json::from_str::<Value>(value).unwrap()["method"] == "tools/list")
    );
    let effects = client.receive(&frame(json!({"jsonrpc":"2.0","id":2,"result":{"tools":[{"name":"unity_get_scene_info"}],"nextCursor":"next"}}))).unwrap();
    assert!(
        matches!(&effects[0], DiscoveryEffect::Send(value) if serde_json::from_str::<Value>(value).unwrap()["params"]["cursor"] == "next")
    );
    let effects = client
        .receive(&frame(
            json!({"jsonrpc":"2.0","id":3,"result":{"tools":[{"name":"unity_edit_scene"}]}}),
        ))
        .unwrap();
    assert_eq!(
        effects,
        vec![DiscoveryEffect::Completed(vec![
            "unity_get_scene_info".into(),
            "unity_edit_scene".into()
        ])]
    );
    assert!(client.is_complete());
}

#[test]
fn rejects_server_requests_version_mismatch_and_duplicate_pagination() {
    let mut client = UnityMcpDiscovery::new();
    client.initialize().unwrap();
    assert_eq!(
        client.receive(&frame(
            json!({"jsonrpc":"2.0","id":7,"method":"tools/call","params":{}})
        )),
        Err(DiscoveryError::ServerRequest)
    );
    assert_eq!(client.receive(&frame(json!({"jsonrpc":"2.0","id":1,"result":{"protocolVersion":"2099-01-01","capabilities":{"tools":{}},"serverInfo":{"name":"fixture"}}}))), Err(DiscoveryError::UnsupportedVersion));

    let mut client = UnityMcpDiscovery::new();
    client.initialize().unwrap();
    client.receive(&frame(json!({"jsonrpc":"2.0","id":1,"result":{"protocolVersion":"2025-06-18","capabilities":{"tools":{}},"serverInfo":{"name":"fixture"}}}))).unwrap();
    client
        .receive(&frame(
            json!({"jsonrpc":"2.0","id":2,"result":{"tools":[],"nextCursor":"same"}}),
        ))
        .unwrap();
    assert_eq!(
        client.receive(&frame(
            json!({"jsonrpc":"2.0","id":3,"result":{"tools":[],"nextCursor":"same"}})
        )),
        Err(DiscoveryError::InvalidFrame)
    );
}
