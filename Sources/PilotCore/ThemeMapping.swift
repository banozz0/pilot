import Foundation

/// Portable declarations grant selectors, never a local path or executable.
public struct ThemeMapping: Codable, Equatable, Sendable {
    public enum Ownership: Codable, Equatable, Sendable {
        case generatedFile
        case block(begin: String, end: String)
        case json(path: [String])
    }
    public var id: String
    public var ownership: Ownership
    public var template: String
    public init(id: String, ownership: Ownership, template: String) {
        self.id = id; self.ownership = ownership; self.template = template
    }
    public func selector(prefix: Int = 0) -> ThemeSelector {
        switch ownership {
        case .generatedFile: .file
        case .block(let begin, let end): .block(begin: begin, end: end, prefix: prefix)
        case .json(let path): .jsonValue(path: path)
        }
    }
    public func validate(palette: [String: String]) throws {
        guard ThemePack.validID(id), !["ghostty", "zed", "obsidian"].contains(id) else { throw ThemeFailure("invalid/reserved custom mapping identity") }
        let rendered = try ThemeTemplate.render(template, palette: palette)
        switch ownership {
        case .generatedFile: break
        case .block(let begin, let end):
            guard !begin.isEmpty, !end.isEmpty, begin != end,
                  !begin.contains(end), !end.contains(begin),
                  [begin, end].allSatisfy({ $0 == $0.trimmingCharacters(in: .whitespacesAndNewlines) && !$0.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) }),
                  !rendered.contains(begin), !rendered.contains(end) else { throw ThemeFailure("ambiguous custom block markers") }
        case .json(let path):
            guard !path.isEmpty, path.allSatisfy({ !$0.isEmpty && !$0.utf8.contains(0) }) else { throw ThemeFailure("empty/invalid structural key selector") }
            let value = try JSONDecoder().decode(JSONValue.self, from: Data(rendered.utf8))
            try ThemeLedger.validateFields(Data(("{\"value\":" + rendered + "}").utf8), encoded: ThemeDigest.encoded(["value": value]))
        }
    }

    /// Pure preparation reuses the exact ownership/file/JSONC primitives used by built-in adapters.
    public func prepare(palette: [String: String], target: ThemeSnapshot, previous: ThemeClaim?) throws -> ThemeMutation {
        try validate(palette: palette)
        let rendered = try ThemeTemplate.render(template, palette: palette)
        let selected: ThemeSelector, after: Data, replacement: Data?
        switch ownership {
        case .generatedFile:
            guard target.bytes == nil || previous != nil else { throw ThemeFailure("unclaimed generated custom file collision") }
            selected = .file; after = Data(rendered.utf8); replacement = after
        case .json:
            selected = selector(); after = Data(rendered.utf8)
            // An explicit existing object/container is required; never invent a config hierarchy.
            replacement = try ThemeRegions.replacing(selected, in: target.bytes, with: after)
        case .block(let begin, let end):
            let prefix: Int
            if let previous, case .block(_, _, let oldPrefix) = previous.selector { prefix = oldPrefix }
            else if try ThemeRegions.range(selector(), in: target.bytes) != nil { prefix = 0 }
            else { prefix = target.bytes?.isEmpty == false && target.bytes?.last != 10 ? 1 : 0 }
            selected = selector(prefix: prefix)
            after = Data(((prefix == 1 ? "\n" : "") + begin + "\n" + rendered + (rendered.hasSuffix("\n") ? "" : "\n") + end).utf8)
            replacement = try ThemeRegions.replacing(selected, in: target.bytes, with: after)
        }
        return .init(target: target, selector: selected, before: try ThemeRegions.owned(selected, in: target.bytes), after: after, replacement: replacement, bindingID: id)
    }
}

/// Fixed local argv. Import cannot create it, and no palette/template substitution reaches it.
public struct ThemeReloadCommand: Codable, Equatable, Sendable {
    public var executable: String
    public var arguments: [String]
    public init(executable: String, arguments: [String]) { self.executable = executable; self.arguments = arguments }
}

public struct ThemeMappingBinding: Codable, Equatable, Sendable {
    public var id, root, path, app: String
    public var reload: ThemeReloadCommand?
    public init(id: String, root: String, path: String, app: String, reload: ThemeReloadCommand? = nil) {
        self.id = id; self.root = root; self.path = path; self.app = app; self.reload = reload
    }
    public func validate() throws {
        func absolute(_ value: String) -> Bool {
            value.hasPrefix("/") && value != "/" && URL(fileURLWithPath: value).standardizedFileURL.path == value &&
            !value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
        }
        guard ThemePack.validID(id), !["ghostty", "zed", "obsidian"].contains(id), absolute(root), ThemeFiles.relative(path), absolute(app), app.hasSuffix(".app") else { throw ThemeFailure("invalid explicit custom app binding") }
        if let reload {
            // Only the selected application's own native helper: no shell, installer or package manager.
            guard absolute(reload.executable), reload.executable.hasPrefix(app + "/Contents/MacOS/"),
                  !reload.arguments.contains(where: { $0.contains("{{") || $0.utf8.contains(0) || $0.contains("://") }),
                  !["sh", "bash", "zsh", "fish", "python", "python3", "osascript", "env", "open", "installer", "pkgutil", "brew", "npm", "npx", "restart", "reboot"].contains(URL(fileURLWithPath: reload.executable).lastPathComponent.lowercased()) else { throw ThemeFailure("reload must be fixed argv for the exact selected app's native helper; no shell/install/restart") }
        }
    }
}

public struct ThemeReloadIntent: Sendable {
    public let binding: ThemeMappingBinding
    public let executable, app: ThemeSnapshot
    public init(binding: ThemeMappingBinding, executable: ThemeSnapshot, app: ThemeSnapshot) {
        self.binding = binding; self.executable = executable; self.app = app
    }

    /// Final synchronous launch boundary, shared by production and the recording fixture.
    /// Observed substitutions fail; pathname launch is not a cross-process compare-and-swap.
    public func launch(_ effect: (ThemeReloadCommand) throws -> String) throws -> String {
        try binding.validate()
        guard let command = binding.reload,
              app.root == binding.app, app.path == "Contents/Info.plist",
              executable.root == binding.app, executable.root + "/" + executable.path == command.executable,
              executable.resolved == command.executable,
              try ThemeFiles.read(root: app.root, path: app.path) == app,
              try ThemeFiles.read(root: executable.root, path: executable.path) == executable,
              let bytes = executable.bytes, executable.mode & 0o111 != 0,
              [[UInt8]([0xcf,0xfa,0xed,0xfe]), [0xce,0xfa,0xed,0xfe], [0xca,0xfe,0xba,0xbe], [0xbe,0xba,0xfe,0xca]].contains(Array(bytes.prefix(4))) else {
            throw ThemeFailure("approved app/native helper identity changed before launch; command not run")
        }
        return try effect(command)
    }
}
