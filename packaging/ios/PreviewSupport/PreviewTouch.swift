import Foundation

/// Stateful touch-control replies for the simulator-only launcher preview.
enum PreviewTouch {
    private static let lock = NSLock()
    private static let defaults = TouchConfiguration(opacity: 1, buttons: [
        TouchButtonSetting(id: "forward", x: 0.14, y: 0.48, scale: 1, visible: true),
        TouchButtonSetting(id: "back", x: 0.14, y: 0.75, scale: 1, visible: true),
        TouchButtonSetting(id: "left", x: 0.065, y: 0.61, scale: 1, visible: true),
        TouchButtonSetting(id: "right", x: 0.215, y: 0.61, scale: 1, visible: true),
        TouchButtonSetting(id: "sneak", x: 0.14, y: 0.61, scale: 1, visible: true),
        TouchButtonSetting(id: "jump", x: 0.94, y: 0.61, scale: 1, visible: true),
        TouchButtonSetting(id: "view", x: 0.44, y: 0.05, scale: 1, visible: true),
        TouchButtonSetting(id: "chat", x: 0.5, y: 0.05, scale: 1, visible: true),
        TouchButtonSetting(id: "pause", x: 0.56, y: 0.05, scale: 1, visible: true),
        TouchButtonSetting(id: "inventory", x: 0.67, y: 0.94, scale: 1, visible: true),
        TouchButtonSetting(id: "attack", x: 0.82, y: 0.48, scale: 1, visible: false),
        TouchButtonSetting(id: "use", x: 0.92, y: 0.48, scale: 1, visible: false),
        TouchButtonSetting(id: "sprint", x: 0.07, y: 0.43, scale: 1, visible: false),
        TouchButtonSetting(id: "drop", x: 0.75, y: 0.80, scale: 1, visible: false),
    ])
    private static var current = defaults

    static func reply(_ line: String) -> [String: Any]? {
        guard line == "touch-controls-get" || line.hasPrefix("touch-controls-set ") else { return nil }
        lock.lock()
        defer { lock.unlock() }
        if line.hasPrefix("touch-controls-set ") {
            let json = String(line.dropFirst("touch-controls-set ".count))
            guard let data = json.data(using: .utf8), let config = try? JSONDecoder().decode(TouchConfiguration.self, from: data)
            else { return ["error": "Invalid control settings."] }
            current = config
            return ["ok": true]
        }
        func object(_ config: TouchConfiguration) -> Any {
            (try? JSONSerialization.jsonObject(with: JSONEncoder().encode(config))) ?? [:]
        }
        return ["ok": true, "settings": object(current), "defaults": object(defaults)]
    }
}
