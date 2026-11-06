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
  private func capturedPage(_ id: String?) -> Int? {
    capturePanes()
    return workspace.documents.first { $0.id == id }?.page
  }
  /// One-click comparison: reuse views, keep reading state, never touch other workspaces.
  func checkCompareSideBySide(path: String, otherPath: String, thirdPath: String) {
    let original = workspace
    capturePanes()
    let before = session.views.map { ($0.id, $0.documents.map(\.id), $0.slots, $0.layout) }
    let compare = Workspace(name: "Compare")
    session.views.append(compare)
    session.active = compare.id
    compare.setLayout("single")
    refreshChrome()
    buildLayout()
    checks["compareMenuDisabledWithoutPDF"] = !(NSApp.mainMenu?.items.contains { top in
      top.submenu?.items.contains { $0.keyEquivalent == "\\" && validateMenuItem($0) } == true
    } ?? true)
    importURLs([URL(fileURLWithPath: otherPath)], target: 0)
    importURLs([URL(fileURLWithPath: path)], target: 0)
    let answersID = compare.documents[0].id
    let questionsID = compare.slots[0]!
    let left = panes[0]
    let leftPDF = left.pdf.document
    left.fitWidth()
    left.navigate(to: 3)
    compare.linked = true
    focusedOnly = true
    refreshChrome()
    buildLayout()
    // Pane button: the path available when the document list is hidden.
    checks["comparePaneButtonAccessible"] = left.compareControl.isEnabled
      && left.compareControl.toolTip == compareHelp
      && left.compareControl.accessibilityLabel()?.contains("questions.pdf") == true
    left.compareControl.performClick(nil)
    let copyID = compare.slots[1]
    let copy = compare.documents.first { $0.id == copyID }
    checks["compareOpensTwoIndependentViews"] = compare.layout == "columns"
      && compare.slots[0] == questionsID && copy?.path == path && copyID != questionsID
      && compare.documents.count == 3 && panes.count == 2 && panes[0] === left
      && left.pdf.document === leftPDF && panes[1].pdf.document != nil
      && panes[1].pdf.document !== leftPDF
    checks["compareCopiesReadingPosition"] = copy?.page == 3 && copy?.fit == "width"
    checks["compareRestoresLayoutAndUnlinks"] = !focusedOnly && !compare.linked
      && linkButton.state == .off && layoutPicker.indexOfSelectedItem == 1 && compare.focused == 1
    panes[1].navigate(to: 4)
    let split = splitController
    // Repeat from the document row, its context menu, and the menu command.
    let row = compare.filePaths.firstIndex(of: path)!
    checks["sidebarOneRowPerFile"] = table.numberOfRows == 2 && compare.documents.count == 3
    let rowButton = tableView(table, viewFor: nil, row: row)?.subviews
      .compactMap { $0 as? NSButton }.first
    checks["compareRowButtonAccessible"] = rowButton?.image != nil
      && rowButton?.toolTip == compareHelp
      && rowButton?.accessibilityLabel() == "Compare questions.pdf side by side"
    if let rowButton { NSApp.sendAction(rowButton.action!, to: rowButton.target, from: rowButton) }
    checks["compareContextMenuItem"] = documentMenu(row)?.items.first?.title == "Compare side by side"
    workspace.focused = 1
    checks["compareMenuEnabled"] = NSApp.mainMenu?.items.contains { top in
      top.submenu?.items.contains {
        $0.keyEquivalent == "\\" && $0.keyEquivalentModifierMask == .command && validateMenuItem($0)
      } == true
    } == true
    window.makeFirstResponder(panes[1].pdf)
    NSApp.sendAction(#selector(compareSideBySide), to: self, from: nil)
    checks["compareRepeatAddsNoCopies"] = compare.documents.count == 3
      && compare.slots == [questionsID, copyID] && splitController === split
      && capturedPage(questionsID) == 3 && capturedPage(copyID) == 4
    table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
    selectDocument()
    checks["compareSelectExistingSide"] = compare.focused == 1 && splitController === split
      && compare.slots == [questionsID, copyID] && compare.documents.count == 3
    // A hidden second view is reused with its own position, whichever view is chosen.
    compare.setLayout("single")
    buildLayout()
    compareDocument(copyID!)
    checks["compareReusesHiddenView"] = compare.documents.count == 3
      && compare.slots == [questionsID, copyID] && panes[0] === left
      && capturedPage(questionsID) == 3 && capturedPage(copyID) == 4
    // Multi-column layouts stay; only the neighbouring pane changes.
    importURLs([URL(fileURLWithPath: thirdPath)])
    let referenceID = compare.documents.last!.id
    compare.setLayout("triple")
    compare.slots = [answersID, questionsID, referenceID]
    buildLayout()
    compareDocument(questionsID)
    checks["compareKeepsMultiColumnLayout"] = compare.layout == "triple"
      && compare.slots == [answersID, questionsID, copyID]
      && compare.documents.count == 4 && panes.count == 3
    let existingPair = [copyID, questionsID, referenceID]
    compare.slots = existingPair
    checks["compareReusesLeftNeighborInMiddleColumn"] =
      compare.compare(questionsID) == .unchanged && compare.slots == existingPair
    compare.setLayout("grid")
    compare.slots = [answersID, referenceID, nil, questionsID]
    compare.compare(questionsID)
    checks["compareUsesLeftNeighbourAtRightEdge"] =
      compare.slots == [answersID, referenceID, copyID, questionsID]
    compare.setLayout("rows")
    compare.compare(answersID)
    checks["compareStackedBecomesSideBySide"] = compare.layout == "columns"
      && compare.documents.count == 5 && compare.slots[0] == answersID
      && compare.documents.first { $0.id == compare.slots[1] }?.path == otherPath
    buildLayout()
    do {
      let restored = try Session.restore(session.json()).views.first { $0.id == compare.id }!
      checks["compareStateRoundTrip"] = restored.slots == compare.slots
        && restored.documents.filter { $0.path == path }.map(\.page) == [3, 4]
    } catch { checks["compareStateRoundTrip"] = false }
    // Click an unselected real table row while a different PDF is showing.
    compare.setLayout("single")
    compare.assign(answersID, to: 0)
    refreshChrome()
    buildLayout()
    table.deselectAll(nil)
    let button = table.view(atColumn: 0, row: row, makeIfNecessary: true)?.subviews
      .compactMap { $0 as? NSButton }.first
    if let button {
      let point = button.convert(NSPoint(x: button.bounds.midX, y: button.bounds.midY), to: nil)
      func mouse(_ type: NSEvent.EventType) -> NSEvent {
        NSEvent.mouseEvent(with: type, location: point, modifierFlags: [],
          timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
          context: nil, eventNumber: 1, clickCount: 1, pressure: 1)!
      }
      NSApp.postEvent(mouse(.leftMouseUp), atStart: true)
      NSApp.sendEvent(mouse(.leftMouseDown))
      // Some AppKit versions deliver button mouse-up outside the tracking loop.
      if let up = NSApp.nextEvent(matching: .leftMouseUp, until: .distantPast,
        inMode: .default, dequeue: true) {
        NSApp.sendEvent(up)
      }
      RunLoop.current.run(until: Date().addingTimeInterval(0.1))
    }
    checks["compareFirstClickOnSidebarIcon"] = compare.layout == "columns"
      && Set(compare.slots.compactMap { $0 }) == Set([questionsID, copyID!])
    let entriesBeforeMove = Set(compare.documents.filter { $0.path == path }.map(\.id))
    compare.reorderFile(path, before: otherPath)
    checks["sidebarReorderKeepsBothPanes"] = compare.filePaths.first == path
      && Set(compare.slots.compactMap { $0 }) == entriesBeforeMove
    let destination = Workspace(name: "File move")
    session.views.append(destination)
    session.moveFile(questionsID, from: compare.id, to: destination.id)
    checks["sidebarMoveIncludesAllViews"] = !compare.filePaths.contains(path)
      && destination.filePaths == [path] && Set(destination.documents.map(\.id)) == entriesBeforeMove
    let sameName = "/another-folder/" + URL(fileURLWithPath: path).lastPathComponent
    destination.open(sameName)
    checks["sidebarSeparatesFilesWithSameName"] = destination.filePaths == [path, sameName]
    session.views.removeAll { $0 === destination }
    session.views.removeAll { $0 === compare }
    session.active = original.id
    refreshChrome()
    buildLayout()
    checks["compareLeavesOtherWorkspaces"] =
      session.views.map { ($0.id, $0.documents.map(\.id), $0.slots, $0.layout) }
      .elementsEqual(before) { $0.0 == $1.0 && $0.1 == $1.1 && $0.2 == $1.2 && $0.3 == $1.3 }
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
    let fixturePaths = originalWorkspace.documents.map(\.path)
    checkCompareSideBySide(
      path: firstDoc.path, otherPath: fixturePaths.first { $0.hasSuffix("answers.pdf") }!,
      thirdPath: fixturePaths.first { $0.hasSuffix("reference.pdf") }!)
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
