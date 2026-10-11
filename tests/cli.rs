use std::process::Command;

#[test]
fn command_line_edits_saves_and_finds_source() {
    let exe = env!("CARGO_BIN_EXE_codestrike");
    let root = std::env::temp_dir().join(format!("codestrike-cli-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&root);
    std::fs::create_dir_all(&root).unwrap();
    let file = root.join("main.rs");
    std::fs::write(&file, "fn main() {}\n").unwrap();
    let edit = Command::new(exe)
        .args(["insert", &file.display().to_string(), "0", "// café\n"])
        .output()
        .unwrap();
    assert!(
        edit.status.success(),
        "{}",
        String::from_utf8_lossy(&edit.stderr)
    );
    assert!(
        std::fs::read_to_string(&file)
            .unwrap()
            .starts_with("// café\n")
    );
    let search = Command::new(exe)
        .args(["find", &root.display().to_string(), "café"])
        .output()
        .unwrap();
    assert!(search.status.success());
    assert!(String::from_utf8_lossy(&search.stdout).contains(":1:4:"));
}
