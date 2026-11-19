use crate::provider::Skill;
use crate::settings::write_json_atomic;
use chrono::{DateTime, Utc};
use serde::{Deserialize, Serialize};
use std::fs;
use std::path::PathBuf;
use uuid::Uuid;

pub const MAXIMUM_ENTRIES: usize = 200;
const MAXIMUM_ENTRY_BYTES: usize = 512 * 1024;
const MAXIMUM_FILE_BYTES: usize = 16 * 1024 * 1024;

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct HistoryEntry {
    pub id: String,
    pub skill: Skill,
    pub created_at: DateTime<Utc>,
    pub model: String,
    pub source_text: String,
    pub source_preview: String,
    pub result_text: String,
}

impl HistoryEntry {
    pub fn new(skill: Skill, model: String, source_text: String, result_text: String) -> Self {
        let source_preview = build_preview(&source_text);
        Self {
            id: Uuid::new_v4().to_string(),
            skill,
            created_at: Utc::now(),
            model,
            source_text,
            source_preview,
            result_text,
        }
    }
}

pub fn build_preview(source: &str) -> String {
    let single_line = source
        .lines()
        .map(str::trim)
        .filter(|line| !line.is_empty())
        .collect::<Vec<_>>()
        .join(" ");
    let mut chars = single_line.chars();
    let head: String = chars.by_ref().take(100).collect();
    if chars.next().is_some() {
        format!("{head}…")
    } else {
        head
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum HistoryError {
    EntryTooLarge,
    StorageFailure,
}

impl std::fmt::Display for HistoryError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::EntryTooLarge => write!(
                f,
                "Kết quả quá lớn để lưu vào lịch sử. Bạn vẫn có thể xem và sao chép kết quả hiện tại."
            ),
            Self::StorageFailure => write!(
                f,
                "Không thể lưu lịch sử trên máy. Các chức năng dịch hiện tại vẫn dùng được."
            ),
        }
    }
}

#[derive(Debug, Clone, Serialize)]
pub struct HistoryListResponse {
    pub entries: Vec<HistoryEntry>,
    pub has_read_error: bool,
}

pub struct HistoryStore {
    file_path: PathBuf,
    entries: Vec<HistoryEntry>,
    has_read_error: bool,
}

impl HistoryStore {
    pub fn new(directory: PathBuf) -> Self {
        let file_path = directory.join("history.json");
        let mut store = Self {
            file_path,
            entries: Vec::new(),
            has_read_error: false,
        };
        store.load();
        store
    }

    fn load(&mut self) {
        if !self.file_path.exists() {
            return;
        }
        let loaded = fs::metadata(&self.file_path)
            .ok()
            .filter(|meta| meta.len() as usize <= MAXIMUM_FILE_BYTES)
            .and_then(|_| fs::read(&self.file_path).ok())
            .and_then(|bytes| serde_json::from_slice::<Vec<HistoryEntry>>(&bytes).ok())
            .filter(|items| items.len() <= MAXIMUM_ENTRIES);

        match loaded {
            Some(items) => {
                self.entries = items;
                self.has_read_error = false;
            }
            None => {
                self.entries.clear();
                self.has_read_error = true;
            }
        }
    }

    pub fn list(&self) -> HistoryListResponse {
        HistoryListResponse {
            entries: self.entries.clone(),
            has_read_error: self.has_read_error,
        }
    }

    pub fn add(&mut self, entry: HistoryEntry) -> Result<(), HistoryError> {
        let entry_bytes = serde_json::to_vec(&entry).map_err(|_| HistoryError::StorageFailure)?;
        if entry_bytes.len() > MAXIMUM_ENTRY_BYTES {
            return Err(HistoryError::EntryTooLarge);
        }

        let mut updated = Vec::with_capacity((self.entries.len() + 1).min(MAXIMUM_ENTRIES));
        updated.push(entry.clone());
        for existing in &self.entries {
            if existing.id != entry.id && updated.len() < MAXIMUM_ENTRIES {
                updated.push(existing.clone());
            }
        }

        loop {
            let encoded = serde_json::to_vec(&updated).map_err(|_| HistoryError::StorageFailure)?;
            if encoded.len() <= MAXIMUM_FILE_BYTES {
                write_json_atomic(&self.file_path, &updated)
                    .map_err(|_| HistoryError::StorageFailure)?;
                self.entries = updated;
                self.has_read_error = false;
                return Ok(());
            }
            if updated.len() <= 1 {
                return Err(HistoryError::EntryTooLarge);
            }
            updated.pop();
        }
    }

    pub fn remove(&mut self, id: &str) -> Result<(), HistoryError> {
        let updated: Vec<HistoryEntry> = self
            .entries
            .iter()
            .filter(|item| item.id != id)
            .cloned()
            .collect();
        write_json_atomic(&self.file_path, &updated).map_err(|_| HistoryError::StorageFailure)?;
        self.entries = updated;
        self.has_read_error = false;
        Ok(())
    }

    pub fn remove_all(&mut self) -> Result<(), HistoryError> {
        let empty: Vec<HistoryEntry> = Vec::new();
        write_json_atomic(&self.file_path, &empty).map_err(|_| HistoryError::StorageFailure)?;
        self.entries.clear();
        self.has_read_error = false;
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn persists_newest_first_bounds_200_and_isolates_corrupt_files() {
        let dir = std::env::temp_dir().join(format!("dola-history-test-{}", Uuid::new_v4()));
        let mut store = HistoryStore::new(dir.clone());
        for i in 0..=MAXIMUM_ENTRIES {
            store
                .add(HistoryEntry::new(
                    Skill::Translate,
                    "fixture-model".to_owned(),
                    format!("source-{i}"),
                    format!("result-{i}"),
                ))
                .unwrap();
        }
        assert_eq!(store.list().entries.len(), MAXIMUM_ENTRIES);
        assert_eq!(store.list().entries[0].source_text, format!("source-{MAXIMUM_ENTRIES}"));

        let reloaded = HistoryStore::new(dir.clone());
        assert_eq!(reloaded.list().entries.len(), MAXIMUM_ENTRIES);
        assert!(!reloaded.list().has_read_error);

        fs::write(dir.join("history.json"), b"not-json").unwrap();
        let corrupt = HistoryStore::new(dir.clone());
        assert!(corrupt.list().entries.is_empty());
        assert!(corrupt.list().has_read_error);
        let _ = fs::remove_dir_all(&dir);
    }

    #[test]
    fn rejects_oversized_entry_without_touching_existing_entries() {
        let dir = std::env::temp_dir().join(format!("dola-history-big-{}", Uuid::new_v4()));
        let mut store = HistoryStore::new(dir.clone());
        let first = HistoryEntry::new(
            Skill::Explain,
            "m".to_owned(),
            "hello".to_owned(),
            "xin chào".to_owned(),
        );
        store.add(first.clone()).unwrap();
        let huge = HistoryEntry::new(
            Skill::Explain,
            "m".to_owned(),
            "hello".to_owned(),
            "x".repeat(600_000),
        );
        assert_eq!(store.add(huge), Err(HistoryError::EntryTooLarge));
        assert_eq!(store.list().entries, vec![first]);
        let _ = fs::remove_dir_all(&dir);
    }
}
