//! Read-only review gate for a proposed app-server file change. The host must
//! show these changes before sending an approval response.

use serde_json::Value;
use sha2::{Digest, Sha256};
use std::fs;
use std::path::{Path, PathBuf};

const MAX_FILES: usize = 8;
const MAX_FILE_BYTES: u64 = 4 * 1024 * 1024;
const MAX_DIFF_BYTES: usize = 256 * 1024;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ReviewError {
    InvalidItem,
    UnsupportedChange,
    OutsideWorkspace,
    FileTooLarge,
    Io,
    WrongItem,
    StaleFile,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ReviewedChange {
    pub path: PathBuf,
    pub diff: String,
    requested: PathBuf,
    fingerprint: [u8; 32],
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ReviewedFileChange {
    item_id: String,
    changes: Vec<ReviewedChange>,
}

impl ReviewedFileChange {
    pub fn capture(workspace: &Path, item: &Value) -> Result<Self, ReviewError> {
        let root = fs::canonicalize(workspace).map_err(|_| ReviewError::Io)?;
        if !root.is_dir()
            || item.get("type").and_then(Value::as_str) != Some("fileChange")
            || item.get("status").and_then(Value::as_str) != Some("inProgress")
        {
            return Err(ReviewError::InvalidItem);
        }
        let item_id = item
            .get("id")
            .and_then(Value::as_str)
            .filter(|id| !id.is_empty())
            .ok_or(ReviewError::InvalidItem)?
            .to_owned();
        let proposed = item
            .get("changes")
            .and_then(Value::as_array)
            .filter(|changes| !changes.is_empty() && changes.len() <= MAX_FILES)
            .ok_or(ReviewError::InvalidItem)?;
        let mut changes = Vec::with_capacity(proposed.len());
        let mut total_diff_bytes = 0usize;
        for change in proposed {
            if change.get("kind").and_then(Value::as_str) != Some("update") {
                return Err(ReviewError::UnsupportedChange);
            }
            let path = change
                .get("path")
                .and_then(Value::as_str)
                .filter(|path| !path.is_empty())
                .ok_or(ReviewError::InvalidItem)?;
            let requested = PathBuf::from(path);
            let requested = if requested.is_absolute() {
                requested
            } else {
                root.join(requested)
            };
            let path = fs::canonicalize(&requested).map_err(|_| ReviewError::Io)?;
            if !path.starts_with(&root) || path == root {
                return Err(ReviewError::OutsideWorkspace);
            }
            if fs::symlink_metadata(&requested)
                .map_err(|_| ReviewError::Io)?
                .file_type()
                .is_symlink()
            {
                return Err(ReviewError::UnsupportedChange);
            }
            let metadata = fs::metadata(&path).map_err(|_| ReviewError::Io)?;
            if !metadata.is_file() {
                return Err(ReviewError::UnsupportedChange);
            }
            if metadata.len() > MAX_FILE_BYTES {
                return Err(ReviewError::FileTooLarge);
            }
            let diff = change
                .get("diff")
                .and_then(Value::as_str)
                .ok_or(ReviewError::InvalidItem)?;
            total_diff_bytes = total_diff_bytes.saturating_add(diff.len());
            if total_diff_bytes > MAX_DIFF_BYTES {
                return Err(ReviewError::FileTooLarge);
            }
            let bytes = fs::read(&path).map_err(|_| ReviewError::Io)?;
            if bytes.len() as u64 > MAX_FILE_BYTES {
                return Err(ReviewError::FileTooLarge);
            }
            changes.push(ReviewedChange {
                path,
                diff: diff.to_owned(),
                requested,
                fingerprint: Sha256::digest(bytes).into(),
            });
        }
        Ok(Self { item_id, changes })
    }

    pub fn item_id(&self) -> &str {
        &self.item_id
    }

    pub fn changes(&self) -> &[ReviewedChange] {
        &self.changes
    }

    pub fn validate_approval(&self, params: &Value) -> Result<(), ReviewError> {
        if params.get("itemId").and_then(Value::as_str) != Some(self.item_id.as_str()) {
            return Err(ReviewError::WrongItem);
        }
        for change in &self.changes {
            if fs::canonicalize(&change.requested).ok().as_ref() != Some(&change.path) {
                return Err(ReviewError::StaleFile);
            }
            let bytes = fs::read(&change.path).map_err(|_| ReviewError::StaleFile)?;
            if bytes.len() as u64 > MAX_FILE_BYTES
                || Sha256::digest(bytes).as_slice() != change.fingerprint
            {
                return Err(ReviewError::StaleFile);
            }
        }
        Ok(())
    }
}
