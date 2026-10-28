import Foundation

/// A drive action (GLOSSARY.md; stories 45 and 47; card agent-bo-95422444): another app's command, named by its action
/// id the way AppLink names an app, so the bind store keeps it and the engine rebuilds it whenever a bind runs one.
/// Never a keystroke aimed at another app's global hotkey (ADR 0001): a keystroke goes into the focused app.
public enum DriveRoute: Equatable, Sendable {
    /// Another app's URL scheme, opened without activating it: `drive.url:obsidian://new`.
    case url(String)
    /// A menu item of a running app, pressed through Accessibility by title path:
    /// `drive.menu:com.apple.finder:File > New Finder Window`.
    case menu(bundle: String, path: [String])
    /// A keystroke into the focused app, a plain combo's spelling: `drive.key:shift+cmd+T`.
    case keystroke(Key)
    /// A shortcut from the Shortcuts app by name: `drive.shortcut:Morning routine`.
    case shortcut(String)
    /// A shell command in a child login shell: `drive.shell:touch /tmp/probe`.
    case shell(String)
    /// A picker (story 48, card agent-bo-95422698): `list` runs in a login shell, its lines are the rows, and `run` runs
    /// with the pick as `$1`: `drive.pick:{"list":"…","run":"…","title":"…"}`, JSON so either command may hold any text.
    case picker(title: String?, list: String, run: String)

    public static let pathSeparator = " > "
    /// A menu path as people read it: "File › New Window".
    public static func title(_ path: [String]) -> String { path.joined(separator: " › ") }

    /// The route's own id read back, nil when it has nothing to run (an empty field, a key that does not exist): the
    /// Binds editor's check before Save.
    public var checked: DriveRoute? { DriveRoute(id: id) }

    public init?(id: String) {
        func rest(_ prefix: String) -> String? {
            guard id.hasPrefix(prefix) else { return nil }
            let value = String(id.dropFirst(prefix.count))
            return value.trimmingCharacters(in: .whitespaces).isEmpty ? nil : value
        }
        if let url = rest("drive.url:") { self = .url(url) }
        else if let pair = rest("drive.menu:"), let colon = pair.firstIndex(of: ":"), colon != pair.startIndex {
            let path = pair[pair.index(after: colon)...].components(separatedBy: ">").map { $0.trimmingCharacters(in: .whitespaces) }
            guard !path.contains(where: \.isEmpty) else { return nil }
            self = .menu(bundle: String(pair[..<colon]), path: path)
        }
        else if let keys = rest("drive.key:"), let key = Key(spelling: keys) { self = .keystroke(key) }
        else if let name = rest("drive.shortcut:") { self = .shortcut(name) }
        else if let command = rest("drive.shell:") { self = .shell(command) }
        else if let json = rest("drive.pick:"), let p = try? JSONDecoder().decode(Picker.self, from: Data(json.utf8)),
                ![p.list, p.run].contains(where: { $0.trimmingCharacters(in: .whitespaces).isEmpty }) {
            self = .picker(title: p.title?.trimmingCharacters(in: .whitespaces).isEmpty == false ? p.title : nil, list: p.list, run: p.run)
        }
        else { return nil }
    }

    public var id: String {
        switch self {
        case .url(let url): "drive.url:\(url)"
        case .menu(let bundle, let path): "drive.menu:\(bundle):\(path.joined(separator: Self.pathSeparator))"
        case .keystroke(let key): "drive.key:\(key.spelling)"
        case .shortcut(let name): "drive.shortcut:\(name)"
        case .shell(let command): "drive.shell:\(command)"
        case .picker(let title, let list, let run):
            "drive.pick:" + String(decoding: try! Self.json.encode(Picker(title: title, list: list, run: run)), as: UTF8.self)
        }
    }

    private struct Picker: Codable { var title: String?, list: String, run: String }
    private static let json = {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return e
    }()

    /// What the Binds screen and Learn show; `appName` is the menu route's app, looked up by the caller.
    public func label(appName: String?) -> String {
        switch self {
        case .url(let url): "Open \(url)"
        case .menu(let bundle, let path): "\(appName ?? bundle): \(Self.title(path))"
        case .keystroke(let key): "Keystroke \(key.label)"
        case .shortcut(let name): "Shortcut: \(name)"
        case .shell(let command): "Shell: \(command)"
        case .picker(let title, let list, _): title.map { "Pick: \($0)" } ?? "Pick from: \(list)"
        }
    }

    public struct Command: Equatable, Sendable {
        public var path: String, arguments: [String]
        public init(path: String, arguments: [String]) { self.path = path; self.arguments = arguments }
    }

    /// The child process a shell or Shortcuts route runs, or a picker's list command; nil for the routes that run none.
    public func command(loginShell: String) -> Command? {
        switch self {
        case .shell(let command), .picker(_, let command, _): Command(path: loginShell, arguments: ["-l", "-c", command])
        case .shortcut(let name): Command(path: "/usr/bin/shortcuts", arguments: ["run", name])
        case .url, .menu, .keystroke: nil
        }
    }

    /// A picker's second command: the pick is `$1` (after `$0`, "pilot-pick"), an argument, never pasted into the text,
    /// so a row holding shell syntax runs nothing.
    public func pickCommand(loginShell: String, pick: String) -> Command? {
        guard case .picker(_, _, let run) = self else { return nil }
        return Command(path: loginShell, arguments: ["-l", "-c", run, "pilot-pick", pick])
    }

    /// The rows a list command printed: each non-empty line, trimmed, once, in order.
    public static func rows(_ output: String) -> [String] {
        var seen = Set<String>()
        return output.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && seen.insert($0).inserted }
    }
}

extension Key {
    /// A plain combo from "cmd+shift+t", any case, a side as "leftAlt"; the last part is the key. Hyper is no modifier.
    public init?(spelling: String) {
        var parts = spelling.components(separatedBy: "+").map { $0.trimmingCharacters(in: .whitespaces) }
        guard let name = parts.popLast(), let code = KeyNames.code(for: name), let modifiers = Modifiers(names: parts) else { return nil }
        self.init(keyCode: code, modifiers: modifiers, hyper: false)
    }

    /// "shift+cmd+T", which `init(spelling:)` reads back.
    public var spelling: String { (modifiers.names + [KeyNames.name(for: keyCode)]).joined(separator: "+") }
}
