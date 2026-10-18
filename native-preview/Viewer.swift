import AppKit
import PDFKit
import UniformTypeIdentifiers

private let accent = NSColor.systemOrange

private func button(_ title: String, _ target: AnyObject, _ action: Selector, help: String) -> NSButton {
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
        case .unreadable: return "This PDF could not be opened. Check that it is downloaded and you have permission to read it."
        }
    }
}

private func readPDF(_ url: URL) throws -> PDFDocument {
    guard url.isFileURL, url.pathExtension.lowercased() == "pdf" else { throw FileError.notPDF }
    let file = try FileHandle(forReadingFrom: url)
    defer { try? file.close() }
    let header = try file.read(upToCount: 1024) ?? Data()
    guard header.range(of: Data("%PDF-".utf8)) != nil else { throw FileError.notPDF }
    guard let document = PDFDocument(url: url), document.isLocked || document.pageCount > 0 else { throw FileError.unreadable }
    return document
}

private final class DropPDFView: PDFView {
    var openURLs: (([URL]) -> Void)?
    var activate: (() -> Void)?
    override func mouseDown(with event: NSEvent) {
        activate?()
        super.mouseDown(with: event)
    }
    override func magnify(with event: NSEvent) {
        activate?()
        super.magnify(with: event)
    }
    private func urls(_ sender: NSDraggingInfo) -> [URL] {
        sender.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
    }
    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        let files = urls(sender)
        return !files.isEmpty && files.allSatisfy { $0.pathExtension.lowercased() == "pdf" } ? .copy : []
    }
    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation { draggingEntered(sender) }
    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool { !urls(sender).isEmpty }
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let files = urls(sender)
        guard !files.isEmpty else { return false }
        activate?()
        openURLs?(files)
        return true
    }
}

private final class Pane: NSViewController {
    let pdf = DropPDFView()
    let titleLabel = NSTextField(labelWithString: "Open a PDF")
    let pageLabel = NSTextField(labelWithString: "")
    let zoomLabel = NSTextField(labelWithString: "—")
    let emptyLabel = NSTextField(wrappingLabelWithString: "Drop a PDF here\nor choose Open")
    var didActivate: (() -> Void)?
    var openURLs: (([URL]) -> Void)?
    var openedURL: URL?
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
        heading.addArrangedSubview(button("Open…", self, #selector(openFile), help: "Open a PDF in this pane"))
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
        controls.addArrangedSubview(pageLabel)
        pdf.displayMode = .singlePageContinuous
        pdf.displayDirection = .vertical
        pdf.displaysPageBreaks = true
        pdf.pageBreakMargins = NSEdgeInsets(top: 8, left: 8, bottom: 8, right: 8)
        pdf.backgroundColor = .underPageBackgroundColor
        pdf.minScaleFactor = 0.1
        pdf.maxScaleFactor = 8
        pdf.autoScales = true
        pdf.registerForDraggedTypes([.fileURL])
        pdf.activate = { [weak self] in self?.didActivate?() }
        pdf.openURLs = { [weak self] urls in self?.openURLs?(urls) }
        emptyLabel.alignment = .center
        emptyLabel.font = .systemFont(ofSize: 17, weight: .medium)
        emptyLabel.textColor = .secondaryLabelColor
        emptyLabel.isSelectable = false
        for child in [heading, controls, pdf, emptyLabel] {
            child.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(child)
        }
        NSLayoutConstraint.activate([
            heading.topAnchor.constraint(equalTo: view.topAnchor, constant: 12),
            heading.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 14),
            heading.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -14),
            controls.topAnchor.constraint(equalTo: heading.bottomAnchor, constant: 8),
            controls.leadingAnchor.constraint(equalTo: heading.leadingAnchor),
            controls.trailingAnchor.constraint(equalTo: heading.trailingAnchor),
            pdf.topAnchor.constraint(equalTo: controls.bottomAnchor, constant: 10),
            pdf.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            pdf.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            pdf.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            emptyLabel.centerXAnchor.constraint(equalTo: pdf.centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: pdf.centerYAnchor),
        ])
        for name in [Notification.Name.PDFViewScaleChanged, .PDFViewPageChanged, .PDFViewVisiblePagesChanged] {
            observations.append(NotificationCenter.default.addObserver(forName: name, object: pdf, queue: .main) { [weak self] _ in
                self?.scheduleStatusUpdate()
            })
        }
    }

    deinit { for observation in observations { NotificationCenter.default.removeObserver(observation) } }

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
            pageLabel.stringValue = "\(document.index(for: page) + 1) / \(document.pageCount)"
        } else { pageLabel.stringValue = "" }
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
        guard !document.isLocked else { throw FileError.unreadable }
        pdf.document = document
        openedURL = url
        titleLabel.stringValue = url.lastPathComponent
        titleLabel.toolTip = url.path
        emptyLabel.isHidden = true
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
    @objc func zoomIn() { didActivate?(); pdf.autoScales = false; pdf.zoomIn(nil) }
    @objc func zoomOut() { didActivate?(); pdf.autoScales = false; pdf.zoomOut(nil) }
    @objc func fitPage() { fit(wholePage: true) }
    @objc func fitWidth() { fit(wholePage: false) }
    private func fit(wholePage: Bool) {
        didActivate?()
        guard let page = visiblePage else { return }
        var size = page.bounds(for: pdf.displayBox).size
        if abs(page.rotation) % 180 == 90 { size = NSSize(width: size.height, height: size.width) }
        guard size.width > 0, size.height > 0 else { return }
        // PDFKit's autoScales in continuous mode can prefer width. Explicitly
        // calculate a whole-page fit for the Page button, outside gesture input.
        let widthScale = (pdf.bounds.width - 32) / size.width
        let heightScale = (pdf.bounds.height - 32) / size.height
        pdf.autoScales = false
        pdf.scaleFactor = max(pdf.minScaleFactor, min(pdf.maxScaleFactor, wholePage ? min(widthScale, heightScale) : widthScale))
        if wholePage { pdf.go(to: page) }
        updateStatus()
    }
}

