# Folio Desk

A local PDF workspace for macOS. Compare question papers and answers, keep references beside your reading, and organize related PDFs into tabs.

![Two PDFs in a Folio Desk workspace](docs/workspace.png)

## Download

[Download the latest Mac app](https://github.com/justinechang39/folio-desk/releases/latest).

1. Download **Folio-Desk-macOS-arm64.zip** (Apple silicon, macOS 13.3 or newer).
2. Unzip it and move **Folio Desk.app** into **Applications**.
3. Open the app and choose **Add PDFs**, or drop PDFs onto a pane.

The first release is ad-hoc signed, not Apple-notarized. macOS may require **System Settings → Privacy & Security → Open Anyway** after the first launch attempt. Intel builds can be built from source on an Intel Mac; the published binary is Apple silicon only. Automatic updates are not included in this first release.

## Workspaces

- Each tab holds a separate group of PDFs. Double-click a tab, or use the pencil in the document list, to rename it.
- Choose one pane, side by side, stacked, three columns, or a 2 × 2 grid.
- Drag a document’s grip or its entry in the document list onto a pane to show it there. If both panes are occupied, their documents swap.
- Drop a document onto another workspace tab to move it there. The **•••** menu also lets you move it to an existing or new workspace, assign a pane, or remove it from the workspace.
- Shrinking a layout keeps extra documents in the list. Click one to show it in the active pane.
- Use **Focus this pane** to expand one PDF temporarily; press Escape to return.
- Page, zoom, fit, and rotation belong to the document and follow it when it moves.
- **Link pages** navigates visible PDFs to the same page number. Shorter documents stop at their final page. It does not synchronize scrolling or infer matching content.
- Search finds pages containing selectable text. It does not perform OCR, highlight individual matches, or search text embedded only in scans.
- Encrypted PDFs prompt for a password. Passwords are kept in memory only and must be entered again after a workspace is reopened.

The app is a viewer: it does not edit, annotate, merge, convert, or print files. It displays one page at a time per pane, with selectable text, fit-to-page, fit-to-width, 25–400% manual zoom, rotation, and page navigation. Hyperlink and interactive form widgets are not active. PDF JavaScript is not executed.

## Keyboard shortcuts

| Shortcut | Action |
| --- | --- |
| ⌘O | Add PDFs |
| ⌘T | New workspace |
| ⌘W | Close workspace (asks before closing a populated workspace) |
| ⌘1–9 | Switch workspace |
| ← / → or Page Up / Page Down | Previous / next page in the active pane |
| ⌘+ / ⌘− | Zoom active PDF |
| ⌘0 | Fit active PDF to pane |
| Escape | Restore split layout |

## Local storage and privacy

Rust handles native dialogs, PDF validation and reading, and atomic session saves. Tauri uses macOS’s system WebKit; React provides the interface, and the bundled Mozilla PDF.js renderer draws PDFs in a worker. No Node runtime, external PDF app, cloud service, telemetry, or online fonts are needed at runtime.

Only PDF files are accepted (extension and PDF header checked in Rust), up to **256 MB per file**. Every file is read-only. Originals are never modified. A PDF must first be imported before the renderer can read it through the native bridge.

Workspace metadata—including local paths, names, layout, page, zoom, and rotation—is saved to:

```text
~/Library/Application Support/io.github.justinechang39.foliodesk/session.json
```

The preceding save is retained as `session.previous.json`. Starting fresh after a restore error also retains a separate timestamped recovery copy. PDFs themselves are not copied into this folder. Moving, deleting, or disconnecting a source file can prevent it from reopening; add it from its new location and remove the old entry. Closing the app saves the workspace before the window exits.

## Build locally

Requirements: macOS, Xcode Command Line Tools (`xcode-select --install`), Rust stable (tested with 1.98.0), and Node.js 22.13+ (tested with 22.15.0). The initial dependency install needs internet access; reading PDFs does not.

```sh
git clone https://github.com/justinechang39/folio-desk.git
cd folio-desk
npm ci
npm run tauri -- dev
```

Build the app for the current machine:

```sh
./scripts/package.sh
```

Output:

```text
src-tauri/target/release/bundle/macos/Folio Desk.app
```

Quit an existing Folio Desk before replacing its application bundle, then copy the built `.app` into `/Applications`. Workspace settings live separately and are preserved.

`npm run dev` also offers a browser-only UI preview. This preview uses a file input and local storage; unlike the desktop app, it cannot reopen file contents after a reload. Use `tauri dev` for native behavior.

## Tests

```sh
npm test
cargo test --manifest-path src-tauri/Cargo.toml
npx playwright install chromium webkit
npm run test:e2e
npm audit
```

Tests use synthetic PDFs, never personal documents or printers. They cover layout preservation, swaps and transfers, linked pagination, persistence validation, file validation, atomic save backups, rendering, search, zoom, encrypted PDFs, and drag-and-drop in WebKit and Chromium. Fixtures are checked in; `scripts/test-fixtures.py` recreates the unencrypted fixtures. The encrypted fixture uses the test password `test-password`.

For a packaged native WebKit/IPC smoke test:

```sh
python3 scripts/test-native.py
```

This builds a test-only feature and uses a separate application identifier and data folder. It verifies PDF pixels, text, native file reads, saved page state, and rejection of non-PDF reads. The smoke-test hook is absent from normal release builds.

## Releases

Builds run locally. GitHub Actions is disabled and no workflows are included. `scripts/package.sh` builds, verifies the local signature, and creates a ZIP and SHA256 checksum under `dist-release/`. Upload those artifacts to a GitHub Release after testing.

## License

MIT for Folio Desk. See [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md) for bundled third-party software, including PDF.js under Apache-2.0. Lockfiles pin the tested dependency versions.
