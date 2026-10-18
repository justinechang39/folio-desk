fn main() {
    if std::env::var_os("CARGO_FEATURE_NATIVE_UI").is_some() {
        let dir = std::env::var("FOLIO_NATIVE_LIB_DIR")
            .expect("Use scripts/package.sh to build the native app");
        println!("cargo:rustc-link-search=native={dir}");
        println!("cargo:rustc-link-lib=dylib=FolioNative");
        println!("cargo:rustc-link-arg=-Wl,-rpath,@executable_path/../Frameworks");
        println!("cargo:rerun-if-env-changed=FOLIO_NATIVE_LIB_DIR");
    }
}
