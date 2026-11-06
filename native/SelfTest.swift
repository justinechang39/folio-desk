import AppKit
import PDFKit

// Supply window-local coordinates so AppKit can dispatch without moving the user's mouse.
private final class TestWheelEvent: NSEvent {
  var target: NSWindow!
  var point = NSPoint.zero
  var delta: CGFloat = 1
  var modifiers: NSEvent.ModifierFlags = [.command]
  override var type: EventType { .scrollWheel }
  override var window: NSWindow? { target }
  override var locationInWindow: NSPoint { point }
  override var scrollingDeltaY: CGFloat { delta }
  override var hasPreciseScrollingDeltas: Bool { false }
  override var isDirectionInvertedFromDevice: Bool { false }
  override var momentumPhase: Phase { [] }
  override var modifierFlags: ModifierFlags { modifiers }
}

extension Application {
  private func checkWheelZoom() {
    let pane = panes[1]
    let otherScale = panes[0].pdf.scaleFactor
    let initial = pane.pdf.scaleFactor
    let wheel = TestWheelEvent()
    wheel.target = window
    wheel.point = pane.pdf.convert(NSPoint(x: pane.pdf.bounds.midX, y: pane.pdf.bounds.midY), to: nil)
    workspace.focused = 0
    wheel.modifiers = []
    checks["plainWheelPassesThrough"] = !pane.handleCommandScroll(wheel)
    wheel.modifiers = [.command]
    NSApp.sendEvent(wheel)
    checks["commandWheelZoomsHoveredPane"] = pane.pdf.scaleFactor > initial
      && pane.state?.fit == "manual" && workspace.focused == 1
      && panes[0].pdf.scaleFactor == otherScale
    wheel.delta = -1
    NSApp.sendEvent(wheel)
    checks["commandWheelZoomsBackOut"] = abs(pane.pdf.scaleFactor - initial) < 0.0001
  }