private final class Application: NSObject, NSApplicationDelegate, NSWindowDelegate {
    var window: NSWindow!
    let panes = [Pane(), Pane()]
    var activePane = 0
    var arguments: [String]
    var heartbeat: Timer?
    var stressTimer: Timer?
    var gaps: [Double] = []
    var operationTimes: [Double] = []
    var lastTick = 0.0
    var tickCount = 0
    var stressStep = 0
    var reportPath: String?
    var inputMonitor: Any?
    var benchmark = false
    var activity: NSObjectProtocol?
    var activeTicks = 0
    var checks: [String: Bool] = [:]

    init(arguments: [String]) { self.arguments = arguments }
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        makeMenu()
        let split = NSSplitViewController()
        for (index, pane) in panes.enumerated() {
            let item = NSSplitViewItem(viewController: pane)
            item.minimumThickness = 340
            split.addSplitViewItem(item)
            pane.didActivate = { [weak self] in self?.activePane = index }
            pane.openURLs = { [weak self] urls in self?.open(urls, startingAt: index) }
        }
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1180, height: 820), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = "Folio Native Preview"
        window.subtitle = "PDFKit experiment · independent scroll and pinch"
        window.minSize = NSSize(width: 740, height: 440)
        window.contentViewController = split
        window.setContentSize(NSSize(width: 1180, height: 820))
        window.delegate = self
        window.isReleasedWhenClosed = false
        window.center()
        window.makeKeyAndOrderFront(nil)
        // PDFKit's internal subviews can receive events before PDFView does.
        // Observe only our own window to route toolbar/menu shortcuts correctly.
        inputMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .scrollWheel, .magnify]) { [weak self] event in
            guard let self, event.window === self.window else { return event }
            for (index, pane) in self.panes.enumerated() {
                if pane.view.bounds.contains(pane.view.convert(event.locationInWindow, from: nil)) { self.activePane = index }
            }
            return event
        }
        NSApp.activate(ignoringOtherApps: true)
        if let index = arguments.firstIndex(of: "--report"), arguments.indices.contains(index + 1) {
            reportPath = arguments[index + 1]
            arguments.removeSubrange(index...(index + 1))
        }
        benchmark = arguments.contains("--benchmark")
        arguments.removeAll { $0 == "--benchmark" || $0.hasPrefix("-psn_") }
        if benchmark {
            do {
                guard arguments.count == 2 else { throw FileError.notPDF }
                for (index, path) in arguments.enumerated() { try panes[index].open(URL(fileURLWithPath: path), interactive: false) }
                checks["twoDocumentsLoaded"] = panes.allSatisfy { ($0.pdf.document?.pageCount ?? 0) > 0 }
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) { self.beginBenchmark() }
            } catch { finishBenchmark(error: error.localizedDescription) }
        } else { open(arguments.map { URL(fileURLWithPath: $0) }, startingAt: 0) }
    }
    func open(_ urls: [URL], startingAt index: Int) {
        guard !urls.isEmpty else { return }
        if urls.count > 2 {
            let alert = NSAlert()
            alert.messageText = "This preview has two panes"
            alert.informativeText = "Choose one or two PDFs. Folio Desk’s workspaces remain available in the main app."
            alert.beginSheetModal(for: window)
            return
        }
        for (offset, url) in urls.enumerated() {
            do { try panes[(index + offset) % 2].open(url) }
            catch {
                let alert = NSAlert(error: error)
                alert.beginSheetModal(for: window)
                break
            }
        }
    }
    func applicationWillTerminate(_ notification: Notification) {
        if let inputMonitor { NSEvent.removeMonitor(inputMonitor) }
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
    @objc func openFiles() { panes[activePane].openFile() }
    @objc func zoomIn() { panes[activePane].zoomIn() }
    @objc func zoomOut() { panes[activePane].zoomOut() }
    @objc func fit() { panes[activePane].fitPage() }
    @objc func swap() {
        let left = panes[0].pdf.document
        let right = panes[1].pdf.document
        let leftURL = panes[0].openedURL
        let rightURL = panes[1].openedURL
        // PDFDocuments are shared by reference; no rereading or raster copies.
        for (pane, document, url) in [(panes[0], right, rightURL), (panes[1], left, leftURL)] {
            pane.pdf.document = document
            pane.openedURL = url
            pane.titleLabel.stringValue = url?.lastPathComponent ?? "Open a PDF"
            pane.titleLabel.toolTip = url?.path
            pane.emptyLabel.isHidden = document != nil
            pane.pdf.autoScales = true
            pane.updateStatus()
        }
    }
    func makeMenu() {
        let menu = NSMenu()
        func submenu(_ name: String) -> NSMenu {
            let item = NSMenuItem()
            let child = NSMenu(title: name)
            item.submenu = child
            menu.addItem(item)
            return child
        }
        func add(_ menu: NSMenu, _ title: String, _ action: Selector, _ key: String, target: AnyObject? = nil) {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
            item.target = target
            menu.addItem(item)
        }
        let app = submenu("Folio Native Preview")
        add(app, "Quit Folio Native Preview", #selector(NSApplication.terminate(_:)), "q", target: NSApp)
        let file = submenu("File")
        add(file, "Open PDFs…", #selector(openFiles), "o", target: self)
        add(file, "Close Window", #selector(NSWindow.performClose(_:)), "w")
        let edit = submenu("Edit")
        add(edit, "Copy", #selector(NSText.copy(_:)), "c")
        add(edit, "Select All", #selector(NSText.selectAll(_:)), "a")
        let view = submenu("View")
        add(view, "Zoom In", #selector(zoomIn), "+", target: self)
        add(view, "Zoom Out", #selector(zoomOut), "-", target: self)
        add(view, "Fit Page", #selector(fit), "0", target: self)
        add(view, "Swap PDFs", #selector(swap), "", target: self)
        NSApp.mainMenu = menu
    }

    // Automated workload measures main-run-loop stalls, not display frame times
    // or physical trackpad feel. Actual gestures must still be tried by a user.
    func beginBenchmark() {
        activity = ProcessInfo.processInfo.beginActivity(options: [.userInitiatedAllowingIdleSystemSleep], reason: "Measure native PDF interaction without App Nap throttling")
        let unchangedScale = panes[1].pdf.scaleFactor
        panes[0].pdf.autoScales = false
        panes[0].pdf.scaleFactor = unchangedScale * 1.2
        checks["independentZoom"] = panes[1].pdf.scaleFactor == unchangedScale
        let unchangedPage = panes[1].pdf.currentPage
        if let document = panes[0].pdf.document, let page = document.page(at: min(2, document.pageCount - 1)) { panes[0].pdf.go(to: page) }
        checks["independentNavigation"] = panes[1].pdf.currentPage === unchangedPage
        for pane in panes { pane.pdf.autoScales = false }
        lastTick = ProcessInfo.processInfo.systemUptime
        heartbeat = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            guard let self else { return }
            let now = ProcessInfo.processInfo.systemUptime
            self.gaps.append((now - self.lastTick) * 1000)
            self.lastTick = now
            self.tickCount += 1
            if NSApp.isActive { self.activeTicks += 1 }
        }
        RunLoop.main.add(heartbeat!, forMode: .common)
        stressTimer = Timer(timeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in self?.stress() }
        RunLoop.main.add(stressTimer!, forMode: .common)
    }
    func stress() {
        let start = ProcessInfo.processInfo.systemUptime
        let pane = panes[(stressStep / 120) % 2]
        let phase = Double(stressStep % 120) / 119.0
        // Smooth zoom in/out, alternating panes, plus continuous movement.
        pane.pdf.scaleFactor = 0.4 + 2.1 * (1 - cos(phase * 2 * .pi)) / 2
        if let scroll = findScroll(pane.pdf), let content = scroll.documentView {
            let limit = max(0, content.bounds.height - scroll.contentView.bounds.height)
            var origin = scroll.contentView.bounds.origin
            origin.y = min(limit, max(0, origin.y + 18))
            scroll.contentView.scroll(to: origin)
            scroll.reflectScrolledClipView(scroll.contentView)
        }
        operationTimes.append((ProcessInfo.processInfo.systemUptime - start) * 1000)
        stressStep += 1
        if stressStep >= 1800 {
            stressTimer?.invalidate()
            heartbeat?.invalidate()
            checks["completed1800ZoomScrollSteps"] = true
            checks["documentsStillLoaded"] = panes.allSatisfy { ($0.pdf.document?.pageCount ?? 0) > 0 }
            for pane in panes { pane.fitPage(); pane.pdf.layoutDocumentView() }
            checks["fitPageFitsViewport"] = panes.allSatisfy { pane in
                guard let page = pane.visiblePage else { return false }
                let box = pane.pdf.convert(page.bounds(for: pane.pdf.displayBox), from: page)
                return box.width <= pane.pdf.bounds.width && box.height <= pane.pdf.bounds.height
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { self.finishBenchmark(error: nil) }
        }
    }
    func findScroll(_ view: NSView) -> NSScrollView? {
        if let scroll = view as? NSScrollView { return scroll }
        for child in view.subviews { if let scroll = findScroll(child) { return scroll } }
        return nil
    }
    func finishBenchmark(error: String?) {
        func percentile(_ values: [Double], _ p: Double) -> Double {
            let sorted = values.sorted()
            return sorted.isEmpty ? 0 : sorted[min(sorted.count - 1, Int(Double(sorted.count - 1) * p))]
        }
        var report: [String: Any] = [
            "renderer": "PDFKit", "steps": stressStep, "heartbeatSamples": tickCount,
            "activeHeartbeatSamples": activeTicks, "appNapSuppressedForBenchmark": activity != nil,
            "statusUpdateMaxMS": panes.map { $0.statusMaxMS }.max() ?? 0,
            "heartbeatGapP50MS": percentile(gaps, 0.5), "heartbeatGapP95MS": percentile(gaps, 0.95),
            "heartbeatGapMaxMS": gaps.max() ?? 0, "heartbeatGapsOver100MS": gaps.filter { $0 > 100 }.count,
            "zoomScrollCallP95MS": percentile(operationTimes, 0.95), "checks": checks,
            "note": "Main-run-loop timer gaps; not display frame times. Programmatic scale/scroll; not physical gesture input."
        ]
        if let error { report["error"] = error }
        if let reportPath {
            // PDFKit uses layer-backed drawing which cacheDisplay omits.
            // Capture only this test window, and only with existing permission.
            if error == nil && CGPreflightScreenCaptureAccess() {
                let capture = Process()
                capture.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
                capture.arguments = ["-x", "-l", String(window.windowNumber), reportPath + ".png"]
                do {
                    try capture.run()
                    capture.waitUntilExit()
                    report["snapshotAvailable"] = capture.terminationStatus == 0
                } catch { report["snapshotAvailable"] = false }
            } else { report["snapshotAvailable"] = false }
            do {
                let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
                try data.write(to: URL(fileURLWithPath: reportPath), options: .atomic)
            } catch { fputs("Could not write benchmark report: \(error)\n", stderr); exit(2) }
        }
        if let activity { ProcessInfo.processInfo.endActivity(activity) }
        exit(error == nil && !checks.values.contains(false) ? 0 : 1)
    }
}

@_cdecl("folio_native_run")
public func folioNativeRun(_ argumentData: UnsafePointer<CChar>) -> Int32 {
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
