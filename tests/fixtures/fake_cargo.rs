use std::fs;
use std::process::{Command, Stdio};
use std::time::Duration;

fn main() {
    if std::env::args().any(|arg| arg == "--grandchild") {
        std::thread::sleep(Duration::from_secs(2));
        fs::write("fake-grandchild-survived.txt", b"child was not stopped").unwrap();
        return;
    }
    Command::new(std::env::current_exe().unwrap()).arg("--grandchild")
        .stdout(Stdio::inherit()).stderr(Stdio::inherit()).spawn().unwrap();
    fs::write("fake-child-ready.txt", b"ready").unwrap();
    loop { std::thread::sleep(Duration::from_secs(1)); }
}
