import AppKit
import PDFKit

extension Application {
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
      self.finishBenchmark(error: nil)
    }
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
