import AppKit
import PilotCore

/// Native controls, settings handlers and the private host share these writers on the existing item store.
extension BarItemsStore {
    func choosePreset(_ id: String) throws(ControlError) {
        try requireWritable()
        if id == "legacy" { settings.preset = nil; return }
        guard let preset = BarPreset(rawValue: id) else { throw ControlError(.badValue, "unknown bar preset") }
        settings.preset = preset.configuration
    }

    func applyGeometry(_ json: String) throws(ControlError) {
        try requireWritable()
        do {
            let bytes = Data(json.utf8), value = try JSONDecoder().decode(BarPresetConfiguration.self, from: bytes)
            try value.validate()
            try ThemeLedger.validateFields(bytes, encoded: ThemeDigest.encoded(value))
            settings.preset = value
        } catch { throw ControlError(.badValue, String(describing: error)) }
    }

    static let geometryFields: [(String, String, WritableKeyPath<BarPresetConfiguration, Double>)] = [
        ("height", "Height", \.height), ("horizontalMargin", "Side margins", \.horizontalMargin),
        ("topMargin", "Top margin", \.topMargin), ("spacing", "Item spacing", \.spacing),
        ("padding", "Inner padding", \.padding), ("radius", "Corner radius", \.radius),
        ("border", "Border", \.border),
    ]

    func setGeometry(_ key: String, value: Double) throws(ControlError) {
        try requireWritable()
        guard var config = settings.preset else { throw ControlError(.badValue, "choose a bar preset before editing geometry") }
        guard let field = Self.geometryFields.first(where: { $0.0 == key }) else { throw ControlError(.badValue, "unknown bar geometry") }
        config[keyPath: field.2] = value
        do { try config.validate() } catch { throw ControlError(.outOfRange, String(describing: error)) }
        settings.preset = config
    }
}

enum BarPresetGeometry {
    static func hit(_ point: CGPoint, in group: CGRect?) -> Bool { group?.contains(point) == true }

    /// Only nonempty final groups have windows. Local row coordinates have their origin at the top left.
    static func islandFrame(_ group: CGRect?, in bar: CGRect) -> CGRect? {
        guard let group, group.width > 0, group.height > 0, group.minX >= 0, group.maxX <= bar.width else { return nil }
        return CGRect(x: bar.minX + group.minX, y: bar.maxY - group.maxY, width: group.width, height: group.height)
    }

    /// One panel frame for drawing, overflow and native item/popover anchors. No overlay window around the margins.
    static func frame(_ config: BarPresetConfiguration?, screen: CGRect, strip: Double, notch: Double = 0) -> CGRect {
        config?.frame(screen: screen, notchHeight: notch) ?? TopBarGeometry.frame(screen: screen, strip: strip)
    }
}
