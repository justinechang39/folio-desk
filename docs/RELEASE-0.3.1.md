# Folio Desk 0.3.1

Open the same PDF in multiple panes. Use **Open…** in each pane, drop the file onto another pane, or right-click the document and choose **Open in pane…**. Each reading view has its own page, scroll position, zoom, and rotation; those views survive a restart. Enable **Link pages** only when you want synchronized page navigation.

Moving a view between workspaces preserves it even when that workspace already contains the same PDF. Reopening a file in its current pane reuses that view. Existing drag-to-move and swap behavior remains available.

Built locally for Apple silicon, macOS 13.3 or later. Download the ZIP, unzip, and replace Folio Desk in Applications after quitting. Saved workspaces and preferences remain in place. GitHub Actions remains disabled.

Validated with Rust storage tests, native same-PDF independence and relaunch checks, layout and workspace-move regressions, and a 1,800-step zoom/scroll workload with the same PDF in both panes. No renderer changes.