  func runRestoreTest() {
    let expected = Dictionary(
      uniqueKeysWithValues: panes.compactMap { pane -> (String, (Int, Double, Double?))? in
        guard let state = pane.state else { return nil }
        return (state.id, (state.page, state.zoom, state.pointY))
      })
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
      self.checks["relaunchLoadedNativeDocuments"] = self.panes.allSatisfy {
        $0.pdf.document != nil
      }
      self.checks["relaunchRestoredTabsAndAppearance"] =
        self.session.views.count == 3 && self.session.appearance.theme == "orange"
        && self.session.appearance.mode == "dark"
      self.capturePanes()
      self.checks["relaunchRestoredPageAndZoom"] = self.panes.allSatisfy { pane in
        guard let state = pane.state, let before = expected[state.id] else { return false }
        return state.page == before.0 && abs(state.zoom - before.1) < 0.02
      }
      self.checks["relaunchRestoredScrollPosition"] = self.panes.allSatisfy { pane in
        guard let state = pane.state, let before = expected[state.id], let y = before.2 else {
          return false
        }
        return abs((state.pointY ?? 0) - y) < 5
      }
      if let duplicate = self.session.views.first(where: { $0.name == "Moved documents" }) {
        let docs = duplicate.documents
        self.checks["relaunchKeepsIndependentCopies"] = docs.count == 2
          && docs[0].path == docs[1].path && docs[0].id != docs[1].id
          && docs[0].page != docs[1].page && docs[0].rotation != docs[1].rotation
        self.session.active = duplicate.id
        self.refreshChrome()
        self.buildLayout()
        self.checks["relaunchLoadsSamePDFTwice"] = self.panes.count == 2
          && self.panes.allSatisfy { $0.pdf.document != nil }
          && self.panes[0].pdf.document !== self.panes[1].pdf.document
      } else { self.checks["relaunchKeepsIndependentCopies"] = false }
      self.finishBenchmark(error: nil)
    }
  }
  func checkDuplicateViews(in duplicate: Workspace, path: String) {
    let original = workspace
    capturePanes()
    session.active = duplicate.id
    refreshChrome()
    buildLayout()
    let url = URL(fileURLWithPath: path)
    importURLs([url], target: 0)
    let leftID = duplicate.slots[0]!
    let leftPDF = panes[0].pdf.document
    importURLs([url], target: 1)
    checks["openSamePDFInBothPanes"] = duplicate.documents.count == 2
      && duplicate.slots[0] != duplicate.slots[1]
      && panes.allSatisfy { $0.pdf.document != nil }
      && panes[0].pdf.document === leftPDF
      && panes[0].pdf.document !== panes[1].pdf.document
    let ids = duplicate.slots
    importURLs([url], target: 1)
    checks["reopenCurrentPaneDoesNotAddCopies"] = duplicate.slots == ids && duplicate.documents.count == 2
    let oldRight = duplicate.slots[1]!
    duplicate.show(leftID, in: 1)
    duplicate.remove(oldRight)
    buildLayout()
    checks["sidebarCanOpenIndependentView"] = duplicate.slots[0] == leftID
      && duplicate.slots[1] != leftID && duplicate.documents.count == 2
    let rightScale = panes[1].pdf.scaleFactor
    let rightPage = panes[1].pdf.currentPage
    let rightRotation = panes[1].pdf.document!.page(at: 0)!.rotation
    panes[0].zoomIn()
    panes[0].navigate(to: 2)
    panes[0].rotatePages()
    capturePanes()
    checks["samePDFViewsAreIndependent"] = panes[1].pdf.scaleFactor == rightScale
      && panes[1].pdf.currentPage === rightPage
      && panes[1].pdf.document!.page(at: 0)!.rotation == rightRotation
    duplicate.setLayout("single")
    buildLayout()
    duplicate.setLayout("columns")
    buildLayout()
    checks["layoutKeepsSamePDFViews"] = duplicate.documents.count == 2
      && Set(duplicate.slots.compactMap { $0 }).count == 2
    // Moving a reading view must not merge it with an existing view of the same path.
    let moving = duplicate.slots[1]!
    capturePanes()
    session.move(moving, from: duplicate.id, to: original.id, slot: 1)
    checks["moveDoesNotMergeSameFileViews"] = original.documents.contains { $0.id == moving }
      && original.documents.filter { $0.path == path }.count == 2
    session.move(moving, from: original.id, to: duplicate.id, slot: 1)
    buildLayout()
    panes[0].navigate(to: 2)
    panes[1].navigate(to: 1)
    capturePanes()
    do {
      let restored = try Session.restore(session.json())
      let copy = restored.views.first { $0.id == duplicate.id }!
      checks["samePDFStateRoundTrip"] = copy.slots == duplicate.slots
        && copy.documents.count == 2
        && copy.documents[0].page != copy.documents[1].page
        && copy.documents[0].rotation != copy.documents[1].rotation
    } catch { checks["samePDFStateRoundTrip"] = false }
    session.active = original.id
    refreshChrome()
    buildLayout()
  }
  func runSelfTest() {
    if arguments.contains("--restore") {
      runRestoreTest()
      return
    }
    checks["legacySessionLoaded"] =
      session.views.count >= 2 && workspace.documents.count >= 3 && panes.count == 2
    checks["twoNativeDocumentsLoaded"] = panes.allSatisfy { $0.pdf.document != nil }
    guard let first = panes.first, let firstDoc = first.state, let pdf = first.pdf.document else {
      finishBenchmark(error: "Missing native fixture documents")
      return
    }
    checkWheelZoom()
    let originalWorkspace = workspace
    let originalIDs = Set(originalWorkspace.documents.map(\.id))
    let originalTabCount = session.views.count
    let originalPDF = pdf
    session.appearance.theme = "nord"
    session.appearance.mode = "dark"
    applyAppearance()
    checks["themeDoesNotReloadPDF"] = first.pdf.document === originalPDF
    for layout in ["grid", "triple", "rows", "single", "columns"] {
      capturePanes()
      workspace.setLayout(layout)
      buildLayout()
      checks["layout-\(layout)"] =
        panes.count == paneCount(layout) && Set(workspace.documents.map(\.id)) == originalIDs
    }
    checks["visiblePDFRetainedAcrossLayouts"] = paneCache[firstDoc.id]?.pdf.document === originalPDF
    workspace.assign(firstDoc.id, to: 1)
    buildLayout()
    checks["swapPreservesDocuments"] =
      workspace.slots[1] == firstDoc.id && Set(workspace.documents.map(\.id)) == originalIDs
    let moved = Workspace(name: "Moved documents")
    session.views.append(moved)
    capturePanes()
    session.move(firstDoc.id, from: originalWorkspace.id, to: moved.id, slot: 0)
    session.active = moved.id
    refreshChrome()
    buildLayout()
    checks["moveAcrossTabs"] =
      workspace.documents.first?.id == firstDoc.id
      && !originalWorkspace.documents.contains(where: { $0.id == firstDoc.id })
      && panes[0].pdf.document != nil
    session.move(firstDoc.id, from: moved.id, to: originalWorkspace.id, slot: 0)
    session.active = originalWorkspace.id
    refreshChrome()
    buildLayout()
    checks["moveBack"] =
      Set(workspace.documents.map(\.id)) == originalIDs
      && session.views.count == originalTabCount + 1
    checkDuplicateViews(in: moved, path: firstDoc.path)
    guard let pane = paneCache[firstDoc.id] else {
      finishBenchmark(error: "Missing moved PDF")
      return
    }
    let unchangedScale = panes[1].pdf.scaleFactor
    pane.zoomIn()
    checks["independentZoom"] = panes[1].pdf.scaleFactor == unchangedScale
    pane.navigate(to: 2)
    pane.capture()
    checks["nativePositionCaptured"] =
      firstDoc.pointX != nil && firstDoc.pointY != nil && firstDoc.zoom > 0
    let before = pane.pdf.document!.page(at: 0)!.rotation
    pane.rotatePages()
    checks["rotation"] = pane.pdf.document!.page(at: 0)!.rotation == (before + 90) % 360
    for _ in 0..<3 { pane.rotatePages() }
    pane.fitPage()
    pane.pdf.layoutDocumentView()
    if let page = pane.visiblePage {
      let rect = pane.pdf.convert(page.bounds(for: pane.pdf.displayBox), from: page)
      checks["fitPage"] =
        rect.height <= pane.pdf.bounds.height && rect.width <= pane.pdf.bounds.width
    }
    pane.lastSize = .zero
    pane.viewDidLayout()
    pane.zoomIn()
    let manualScale = pane.pdf.scaleFactor
    pane.searchField.stringValue = "momentum"
    pane.findText()
    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
      self.checks["nativeSearch"] = !pane.matches.isEmpty
      self.checks["manualZoomCancelsPendingFit"] =
        pane.state?.fit == "manual" && abs(pane.pdf.scaleFactor - manualScale) < 0.001
      pane.navigate(to: 2)
      pane.capture()
      self.session.appearance = Appearance(theme: "orange", mode: "dark")
      self.workspace.assign(firstDoc.id, to: 0)
      if let other = self.workspace.documents.first(where: { $0.id != firstDoc.id }) {
        self.workspace.assign(other.id, to: 1)
      }
      self.refreshChrome()
      self.buildLayout()
      self.applyAppearance()
      self.root.view.layoutSubtreeIfNeeded()
      self.checks["panesFillAvailableWidth"] =
        self.paneHost.frame.width > self.window.contentView!.bounds.width - 260
      do {
        try self.flushSave()
        let restored = try Session.restore(bridge(["op": "load"]))
        self.checks["savedTabsAndTheme"] =
          restored.views.count == self.session.views.count && restored.appearance.theme == "orange"
          && restored.appearance.mode == "dark"
        let restoredDoc = restored.current.documents.first { $0.id == firstDoc.id }
        self.checks["savedPositionAndZoom"] =
          abs((restoredDoc?.pointY ?? .infinity) - (firstDoc.pointY ?? 0)) < 0.000001
          && abs((restoredDoc?.zoom ?? .infinity) - firstDoc.zoom) < 0.000001
          && restoredDoc?.page == firstDoc.page
        self.checks["originalDocumentsPreserved"] =
          Set(restored.current.documents.map(\.id)) == originalIDs
        self.finishBenchmark(error: nil)
      } catch { self.finishBenchmark(error: error.localizedDescription) }
    }
  }
}
