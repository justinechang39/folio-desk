use serde_json::{json, Value};
use std::{
    fs::{self, File},
    io::{Read, Write},
    path::{Path, PathBuf},
};
pub const MAX_PDF: u64 = 256 * 1024 * 1024;
const MAX_SESSION: usize = 4 * 1024 * 1024;

pub fn validate_pdf(path: &Path) -> Result<PathBuf, String> {
    if !path
        .extension()
        .is_some_and(|e| e.eq_ignore_ascii_case("pdf"))
    {
        return Err("Only PDF files can be opened.".into());
    }
    let path = path.canonicalize().map_err(|_| {
        "File is missing or cannot be accessed. Download it locally or add it again."
    })?;
    let mut file = File::open(&path).map_err(|e| e.to_string())?;
    let meta = file.metadata().map_err(|e| e.to_string())?;
    if !meta.is_file() {
        return Err("Choose a file, not a folder.".into());
    }
    if meta.len() > MAX_PDF {
        return Err("This PDF exceeds the 256 MB limit.".into());
    }
    let mut header = [0u8; 1024];
    let count = file.read(&mut header).map_err(|e| e.to_string())?;
    if !header[..count].windows(5).any(|w| w == b"%PDF-") {
        return Err("This file does not contain a PDF header.".into());
    }
    Ok(path)
}

pub struct Store {
    dir: PathBuf,
}
impl Store {
    pub fn new(dir: PathBuf) -> Self {
        Self { dir }
    }
    fn path(&self) -> PathBuf {
        self.dir.join("session.json")
    }
    pub fn load(&self) -> Result<Value, String> {
        let path = self.path();
        if !path.exists() {
            return Ok(Value::Null);
        }
        let mut bytes = vec![];
        File::open(path)
            .map_err(|e| e.to_string())?
            .take((MAX_SESSION + 1) as u64)
            .read_to_end(&mut bytes)
            .map_err(|e| e.to_string())?;
        if bytes.len() > MAX_SESSION {
            return Err(
                "Saved workspace exceeds the storage limit. The original is preserved.".into(),
            );
        }
        serde_json::from_slice(&bytes)
            .map_err(|_| "Saved workspace is unreadable. The original is preserved.".into())
    }
    pub fn save(&self, value: &Value) -> Result<(), String> {
        if value["version"] != 1
            || !value["views"].is_array()
            || value["views"].as_array().unwrap().is_empty()
        {
            return Err("Unsupported workspace format.".into());
        }
        let bytes = serde_json::to_vec(value).map_err(|e| e.to_string())?;
        if bytes.len() > MAX_SESSION {
            return Err("Workspace has reached the storage limit.".into());
        }
        fs::create_dir_all(&self.dir).map_err(|e| e.to_string())?;
        let path = self.path();
        if path.exists() {
            let migration = self.dir.join("session.before-native.json");
            if !migration.exists() {
                fs::copy(&path, migration).map_err(|e| e.to_string())?;
            }
            fs::copy(&path, self.dir.join("session.previous.json")).map_err(|e| e.to_string())?;
        }
        let temp = self.dir.join("session.tmp");
        let mut file = File::create(&temp).map_err(|e| e.to_string())?;
        file.write_all(&bytes)
            .and_then(|_| file.sync_all())
            .map_err(|e| e.to_string())?;
        fs::rename(&temp, &path).map_err(|e| e.to_string())?;
        File::open(&self.dir)
            .and_then(|dir| dir.sync_all())
            .map_err(|e| e.to_string())
    }
    pub fn request(&self, input: Value) -> Result<Value, String> {
        match input["op"].as_str() {
            Some("load") => self.load(),
            Some("save") => {
                self.save(&input["session"])?;
                Ok(Value::Null)
            }
            Some("archive") => {
                if self.path().exists() {
                    let stamp = std::time::SystemTime::now()
                        .duration_since(std::time::UNIX_EPOCH)
                        .map_err(|e| e.to_string())?
                        .as_nanos();
                    fs::copy(
                        self.path(),
                        self.dir.join(format!("session.recovery-{stamp}.json")),
                    )
                    .map_err(|e| e.to_string())?;
                }
                Ok(Value::Null)
            }
            Some("validate") => {
                let path = input["path"].as_str().ok_or("Missing PDF path")?;
                Ok(json!(validate_pdf(Path::new(path))?.to_string_lossy()))
            }
            _ => Err("Unknown native operation".into()),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn save_preserves_migration_and_previous() {
        let tmp = tempfile::tempdir().unwrap();
        let store = Store::new(tmp.path().into());
        let first = json!({"version":1,"views":[{"name":"original"}]});
        let second = json!({"version":1,"views":[{"name":"changed"}]});
        store.save(&first).unwrap();
        store.save(&second).unwrap();
        store.save(&second).unwrap();
        assert_eq!(store.load().unwrap(), second);
        assert_eq!(
            serde_json::from_slice::<Value>(
                &fs::read(tmp.path().join("session.before-native.json")).unwrap()
            )
            .unwrap(),
            first
        );
        assert_eq!(
            serde_json::from_slice::<Value>(
                &fs::read(tmp.path().join("session.previous.json")).unwrap()
            )
            .unwrap(),
            second
        );
    }
    #[test]
    fn corrupt_load_does_not_write_and_invalid_save_is_rejected() {
        let tmp = tempfile::tempdir().unwrap();
        let store = Store::new(tmp.path().into());
        fs::write(store.path(), b"broken").unwrap();
        assert!(store.load().is_err());
        assert!(store.save(&json!({"version":2,"views":[]})).is_err());
        assert_eq!(fs::read(store.path()).unwrap(), b"broken");
    }
    #[test]
    fn pdf_validation_and_size_limit() {
        let tmp = tempfile::tempdir().unwrap();
        let pdf = tmp.path().join("file.PDF");
        fs::write(&pdf, b"%PDF-1.7\n").unwrap();
        assert!(validate_pdf(&pdf).is_ok());
        fs::write(&pdf, b"fake").unwrap();
        assert!(validate_pdf(&pdf).is_err());
        File::create(&pdf).unwrap().set_len(MAX_PDF + 1).unwrap();
        assert!(validate_pdf(&pdf).is_err());
        assert!(validate_pdf(&tmp.path().join("notes.txt")).is_err());
    }
}
