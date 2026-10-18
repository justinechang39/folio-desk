Folio Desk now uses native macOS PDFKit exclusively. Pinch zoom, continuous scrolling, text selection, and search run directly in native PDF views; the browser renderer and the separate Native Preview app are retired.

Workspace tabs, five layouts, document drag-and-drop and move menus, independent zoom/scroll, linked page navigation, rotation, theme/mode selection, and session restoration are included. Existing sessions migrate automatically, retaining the original session as `session.before-native.json`.

Built and tested locally on Apple silicon. Rust storage/validation checks, native migration and relaunch tests, all layouts and document moves, and 1,800-step zoom/scroll workloads passed. macOS 13.3+; the downloadable app is ad-hoc signed and not Apple notarized. GitHub Actions remains disabled.

Quit Folio Desk, replace the app in Applications, and reopen it. The standalone Folio Native Preview can be removed; it has no saved workspaces.
