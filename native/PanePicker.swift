import AppKit
import SwiftUI

final class PaneChoices: ObservableObject {
  @Published private(set) var layout: String
  @Published private(set) var selected: Set<Int>
  let name: String
  let occupants: [String?]
  let finish: (String, Set<Int>) -> Void

  init(workspace: Workspace, document: DocumentState, finish: @escaping (String, Set<Int>) -> Void) {
    name = document.name
    layout = workspace.layout == "single" ? "columns" : workspace.layout
    let assigned = workspace.slots.map { id in workspace.documents.first { $0.id == id } }
    selected = Set(assigned.indices.filter { assigned[$0]?.path == document.path })
    occupants = assigned.map { $0?.path == document.path ? nil : $0?.name }
    self.finish = finish
  }

  func changeLayout(to value: String) {
    selected = selected.filter { $0 < paneCount(value) }
    layout = value
  }
  func toggle(_ slot: Int) {
    if !selected.insert(slot).inserted { selected.remove(slot) }
  }
  func apply() { finish(layout, selected) }
}

struct PanePickerView: View {
  @ObservedObject var choices: PaneChoices
  let cancel: () -> Void

  private var positions: [String] {
    switch choices.layout {
    case "single": return ["Single"]
    case "rows": return ["Top", "Bottom"]
    case "triple": return ["Left", "Middle", "Right"]
    case "grid": return ["Top left", "Top right", "Bottom left", "Bottom right"]
    default: return ["Left", "Right"]
    }
  }
  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text("Choose panes").font(.headline)
      Text(choices.name).font(.caption).foregroundStyle(.secondary).lineLimit(1)
        .truncationMode(.middle).help(choices.name)
      Picker("Layout", selection: Binding(get: { choices.layout }, set: choices.changeLayout)) {
        ForEach(layoutNames, id: \.0) { layout in Text(layout.1).tag(layout.0) }
      }
      let columns = choices.layout == "grid" ? 2 : choices.layout == "rows" ? 1 : positions.count
      LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: columns), spacing: 6) {
        ForEach(positions.indices, id: \.self) { slot in
          let on = choices.selected.contains(slot)
          let occupant = slot < choices.occupants.count ? choices.occupants[slot] : nil
          Button { choices.toggle(slot) } label: {
            VStack(spacing: 4) {
              Image(systemName: on ? "checkmark.circle.fill" : "circle")
              Text(positions[slot]).font(.callout)
              Text(on ? choices.name : occupant ?? "Empty").font(.caption2)
                .foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            }
            .padding(5).frame(maxWidth: .infinity, minHeight: 54)
            .background(on ? Color.accentColor.opacity(0.14) : Color.secondary.opacity(0.08),
              in: RoundedRectangle(cornerRadius: 7))
            .overlay(RoundedRectangle(cornerRadius: 7).stroke(on ? Color.accentColor : .clear))
            .contentShape(Rectangle())
          }
          .buttonStyle(.plain).accessibilityLabel(positions[slot])
          .accessibilityValue(on ? "Selected" : "Unselected")
          .help(occupant ?? positions[slot])
        }
      }
      HStack {
        Spacer()
        Button("Cancel", action: cancel).keyboardShortcut(.cancelAction)
        Button("Apply", action: choices.apply).keyboardShortcut(.defaultAction)
      }
    }.padding(16).frame(width: 300).fixedSize().accentColor(Color(nsColor: accent))
  }
}
