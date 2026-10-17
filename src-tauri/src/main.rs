#![cfg_attr(not(debug_assertions), windows_subsystem = "windows")]
use serde::Serialize;
use std::{
    collections::HashSet,
    fs::{self, File},
    io::{Read, Write},
    path::{Path, PathBuf},
    sync::Mutex,
};
use tauri::{Emitter, Manager};

const MAX_PDF: u64 = 256 * 1024 * 1024;
const MAX_SESSION: usize = 4 * 1024 * 1024;
#[derive(Default)]
struct DeskState {
    allowed: Mutex<HashSet<PathBuf>>,
    pending: Mutex<Vec<String>>,
}
#[derive(Serialize, Clone)]
struct Document {
    path: String,
    name: String,
}
#[derive(Serialize)]
struct Imports {
    documents: Vec<Document>,
    errors: Vec<String>,
}

fn validate_pdf(path: &Path) -> Result<PathBuf, String> {
    if !path
        .extension()
        .is_some_and(|e| e.eq_ignore_ascii_case("pdf"))
    {
        return Err("Only PDF files can be opened.".into());
    }
    let path = path
        .canonicalize()
        .map_err(|_| "File is missing or cannot be accessed. Try adding it again.")?;
    let mut file = File::open(&path).map_err(|e| e.to_string())?;
    let metadata = file.metadata().map_err(|e| e.to_string())?;
    if !metadata.is_file() {
        return Err("Choose a PDF file, not a folder.".into());
    }
    if metadata.len() > MAX_PDF {
        return Err("This PDF exceeds the 256 MB limit.".into());
    }
    let mut header = [0u8; 1024];
    let len = file.read(&mut header).map_err(|e| e.to_string())?;
    if !header[..len].windows(5).any(|w| w == b"%PDF-") {
        return Err("This file does not contain a PDF header.".into());
    }
    Ok(path)
}
fn import_files(paths: Vec<String>, state: &DeskState) -> Imports {
    let mut result = Imports {
        documents: vec![],
        errors: vec![],
    };
    for source in paths {
        match validate_pdf(Path::new(&source)) {
            Ok(path) => {
                state.allowed.lock().unwrap().insert(path.clone());
                let document = Document {
                    name: path
                        .file_name()
                        .unwrap_or_default()
                        .to_string_lossy()
                        .into_owned(),
                    path: path.to_string_lossy().into_owned(),
                };
                if !result.documents.iter().any(|d| d.path == document.path) {
                    result.documents.push(document);
                }
            }
            Err(error) => result.errors.push(format!(
                "{}: {}",
                Path::new(&source)
                    .file_name()
                    .unwrap_or_default()
                    .to_string_lossy(),
                error
            )),
        }
    }
    result
}
#[tauri::command]
async fn pick_pdfs(app: tauri::AppHandle) -> Imports {
    let files = rfd::AsyncFileDialog::new()
        .add_filter("PDF documents", &["pdf"])
        .pick_files()
        .await
        .unwrap_or_default();
    import_files(
        files
            .iter()
            .map(|f| f.path().to_string_lossy().into_owned())
            .collect(),
        &app.state::<DeskState>(),
    )
}
#[tauri::command]
async fn import_paths(paths: Vec<String>, app: tauri::AppHandle) -> Result<Imports, String> {
    if paths.len() > 200 {
        return Err("Add up to 200 PDFs at a time.".into());
    }
    Ok(import_files(paths, &app.state::<DeskState>()))
}
#[tauri::command]
async fn read_pdf(path: String, app: tauri::AppHandle) -> Result<tauri::ipc::Response, String> {
    let canonical = validate_pdf(Path::new(&path))?;
    if !app
        .state::<DeskState>()
        .allowed
        .lock()
        .unwrap()
        .contains(&canonical)
    {
        return Err("Add this PDF to the workspace first.".into());
    }
    let mut file = File::open(canonical).map_err(|e| e.to_string())?;
    let mut bytes = Vec::new();
    (&mut file)
        .take(MAX_PDF + 1)
        .read_to_end(&mut bytes)
        .map_err(|e| e.to_string())?;
    if bytes.len() as u64 > MAX_PDF {
        return Err("This PDF exceeds the 256 MB limit.".into());
    }
    Ok(tauri::ipc::Response::new(bytes))
}
fn session_path(app: &tauri::AppHandle) -> Result<PathBuf, String> {
    let dir = app.path().app_data_dir().map_err(|e| e.to_string())?;
    fs::create_dir_all(&dir).map_err(|e| e.to_string())?;
    Ok(dir.join("session.json"))
}
#[tauri::command]
fn load_session(app: tauri::AppHandle) -> Result<Option<serde_json::Value>, String> {
    let path = session_path(&app)?;
    if !path.exists() {
        return Ok(None);
    }
    let bytes = fs::read(&path).map_err(|e| e.to_string())?;
    if bytes.len() > MAX_SESSION {
        return Err("Saved workspace is too large. The original session is preserved.".into());
    }
    let value: serde_json::Value = serde_json::from_slice(&bytes)
        .map_err(|_| "Saved workspace is unreadable. The original session is preserved.")?;
    if let Some(views) = value["views"].as_array() {
        for view in views {
            if let Some(docs) = view["documents"].as_array() {
                for doc in docs {
                    if let Some(path) = doc["path"].as_str() {
                        if let Ok(path) = validate_pdf(Path::new(path)) {
                            app.state::<DeskState>()
                                .allowed
                                .lock()
                                .unwrap()
                                .insert(path);
                        }
                    }
                }
            }
        }
    }
    Ok(Some(value))
}
fn atomic_save(path: &Path, data: &[u8]) -> Result<(), String> {
    if data.len() > MAX_SESSION {
        return Err("Workspace has reached the storage limit.".into());
    }
    let temp = path.with_extension("tmp");
    let mut file = File::create(&temp).map_err(|e| e.to_string())?;
    file.write_all(data)
        .and_then(|_| file.sync_all())
        .map_err(|e| e.to_string())?;
    if path.exists() {
        fs::copy(path, path.with_extension("previous.json")).map_err(|e| e.to_string())?;
    }
    fs::rename(temp, path).map_err(|e| e.to_string())
}
#[tauri::command]
fn save_session(session: serde_json::Value, app: tauri::AppHandle) -> Result<(), String> {
    if session["version"] != 1 || !session["views"].is_array() {
        return Err("Unsupported workspace format.".into());
    }
    atomic_save(
        &session_path(&app)?,
        &serde_json::to_vec(&session).map_err(|e| e.to_string())?,
    )
}
#[tauri::command]
fn archive_session(app: tauri::AppHandle) -> Result<(), String> {
    let path = session_path(&app)?;
    if path.exists() {
        let stamp = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .map_err(|e| e.to_string())?
            .as_nanos();
        fs::copy(&path, path.with_extension(format!("recovery-{stamp}.json")))
            .map_err(|e| e.to_string())?;
    }
    Ok(())
}
#[tauri::command]
fn take_pending(app: tauri::AppHandle) -> Vec<String> {
    std::mem::take(&mut *app.state::<DeskState>().pending.lock().unwrap())
}
#[cfg(feature = "native-smoke")]
#[tauri::command]
fn smoke_report(report: String, app: tauri::AppHandle) {
    if let Ok(path) = std::env::var("FOLIO_SMOKE_REPORT") {
        fs::write(path, report).expect("Could not write smoke test report");
    }
    app.exit(0);
}
fn main() {
    let builder = tauri::Builder::default()
        .manage(DeskState::default())
        .setup(|app| {
            #[cfg(feature = "native-smoke")]
            {
                assert!(app.config().identifier.ends_with(".smoketest"));
                if let Ok(paths) = std::env::var("FOLIO_SMOKE_FILES") {
                    *app.state::<DeskState>().pending.lock().unwrap() =
                        serde_json::from_str(&paths)?;
                }
            }
            use tauri::menu::{Menu, MenuItem, PredefinedMenuItem, Submenu};
            let handle = app.handle();
            let menu = Menu::with_items(
                handle,
                &[
                    &Submenu::with_items(
                        handle,
                        "Folio Desk",
                        true,
                        &[
                            &PredefinedMenuItem::about(handle, Some("About Folio Desk"), None)?,
                            &PredefinedMenuItem::separator(handle)?,
                            &PredefinedMenuItem::hide(handle, None)?,
                            &PredefinedMenuItem::hide_others(handle, None)?,
                            &PredefinedMenuItem::show_all(handle, None)?,
                            &PredefinedMenuItem::separator(handle)?,
                            &MenuItem::with_id(
                                handle,
                                "quit",
                                "Quit Folio Desk",
                                true,
                                Some("CmdOrCtrl+Q"),
                            )?,
                        ],
                    )?,
                    &Submenu::with_items(
                        handle,
                        "File",
                        true,
                        &[
                            &MenuItem::with_id(
                                handle,
                                "open",
                                "Add PDFs…",
                                true,
                                Some("CmdOrCtrl+O"),
                            )?,
                            &MenuItem::with_id(
                                handle,
                                "new-view",
                                "New Workspace",
                                true,
                                Some("CmdOrCtrl+T"),
                            )?,
                            &MenuItem::with_id(
                                handle,
                                "close-view",
                                "Close Workspace",
                                true,
                                Some("CmdOrCtrl+W"),
                            )?,
                        ],
                    )?,
                    &Submenu::with_items(
                        handle,
                        "Edit",
                        true,
                        &[
                            &PredefinedMenuItem::undo(handle, None)?,
                            &PredefinedMenuItem::redo(handle, None)?,
                            &PredefinedMenuItem::separator(handle)?,
                            &PredefinedMenuItem::cut(handle, None)?,
                            &PredefinedMenuItem::copy(handle, None)?,
                            &PredefinedMenuItem::paste(handle, None)?,
                            &PredefinedMenuItem::select_all(handle, None)?,
                        ],
                    )?,
                    &Submenu::with_items(
                        handle,
                        "Window",
                        true,
                        &[
                            &PredefinedMenuItem::minimize(handle, None)?,
                            &PredefinedMenuItem::maximize(handle, None)?,
                            &PredefinedMenuItem::fullscreen(handle, None)?,
                        ],
                    )?,
                ],
            )?;
            app.set_menu(menu)?;
            Ok(())
        })
        .on_menu_event(|app, event| {
            let _ = app.emit("menu-action", event.id().as_ref());
        });
    #[cfg(feature = "native-smoke")]
    let builder = builder
        .on_page_load(|webview, payload| {
            if payload.event() == tauri::webview::PageLoadEvent::Finished {
                let _ = webview.eval(include_str!("../../tests/native-smoke.js"));
            }
        })
        .invoke_handler(tauri::generate_handler![
            pick_pdfs,
            import_paths,
            read_pdf,
            load_session,
            save_session,
            take_pending,
            archive_session,
            smoke_report
        ]);
    #[cfg(not(feature = "native-smoke"))]
    let builder = builder.invoke_handler(tauri::generate_handler![
        pick_pdfs,
        import_paths,
        read_pdf,
        load_session,
        save_session,
        take_pending,
        archive_session
    ]);
    builder
        .build(tauri::generate_context!())
        .expect("Could not start Folio Desk")
        .run(|app, event| {
            #[cfg(target_os = "macos")]
            if let tauri::RunEvent::Opened { urls } = event {
                let paths = urls
                    .iter()
                    .filter_map(|u| u.to_file_path().ok())
                    .map(|p| p.to_string_lossy().into_owned())
                    .collect::<Vec<_>>();
                app.state::<DeskState>()
                    .pending
                    .lock()
                    .unwrap()
                    .extend(paths);
                let _ = app.emit("open-pdfs", ());
                if let Some(window) = app.get_webview_window("main") {
                    let _ = window.show();
                    let _ = window.set_focus();
                }
            }
        });
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn rejects_disguised_files_and_directories() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("fake.pdf");
        fs::write(&path, b"private text").unwrap();
        assert!(validate_pdf(&path).is_err());
        assert!(validate_pdf(dir.path()).is_err());
    }
    #[test]
    fn validates_header_and_deduplicates_imports() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("sample.PDF");
        fs::write(&path, b"%PDF-1.7\n").unwrap();
        let source = path.to_string_lossy().into_owned();
        let state = DeskState::default();
        let result = import_files(vec![source.clone(), source, "/missing.pdf".into()], &state);
        assert_eq!(result.documents.len(), 1);
        assert_eq!(result.errors.len(), 1);
        assert!(state
            .allowed
            .lock()
            .unwrap()
            .contains(&path.canonicalize().unwrap()));
    }
    #[test]
    fn saves_atomically_with_previous_copy() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("session.json");
        atomic_save(&path, b"first").unwrap();
        atomic_save(&path, b"second").unwrap();
        assert_eq!(fs::read(&path).unwrap(), b"second");
        assert_eq!(
            fs::read(path.with_extension("previous.json")).unwrap(),
            b"first"
        );
    }
}
