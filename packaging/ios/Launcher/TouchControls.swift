import SwiftUI

struct TouchButtonSetting: Codable, Identifiable, Equatable {
    let id: String
    var x: Double
    var y: Double
    var scale: Double
    var visible: Bool

    var title: String {
        switch id {
        case "forward": return "Forward"
        case "back": return "Back"
        case "left": return "Left"
        case "right": return "Right"
        case "sneak": return "Sneak"
        case "jump": return "Jump"
        case "view": return "Perspective"
        case "chat": return "Chat"
        case "pause": return "Pause"
        case "inventory": return "Inventory"
        case "attack": return "Attack / mine"
        case "use": return "Use / place"
        case "sprint": return "Sprint"
        case "drop": return "Drop item"
        default: return id
        }
    }

    var symbol: String {
        switch id {
        case "forward": return "arrow.up"
        case "back": return "arrow.down"
        case "left": return "arrow.left"
        case "right": return "arrow.right"
        case "sneak": return "figure.crouching"
        case "jump": return "arrow.up.to.line"
        case "view": return "eye"
        case "chat": return "bubble.left"
        case "pause": return "pause"
        case "inventory": return "square.grid.3x3"
        case "attack": return "xmark"
        case "use": return "plus"
        case "sprint": return "figure.run"
        case "drop": return "arrow.down"
        default: return "circle"
        }
    }
}

struct TouchConfiguration: Codable, Equatable {
    var opacity: Double
    var buttons: [TouchButtonSetting]
    static let empty = TouchConfiguration(opacity: 1, buttons: [])
}

/// The engine owns and validates the settings file; the launcher edits a draft until Save.
@MainActor
final class TouchEditorModel: ObservableObject {
    typealias Request = @MainActor (String) async -> [String: Any]
    @Published var draft = TouchConfiguration.empty
    @Published private(set) var loading = false
    @Published private(set) var saving = false
    @Published var error: String?
    private var defaults = TouchConfiguration.empty
    private let request: Request

    init(request: @escaping Request = { await Bridge.send($0) }) { self.request = request }

    func load() async {
        loading = true
        error = nil
        defer { loading = false }
        let answer = await request("touch-controls-get")
        if let message = answer.error { error = message; return }
        guard let current = Self.decode(answer["settings"]), let original = Self.decode(answer["defaults"]),
              !current.buttons.isEmpty, !original.buttons.isEmpty else {
            error = "Could not load touch controls. Try again."
            return
        }
        draft = current
        defaults = original
    }

    func resetDraft() { draft = defaults }

    func save() async -> Bool {
        guard !saving else { return false }
        saving = true
        error = nil
        defer { saving = false }
        guard let data = try? JSONEncoder().encode(draft), let json = String(data: data, encoding: .utf8) else {
            error = "Could not prepare control settings."
            return false
        }
        let answer = await request("touch-controls-set " + json)
        if let message = answer.error { error = message; return false }
        guard answer["ok"] as? Bool == true else { error = "The game did not confirm the changes."; return false }
        return true
    }

    private static func decode(_ object: Any?) -> TouchConfiguration? {
        guard let object, JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject: object) else { return nil }
        return try? JSONDecoder().decode(TouchConfiguration.self, from: data)
    }
}

struct TouchControlsEditor: View {
    @StateObject private var model = TouchEditorModel()
    @State private var selected = "jump"
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text("Drag the buttons to move them. Select one to change its size or show it. Attack, use, sprint and drop are optional.")
                    .foregroundStyle(.secondary)
                if model.loading && model.draft.buttons.isEmpty {
                    ProgressView("Loading controls…").frame(maxWidth: .infinity).padding()
                } else if model.draft.buttons.isEmpty {
                    if let error = model.error { Text(error).foregroundStyle(Theme.warn) }
                    Button("Retry") { Task { await model.load() } }
                } else {
                    TouchCanvas(buttons: $model.draft.buttons, selected: $selected)
                        .aspectRatio(16.0 / 9.0, contentMode: .fit)
                        .accessibilityIdentifier("touch-layout-preview")
                    Picker("Button", selection: $selected) {
                        ForEach(model.draft.buttons) { button in Text(button.title).tag(button.id) }
                    }
                    .accessibilityIdentifier("touch-selected-button")
                    if let index = model.draft.buttons.firstIndex(where: { $0.id == selected }) {
                        Toggle("Show button", isOn: $model.draft.buttons[index].visible)
                            .accessibilityIdentifier("touch-visible")
                        HStack { Text("Button size"); Spacer(); Text("\(Int(model.draft.buttons[index].scale * 100))%") }
                        Slider(value: $model.draft.buttons[index].scale, in: 0.5...2.0, step: 0.05)
                            .accessibilityLabel("Button size")
                            .accessibilityIdentifier("touch-size")
                    }
                    HStack { Text("Opacity"); Spacer(); Text("\(Int(model.draft.opacity * 100))%") }
                    Slider(value: $model.draft.opacity, in: 0.2...1.0, step: 0.05)
                        .accessibilityLabel("Control opacity")
                        .accessibilityIdentifier("touch-opacity")
                    Text("The hotbar stays aligned with the game's inventory. Changes apply when you save.")
                        .font(.footnote).foregroundStyle(.secondary)
                    Button("Reset to defaults") { model.resetDraft() }
                        .accessibilityIdentifier("touch-reset")
                    if let error = model.error { Text(error).foregroundStyle(Theme.warn) }
                }
            }
            .padding(20)
        }
        .background(Theme.background.ignoresSafeArea())
        .navigationTitle("Touch controls")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button(model.saving ? "Saving…" : "Save") {
                    Task { if await model.save() { Haptics.done(); dismiss() } }
                }
                .disabled(model.loading || model.saving || model.draft.buttons.isEmpty)
                .accessibilityIdentifier("touch-save")
            }
        }
        .task { await model.load() }
    }
}

private struct TouchCanvas: View {
    @Binding var buttons: [TouchButtonSetting]
    @Binding var selected: String

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 14).fill(Theme.surfaceSunken)
                Text("GAME SCREEN").font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                    .padding(10).allowsHitTesting(false)
                ForEach($buttons) { $button in
                    let base: CGFloat = ["view", "chat", "pause", "inventory"].contains(button.id) ? 0.087 : 0.133
                    let size = max(20, geometry.size.height * base * CGFloat(button.scale))
                    Image(systemName: button.symbol)
                        .font(.system(size: max(9, size * 0.42), weight: .semibold))
                        .frame(width: size, height: size)
                        .background(button.visible ? Theme.accent.opacity(0.75) : Color.gray.opacity(0.3), in: RoundedRectangle(cornerRadius: 6))
                        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(selected == button.id ? Color.white : .clear, lineWidth: 2))
                        .position(x: geometry.size.width * CGFloat(button.x), y: geometry.size.height * CGFloat(button.y))
                        .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .named("touchCanvas"))
                            .onChanged { value in
                                selected = button.id
                                button.x = min(1, max(0, Double(value.location.x / max(geometry.size.width, 1))))
                                button.y = min(1, max(0, Double(value.location.y / max(geometry.size.height, 1))))
                            })
                        .accessibilityLabel(button.title)
                }
            }
            .coordinateSpace(name: "touchCanvas")
            .clipShape(RoundedRectangle(cornerRadius: 14))
        }
    }
}
