use codestrike::agent_review::{ReviewError, ReviewedFileChange};
use serde_json::json;
use std::time::{SystemTime, UNIX_EPOCH};

fn fixture() -> (std::path::PathBuf, std::path::PathBuf) {
    let nonce = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap()
        .as_nanos();
    let root =
        std::env::temp_dir().join(format!("codestrike-review-{}-{nonce}", std::process::id()));
    std::fs::create_dir(&root).unwrap();
    let source = root.join("main.rs");
    std::fs::write(&source, b"fn original() {}\n").unwrap();
    (root, source)
}

#[test]
fn reviewed_update_matches_item_and_rejects_stale_bytes() {
    let (root, source) = fixture();
    let item = json!({"id":"change-1","type":"fileChange","status":"inProgress","changes":[{"path":source,"kind":"update","diff":"-old\n+new"}]});
    let review = ReviewedFileChange::capture(&root, &item).unwrap();
    assert_eq!(review.item_id(), "change-1");
    assert_eq!(review.changes().len(), 1);
    assert_eq!(review.changes()[0].diff, "-old\n+new");
    assert_eq!(
        review.validate_approval(&json!({"itemId":"change-1"})),
        Ok(())
    );
    assert_eq!(
        review.validate_approval(&json!({"itemId":"other"})),
        Err(ReviewError::WrongItem)
    );
    std::fs::write(&source, b"fn someone_else() {}\n").unwrap();
    assert_eq!(
        review.validate_approval(&json!({"itemId":"change-1"})),
        Err(ReviewError::StaleFile)
    );
    std::fs::remove_file(source).unwrap();
    std::fs::remove_dir(root).unwrap();
}

#[test]
fn reviewed_update_rejects_changes_outside_root_and_unsupported_kinds() {
    let (root, source) = fixture();
    let outside =
        std::env::temp_dir().join(format!("codestrike-outside-{}.rs", std::process::id()));
    std::fs::write(&outside, b"outside").unwrap();
    let item = json!({"id":"change-2","type":"fileChange","status":"inProgress","changes":[{"path":outside,"kind":"update","diff":"+bad"}]});
    assert_eq!(
        ReviewedFileChange::capture(&root, &item).unwrap_err(),
        ReviewError::OutsideWorkspace
    );
    let add = json!({"id":"change-3","type":"fileChange","status":"inProgress","changes":[{"path":source,"kind":"add","diff":"+new"}]});
    assert_eq!(
        ReviewedFileChange::capture(&root, &add).unwrap_err(),
        ReviewError::UnsupportedChange
    );
    std::fs::remove_file(source).unwrap();
    std::fs::remove_file(outside).unwrap();
    std::fs::remove_dir(root).unwrap();
}

#[test]
fn aggregate_preview_limit_rejects_many_large_diffs() {
    let (root, first) = fixture();
    let second = root.join("other.rs");
    std::fs::write(&second, b"fn second() {}\n").unwrap();
    let large_diff = "+".repeat(140 * 1024);
    let item = json!({"id":"many-diffs","type":"fileChange","status":"inProgress","changes":[
        {"path":first,"kind":"update","diff":large_diff},
        {"path":second,"kind":"update","diff":large_diff}
    ]});
    assert_eq!(
        ReviewedFileChange::capture(&root, &item).unwrap_err(),
        ReviewError::FileTooLarge
    );
    std::fs::remove_file(first).unwrap();
    std::fs::remove_file(second).unwrap();
    std::fs::remove_dir(root).unwrap();
}
