use codestrike::{CargoAction, Document, SearchQuery, run_cargo, run_cargo_with_control, search_workspace};
use std::sync::atomic::AtomicBool;
use std::sync::atomic::{AtomicU64, Ordering};
use std::time::Duration;
use std::time::{SystemTime, UNIX_EPOCH};

static NEXT_TEST_ID: AtomicU64 = AtomicU64::new(0);
fn unique_root(label: &str) -> std::path::PathBuf {
    let nonce = SystemTime::now().duration_since(UNIX_EPOCH).unwrap().as_nanos();
    std::env::temp_dir().join(format!("codestrike-{label}-{}-{nonce}-{}",
        std::process::id(), NEXT_TEST_ID.fetch_add(1, Ordering::Relaxed)))
}

#[test]
fn explicit_cargo_cancellation_stops_a_new_child() {
    let root = std::env::temp_dir().join(format!("codestrike-cancel-{}", std::process::id()));
    std::fs::create_dir_all(&root).unwrap();
    std::fs::write(root.join("Cargo.toml"), "[package]\nname='cancel-fixture'\nversion='0.1.0'\nedition='2024'\n").unwrap();
    let cancelled = AtomicBool::new(true);
    let result = run_cargo_with_control(&root, CargoAction::Check, &cancelled, Duration::from_secs(10));
    let error = result.unwrap_err().to_string();
    if cfg!(windows) {
        assert!(error.contains("cancelled"));
    } else {
        // The preserved support core deliberately refuses unsafe process execution.
        assert!(error.contains("process-tree isolation unavailable"));
    }
}

#[test]
fn unicode_edit_undo_recovery_and_crlf_roundtrip() {
    let root = std::env::temp_dir().join(format!("codestrike-doc-{}", std::process::id()));
    std::fs::create_dir_all(&root).unwrap();
    let file = root.join("main.rs");
    std::fs::write(&file, b"\xef\xbb\xbffn main() {\r\n}\r\n").unwrap();
    let mut doc = Document::open(&file).unwrap();
    assert!(doc.editable());
    doc.insert(13, "let café = 42;\n").unwrap();
    assert!(doc.recovery_path().exists());
    doc.undo().unwrap();
    assert_eq!(doc.text(), "fn main() {\r\n}\r\n");
    doc.redo().unwrap();
    doc.save().unwrap();
    assert!(!doc.recovery_path().exists());
    let bytes = std::fs::read(&file).unwrap();
    assert!(bytes.starts_with(b"\xef\xbb\xbf"));
    assert!(bytes.windows(2).any(|w| w == b"\r\n"));
    assert!(String::from_utf8(bytes).unwrap().contains("café"));
}

#[test]
fn invalid_utf8_is_read_only_and_external_edit_blocks_save() {
    let root = std::env::temp_dir().join(format!("codestrike-conflict-{}", std::process::id()));
    std::fs::create_dir_all(&root).unwrap();
    let file = root.join("invalid.rs");
    std::fs::write(&file, [0xff, 0x00, 0x01]).unwrap();
    let mut invalid = Document::open(&file).unwrap();
    assert!(!invalid.editable());
    assert!(invalid.insert(0, "anything").is_err());
    assert!(invalid.save().is_err());
    assert_eq!(std::fs::read(&file).unwrap(), [0xff, 0x00, 0x01]);

    std::fs::write(&file, "fn first() {}\n").unwrap();
    let mut doc = Document::open(&file).unwrap();
    doc.insert(0, "// local\n").unwrap();
    std::fs::write(&file, "fn external() {}\n").unwrap();
    assert!(doc.save().is_err());
    assert_eq!(
        std::fs::read_to_string(&file).unwrap(),
        "fn external() {}\n"
    );
    assert!(doc.recovery_path().exists());
}

