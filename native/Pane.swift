import AppKit
import PDFKit
import UniformTypeIdentifiers

func button(_ title: String, _ target: AnyObject, _ action: Selector, help: String) -> NSButton {
  let button = NSButton(title: title, target: target, action: action)
  button.bezelStyle = .rounded
  button.controlSize = .regular
  button.contentTintColor = accent
  button.toolTip = help
  button.setAccessibilityLabel(help)
  button.heightAnchor.constraint(greaterThanOrEqualToConstant: 30).isActive = true
  return button
}

private enum FileError: LocalizedError {
  case notPDF, unreadable
  var errorDescription: String? {
    switch self {
    case .notPDF: return "Choose a PDF file."
    case .unreadable:
      return
        "This PDF could not be opened. Check that it is downloaded and you have permission to read it."
    }
  }
}

private func readPDF(_ url: URL) throws -> PDFDocument {
  guard url.isFileURL, url.pathExtension.lowercased() == "pdf" else { throw FileError.notPDF }
  _ = try bridge(["op": "validate", "path": url.path])
  let file = try FileHandle(forReadingFrom: url)
  defer { try? file.close() }
  let header = try file.read(upToCount: 1024) ?? Data()
  guard header.range(of: Data("%PDF-".utf8)) != nil else { throw FileError.notPDF }
  guard let document = PDFDocument(url: url), document.isLocked || document.pageCount > 0 else {
    throw FileError.unreadable
  }
  return document
}

final class DropPDFView: PDFView {
  var openURLs: (([URL]) -> Void)?
  var activate: (() -> Void)?
  var documentDropped: ((String, String) -> Void)?
  override func mouseDown(with event: NSEvent) {
    activate?()
    super.mouseDown(with: event)
  }
  override func magnify(with event: NSEvent) {
    activate?()
    super.magnify(with: event)
  }
  private func urls(_ sender: NSDraggingInfo) -> [URL] {
    sender.draggingPasteboard.readObjects(
      forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
  }
  override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
    if sender.draggingPasteboard.string(forType: documentDragType) != nil { return .move }
    let files = urls(sender)
    return !files.isEmpty && files.allSatisfy { $0.pathExtension.lowercased() == "pdf" }
      ? .copy : []
  }
  override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
    draggingEntered(sender)
  }
  override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool {
    !urls(sender).isEmpty || sender.draggingPasteboard.string(forType: documentDragType) != nil
  }
  override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
    if let ids = dragIDs(sender.draggingPasteboard) {
      activate?()
      documentDropped?(ids[0], ids[1])
      return true
    }
    let files = urls(sender)
    guard !files.isEmpty else { return false }
    activate?()
    openURLs?(files)
    return true
  }
}

final class Pane: NSViewController {
  let pdf = DropPDFView()
  let titleLabel = NSTextField(labelWithString: "Open a PDF")
  let pageLabel = NSTextField(labelWithString: "")
  let zoomLabel = NSTextField(labelWithString: "—")
  let emptyLabel = NSTextField(wrappingLabelWithString: "Drop a PDF here\nor choose Open")
  var didActivate: (() -> Void)?
  var openURLs: (([URL]) -> Void)?
  var openedURL: URL?
  var state: DocumentState?
  var stateChanged: (() -> Void)?
  var pageChanged: ((Int) -> Void)?
  var documentDropped: ((String, String) -> Void)?
  var restoring = false
  var fitting = false
  var lastReportedPage = 0
  var fitWork: DispatchWorkItem?
  var lastSize = NSSize.zero
  var searchObservations: [NSObjectProtocol] = []
  var matches: [PDFSelection] = []
  var matchIndex = 0
  let searchField = NSSearchField()
  let searchLabel = NSTextField(labelWithString: "")
  let searchRow = NSStackView()
  let pageField = NSTextField(string: "1")
  var searchVisible = false
  let retryButton = NSButton(title: "Retry opening", target: nil, action: nil)
  private var observations: [NSObjectProtocol] = []
  private var statusUpdatePending = false
  var statusMaxMS = 0.0

