# Folio Native Preview

An isolated macOS PDFKit experiment for Folio Desk. The Rust executable calls a small Swift library that hosts two native `PDFView`s. PDF drawing, trackpad gestures, continuous scrolling, selection, and page navigation belong to PDFKit; there is no webview or custom canvas renderer in this experiment.

This is a performance trial, not a replacement release. Folio Desk's installed app, session, and templates are not modified. No workspace/session metadata is read or saved. The two PDFs are opened read-only and are never written back. All processing stays local. The app has its own bundle ID and does not register as a PDF handler, so it does not add another entry to Finder's Open With menu.

## Try it

Requires macOS 13.3+, Xcode Command Line Tools, and Rust. No downloaded dependencies are needed beyond those development tools.

```sh
./scripts/build-native-preview.sh
open 'dist-release/Folio Native Preview.app'
```

Use **Open…** in either pane, drop a PDF onto a pane, or select two PDFs in the open dialog. Drag the divider to resize the panes. Pinch and scroll independently over either document. Each pane has zoom, fit width, and fit page controls. **View → Swap PDFs** swaps the loaded documents. Encrypted PDFs prompt for a password, held only in memory.

The keyboard shortcuts are ⌘O to open, ⌘+/⌘− to zoom, ⌘0 to fit a page, and ⌘Q to quit. Zoom shortcuts affect the last clicked or pinched pane. The UI follows macOS light/dark appearance and uses orange controls.

To install separately:

```sh
ditto 'dist-release/Folio Native Preview.app' '/Applications/Folio Native Preview.app'
open '/Applications/Folio Native Preview.app'
```

To launch with two files (paths are separate, quoted arguments):

```sh
open 'dist-release/Folio Native Preview.app' --args '/absolute/path/first.pdf' '/absolute/path/second.pdf'
```

The prototype deliberately has no workspace tabs, saved themes, search UI, or session restoration. Those remain in Folio Desk. This keeps the experiment focused on whether PDFKit is a better foundation for document interaction. Integrating it with the existing shell would still require native view positioning, focus, overlays, document lifetime management, and restoring workspace state.

## Local checks

```sh
python3 scripts/test-native-preview.py
# Optional local documents (not uploaded, copied into fixtures, or committed):
python3 scripts/test-native-preview.py --skip-build --name personal-trial \
  --pdf '/absolute/path/first.pdf' --pdf '/absolute/path/second.pdf'
```

The script verifies rejection of invalid, non-PDF, and locked inputs in unattended mode, then checks independent zoom/navigation and performs 1,800 programmatic zoom-and-scroll steps across two panes. Each four-second cycle zooms in and back out, alternating panes. It samples process resident memory, control-update cost, window activation, and main-run-loop timer gaps. App Nap is suppressed only during the automated workload so background throttling does not distort the test; normal use keeps macOS’s default power behavior. It checks whole-page fitting, and captures only the test window at the end if screen capture permission is already granted (it does not request permission). Reports and snapshots go in ignored `work/` folders. The script opens a temporary visible window and exits when complete; it never drives other applications.

Timer gaps **are not display frame times**. Programmatic `scaleFactor` changes also do not exercise the physical trackpad gesture path. These checks can reveal stalls and resource growth but cannot establish that native pinching feels better. Compare both apps on the same documents, scrolling and pinching repeatedly for several minutes before deciding whether to migrate. There is no claimed speedup based on these checks alone.

Builds and checks run locally; no GitHub Actions workflow is added or enabled.
