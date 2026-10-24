//! Source-checkout launcher. CodeStrike's only editor is the patched Lapce build.
use std::{
    env,
    ffi::OsString,
    path::PathBuf,
    process::{Command, ExitCode},
};

fn editor_path(override_path: Option<OsString>) -> PathBuf {
    override_path.map(PathBuf::from).unwrap_or_else(|| {
        PathBuf::from(env!("CARGO_MANIFEST_DIR"))
            .join("editor/lapce/target/debug")
            .join(if cfg!(windows) { "lapce.exe" } else { "lapce" })
    })
}

fn main() -> ExitCode {
    let editor = editor_path(env::var_os("CODESTRIKE_EDITOR"));
    // Never interpret arguments through a shell or fall back to the retired editor.
    match Command::new(&editor).args(env::args_os().skip(1)).status() {
        Ok(status) => ExitCode::from(status.code().unwrap_or(1).clamp(0, 255) as u8),
        Err(error) => {
            eprintln!(
                "Could not launch Lapce-based CodeStrike at {}: {error}\n\
                Prepare/build it with scripts/build-codestrike.ps1 (see README). \
                For a different build, set CODESTRIKE_EDITOR to its executable path.",
                editor.display()
            );
            ExitCode::FAILURE
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn default_routes_only_to_lapce() {
        let path = editor_path(None);
        assert!(path.to_string_lossy().contains("editor/lapce/target/debug"));
        assert_eq!(path.file_stem().unwrap(), "lapce");
    }
    #[test]
    fn explicit_path_preserves_spaces_without_shell_parsing() {
        assert_eq!(
            editor_path(Some(OsString::from("path with spaces/CodeStrike"))),
            PathBuf::from("path with spaces/CodeStrike")
        );
    }
}
