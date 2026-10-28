import Foundation

/// What the Extensions page shows (card agent-bo-95423247): every extension in the Extensions folder with its commands,
/// what it says it touches in plain words, and a field per preference holding its value; then the folders that are not
/// extensions, each with why.
public enum ExtensionsPage {
    public struct Row: Equatable, Sendable, Identifiable {
        public let ext: Extension
        /// What it says it touches, a line each (notEnforced goes under them).
        public let permissions: [Permission]
        /// Its preferences in the manifest's order, each with the value a run gets now (nil when it has none).
        public var fields: [Field]
        public var id: String { ext.id }

        public init(ext: Extension, permissions: [Permission], fields: [Field]) { self.ext = ext; self.permissions = permissions; self.fields = fields }
    }

    public struct Field: Equatable, Sendable, Identifiable {
        public let preference: Extension.Preference
        public let value: JSONValue?
        public var id: String { preference.name }

        public init(preference: Extension.Preference, value: JSONValue?) { self.preference = preference; self.value = value }

        /// A required preference with no value: its command does not run.
        public var isMissing: Bool { preference.isMissing(value) }
    }

    /// One thing an extension says it touches, in plain words, with its kind so the page can draw its symbol.
    public struct Permission: Equatable, Sendable {
        public enum Kind: Equatable, Sendable { case network, clipboard, files, actions, nothing }
        public let kind: Kind, text: String
        public init(_ kind: Kind, _ text: String) { self.kind = kind; self.text = text }
    }

    /// The line under every extension's permissions.
    public static let notEnforced = "Shown, not enforced: it runs as you."

    /// The page's rows: `found`'s extensions by title with their values from `values`, a Pilot action named by `label`
    /// when it has one.
    public static func rows(_ found: Extension.Found, values: (Extension) -> [String: JSONValue],
                            label: (String) -> String? = { _ in nil }) -> [Row] {
        found.extensions.map { ext in
            let values = values(ext)
            return Row(ext: ext, permissions: permissions(ext.permissions, label: label),
                       fields: ext.preferences.map { Field(preference: $0, value: values[$0.name]) })
        }
    }

    /// `permissions` in plain words, a line per kind it declares; "Touches nothing it names" when none.
    public static func permissions(_ permissions: Extension.Permissions, label: (String) -> String? = { _ in nil }) -> [Permission] {
        var lines: [Permission] = []
        if !permissions.network.isEmpty { lines.append(Permission(.network, "Connects to \(spokenList(permissions.network))")) }
        if permissions.clipboard { lines.append(Permission(.clipboard, "Reads and writes the clipboard")) }
        if !permissions.files.isEmpty { lines.append(Permission(.files, "Reads and writes \(spokenList(permissions.files))")) }
        if !permissions.actions.isEmpty {
            lines.append(Permission(.actions, "Runs Pilot actions: \(spokenList(permissions.actions.map { label($0) ?? $0 }))"))
        }
        return lines.isEmpty ? [Permission(.nothing, "Touches nothing it names")] : lines
    }
}