  override func loadView() {
    view = NSView()
    let heading = NSStackView()
    heading.orientation = .horizontal
    heading.spacing = 10
    titleLabel.font = .systemFont(ofSize: 13, weight: .semibold)
    titleLabel.lineBreakMode = .byTruncatingMiddle
    titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    heading.addArrangedSubview(titleLabel)
    heading.addArrangedSubview(
      button("Open…", self, #selector(openFile), help: "Open a PDF in this pane"))
    let controls = NSStackView(views: [
      button("−", self, #selector(zoomOut), help: "Zoom out"), zoomLabel,
      button("+", self, #selector(zoomIn), help: "Zoom in"),
      button("Width", self, #selector(fitWidth), help: "Fit page width"),
      button("Page", self, #selector(fitPage), help: "Fit whole page"),
    ])
    controls.spacing = 6
    zoomLabel.font = .monospacedDigitSystemFont(ofSize: 12, weight: .medium)
    zoomLabel.alignment = .center
    zoomLabel.widthAnchor.constraint(equalToConstant: 48).isActive = true
    let spacer = NSView()
    spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
    controls.addArrangedSubview(spacer)
    pageLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
    pageLabel.textColor = .secondaryLabelColor
    pageField.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
    pageField.alignment = .center
    pageField.widthAnchor.constraint(equalToConstant: 36).isActive = true
    pageField.target = self
    pageField.action = #selector(jumpPage)
    pageField.setAccessibilityLabel("Page number")
    let navSpacer = NSView()
    navSpacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
    let navigation = NSStackView(views: [
      button("↻", self, #selector(rotatePages), help: "Rotate clockwise"),
      button("Find", self, #selector(toggleSearch), help: "Find text"), navSpacer, pageField,
      pageLabel,
    ])
    navigation.spacing = 6
    searchField.placeholderString = "Find in this PDF"
    searchField.target = self
    searchField.action = #selector(findText)
    searchField.sendsSearchStringImmediately = false
    searchField.sendsWholeSearchString = true
    searchField.widthAnchor.constraint(greaterThanOrEqualToConstant: 100).isActive = true
    searchRow.orientation = .horizontal
    searchRow.spacing = 6
    for child in [
      searchField, searchLabel, button("‹", self, #selector(previousMatch), help: "Previous match"),
      button("›", self, #selector(nextMatch), help: "Next match"),
    ] { searchRow.addArrangedSubview(child) }
    searchRow.isHidden = true
    pdf.displayMode = .singlePageContinuous
    pdf.displayDirection = .vertical
    pdf.displaysPageBreaks = true
    pdf.pageBreakMargins = NSEdgeInsets(top: 8, left: 8, bottom: 8, right: 8)
    pdf.backgroundColor = .underPageBackgroundColor
    pdf.minScaleFactor = 0.1
    pdf.maxScaleFactor = 8
    pdf.autoScales = true
    pdf.registerForDraggedTypes([.fileURL, documentDragType])
    pdf.documentDropped = { [weak self] workspace, document in
      self?.documentDropped?(workspace, document)
    }
    pdf.activate = { [weak self] in self?.didActivate?() }
    pdf.openURLs = { [weak self] urls in self?.openURLs?(urls) }
    emptyLabel.alignment = .center
    emptyLabel.font = .systemFont(ofSize: 17, weight: .medium)
    emptyLabel.textColor = .secondaryLabelColor
    emptyLabel.isSelectable = false
    let toolbar = NSStackView(views: [heading, controls, navigation, searchRow])
    toolbar.orientation = .vertical
    toolbar.alignment = .leading
    toolbar.spacing = 8
    heading.widthAnchor.constraint(equalTo: toolbar.widthAnchor).isActive = true
    controls.widthAnchor.constraint(equalTo: toolbar.widthAnchor).isActive = true
    searchRow.widthAnchor.constraint(equalTo: toolbar.widthAnchor).isActive = true
    navigation.widthAnchor.constraint(equalTo: toolbar.widthAnchor).isActive = true
    retryButton.target = self
    retryButton.action = #selector(retry)
    retryButton.bezelStyle = .rounded
    retryButton.isHidden = true
    for child in [toolbar, pdf, emptyLabel, retryButton] {
      child.translatesAutoresizingMaskIntoConstraints = false
      view.addSubview(child)
    }
    NSLayoutConstraint.activate([
      toolbar.topAnchor.constraint(equalTo: view.topAnchor, constant: 10),
      toolbar.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 12),
      toolbar.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -12),
      pdf.topAnchor.constraint(equalTo: toolbar.bottomAnchor, constant: 10),
      retryButton.topAnchor.constraint(equalTo: emptyLabel.bottomAnchor, constant: 12),
      retryButton.centerXAnchor.constraint(equalTo: pdf.centerXAnchor),
      emptyLabel.widthAnchor.constraint(lessThanOrEqualTo: pdf.widthAnchor, constant: -40),
      pdf.leadingAnchor.constraint(equalTo: view.leadingAnchor),
      pdf.trailingAnchor.constraint(equalTo: view.trailingAnchor),
      pdf.bottomAnchor.constraint(equalTo: view.bottomAnchor),
      emptyLabel.centerXAnchor.constraint(equalTo: pdf.centerXAnchor),
      emptyLabel.centerYAnchor.constraint(equalTo: pdf.centerYAnchor),
    ])
    for name in [
      Notification.Name.PDFViewScaleChanged, .PDFViewPageChanged, .PDFViewVisiblePagesChanged,
    ] {
      observations.append(
        NotificationCenter.default.addObserver(forName: name, object: pdf, queue: .main) {
          [weak self] _ in
          guard let self else { return }
          if name == .PDFViewScaleChanged && !self.restoring && !self.fitting {
            self.state?.fit = "manual"
            self.fitWork?.cancel()
          }
          self.scheduleStatusUpdate()
          if !self.restoring { self.stateChanged?() }
        })
    }
  }

  deinit {
    for observation in observations + searchObservations {
      NotificationCenter.default.removeObserver(observation)
    }
    pdf.document?.cancelFindString()
    fitWork?.cancel()
  }

  // Keep controls outside the interaction path: no per-gesture layout rebuilds,
  // page recreation, manual scroll correction, or document-state saves.
  private func scheduleStatusUpdate() {
    guard !statusUpdatePending else { return }
    statusUpdatePending = true
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { [weak self] in
      guard let self else { return }
      self.statusUpdatePending = false
      self.updateStatus()
    }
  }
  var visiblePage: PDFPage? {
    pdf.page(for: NSPoint(x: pdf.bounds.midX, y: pdf.bounds.midY), nearest: true) ?? pdf.currentPage
  }
  func updateStatus() {
    let start = ProcessInfo.processInfo.systemUptime
    defer { statusMaxMS = max(statusMaxMS, (ProcessInfo.processInfo.systemUptime - start) * 1000) }
    zoomLabel.stringValue = pdf.document == nil ? "—" : "\(Int(pdf.scaleFactor * 100))%"
    if let document = pdf.document, let page = visiblePage {
      let number = document.index(for: page) + 1
      if view.window?.firstResponder !== pageField.currentEditor() {
        pageField.stringValue = "\(number)"
      }
      pageLabel.stringValue = "/ \(document.pageCount)"
      if number != lastReportedPage {
        lastReportedPage = number
        if !restoring { pageChanged?(number) }
      }
    } else {
      pageLabel.stringValue = ""
    }
  }
  func open(_ url: URL, interactive: Bool = true) throws {
    _ = view
    let document = try readPDF(url)
    if document.isLocked && interactive {
      let alert = NSAlert()
      alert.messageText = "Unlock \(url.lastPathComponent)"
      alert.informativeText = "Enter the PDF password. It will not be saved."
      let password = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 280, height: 24))
      alert.accessoryView = password
      alert.addButton(withTitle: "Unlock")
      alert.addButton(withTitle: "Cancel")
      guard alert.runModal() == .alertFirstButtonReturn else { return }
      guard document.unlock(withPassword: password.stringValue) else {
        let error = NSAlert()
        error.messageText = "Incorrect PDF password"
        error.runModal()
        return
      }
    }
    guard !document.isLocked else {
      throw NativeError(message: "This PDF is locked. Choose Unlock to enter its password.")
    }
    pdf.document?.cancelFindString()
    for observation in searchObservations { NotificationCenter.default.removeObserver(observation) }
    searchObservations.removeAll()
    matches.removeAll()
    searchLabel.stringValue = ""
    pdf.document = document
    searchObservations.append(
      NotificationCenter.default.addObserver(
        forName: .PDFDocumentDidFindMatch, object: document, queue: .main
      ) { [weak self] note in
        guard let self, let selection = note.userInfo?["PDFDocumentFoundSelection"] as? PDFSelection
        else { return }
        self.matches.append(selection)
        self.searchLabel.stringValue = "\(self.matches.count)"
      })
    searchObservations.append(
      NotificationCenter.default.addObserver(
        forName: .PDFDocumentDidEndFind, object: document, queue: .main
      ) { [weak self] _ in self?.showMatch() })
    openedURL = url
    titleLabel.stringValue = url.lastPathComponent
    titleLabel.toolTip = url.path
    emptyLabel.isHidden = true
    retryButton.isHidden = true
    pdf.autoScales = true
    pdf.layoutDocumentView()
    updateStatus()
  }
  @objc func openFile() {
    didActivate?()
    let panel = NSOpenPanel()
    panel.allowedContentTypes = [.pdf]
    panel.allowsMultipleSelection = true
    panel.canChooseDirectories = false
    guard let window = view.window else { return }
    panel.beginSheetModal(for: window) { [weak self] result in
      if result == .OK { self?.openURLs?(panel.urls) }
    }
  }
  @objc func zoomIn() {
    didActivate?()
    state?.fit = "manual"
    pdf.autoScales = false
    pdf.zoomIn(nil)
  }
  @objc func zoomOut() {
    didActivate?()
    state?.fit = "manual"
    pdf.autoScales = false
    pdf.zoomOut(nil)
  }
  @objc func fitPage() { fit(wholePage: true) }
  @objc func fitWidth() { fit(wholePage: false) }
  private func fit(wholePage: Bool, navigate: Bool = true) {
    if !restoring { didActivate?() }
    fitting = true
    defer { fitting = false }
    state?.fit = wholePage ? "page" : "width"
    guard let page = visiblePage else { return }
    var size = page.bounds(for: pdf.displayBox).size
    if abs(page.rotation) % 180 == 90 { size = NSSize(width: size.height, height: size.width) }
    guard size.width > 0, size.height > 0 else { return }
    // PDFKit's autoScales in continuous mode can prefer width. Explicitly
    // calculate a whole-page fit for the Page button, outside gesture input.
    let widthScale = (pdf.bounds.width - 32) / size.width
    let heightScale = (pdf.bounds.height - 32) / size.height
    pdf.autoScales = false
    pdf.scaleFactor = max(
      pdf.minScaleFactor,
      min(pdf.maxScaleFactor, wholePage ? min(widthScale, heightScale) : widthScale))
    if wholePage && navigate { pdf.go(to: page) }
    updateStatus()
  }
  override func viewDidLayout() {
    super.viewDidLayout()
    guard view.bounds.size != lastSize else { return }
    lastSize = view.bounds.size
    guard !restoring, let fit = state?.fit, fit != "manual", pdf.document != nil else { return }
    fitWork?.cancel()
    let work = DispatchWorkItem { [weak self] in
      guard let self, self.state?.fit == fit else { return }
      self.restoring = true
      self.fit(wholePage: fit == "page", navigate: false)
      self.restoring = false
    }
    fitWork = work
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: work)
  }
  func load(_ state: DocumentState, interactive: Bool = true) {
    self.state = state
    restoring = true
    defer { restoring = false }
    do {
      try open(URL(fileURLWithPath: state.path), interactive: interactive)
      guard pdf.document != nil else { throw NativeError(message: "Unlock this PDF to read it.") }
      if state.rotation != 0, let document = pdf.document {
        for index in 0..<document.pageCount {
          if let page = document.page(at: index) {
            page.rotation = (page.rotation + state.rotation) % 360
          }
        }
      }
      restorePosition()
    } catch {
      titleLabel.stringValue = state.name
      emptyLabel.stringValue = error.localizedDescription
      emptyLabel.isHidden = false
      retryButton.isHidden = false
      retryButton.title =
        error.localizedDescription.contains("locked") ? "Unlock PDF" : "Retry opening"
    }
  }
  func restorePosition() {
    guard let state, let doc = pdf.document,
      let page = doc.page(at: min(doc.pageCount - 1, max(0, state.page - 1)))
    else { return }
    restoring = true
    defer { restoring = false }
    pdf.autoScales = false
    pdf.go(to: page)
    if state.fit == "manual" {
      pdf.scaleFactor = state.zoom
    } else {
      fit(wholePage: state.fit == "page")
    }
    pdf.layoutDocumentView()
    let bounds = page.bounds(for: pdf.displayBox)
    let point = NSPoint(
      x: state.pointX ?? bounds.minX,
      y: state.pointY ?? (bounds.maxY - bounds.height * (state.offset ?? 0)))
    pdf.go(to: PDFDestination(page: page, at: point))
    updateStatus()
  }
  func capture() {
    guard !restoring, let state, let document = pdf.document else { return }
    let top = NSPoint(
      x: pdf.bounds.minX + 20, y: pdf.isFlipped ? pdf.bounds.minY + 2 : pdf.bounds.maxY - 2)
    guard let page = pdf.page(for: top, nearest: true) else { return }
    let position = pdf.convert(top, to: page)
    state.page = document.index(for: page) + 1
    state.pointX = position.x
    state.pointY = position.y
    state.zoom = pdf.scaleFactor
    let bounds = page.bounds(for: pdf.displayBox)
    state.offset = max(0, min(0.999, (bounds.maxY - position.y) / max(1, bounds.height)))
  }
  @objc func retry() { if let state { load(state) } }
  @objc func jumpPage() { navigate(to: pageField.integerValue) }
  func navigate(to number: Int) {
    guard let doc = pdf.document,
      let page = doc.page(at: max(0, min(doc.pageCount - 1, number - 1)))
    else { return }
    pdf.go(to: page)
    updateStatus()
    stateChanged?()
  }
  @objc func rotatePages() {
    guard let document = pdf.document else { return }
    capture()
    let savedPage = state?.page ?? 1
    restoring = true
    for index in 0..<document.pageCount {
      if let page = document.page(at: index) { page.rotation = (page.rotation + 90) % 360 }
    }
    state?.rotation = ((state?.rotation ?? 0) + 90) % 360
    state?.pointX = nil
    state?.pointY = nil
    pdf.layoutDocumentView()
    navigate(to: savedPage)
    if state?.fit != "manual" { fit(wholePage: state?.fit == "page") }
    restoring = false
    stateChanged?()
  }
  @objc func toggleSearch() {
    searchVisible.toggle()
    searchRow.isHidden = !searchVisible
    if searchVisible {
      view.window?.makeFirstResponder(searchField)
    } else {
      pdf.document?.cancelFindString()
      pdf.clearSelection()
      view.window?.makeFirstResponder(pdf)
    }
  }
  @objc func findText() {
    guard let document = pdf.document else { return }
    document.cancelFindString()
    matches.removeAll()
    matchIndex = 0
    pdf.clearSelection()
    guard !searchField.stringValue.isEmpty else {
      searchLabel.stringValue = ""
      return
    }
    searchLabel.stringValue = "Searching…"
    document.beginFindString(searchField.stringValue, withOptions: .caseInsensitive)
  }
  @objc func nextMatch() {
    if !matches.isEmpty { matchIndex = (matchIndex + 1) % matches.count }
    showMatch()
  }
  @objc func previousMatch() {
    if !matches.isEmpty { matchIndex = (matchIndex + matches.count - 1) % matches.count }
    showMatch()
  }
  func showMatch() {
    guard !matches.isEmpty else {
      searchLabel.stringValue = "No matches"
      return
    }
    matchIndex = min(matchIndex, matches.count - 1)
    searchLabel.stringValue = "\(matchIndex + 1)/\(matches.count)"
    pdf.setCurrentSelection(matches[matchIndex], animate: false)
    pdf.go(to: matches[matchIndex])
    stateChanged?()
  }
}
