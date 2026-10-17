# Folio Desk 0.1.0

The first release of Folio Desk: a local PDF workspace for macOS, built with Rust/Tauri and Mozilla PDF.js.

- Workspace tabs with automatic session restore.
- Single, side-by-side, stacked, three-column, and 2 × 2 layouts.
- Drag PDFs between panes and workspace tabs, or use the document options menu.
- Per-document page, zoom, fit, and rotation; optional linked page turns.
- Text selection, page-based text search, and password-protected PDFs.
- Native file picker, Finder Open With support, and PDF drag-and-drop.

Download **Folio-Desk-macOS-arm64.zip**, unzip it, and move **Folio Desk.app** into Applications. Requires an Apple silicon Mac and macOS 13.3 or newer. The app is ad-hoc signed, not Apple-notarized; macOS may require Privacy & Security → Open Anyway on first launch.

This release is a viewer. It does not edit or print PDFs, perform OCR, or install automatic updates. PDFs stay local and original files are never modified.

Validation: 8 workspace-model tests, 3 Rust tests, 12 WebKit/Chromium scenarios, and two native WebKit/IPC runs covering rendering, file validation, saving, and restoring. Dependency audit clean. Built locally; GitHub Actions disabled.
