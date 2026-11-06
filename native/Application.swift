import AppKit
import PDFKit
import SwiftUI
import UniformTypeIdentifiers

let documentDragType = NSPasteboard.PasteboardType("io.github.justinechang39.foliodesk.document")
func dragIDs(_ pasteboard: NSPasteboard) -> [String]? {
  guard let text = pasteboard.string(forType: documentDragType), let data = text.data(using: .utf8),
    let ids = try? JSONDecoder().decode([String].self, from: data), ids.count == 2
  else { return nil }
  return ids
}
final class TabButton: NSButton {
  var dropped: ((NSPasteboard) -> Void)?
  override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
    sender.draggingPasteboard.string(forType: documentDragType) != nil ? .move : .copy
  }
  override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool { true }
  override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
    dropped?(sender.draggingPasteboard)
    return true
  }
}
final class DocumentTable: NSTableView {
  var menuForRow: ((Int) -> NSMenu?)?
  override func validateProposedFirstResponder(_ responder: NSResponder, for event: NSEvent?) -> Bool {
    if let button = responder as? NSButton, button.action == #selector(Application.chooseRowPanes(_:)) {
      return true
    }
    return super.validateProposedFirstResponder(responder, for: event)
  }
  override func menu(for event: NSEvent) -> NSMenu? {
    let index = row(at: convert(event.locationInWindow, from: nil))
    guard index >= 0 else { return nil }
    selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
    return menuForRow?(index)
  }
}
final class Application: NSObject, NSApplicationDelegate, NSWindowDelegate, NSTableViewDataSource,
  NSTableViewDelegate
{
  var window: NSWindow!
  var session = Session()
  var arguments: [String]
  var pendingURLs: [URL] = []
  let root = NSViewController()
  let tabs = NSStackView()
  let tabScroll = NSScrollView()
  let layoutPicker = NSPopUpButton()
  let themePicker = NSPopUpButton()
  let modePicker = NSPopUpButton()
  let linkButton = NSButton(checkboxWithTitle: "Link pages", target: nil, action: nil)
  let sidebarButton = NSButton(title: "Documents", target: nil, action: nil)
  let table = DocumentTable()
  let panePopover = NSPopover()
  private var sidebarPaths: [String] = []
  let sidebar = NSScrollView()
  let paneHost = NSView()
  var splitController: NSViewController?
  var panes: [Pane] = []
  var paneCache: [String: Pane] = [:]
  var focusedOnly = false
  var inputMonitor: Any?
  var appearanceObservation: NSKeyValueObservation?
  var saveWork: DispatchWorkItem?
  let storageQueue = DispatchQueue(label: "folio.session", qos: .utility)
  var saveError: Error?
  var restoringLayout = false
  var linking = false
  var benchmark = false
  var selfTest = false
  var reportPath: String?
  var heartbeat: Timer?
  var stressTimer: Timer?
  var activity: NSObjectProtocol?
  var gaps: [Double] = []
  var operationTimes: [Double] = []
  var tickCount = 0
  var activeTicks = 0
  var lastTick = 0.0
  var stressStep = 0
  var checks: [String: Bool] = [:]
  init(arguments: [String]) { self.arguments = arguments }
  var workspace: Workspace { session.current }
  var activePane: Pane? {
    panes.first { $0.state?.id == workspace.slots[workspace.focused] } ?? panes.first
  }

  func applicationDidFinishLaunching(_ notification: Notification) {
    NSApp.setActivationPolicy(.regular)
    benchmark = arguments.contains("--benchmark")
    selfTest = arguments.contains("--self-test")
    if let index = arguments.firstIndex(of: "--report"), arguments.indices.contains(index + 1) {
      reportPath = arguments[index + 1]
      arguments.removeSubrange(index...(index + 1))
    }
    arguments.removeAll { $0 == "--benchmark" || $0 == "--self-test" || $0.hasPrefix("-psn_") }
    do { if !benchmark { session = try Session.restore(bridge(["op": "load"])) } } catch {
      if selfTest {
        finishBenchmark(error: error.localizedDescription)
        return
      }
      let alert = NSAlert(error: error)
      alert.addButton(withTitle: "Quit")
      alert.addButton(withTitle: "Start a new workspace")
      if alert.runModal() != .alertSecondButtonReturn {
        NSApp.terminate(nil)
        return
      }
      do { _ = try bridge(["op": "archive"]) } catch {
        NSAlert(error: error).runModal()
        NSApp.terminate(nil)
        return
      }
    }
    makeWindow()
    makeMenu()
    refreshChrome()
    buildLayout()
    applyAppearance()
    window.makeKeyAndOrderFront(nil)
    NSApp.activate(ignoringOtherApps: true)
    inputMonitor = NSEvent.addLocalMonitorForEvents(matching: [
      .leftMouseDown, .scrollWheel, .magnify, .keyDown,
    ]) { [weak self] event in
      guard let self, event.window === self.window else { return event }
      if event.type == .keyDown && event.keyCode == 53 && self.focusedOnly {
        self.toggleFocus()
        return nil
      }
      if event.type != .keyDown {
        for pane in self.panes
        where pane.view.bounds.contains(pane.view.convert(event.locationInWindow, from: nil)) {
          if let id = pane.state?.id, let slot = self.workspace.slots.firstIndex(of: id) {
            self.workspace.focused = slot
          }
          if event.type == .scrollWheel && pane.handleCommandScroll(event) { return nil }
        }
      }
      return event
    }
    appearanceObservation = NSApp.observe(\.effectiveAppearance, options: [.new]) {
      [weak self] _, _ in
      DispatchQueue.main.async { self?.applyAppearance() }
    }
    if benchmark {
      do {
        guard arguments.count == 2 else {
          throw NativeError(message: "Two PDFs are required for the benchmark.")
        }
        for path in arguments { _ = try bridge(["op": "validate", "path": path]) }
        importURLs(arguments.map { URL(fileURLWithPath: $0) })
        guard panes.count == 2, panes.allSatisfy({ $0.pdf.document != nil }) else {
          throw NativeError(message: "Could not load benchmark PDFs (locked or corrupt).")
        }
        checks["twoDocumentsLoaded"] = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { self.beginBenchmark() }
      } catch { finishBenchmark(error: error.localizedDescription) }
    } else if selfTest {
      DispatchQueue.main.asyncAfter(deadline: .now() + 1) { self.runSelfTest() }
    } else {
      importURLs(
        arguments.map { URL(fileURLWithPath: $0) } + pendingURLs, target: workspace.focused)
      pendingURLs.removeAll()
    }
  }
  func makeWindow() {
    root.view = NSView()
    tabs.orientation = .horizontal
    tabs.spacing = 6
    tabs.edgeInsets = NSEdgeInsets(top: 0, left: 0, bottom: 0, right: 12)
    tabScroll.documentView = tabs
    tabScroll.hasHorizontalScroller = true
    tabScroll.autohidesScrollers = true
    tabScroll.drawsBackground = false
    tabs.translatesAutoresizingMaskIntoConstraints = false
    tabs.heightAnchor.constraint(equalTo: tabScroll.contentView.heightAnchor).isActive = true
    let tabRow = NSStackView(views: [
      tabScroll, button("+", self, #selector(newWorkspace), help: "New workspace"),
      button("Rename", self, #selector(renameWorkspace), help: "Rename workspace"),
      button("×", self, #selector(closeWorkspace), help: "Close workspace"),
    ])
    tabRow.spacing = 6
    tabScroll.setContentHuggingPriority(.defaultLow, for: .horizontal)
    for (_, name) in layoutNames { layoutPicker.addItem(withTitle: name) }
    layoutPicker.target = self
    layoutPicker.action = #selector(changeLayout)
    layoutPicker.setAccessibilityLabel("Layout")
    for theme in ["Orange", "Nord", "Dracula", "Solarized"] {
      themePicker.addItem(withTitle: theme)
    }
    themePicker.target = self
    themePicker.action = #selector(changeAppearance)
    themePicker.setAccessibilityLabel("Theme")
    for mode in ["System", "Light", "Dark"] { modePicker.addItem(withTitle: mode) }
    modePicker.target = self
    modePicker.action = #selector(changeAppearance)
    modePicker.setAccessibilityLabel("Color mode")
    linkButton.target = self
    linkButton.action = #selector(toggleLinked)
    sidebarButton.target = self
    sidebarButton.action = #selector(toggleSidebar)
    sidebarButton.bezelStyle = .rounded
    let spacer = NSView()
    spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
    let toolbar = NSStackView(views: [
      sidebarButton,
      button("Add PDFs…", self, #selector(openFiles), help: "Add PDFs to this workspace"),
      layoutPicker,
      button(
        "Focus", self, #selector(toggleFocus), help: "Focus this pane / restore layout (Escape)"),
      linkButton, spacer, themePicker, modePicker,
    ])
    toolbar.spacing = 10
    let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("document"))
    column.title = "Documents"
    table.addTableColumn(column)
    table.headerView = nil
    table.rowHeight = 42
    table.dataSource = self
    table.delegate = self
    table.target = self
    table.action = #selector(selectDocument)
    table.doubleAction = #selector(selectDocument)
    table.allowsMultipleSelection = false
    table.style = .sourceList
    table.registerForDraggedTypes([documentDragType, .fileURL])
    table.setDraggingSourceOperationMask(.move, forLocal: true)
    table.menuForRow = { [weak self] row in self?.documentMenu(row) }
    table.setAccessibilityLabel("Workspace documents")
    sidebar.documentView = table
    sidebar.hasVerticalScroller = true
    sidebar.autohidesScrollers = true
    sidebar.widthAnchor.constraint(equalToConstant: 240).isActive = true
    let body = NSStackView(views: [sidebar, paneHost])
    body.orientation = .horizontal
    body.spacing = 1
    body.alignment = .top
    body.distribution = .fill
    paneHost.setContentHuggingPriority(.defaultLow, for: .horizontal)
    for view in [tabRow, toolbar, body] {
      view.translatesAutoresizingMaskIntoConstraints = false
      root.view.addSubview(view)
    }
    NSLayoutConstraint.activate([
      tabRow.topAnchor.constraint(equalTo: root.view.topAnchor, constant: 8),
      tabRow.leadingAnchor.constraint(equalTo: root.view.leadingAnchor, constant: 12),
      tabRow.trailingAnchor.constraint(equalTo: root.view.trailingAnchor, constant: -12),
      tabRow.heightAnchor.constraint(equalToConstant: 40),
      toolbar.topAnchor.constraint(equalTo: tabRow.bottomAnchor, constant: 6),
      toolbar.leadingAnchor.constraint(equalTo: tabRow.leadingAnchor),
      toolbar.trailingAnchor.constraint(equalTo: tabRow.trailingAnchor),
      toolbar.heightAnchor.constraint(equalToConstant: 36),
      body.topAnchor.constraint(equalTo: toolbar.bottomAnchor, constant: 10),
      body.leadingAnchor.constraint(equalTo: root.view.leadingAnchor),
      body.trailingAnchor.constraint(equalTo: root.view.trailingAnchor),
      body.bottomAnchor.constraint(equalTo: root.view.bottomAnchor),
      sidebar.heightAnchor.constraint(equalTo: body.heightAnchor),
      paneHost.heightAnchor.constraint(equalTo: body.heightAnchor),
    ])
    window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 1380, height: 920),
      styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false
    )
    window.title = "Folio Desk"
    window.contentViewController = root
    window.setContentSize(NSSize(width: 1380, height: 920))
    window.minSize = NSSize(width: 1040, height: 650)
    window.delegate = self
    window.isReleasedWhenClosed = false
    window.center()
    if !benchmark && !selfTest { window.setFrameAutosaveName("FolioDeskNative") }
  }
  func refreshChrome() {
    for view in tabs.arrangedSubviews {
      tabs.removeArrangedSubview(view)
      view.removeFromSuperview()
    }
    for workspace in session.views {
      let tab = TabButton(title: workspace.name, target: self, action: #selector(selectTab(_:)))
      tab.identifier = NSUserInterfaceItemIdentifier(workspace.id)
      tab.bezelStyle = .rounded
      tab.setButtonType(.toggle)
      tab.state = workspace.id == session.active ? .on : .off
      tab.contentTintColor = accent
      tab.registerForDraggedTypes([documentDragType, .fileURL])
      tab.toolTip = "Switch workspace or drop a document here"
      tab.dropped = { [weak self] pasteboard in
        guard let self else { return }
        self.capturePanes()
        if let ids = dragIDs(pasteboard) {
          self.session.moveFile(ids[1], from: ids[0], to: workspace.id)
        }
        self.session.active = workspace.id
        self.focusedOnly = false
        self.refreshChrome()
        self.buildLayout()
        if let urls = pasteboard.readObjects(
          forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]
        {
          self.importURLs(urls)
        }
        self.scheduleSave()
      }
      tabs.addArrangedSubview(tab)
    }
    layoutPicker.selectItem(at: layoutNames.firstIndex { $0.0 == workspace.layout } ?? 1)
    themePicker.selectItem(withTitle: session.appearance.theme.capitalized)
    modePicker.selectItem(withTitle: session.appearance.mode.capitalized)
    sidebar.isHidden = !session.sidebar
    sidebarButton.state = session.sidebar ? .on : .off
    linkButton.state = workspace.linked ? .on : .off
    reloadDocumentList()
    window?.subtitle = workspace.name
  }
  func capturePanes() { for pane in panes { pane.capture() } }
  func buildLayout() {
    restoringLayout = true
    defer { restoringLayout = false }
    capturePanes()
    let minimumWidth: CGFloat =
      workspace.layout == "triple" && !focusedOnly ? (session.sidebar ? 1160 : 1040) : 1040
    window.minSize = NSSize(width: minimumWidth, height: 650)
    if window.frame.width < minimumWidth {
      window.setContentSize(NSSize(width: minimumWidth, height: window.contentView!.bounds.height))
    }
    let targetSlots = focusedOnly ? [workspace.focused] : Array(workspace.slots.indices)
    let visibleIDs = Set(targetSlots.compactMap { workspace.slots[$0] })
    for pane in panes {
      pane.view.removeFromSuperview()
      pane.removeFromParent()
    }
    splitController?.view.removeFromSuperview()
    splitController?.removeFromParent()
    splitController = nil
    paneCache = paneCache.filter { visibleIDs.contains($0.key) }
    panes = targetSlots.map { slot in
      let id = workspace.slots[slot]
      let pane = id.flatMap { paneCache[$0] } ?? Pane()
      _ = pane.view
      pane.didActivate = { [weak self] in self?.workspace.focused = slot }
      pane.openURLs = { [weak self] urls in self?.importURLs(urls, target: slot) }
      pane.documentDropped = { [weak self] source, doc in
        guard let self else { return }
        self.capturePanes()
        self.session.moveFile(doc, from: source, to: self.session.active, slot: slot)
        self.refreshChrome()
        self.buildLayout()
        self.scheduleSave()
      }
      pane.choosePanesRequested = { [weak self, weak pane] in
        if let pane, let doc = pane.state { self?.choosePanes(for: doc, from: pane.paneButton) }
      }
      pane.stateChanged = { [weak self] in self?.scheduleSave() }
      pane.pageChanged = { [weak self, weak pane] number in
        guard let self, let pane, !self.restoringLayout, !self.linking, self.workspace.linked,
          self.activePane === pane
        else { return }
        self.linking = true
        for other in self.panes where other !== pane {
          other.restoring = true
          other.navigate(to: number)
          other.restoring = false
        }
        self.linking = false
        self.scheduleSave()
      }
      if let id, let doc = workspace.documents.first(where: { $0.id == id }) {
        if pane.state !== doc {
          pane.pdf.document = nil
          pane.state = doc
          pane.openedURL = nil
        }
        paneCache[id] = pane
      }
      pane.paneButton.isEnabled = pane.state != nil
      pane.paneButton.setAccessibilityLabel(
        "Choose panes for \(pane.state?.name ?? "this PDF")")
      return pane
    }
    func split(_ children: [NSViewController], vertical: Bool) -> NSSplitViewController {
      let controller = NSSplitViewController()
      controller.splitView.isVertical = vertical
      controller.splitView.dividerStyle = .thin
      for child in children {
        let item = NSSplitViewItem(viewController: child)
        item.minimumThickness = vertical ? 290 : 180
        controller.addSplitViewItem(item)
      }
      return controller
    }
    let controller: NSViewController
    if workspace.layout == "grid" && !focusedOnly {
      controller = split(
        [
          split(Array(panes.prefix(2)), vertical: true),
          split(Array(panes.suffix(2)), vertical: true),
        ], vertical: false)
    } else {
      controller = split(panes, vertical: workspace.layout != "rows")
    }
    root.addChild(controller)
    paneHost.addSubview(controller.view)
    controller.view.translatesAutoresizingMaskIntoConstraints = false
    NSLayoutConstraint.activate([
      controller.view.leadingAnchor.constraint(equalTo: paneHost.leadingAnchor),
      controller.view.trailingAnchor.constraint(equalTo: paneHost.trailingAnchor),
      controller.view.topAnchor.constraint(equalTo: paneHost.topAnchor),
      controller.view.bottomAnchor.constraint(equalTo: paneHost.bottomAnchor),
    ])
    splitController = controller
    root.view.layoutSubtreeIfNeeded()
    func balance(_ controller: NSViewController) {
      guard let split = controller as? NSSplitViewController else { return }
      let count = split.splitViewItems.count
      let extent = split.splitView.isVertical ? split.view.bounds.width : split.view.bounds.height
      let divider = split.splitView.dividerThickness
      if count > 1 {
        let unit = (extent - CGFloat(count - 1) * divider) / CGFloat(count)
        for index in 0..<(count - 1) {
          split.splitView.setPosition(
            CGFloat(index + 1) * unit + CGFloat(index) * divider, ofDividerAt: index)
        }
      }
      split.view.layoutSubtreeIfNeeded()
      for child in split.children { balance(child) }
    }
    balance(controller)
    for pane in panes {
      if let state = pane.state, pane.pdf.document == nil { pane.load(state, interactive: false) }
    }
    applyAppearance()
  }
  func importURLs(_ urls: [URL], target: Int? = nil) {
    guard !urls.isEmpty else { return }
    capturePanes()
    var errors: [String] = []
    var first = true
    for url in urls.prefix(200) {
      do {
        let path = try bridge(["op": "validate", "path": url.path]) as! String
        workspace.open(path, in: first ? target : nil)
        first = false
      } catch { errors.append("\(url.lastPathComponent): \(error.localizedDescription)") }
    }
    refreshChrome()
    buildLayout()
    scheduleSave()
    if !errors.isEmpty && !benchmark && !selfTest {
      showError(NativeError(message: errors.joined(separator: "\n")))
    }
  }
  func application(_ sender: NSApplication, openFiles filenames: [String]) {
    let urls = filenames.map { URL(fileURLWithPath: $0) }
    if window == nil {
      pendingURLs.append(contentsOf: urls)
    } else {
      importURLs(urls, target: workspace.focused)
    }
    sender.reply(toOpenOrPrint: .success)
  }
  func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
    window?.makeKeyAndOrderFront(nil)
    return true
  }
  @objc func openFiles() { activePane?.openFile() }
  @objc func selectTab(_ sender: NSButton) {
    capturePanes()
    session.active = sender.identifier!.rawValue
    focusedOnly = false
    refreshChrome()
    buildLayout()
    scheduleSave()
  }
  @objc func newWorkspace() {
    capturePanes()
    let new = Workspace(name: "Workspace \(session.views.count+1)")
    session.views.append(new)
    session.active = new.id
    focusedOnly = false
    refreshChrome()
    buildLayout()
    scheduleSave()
  }
  @objc func renameWorkspace() {
    let alert = NSAlert()
    alert.messageText = "Rename workspace"
    let field = NSTextField(string: workspace.name)
    field.frame = NSRect(x: 0, y: 0, width: 300, height: 24)
    alert.accessoryView = field
    alert.addButton(withTitle: "Save")
    alert.addButton(withTitle: "Cancel")
    alert.beginSheetModal(for: window) { response in
      if response == .alertFirstButtonReturn {
        let name = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if !name.isEmpty {
          self.workspace.name = String(name.prefix(80))
          self.refreshChrome()
          self.scheduleSave()
        }
      }
    }
    window.makeFirstResponder(field)
  }
  @objc func closeWorkspace() {
    if workspace.documents.isEmpty {
      removeCurrentWorkspace()
      return
    }
    let alert = NSAlert()
    alert.messageText = "Close \(workspace.name)?"
    alert.informativeText = "The PDFs remain on your Mac. This workspace will be removed."
    alert.addButton(withTitle: "Close workspace")
    alert.addButton(withTitle: "Cancel")
    alert.beginSheetModal(for: window) {
      if $0 == .alertFirstButtonReturn { self.removeCurrentWorkspace() }
    }
  }
  func removeCurrentWorkspace() {
    capturePanes()
    session.views.removeAll { $0.id == session.active }
    if session.views.isEmpty { session.views = [Workspace()] }
    session.active = session.views[0].id
    focusedOnly = false
    refreshChrome()
    buildLayout()
    scheduleSave()
  }
  @objc func changeLayout() {
    capturePanes()
    workspace.setLayout(layoutNames[layoutPicker.indexOfSelectedItem].0)
    focusedOnly = false
    buildLayout()
    scheduleSave()
  }
  @objc func toggleFocus() {
    capturePanes()
    focusedOnly.toggle()
    buildLayout()
  }
  @objc func toggleSidebar() {
    session.sidebar.toggle()
    sidebar.isHidden = !session.sidebar
    sidebarButton.state = session.sidebar ? .on : .off
    scheduleSave()
  }
  @objc func toggleLinked() {
    workspace.linked = linkButton.state == .on
    scheduleSave()
  }
  @objc func changeAppearance() {
    session.appearance.theme = themePicker.titleOfSelectedItem!.lowercased()
    session.appearance.mode = modePicker.titleOfSelectedItem!.lowercased()
    applyAppearance()
    scheduleSave()
  }
  func applyAppearance() {
    guard window != nil else { return }
    let mode = session.appearance.mode
    window.appearance =
      mode == "system" ? nil : NSAppearance(named: mode == "dark" ? .darkAqua : .aqua)
    let dark = window.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
    let (color, desk) = palette(session.appearance, dark: dark)
    accent = color
    func tint(_ view: NSView) {
      if let button = view as? NSButton { button.contentTintColor = color }
      for child in view.subviews { tint(child) }
    }
    tint(root.view)
    for pane in panes { pane.pdf.backgroundColor = desk }
    reloadDocumentList()
  }
  func scheduleSave() {
    guard !restoringLayout else { return }
    saveWork?.cancel()
    let work = DispatchWorkItem { [weak self] in self?.saveAsynchronously() }
    saveWork = work
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.6, execute: work)
  }
  func snapshot() throws -> [String: Any] {
    capturePanes()
    return ["op": "save", "session": try session.json()]
  }
  func saveAsynchronously() {
    do {
      let request = try snapshot()
      storageQueue.async { [weak self] in
        do { _ = try bridge(request) } catch {
          DispatchQueue.main.async {
            self?.saveError = error
            self?.window.subtitle = "Workspace not saved — try quitting to retry"
          }
        }
      }
    } catch { saveError = error }
  }
  func flushSave() throws {
    saveWork?.cancel()
    let request = try snapshot()
    try storageQueue.sync { _ = try bridge(request) }
    saveError = nil
  }
  func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
    guard window != nil else { return .terminateNow }
    do {
      try flushSave()
      return .terminateNow
    } catch {
      let alert = NSAlert(error: error)
      alert.informativeText =
        "Your latest workspace could not be saved. The previous saved session is preserved."
      alert.addButton(withTitle: "Keep open")
      alert.addButton(withTitle: "Quit without saving")
      return alert.runModal() == .alertSecondButtonReturn ? .terminateNow : .terminateCancel
    }
  }
  func applicationWillTerminate(_ notification: Notification) {
    if let inputMonitor { NSEvent.removeMonitor(inputMonitor) }
  }
  func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
  func showError(_ error: Error) { NSAlert(error: error).beginSheetModal(for: window) }

  private func reloadDocumentList() {
    sidebarPaths = workspace.filePaths
    table.reloadData()
  }
  private func sidebarDocument(at row: Int) -> DocumentState? {
    guard sidebarPaths.indices.contains(row) else { return nil }
    return workspace.readingView(for: sidebarPaths[row])
  }
  func numberOfRows(in tableView: NSTableView) -> Int { sidebarPaths.count }
  func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView?
  {
    guard let doc = sidebarDocument(at: row) else { return nil }
    let slot = workspace.slots.firstIndex(of: doc.id)
    let field = NSTextField(labelWithString: doc.name)
    field.lineBreakMode = .byTruncatingMiddle
    field.font = .systemFont(ofSize: 12, weight: slot == nil ? .regular : .medium)
    field.toolTip = "\(doc.path)\nDrag to a pane or workspace tab. Right-click for options."
    field.textColor = slot == nil ? .labelColor : accent

    let labels = NSStackView(views: [field])
    labels.orientation = .vertical
    labels.alignment = .leading
    labels.spacing = 1
    let sameFile = workspace.documents.filter { $0.path == doc.path }
    let paneCount = sameFile.filter { workspace.slots.contains($0.id) }.count
    if paneCount > 1 {
      let detail = NSTextField(labelWithString: "\(paneCount) panes")
      detail.font = .systemFont(ofSize: 10)
      detail.textColor = .secondaryLabelColor
      labels.addArrangedSubview(detail)
    }
    let compared = paneCount > 1
    let compare = panePickerButton(
      self, #selector(chooseRowPanes(_:)), name: doc.name, filled: compared)
    compare.identifier = NSUserInterfaceItemIdentifier(doc.path)
    compare.isBordered = false
    compare.contentTintColor = compared ? accent : .secondaryLabelColor
    let cell = NSTableCellView()
    cell.addSubview(labels)
    cell.addSubview(compare)
    labels.translatesAutoresizingMaskIntoConstraints = false
    compare.translatesAutoresizingMaskIntoConstraints = false
    NSLayoutConstraint.activate([
      labels.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 8),
      labels.trailingAnchor.constraint(equalTo: compare.leadingAnchor, constant: -4),
      labels.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
      field.widthAnchor.constraint(equalTo: labels.widthAnchor),
      compare.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -4),
      compare.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
      compare.widthAnchor.constraint(equalToConstant: 32),
      compare.heightAnchor.constraint(equalToConstant: 32),
    ])
    return cell
  }
  @objc func chooseRowPanes(_ sender: NSButton) {
    if let path = sender.identifier?.rawValue, let doc = workspace.readingView(for: path) {
      choosePanes(for: doc, from: sender)
    }
  }
  private func choosePanes(for doc: DocumentState, from anchor: NSView) {
    guard anchor.window != nil else { return }
    if panePopover.isShown { panePopover.close() }
    let owner = workspace
    let choices = PaneChoices(workspace: owner, document: doc) { [weak self, weak owner] layout, selected in
      guard let self, let owner, self.workspace === owner,
        owner.documents.contains(where: { $0 === doc }) else { return }
      self.panePopover.close()
      self.capturePanes()
      let changed = owner.place(doc, in: selected, layout: layout)
      if changed || self.focusedOnly {
        self.focusedOnly = false
        self.refreshChrome()
        self.buildLayout()
        self.scheduleSave()
      }
    }
    let picker = PanePickerView(choices: choices) { [weak self] in self?.panePopover.close() }
    panePopover.behavior = .transient
    let host = NSHostingController(rootView: picker)
    host.sizingOptions = [.preferredContentSize, .intrinsicContentSize]
    panePopover.contentViewController = host
    panePopover.contentSize = host.sizeThatFits(in: NSSize(width: 300, height: 600))
    panePopover.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .maxY)
  }
  /// The document list's selection when it has keyboard focus, otherwise the active pane.
  var compareTarget: String? {
    if window.firstResponder === table, let doc = sidebarDocument(at: table.selectedRow) {
      return doc.id
    }
    return activePane?.state?.id
  }
  @objc func compareSideBySide() {
    if let id = compareTarget { compareDocument(id) }
  }
  func compareDocument(_ id: String) {
    guard let doc = workspace.documents.first(where: { $0.id == id }) else { return }
    capturePanes()
    let result = workspace.compare(id)
    guard result != .unavailable else { return }
    // Repeating the action leaves dividers and every reading position untouched.
    if result != .unchanged || focusedOnly {
      focusedOnly = false
      refreshChrome()
      buildLayout()
      scheduleSave()
    }
    NSAccessibility.post(
      element: NSApplication.shared, notification: .announcementRequested,
      userInfo: [
        .announcement: result == .unchanged
          ? "\(doc.name) is already side by side" : "\(doc.name) is side by side in two views",
        .priority: NSAccessibilityPriorityLevel.high.rawValue,
      ])
  }
  @objc func selectDocument() {
    guard let doc = sidebarDocument(at: table.selectedRow) else { return }
    if let slot = workspace.slots.firstIndex(of: doc.id) {
      let reveal = focusedOnly && workspace.focused != slot
      workspace.focused = slot
      if reveal { buildLayout() }
      window.makeFirstResponder(activePane?.pdf)
      scheduleSave()
      return
    }
    capturePanes()
    workspace.show(doc.id, in: workspace.focused)
    buildLayout()
    reloadDocumentList()
    scheduleSave()
  }
  func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> NSPasteboardWriting?
  {
    guard let doc = sidebarDocument(at: row) else { return nil }
    let item = NSPasteboardItem()
    let data = try! JSONEncoder().encode([workspace.id, doc.id])
    item.setString(String(data: data, encoding: .utf8)!, forType: documentDragType)
    return item
  }
  func tableView(
    _ tableView: NSTableView, validateDrop info: NSDraggingInfo, proposedRow row: Int,
    proposedDropOperation op: NSTableView.DropOperation
  ) -> NSDragOperation {
    tableView.setDropRow(row, dropOperation: .above)
    return dragIDs(info.draggingPasteboard) != nil ? .move : .copy
  }
  func tableView(
    _ tableView: NSTableView, acceptDrop info: NSDraggingInfo, row: Int,
    dropOperation: NSTableView.DropOperation
  ) -> Bool {
    capturePanes()
    if let ids = dragIDs(info.draggingPasteboard) {
      guard let source = session.views.first(where: { $0.id == ids[0] }),
        let doc = source.documents.first(where: { $0.id == ids[1] }) else { return false }
      let nextPath = sidebarPaths.indices.contains(row) ? sidebarPaths[row] : nil
      if source !== workspace { session.moveFile(doc.id, from: source.id, to: workspace.id) }
      workspace.reorderFile(doc.path, before: nextPath)
      refreshChrome()
      buildLayout()
      scheduleSave()
      return true
    }
    if let urls = info.draggingPasteboard.readObjects(
      forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]
    {
      importURLs(urls)
      return true
    }
    return false
  }
  func documentMenu(_ row: Int) -> NSMenu? {
    guard let doc = sidebarDocument(at: row) else { return nil }
    let id = doc.id
    let menu = NSMenu()
    func item(_ title: String, _ operation: String, _ destination: String = "") {
      let item = NSMenuItem(title: title, action: #selector(documentAction(_:)), keyEquivalent: "")
      item.target = self
      item.representedObject = ["id": id, "op": operation, "dest": destination]
      menu.addItem(item)
    }
    item("Compare side by side", "compare")
    menu.addItem(.separator())
    for slot in workspace.slots.indices { item("Open in pane \(slot+1)", "assign", String(slot)) }
    let views = workspace.documents.filter { $0.path == doc.path }
    let saved = views.filter { !workspace.slots.contains($0.id) }
    if views.count > 1 && !saved.isEmpty {
      let submenu = NSMenu()
      for (index, view) in saved.enumerated() {
        let choice = NSMenuItem(title: "View \(index + 1) · Page \(view.page)",
          action: #selector(documentAction(_:)), keyEquivalent: "")
        choice.target = self
        choice.representedObject = ["id": view.id, "op": "restore"]
        submenu.addItem(choice)
      }
      menu.addItem(withTitle: "Show saved view", action: nil, keyEquivalent: "").submenu = submenu
    }
    menu.addItem(.separator())
    for view in session.views where view.id != session.active {
      item("Move to \(view.name)", "move", view.id)
    }
    item("Move to new workspace", "new")
    menu.addItem(.separator())
    item("Show in Finder", "reveal")
    item("Remove from workspace", "remove")
    return menu
  }
  @objc func documentAction(_ sender: NSMenuItem) {
    guard let data = sender.representedObject as? [String: String], let id = data["id"] else {
      return
    }
    if data["op"] == "compare" { return compareDocument(id) }
    capturePanes()
    switch data["op"] {
    case "restore": workspace.assign(id, to: workspace.focused)
    case "assign":
      guard let doc = workspace.documents.first(where: { $0.id == id }),
        let slot = Int(data["dest"] ?? "") else { return }
      workspace.open(doc.path, in: slot)
    case "move": session.moveFile(id, from: session.active, to: data["dest"]!)
    case "new":
      let new = Workspace(name: "Workspace \(session.views.count+1)")
      session.views.append(new)
      session.moveFile(id, from: session.active, to: new.id)
      session.active = new.id
    case "remove":
      guard let path = workspace.documents.first(where: { $0.id == id })?.path else { return }
      for view in workspace.documents.filter({ $0.path == path }) { workspace.remove(view.id) }
    case "reveal":
      if let doc = workspace.documents.first(where: { $0.id == id }) {
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: doc.path)])
      }
      return
    default: return
    }
    refreshChrome()
    buildLayout()
    scheduleSave()
  }
  @objc func zoomIn() { activePane?.zoomIn() }
  @objc func zoomOut() { activePane?.zoomOut() }
  @objc func fitPage() { activePane?.fitPage() }
  @objc func find() { activePane?.toggleSearch() }
  @objc func selectNumberedTab(_ item: NSMenuItem) {
    guard session.views.indices.contains(item.tag) else { return }
    capturePanes()
    session.active = session.views[item.tag].id
    focusedOnly = false
    refreshChrome()
    buildLayout()
    scheduleSave()
  }
  func makeMenu() {
    let menu = NSMenu()
    func submenu(_ title: String) -> NSMenu {
      let item = NSMenuItem()
      let child = NSMenu(title: title)
      item.submenu = child
      menu.addItem(item)
      return child
    }
    func add(
      _ menu: NSMenu, _ title: String, _ action: Selector, _ key: String, target: AnyObject? = nil
    ) -> NSMenuItem {
      let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
      item.target = target
      menu.addItem(item)
      return item
    }
    let app = submenu("Folio Desk")
    _ = add(
      app, "About Folio Desk", #selector(NSApplication.orderFrontStandardAboutPanel(_:)), "",
      target: NSApp)
    app.addItem(.separator())
    _ = add(app, "Hide Folio Desk", #selector(NSApplication.hide(_:)), "h", target: NSApp)
    _ = add(app, "Quit Folio Desk", #selector(NSApplication.terminate(_:)), "q", target: NSApp)
    let file = submenu("File")
    _ = add(file, "Add PDFs…", #selector(openFiles), "o", target: self)
    _ = add(file, "New Workspace", #selector(newWorkspace), "t", target: self)
    _ = add(file, "Close Workspace", #selector(closeWorkspace), "w", target: self)
    let edit = submenu("Edit")
    _ = add(edit, "Copy", #selector(NSText.copy(_:)), "c")
    _ = add(edit, "Paste", #selector(NSText.paste(_:)), "v")
    _ = add(edit, "Select All", #selector(NSText.selectAll(_:)), "a")
    _ = add(edit, "Find…", #selector(find), "f", target: self)
    let view = submenu("View")
    _ = add(view, "Zoom In", #selector(zoomIn), "+", target: self)
    _ = add(view, "Zoom Out", #selector(zoomOut), "-", target: self)
    _ = add(view, "Fit Page", #selector(fitPage), "0", target: self)
    _ = add(view, "Focus Pane / Restore Layout", #selector(toggleFocus), "", target: self)
    _ = add(view, "Compare Side by Side", #selector(compareSideBySide), "\\", target: self)
    view.addItem(.separator())
    for index in 0..<9 {
      let item = add(
        view, "Workspace \(index+1)", #selector(selectNumberedTab(_:)), "\(index+1)", target: self)
      item.tag = index
    }
    NSApp.mainMenu = menu
  }
}
extension Application: NSMenuItemValidation {
  func validateMenuItem(_ item: NSMenuItem) -> Bool {
    item.action != #selector(compareSideBySide) || compareTarget != nil
  }
}

@_cdecl("folio_native_run")
public func folioNativeRun(
  _ argumentData: UnsafePointer<CChar>,
  _ request: @escaping @convention(c) (UnsafePointer<CChar>?) -> UnsafeMutablePointer<CChar>?,
  _ release: @escaping @convention(c) (UnsafeMutablePointer<CChar>?) -> Void
) -> Int32 {
  rustRequest = request
  rustRelease = release
  var arguments: [String] = []
  var pointer = argumentData
  while pointer.pointee != 0 {
    arguments.append(String(cString: pointer))
    pointer = pointer.advanced(by: strlen(pointer) + 1)
  }
  let application = NSApplication.shared
  let delegate = Application(arguments: arguments)
  application.delegate = delegate
  withExtendedLifetime(delegate) { application.run() }
  return 0
}
