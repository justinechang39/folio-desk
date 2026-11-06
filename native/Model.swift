import AppKit
import Foundation

typealias RustRequest = @convention(c) (UnsafePointer<CChar>?) -> UnsafeMutablePointer<CChar>?
typealias RustRelease = @convention(c) (UnsafeMutablePointer<CChar>?) -> Void
var rustRequest: RustRequest!
var rustRelease: RustRelease!
struct NativeError: LocalizedError {
  let message: String
  var errorDescription: String? { message }
}
func bridge(_ request: [String: Any]) throws -> Any {
  let data = try JSONSerialization.data(withJSONObject: request)
  let text = String(data: data, encoding: .utf8)!
  guard let pointer = text.withCString({ rustRequest($0) }) else {
    throw NativeError(message: "Native storage is unavailable.")
  }
  defer { rustRelease(pointer) }
  let response =
    try JSONSerialization.jsonObject(with: Data(String(cString: pointer).utf8)) as! [String: Any]
  if let error = response["error"] as? String { throw NativeError(message: error) }
  return response["value"] ?? NSNull()
}
let layoutNames = [
  ("single", "Single"), ("columns", "Side by side"), ("rows", "Stacked"),
  ("triple", "Three columns"), ("grid", "2 × 2"),
]
func paneCount(_ layout: String) -> Int {
  ["single": 1, "columns": 2, "rows": 2, "triple": 3, "grid": 4][layout] ?? 2
}
final class DocumentState: Codable {
  var id = UUID().uuidString
  var path: String
  var name: String
  var page = 1
  var zoom = 1.0
  var fit = "page"
  var rotation = 0
  var offset: Double? = 0
  var pointX: Double?
  var pointY: Double?
  init(path: String) {
    self.path = path
    name = URL(fileURLWithPath: path).lastPathComponent
  }
  func independentCopy() -> DocumentState {
    let copy = DocumentState(path: path)
    copy.name = name
    copy.page = page; copy.zoom = zoom; copy.fit = fit; copy.rotation = rotation
    copy.offset = offset; copy.pointX = pointX; copy.pointY = pointY
    return copy
  }
}
enum CompareResult { case unavailable, unchanged, arranged }
final class Workspace: Codable {
  var id = UUID().uuidString
  var name = "Workspace 1"
  var layout = "columns"
  var documents: [DocumentState] = []
  var slots: [String?] = [nil, nil]
  var focused = 0
  var linked = false
  init(name: String = "Workspace 1") { self.name = name }
  var filePaths: [String] {
    var seen = Set<String>()
    return documents.compactMap { seen.insert($0.path).inserted ? $0.path : nil }
  }
  func readingView(for path: String) -> DocumentState? {
    let views = documents.filter { $0.path == path }
    return views.first { $0.id == slots[focused] }
      ?? views.first { slots.contains($0.id) } ?? views.first
  }
  // Reorder the whole file relative to the drop target without changing any pane.
  func reorderFile(_ path: String, before nextPath: String?) {
    guard path != nextPath else { return }
    let views = documents.filter { $0.path == path }
    documents.removeAll { $0.path == path }
    let index = documents.firstIndex { $0.path == nextPath } ?? documents.endIndex
    documents.insert(contentsOf: views, at: index)
  }
  func assign(_ id: String, to slot: Int) {
    guard slots.indices.contains(slot), documents.contains(where: { $0.id == id }) else { return }
    if let old = slots.firstIndex(of: id), old != slot { slots[old] = slots[slot] }
    slots[slot] = id
    focused = slot
  }
  /// Opening a visible document elsewhere creates an independent reading view.
  /// Explicit drag moves still use assign(), which swaps the existing views.
  func show(_ id: String, in slot: Int) {
    guard slots.indices.contains(slot), let doc = documents.first(where: { $0.id == id }) else { return }
    if slots.contains(id), slots[slot] != id {
      let copy = doc.independentCopy()
      documents.append(copy)
      assign(copy.id, to: slot)
    } else { assign(id, to: slot) }
  }
  @discardableResult
  func open(_ path: String, in target: Int? = nil) -> DocumentState {
    let slot = target ?? slots.firstIndex(of: nil)
    if let slot, slots.indices.contains(slot),
      let current = documents.first(where: { $0.id == slots[slot] && $0.path == path }) {
      focused = slot
      return current
    }
    // Reuse an unshown reading view first; a visible view must retain its own state.
    let existing = documents.first { $0.path == path && !slots.contains($0.id) }
      ?? (slot == nil ? documents.first { $0.path == path } : nil)
    let doc = existing ?? documents.first(where: { $0.path == path })?.independentCopy()
      ?? DocumentState(path: path)
    if !documents.contains(where: { $0.id == doc.id }) { documents.append(doc) }
    if let slot { assign(doc.id, to: slot) }
    return doc
  }
  /// Shows two independent views of a document's PDF in horizontally adjacent panes.
  /// Another view of the same file is reused before a copy is made, so repeated
  /// requests never add copies or reset either view's reading position.
  @discardableResult
  func compare(_ id: String) -> CompareResult {
    guard let doc = documents.first(where: { $0.id == id }) else { return .unavailable }
    let others = documents.filter { $0.path == doc.path && $0.id != id }
    let partner = others.first { slots.contains($0.id) } ?? others.first
    // Multi-column layouts already have adjacent panes; other layouts become Side by side.
    let keepsLayout = ["columns", "triple", "grid"].contains(layout)
    if !keepsLayout { setLayout("columns") }
    // Keep whichever view is already visible in place; otherwise use the active pane.
    let anchor =
      partner.flatMap { slots.contains($0.id) && !slots.contains(id) ? $0.id : nil } ?? id
    let anchorSlot = slots.firstIndex(of: anchor) ?? focused
    // In three columns the middle pane has neighbors on both sides. Prefer
    // an existing comparison, then an empty pane, before displacing a reader.
    let neighbors = [anchorSlot + 1, anchorSlot - 1].filter {
      slots.indices.contains($0) && (layout != "grid" || $0 / 2 == anchorSlot / 2)
    }
    if keepsLayout, anchor == id, slots[anchorSlot] == id,
      neighbors.contains(where: { slot in others.contains { $0.id == slots[slot] } })
    {
      return .unchanged
    }
    guard let neighbor = neighbors.first(where: { slots[$0] == nil }) ?? neighbors.first else {
      return .unavailable
    }
    let other = partner ?? doc.independentCopy()
    if partner == nil { documents.append(other) }
    assign(anchor, to: anchorSlot)
    assign(anchor == id ? other.id : id, to: neighbor)
    // Linked pages would pull both views of one file onto the same page.
    linked = false
    return .arranged
  }
  func setLayout(_ value: String) {
    layout = value
    let count = paneCount(value)
    slots = Array(slots.prefix(count))
    var unused = documents.filter { !slots.contains($0.id) }
    while slots.count < count { slots.append(unused.isEmpty ? nil : unused.removeFirst().id) }
    focused = min(focused, count - 1)
  }
  func remove(_ id: String) {
    documents.removeAll { $0.id == id }
    slots = slots.map { $0 == id ? nil : $0 }
  }
}
struct Appearance: Codable {
  var theme = "orange"
  var mode = "system"
}
final class Session: Codable {
  var version = 1
  var active: String
  var views: [Workspace]
  var sidebar = true
  var appearance = Appearance()
  init() {
    let view = Workspace()
    views = [view]
    active = view.id
  }
  var current: Workspace { views.first { $0.id == active } ?? views[0] }
  static func restore(_ value: Any) throws -> Session {
    if value is NSNull { return Session() }
    let session = try JSONDecoder().decode(
      Session.self, from: JSONSerialization.data(withJSONObject: value))
    guard session.version == 1, !session.views.isEmpty, session.views.count <= 100,
      Set(session.views.map(\.id)).count == session.views.count
    else {
      throw NativeError(
        message: "Unsupported saved workspace format. Your original session is preserved.")
    }
    for workspace in session.views {
      guard layoutNames.contains(where: { $0.0 == workspace.layout }),
        Set(workspace.documents.map(\.id)).count == workspace.documents.count
      else {
        throw NativeError(
          message: "A saved workspace is damaged. Your original session is preserved.")
      }
      workspace.name = String(workspace.name.prefix(80))
      var seen = Set<String>()
      workspace.slots = (0..<paneCount(workspace.layout)).map { index in
        guard index < workspace.slots.count, let id = workspace.slots[index],
          workspace.documents.contains(where: { $0.id == id }), seen.insert(id).inserted
        else { return nil }
        return id
      }
      workspace.focused = max(0, min(workspace.slots.count - 1, workspace.focused))
      for doc in workspace.documents {
        doc.page = max(1, doc.page)
        doc.zoom = doc.zoom.isFinite ? min(8, max(0.1, doc.zoom)) : 1
        if ![0, 90, 180, 270].contains(doc.rotation) { doc.rotation = 0 }
        if !["page", "width", "manual"].contains(doc.fit) { doc.fit = "page" }
        doc.offset = max(0, min(0.999, doc.offset ?? 0))
        if doc.pointX?.isFinite == false { doc.pointX = nil }
        if doc.pointY?.isFinite == false { doc.pointY = nil }
      }
    }
    if !session.views.contains(where: { $0.id == session.active }) {
      session.active = session.views[0].id
    }
    if !["orange", "nord", "dracula", "solarized"].contains(session.appearance.theme) {
      session.appearance.theme = "orange"
    }
    if !["system", "light", "dark"].contains(session.appearance.mode) {
      session.appearance.mode = "system"
    }
    return session
  }
  func json() throws -> Any { try JSONSerialization.jsonObject(with: JSONEncoder().encode(self)) }
  func moveFile(_ id: String, from sourceID: String, to destinationID: String, slot: Int? = nil) {
    guard let source = views.first(where: { $0.id == sourceID }),
      let selected = source.documents.first(where: { $0.id == id })
    else { return }
    let siblings = source.documents.filter { $0.path == selected.path && $0.id != id }
    move(id, from: sourceID, to: destinationID, slot: slot)
    if sourceID != destinationID {
      for view in siblings { move(view.id, from: sourceID, to: destinationID) }
    }
  }
  func move(_ id: String, from sourceID: String, to destinationID: String, slot: Int? = nil) {
    guard let source = views.first(where: { $0.id == sourceID }),
      let dest = views.first(where: { $0.id == destinationID }),
      let doc = source.documents.first(where: { $0.id == id })
    else { return }
    if source === dest {
      dest.assign(id, to: slot ?? dest.focused)
      return
    }
    source.remove(id)
    // Reading views remain independent even when the destination already has this PDF.
    if !dest.documents.contains(where: { $0.id == doc.id }) { dest.documents.append(doc) }
    if let target = slot ?? dest.slots.firstIndex(of: nil) { dest.assign(doc.id, to: target) }
  }
}
var accent = NSColor.systemOrange
func hex(_ value: Int) -> NSColor {
  NSColor(
    srgbRed: CGFloat((value >> 16) & 255) / 255, green: CGFloat((value >> 8) & 255) / 255,
    blue: CGFloat(value & 255) / 255, alpha: 1)
}
func palette(_ appearance: Appearance, dark: Bool) -> (NSColor, NSColor) {
  switch appearance.theme {
  case "nord": return (hex(dark ? 0x88c0d0 : 0x366a84), hex(dark ? 0x242933 : 0xd8dee9))
  case "dracula": return (hex(dark ? 0xbd93f9 : 0x7448a8), hex(dark ? 0x21222c : 0xe7e3ee))
  case "solarized": return (hex(dark ? 0xe8a649 : 0xa04f00), hex(dark ? 0x002b36 : 0xeee8d5))
  default: return (hex(dark ? 0xffab70 : 0xb84b08), hex(dark ? 0x202124 : 0xe9e6e2))
  }
}