#[test]
fn bounded_workspace_search_and_cargo_diagnostic() {
    let root = std::env::temp_dir().join(format!("codestrike-workspace-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&root);
    std::fs::create_dir_all(root.join("src")).unwrap();
    std::fs::create_dir_all(root.join("target")).unwrap();
    std::fs::write(
        root.join("Cargo.toml"),
        "[package]\nname = \"cs_fixture\"\nversion = \"0.1.0\"\nedition = \"2024\"\n",
    )
    .unwrap();
    std::fs::write(
        root.join("src/main.rs"),
        "fn main() { let café: u32 = \"wrong\"; println!(\"{café}\"); }\n",
    )
    .unwrap();
    std::fs::write(root.join("target/ignored.rs"), "café").unwrap();
    let hits = search_workspace(
        &root,
        &SearchQuery {
            pattern: "café".into(),
            regex: false,
        },
    )
    .unwrap();
    assert_eq!(hits.len(), 2);
    assert!(hits.iter().all(|h| h.path.ends_with("src/main.rs")));
    assert_eq!(hits[0].line, 1);
    assert_eq!(hits[0].column, 17);
    assert!(
        search_workspace(
            &root,
            &SearchQuery {
                pattern: "[".into(),
                regex: true
            }
        )
        .is_err()
    );
    let result = run_cargo(&root, CargoAction::Check);
    if !cfg!(windows) {
        assert!(result.unwrap_err().to_string().contains("process-tree isolation unavailable"));
        return;
    }
    let report = result.unwrap();
    assert!(!report.success);
    assert!(
        report
            .diagnostics
            .iter()
            .any(|d| d.message.contains("mismatched types") && d.line == Some(1))
    );
}

#[test]
fn interrupted_edit_can_be_recovered_without_overwriting_external_change() {
    let root = std::env::temp_dir().join(format!("codestrike-recover-{}", std::process::id()));
    std::fs::create_dir_all(&root).unwrap();
    let file = root.join("lib.rs");
    std::fs::write(&file, "let answer = 1;\n").unwrap();
    let mut first = Document::open(&file).unwrap();
    first.replace(13, 14, "42").unwrap();
    drop(first);
    let mut reopened = Document::open(&file).unwrap();
    assert!(reopened.recovery_path().exists());
    reopened.recover().unwrap();
    assert_eq!(reopened.text(), "let answer = 42;\n");
    reopened.save().unwrap();
    assert_eq!(
        std::fs::read_to_string(&file).unwrap(),
        "let answer = 42;\n"
    );

    let mut changed = Document::open(&file).unwrap();
    changed.insert(0, "// unsaved\n").unwrap();
    drop(changed);
    std::fs::write(&file, "let answer = 99;\n").unwrap();
    let mut reopened = Document::open(&file).unwrap();
    assert!(reopened.recover().is_err());
    assert_eq!(
        std::fs::read_to_string(&file).unwrap(),
        "let answer = 99;\n"
    );
}

#[test]
fn transaction_sidecar_sentinels_survive_edit_and_save() {
    let root = std::env::temp_dir().join(format!("codestrike-sidecar-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&root);
    std::fs::create_dir_all(&root).unwrap();
    let source = root.join("sample.rs");
    std::fs::write(&source, "fn main() {}\n").unwrap();
    let save_sentinel = source.with_extension("codestrike-save.tmp");
    std::fs::write(&save_sentinel, b"unrelated save sentinel").unwrap();
    let mut doc = Document::open(&source).unwrap();
    doc.insert(0, "// edit\n").unwrap();
    doc.save().unwrap();
    assert_eq!(std::fs::read(&save_sentinel).unwrap(), b"unrelated save sentinel");
    assert!(std::fs::read_to_string(&source).unwrap().starts_with("// edit"));

    let second = root.join("second.rs");
    std::fs::write(&second, "let x = 1;\n").unwrap();
    let recovery_sentinel = second.with_file_name("second.rs.codestrike-recovery.tmp");
    std::fs::write(&recovery_sentinel, b"unrelated recovery sentinel").unwrap();
    let mut second_doc = Document::open(&second).unwrap();
    second_doc.insert(0, "// local\n").unwrap();
    assert_eq!(std::fs::read(&recovery_sentinel).unwrap(), b"unrelated recovery sentinel");

    let external_recovery = root.join("third.rs.codestrike-recovery");
    let third = root.join("third.rs");
    std::fs::write(&third, "let y = 2;\n").unwrap();
    std::fs::write(&external_recovery, b"preserve pre-existing recovery").unwrap();
    let mut third_doc = Document::open(&third).unwrap();
    assert!(third_doc.insert(0, "// refused\n").is_err());
    assert_eq!(std::fs::read(&external_recovery).unwrap(), b"preserve pre-existing recovery");
    assert_eq!(third_doc.text(), "let y = 2;\n");
}

#[test]
fn lone_cr_nul_and_split_crlf_edits_leave_source_editable() {
    let root = unique_root("line-endings");
    std::fs::create_dir_all(&root).unwrap();
    let lf_file = root.join("lf.rs");
    std::fs::write(&lf_file, "one\ntwo\n").unwrap();
    let mut lf = Document::open(&lf_file).unwrap();
    assert!(lf.insert(1, "X\rY").is_err());
    assert!(lf.replace(0, 1, "\r").is_err());
    assert!(lf.insert(0, "\0").is_err());
    assert_eq!(lf.text(), "one\ntwo\n");
    assert!(!lf.recovery_path().exists());
    lf.save().unwrap();
    assert!(Document::open(&lf_file).unwrap().editable());

    let crlf_file = root.join("crlf.rs");
    std::fs::write(&crlf_file, "one\r\ntwo\r\n").unwrap();
    let mut crlf = Document::open(&crlf_file).unwrap();
    assert!(crlf.insert(1, "X\rY").is_err());
    assert!(crlf.replace(3, 4, "").is_err());
    assert_eq!(crlf.text(), "one\r\ntwo\r\n");
    assert!(!crlf.recovery_path().exists());
    crlf.insert(0, "good\n").unwrap();
    crlf.save().unwrap();
    assert_eq!(std::fs::read_to_string(&crlf_file).unwrap(), "good\r\none\r\ntwo\r\n");
    assert!(Document::open(&crlf_file).unwrap().editable());
}

#[test]
fn oversized_edit_is_rejected_before_recovery_write() {
    let root = unique_root("oversized-edit");
    std::fs::create_dir_all(&root).unwrap();
    let file = root.join("main.rs");
    std::fs::write(&file, "x\n").unwrap();
    let mut doc = Document::open(&file).unwrap();
    let huge = "x".repeat(20 * 1024 * 1024 + 1);
    assert!(doc.insert(0, &huge).is_err());
    assert_eq!(doc.text(), "x\n");
    assert!(!doc.recovery_path().exists());
    assert_eq!(std::fs::read_to_string(&file).unwrap(), "x\n");
}

#[test]
fn search_uses_bom_hidden_editor_columns_and_snippets() {
    let root = unique_root("bom-search");
    std::fs::create_dir_all(&root).unwrap();
    let file = root.join("main.rs");
    std::fs::write(&file, b"\xef\xbb\xbfcafe\n").unwrap();
    let mut doc = Document::open(&file).unwrap();
    assert_eq!(doc.text(), "cafe\n");
    let hits = search_workspace(&root, &SearchQuery { pattern: "cafe".into(), regex: false }).unwrap();
    assert_eq!(hits.len(), 1);
    assert_eq!((hits[0].line, hits[0].column), (1, 1));
    assert_eq!(hits[0].snippet, "cafe");
    doc.insert(4, "!").unwrap();
    doc.save().unwrap();
    assert_eq!(std::fs::read(&file).unwrap(), b"\xef\xbb\xbfcafe!\n");
    assert!(Document::open(&file).unwrap().editable());
}

#[cfg(windows)]
#[test]
fn cancelling_real_cargo_also_stops_its_build_script_child() {
    use std::sync::atomic::Ordering;
    use std::time::Instant;
    let nonce = std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).unwrap().as_nanos();
    let root = std::env::temp_dir().join(format!("codestrike-real-tree-{}-{nonce}", std::process::id()));
    std::fs::create_dir_all(root.join("src")).unwrap();
    std::fs::write(root.join("Cargo.toml"), "[package]\nname='real_tree_fixture'\nversion='0.1.0'\nedition='2024'\n").unwrap();
    std::fs::write(root.join("src/lib.rs"), "pub fn fixture() {}\n").unwrap();
    std::fs::write(root.join("build.rs"), r#"
use std::fs;
use std::process::{Command, Stdio};
use std::time::Duration;
fn main() {
    if std::env::args().any(|arg| arg == "--grandchild") {
        std::thread::sleep(Duration::from_secs(2));
        fs::write("real-grandchild-survived.txt", b"child was not stopped").unwrap();
        return;
    }
    Command::new(std::env::current_exe().unwrap()).arg("--grandchild")
        .stdout(Stdio::inherit()).stderr(Stdio::inherit()).spawn().unwrap();
    fs::write("real-child-ready.txt", b"ready").unwrap();
    loop { std::thread::sleep(Duration::from_secs(1)); }
}
"#).unwrap();
    let cancel = AtomicBool::new(false);
    std::thread::scope(|scope| {
        let worker = scope.spawn(|| run_cargo_with_control(&root, CargoAction::Check, &cancel, Duration::from_secs(25)));
        let ready = root.join("real-child-ready.txt");
        let started = Instant::now();
        while !ready.exists() && started.elapsed() < Duration::from_secs(18) {
            std::thread::sleep(Duration::from_millis(20));
        }
        cancel.store(true, Ordering::Release);
        let result = worker.join().unwrap();
        assert!(ready.exists(), "real Cargo child did not start: {result:?}");
        assert!(result.unwrap_err().to_string().contains("cancelled"));
    });
    std::thread::sleep(Duration::from_millis(2300));
    assert!(!root.join("real-grandchild-survived.txt").exists());
}
