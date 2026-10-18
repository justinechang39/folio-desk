//! Small Rust entry point; AppKit/PDFKit own the native viewer and event loop.

unsafe extern "C" {
    fn folio_native_run(arguments: *const std::ffi::c_char) -> i32;
}

fn main() {
    // NUL-separated UTF-8 arguments, terminated by an extra NUL. macOS paths
    // cannot contain NUL. No shell, subprocess, webview, or PDF byte copying.
    let mut arguments = Vec::new();
    for argument in std::env::args().skip(1) {
        arguments.extend_from_slice(argument.as_bytes());
        arguments.push(0);
    }
    arguments.push(0);
    let result = unsafe { folio_native_run(arguments.as_ptr().cast()) };
    std::process::exit(result);
}
