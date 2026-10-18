import AppKit
import PDFKit

extension Application {
  // Automated workload measures main-run-loop stalls, not display frame times
  // or physical trackpad feel. Actual gestures must still be tried by a user.
  func beginBenchmark() {
    activity = ProcessInfo.processInfo.beginActivity(
      options: [.userInitiatedAllowingIdleSystemSleep],
      reason: "Measure native PDF interaction without App Nap throttling")
    let unchangedScale = panes[1].pdf.scaleFactor
    panes[0].pdf.autoScales = false
    panes[0].pdf.scaleFactor = unchangedScale * 1.2
    checks["independentZoom"] = panes[1].pdf.scaleFactor == unchangedScale
    let unchangedPage = panes[1].pdf.currentPage
    if let document = panes[0].pdf.document,
      let page = document.page(at: min(2, document.pageCount - 1))
    {
      panes[0].pdf.go(to: page)
    }
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
      for pane in panes {
        pane.fitPage()
        pane.pdf.layoutDocumentView()
      }
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
      "heartbeatGapMaxMS": gaps.max() ?? 0,
      "heartbeatGapsOver100MS": gaps.filter { $0 > 100 }.count,
      "zoomScrollCallP95MS": percentile(operationTimes, 0.95), "checks": checks,
      "note":
        "Main-run-loop timer gaps; not display frame times. Programmatic scale/scroll; not physical gesture input.",
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
      } else {
        report["snapshotAvailable"] = false
      }
      do {
        let data = try JSONSerialization.data(
          withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: URL(fileURLWithPath: reportPath), options: .atomic)
      } catch {
        fputs("Could not write benchmark report: \(error)\n", stderr)
        exit(2)
      }
    }
    if let activity { ProcessInfo.processInfo.endActivity(activity) }
    exit(error == nil && !checks.values.contains(false) ? 0 : 1)
  }
}
