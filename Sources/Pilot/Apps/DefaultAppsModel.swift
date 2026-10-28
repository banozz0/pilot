import AppKit
import PilotCore
import UniformTypeIdentifiers

/// What the Default apps page asks of macOS: a fake in tests, LaunchServices in the app.
@MainActor
protocol DefaultAppsSystem {
    func current(_ handler: DefaultHandler) -> String?
    func choices(_ handlers: [DefaultHandler]) -> [(name: String, bundle: String)]
    func name(_ bundle: String) -> String
    func setDefault(_ bundle: String, for handler: DefaultHandler) async throws
}

/// Default apps (card agent-bo-95422842): each kind's default app and the apps that can open it, read on the page's
/// appear, and changed only on Sven's pick, then read back. Never at launch, never in a test.
@Observable @MainActor
final class DefaultAppsModel {
    struct Row {
        var current: String?
        /// The apps that open it, the current default first when macOS left it out of that list.
        var choices: [(name: String, bundle: String)]
        /// Why the last change did not take.
        var message: String?
    }

    private(set) var rows: [String: Row] = [:]
    @ObservationIgnored private let kinds: [FileKind]
    @ObservationIgnored private let system: DefaultAppsSystem
    @ObservationIgnored private let forget: @MainActor (AppRole) -> Void

    /// `forget` drops Pilot's remembered app for a role a link default feeds, so the browser and mail keys follow.
    init(kinds: [FileKind] = FileKinds.groups.flatMap(\.kinds), system: DefaultAppsSystem = LaunchServicesDefaults(),
         forget: @escaping @MainActor (AppRole) -> Void = AppsModule.forget) {
        self.kinds = kinds
        self.system = system
        self.forget = forget
    }

    func load() {
        rows = Dictionary(uniqueKeysWithValues: kinds.map { kind in
            let current = kind.handlers.first.flatMap(system.current), apps = system.choices(kind.handlers)
            let missing = current.flatMap { c in apps.contains { $0.bundle == c } ? nil : (name: system.name(c), bundle: c) }
            return (kind.id, Row(current: current, choices: (missing.map { [$0] } ?? []) + apps))
        })
    }

    /// Each handler macOS does not already give to `bundle` (setting https may move http too, so macOS asks once).
    func change(_ kind: FileKind, to bundle: String) async {
        guard rows[kind.id]?.current != bundle else { return }
        var message: String?
        do {
            for handler in kind.handlers where system.current(handler) != bundle { try await system.setDefault(bundle, for: handler) }
        } catch {
            message = "Not changed: \(error.localizedDescription)"
        }
        let now = kind.handlers.first.flatMap(system.current)
        rows[kind.id]?.current = now
        rows[kind.id]?.message = message ?? (now == bundle ? nil : "Not changed: macOS kept the old app.")
        alog.notice("default app \(kind.id, privacy: .public) → \(bundle, privacy: .public): \(self.rows[kind.id]?.message ?? "changed", privacy: .public)")
        if now == bundle, message == nil { kind.roles.forEach(forget) }
    }
}

/// The real defaults, through NSWorkspace's public calls.
@MainActor
struct LaunchServicesDefaults: DefaultAppsSystem {
    func current(_ handler: DefaultHandler) -> String? { AppsModule.defaultApp(for: handler) }

    func choices(_ handlers: [DefaultHandler]) -> [(name: String, bundle: String)] {
        let types = handlers.compactMap { if case .contentType(let id) = $0 { UTType(id) } else { nil } }
        let urls = handlers.compactMap { if case .url(let s) = $0 { URL(string: s) } else { nil } }
        return urls.isEmpty ? AppsModule.apps(opening: types) : AppsModule.apps(opening: urls)
    }

    func name(_ bundle: String) -> String { AppsModule.appName(bundle) ?? bundle }

    func setDefault(_ bundle: String, for handler: DefaultHandler) async throws {
        guard let app = AppsModule.url(forBundle: bundle) else { throw CocoaError(.fileNoSuchFile) }
        switch handler {
        case .contentType(let id):
            guard let type = UTType(id) else { return }
            try await NSWorkspace.shared.setDefaultApplication(at: app, toOpen: type)
        case .url(let s):
            guard let scheme = URL(string: s)?.scheme else { return }
            try await NSWorkspace.shared.setDefaultApplication(at: app, toOpenURLsWithScheme: scheme)
        }
    }
}
