use folio_desk::Store;
use serde_json::{json, Value};
use std::{
    ffi::{c_char, CStr, CString},
    path::PathBuf,
    sync::{Mutex, OnceLock},
};
static STORE: OnceLock<Mutex<Store>> = OnceLock::new();
extern "C" fn request(input: *const c_char) -> *mut c_char {
    let result = std::panic::catch_unwind(|| -> Result<Value, String> {
        if input.is_null() {
            return Err("Missing request".into());
        }
        let bytes = unsafe { CStr::from_ptr(input) }.to_bytes();
        let value = serde_json::from_slice(bytes).map_err(|e| e.to_string())?;
        STORE
            .get()
            .unwrap()
            .lock()
            .map_err(|_| "Session store unavailable")?
            .request(value)
    });
    let value = match result {
        Ok(Ok(value)) => json!({"value":value}),
        Ok(Err(error)) => json!({"error":error}),
        Err(_) => json!({"error":"Native storage failed"}),
    };
    CString::new(value.to_string()).unwrap().into_raw()
}
extern "C" fn release(value: *mut c_char) {
    if !value.is_null() {
        unsafe {
            drop(CString::from_raw(value));
        }
    }
}
unsafe extern "C" {
    fn folio_native_run(
        arguments: *const c_char,
        request: extern "C" fn(*const c_char) -> *mut c_char,
        release: extern "C" fn(*mut c_char),
    ) -> i32;
}
fn main() {
    let args: Vec<_> = std::env::args().skip(1).collect();
    let testing = args
        .iter()
        .any(|a| a == "--benchmark" || a == "--self-test");
    let dir = if testing {
        PathBuf::from(
            std::env::var("FOLIO_TEST_SESSION_DIR")
                .expect("Tests require an isolated FOLIO_TEST_SESSION_DIR"),
        )
    } else {
        PathBuf::from(std::env::var_os("HOME").expect("Missing home directory"))
            .join("Library/Application Support/io.github.justinechang39.foliodesk")
    };
    STORE.set(Mutex::new(Store::new(dir))).ok().unwrap();
    let mut bytes = Vec::new();
    for a in &args {
        bytes.extend_from_slice(a.as_bytes());
        bytes.push(0);
    }
    bytes.push(0);
    let result = unsafe { folio_native_run(bytes.as_ptr().cast(), request, release) };
    std::process::exit(result);
}
