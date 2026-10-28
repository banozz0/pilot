import AppKit
import PilotCore
import UniformTypeIdentifiers

/// The main editor: the Editor role's app, which its key opens and Configs open files with. Sven's pick is a stored setting saved as it changes; nil is automatic, found from the Mac's text default
/// every time it is asked, so a default changed in Finder is followed at once.
@Observable @MainActor
final class EditorChoice {
    static let shared = EditorChoice()
    private static let key = "editor.pick"

    var pick: String? { didSet { defaults.set(pick, forKey: Self.key) } }

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let installed: @MainActor (String) -> Bool
    @ObservationIgnored private let handler: @MainActor (DefaultHandler) -> String?

    init(defaults: UserDefaults = .pilot(), installed: @escaping @MainActor (String) -> Bool = AppsModule.isInstalled,
         handler: @escaping @MainActor (DefaultHandler) -> String? = AppsModule.defaultApp(for:)) {
        self.defaults = defaults
        self.installed = installed
        self.handler = handler
        pick = defaults.string(forKey: Self.key)
    }

    /// The editor's bundle id: the pick while installed, else what Automatic gives.
    var app: String { pick.flatMap { installed($0) ? $0 : nil } ?? automatic }
    /// What the Mac's defaults give, shown beside Automatic in the picker.
    var automatic: String { AppRole.editor.resolve(installed: installed, handler: handler) }

    /// The picker's apps: every app macOS opens the role's kinds of file with (plain text, source code), by name.
    static func choices() -> [(name: String, bundle: String)] {
        AppsModule.apps(opening: AppRole.editor.defaultHandlers.compactMap { if case .contentType(let id) = $0 { UTType(id) } else { nil } })
    }
}
