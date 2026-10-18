# Third-party notices

Folio Desk is MIT licensed. Its dependencies retain their own licenses.

- Rust JSON handling uses **serde_json**, **serde_core**, and their dependencies. Serde and serde_json are MIT OR Apache-2.0. https://github.com/serde-rs
- **AppKit**, **PDFKit**, and the Swift runtime are system components provided by macOS. They are linked from the operating system and are not copied into Folio's bundle.
- The icon and synthetic test PDFs were created for this project. No personal PDFs are included.

The generated [license collection](licenses/ThirdPartyLicenses.txt) includes the locked Rust dependency graph, including local test dependencies. It is included in the app. Regenerate it with `python3 scripts/collect-licenses.py` after changing dependencies.

Folio 0.3 no longer bundles Tauri, React, PDF.js, Lucide, or a browser-based renderer. Historical releases and their notices remain available in Git history.
