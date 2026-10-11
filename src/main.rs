use codestrike::{CargoAction, Document, SearchQuery, run_cargo, search_workspace};
use std::path::Path;

fn usage() -> &'static str {
    "CodeStrike commands:\n  status FILE\n  insert FILE CHAR_INDEX TEXT\n  replace FILE START_CHAR END_CHAR TEXT\n  recover FILE\n  find WORKSPACE LITERAL\n  regex WORKSPACE EXPRESSION\n  check|build|test CARGO_WORKSPACE\nEditing indices are Unicode scalar positions; search columns are one-based Unicode scalar positions."
}
fn arg<'a>(args: &'a [String], n: usize, name: &str) -> Result<&'a str, String> {
    args.get(n)
        .map(String::as_str)
        .ok_or_else(|| format!("missing {name}"))
}
fn index(args: &[String], n: usize, name: &str) -> Result<usize, String> {
    arg(args, n, name)?
        .parse()
        .map_err(|_| format!("invalid {name}"))
}
fn run(args: &[String]) -> Result<(), String> {
    let command = arg(args, 0, "command")?;
    let path = Path::new(arg(args, 1, "file or workspace")?);
    match command {
        "status" => {
            let document = Document::open(path).map_err(|e| e.to_string())?;
            if let Some(reason) = document.read_only_reason() {
                println!("read-only: {reason}");
            } else {
                println!("editable: {} characters", document.len_chars());
            }
            if document.recovery_path().exists() {
                println!("recovery candidate: {}", document.recovery_path().display());
            }
        }
        "insert" | "replace" => {
            let mut document = Document::open(path).map_err(|e| e.to_string())?;
            if command == "insert" {
                document
                    .insert(index(args, 2, "character index")?, arg(args, 3, "text")?)
                    .map_err(|e| e.to_string())?;
            } else {
                document
                    .replace(
                        index(args, 2, "start character")?,
                        index(args, 3, "end character")?,
                        arg(args, 4, "text")?,
                    )
                    .map_err(|e| e.to_string())?;
            }
            document.save().map_err(|e| e.to_string())?;
            println!("Saved {}", path.display());
        }
        "recover" => {
            let mut document = Document::open(path).map_err(|e| e.to_string())?;
            document.recover().map_err(|e| e.to_string())?;
            document.save().map_err(|e| e.to_string())?;
            println!("Recovered and saved {}", path.display());
        }
        "find" | "regex" => {
            let query = SearchQuery {
                pattern: arg(args, 2, "pattern")?.into(),
                regex: command == "regex",
            };
            for hit in search_workspace(path, &query).map_err(|e| e.to_string())? {
                println!(
                    "{}:{}:{}: {}",
                    hit.path.display(),
                    hit.line,
                    hit.column,
                    hit.snippet
                );
            }
        }
        "check" | "build" | "test" => {
            let action = match command {
                "check" => CargoAction::Check,
                "build" => CargoAction::Build,
                _ => CargoAction::Test,
            };
            eprintln!(
                "Running cargo {command} --offline --message-format=json in {}",
                path.display()
            );
            let report = run_cargo(path, action).map_err(|e| e.to_string())?;
            for item in &report.diagnostics {
                println!(
                    "{}: {}:{}:{}: {}",
                    item.level,
                    item.file
                        .as_ref()
                        .map(|p| p.display().to_string())
                        .unwrap_or_default(),
                    item.line.unwrap_or(0),
                    item.column.unwrap_or(0),
                    item.message
                );
            }
            if !report.success {
                eprintln!("Cargo failed. Raw output:\n{}", report.raw_output);
                return Err("Cargo command failed".into());
            }
            println!("Cargo {command} succeeded");
        }
        _ => return Err(usage().into()),
    }
    Ok(())
}
fn main() {
    if let Err(error) = run(&std::env::args().skip(1).collect::<Vec<_>>()) {
        eprintln!("{error}\n{}", usage());
        std::process::exit(2);
    }
}
