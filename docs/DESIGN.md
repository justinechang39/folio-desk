# Native Folio Desk

PDFKit is the only rendering and interaction engine. AppKit owns tabs, the document list, native controls, and split panes. Rust validates files and writes session metadata atomically. There is no webview or JavaScript gesture path.

Native PDF views remain alive when their documents stay visible through a layout change. Hidden documents retain metadata, while their views and raster caches can be released. Pinch and scroll do not rebuild panes, tabs, or the document list. Status labels are coalesced, and session capture waits until interaction settles. Resize-to-fit work runs only when the outer pane size actually changes.

The interface keeps the user's documents prominent: tabs across the top, a compact layout/appearance toolbar, a collapsible document list, and one to four PDF panes. Dividers are resizable. Layout changes begin with equal panes, while documents not currently visible stay in the list. Drag rows to panes to assign/swap them, or to workspace tabs to move them. Context menus provide equivalent move commands.

Orange is the default accent. Nord, Dracula, and Solarized supply alternative accents and reading backgrounds; light, dark, and system mode remain separate choices. PDF paper/ink colors are never altered.

The version-1 session model remains compatible with existing metadata and adds optional native page coordinates. The original pre-migration session is preserved. Every document operation is read-only with respect to source PDF files.
