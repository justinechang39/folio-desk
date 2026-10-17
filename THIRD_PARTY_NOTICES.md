# Third-party notices

Folio Desk is MIT licensed. Its dependencies retain their own licenses.

- **Tauri**, the native Rust application framework: MIT OR Apache-2.0. Copyright Tauri Programme within The Commons Conservancy and contributors. https://github.com/tauri-apps/tauri
- **Mozilla PDF.js**, including its worker, standard fonts, CMaps, WASM decoders, and adapted text-layer styles: Apache-2.0, with additional notices in bundled asset directories. Copyright Mozilla Foundation and contributors. https://github.com/mozilla/pdf.js
- **React / React DOM**: MIT. Copyright Meta Platforms, Inc. and affiliates. https://github.com/facebook/react
- **Lucide**: ISC, with portions derived from Feather under MIT. https://github.com/lucide-icons/lucide
- **rfd**, native file dialogs: MIT. https://github.com/PolyMeilex/rfd
- **Serde / serde_json**: MIT OR Apache-2.0. https://github.com/serde-rs

The generated [third-party license collection](licenses/ThirdPartyLicenses.txt) contains license texts from the locked JavaScript production dependencies and Rust dependency graph. It is included in the app bundle. Rebuild it with `python3 scripts/collect-licenses.py` after dependency updates. Asset-specific notices are also retained with PDF.js font and decoder resources.

The app icon and test documents were created for this project. No personal documents are included.
