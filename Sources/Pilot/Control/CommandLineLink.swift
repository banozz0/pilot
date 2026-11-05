import Foundation
import PilotCore

/// The pilot command on the PATH (ADR 0013): `~/.local/bin/pilot`, a symlink to this bundle's `Contents/Helpers/pilot`,
/// made by General's button. Only that symlink is ever written: never /usr/local/bin or Homebrew's folders, and never a
/// file Pilot did not make.
@Observable @MainActor
final class CommandLineLink {
    static let shared = CommandLineLink()

    enum State: Equatable {
        /// A bare binary (`swift run`) carries no command to link.
        case noCommand
        case notLinked
        case linked
        /// Something else holds the name: a file, or a link to anything but a Pilot bundle's command.
        case taken
    }

    let command: URL
    let folder: URL
    var link: URL { folder.appending(path: "pilot") }
    private(set) var state = State.notLinked
    /// Whether the folder is on the login shell's PATH; nil until read, or when the shell would not say.
    private(set) var onPath: Bool?
    private(set) var problem: String?

    init(command: URL = Bundle.main.bundleURL.appending(path: "Contents/Helpers/pilot"),
         folder: URL = FileManager.default.homeDirectoryForCurrentUser.appending(path: ".local/bin", directoryHint: .isDirectory)) {
        self.command = command
        self.folder = folder
        refresh()
    }

    func refresh() {
        let fm = FileManager.default, commandPath = command.path(percentEncoded: false), linkPath = link.path(percentEncoded: false)
        guard fm.isExecutableFile(atPath: commandPath) else { state = .noCommand; return }
        guard let destination = try? fm.destinationOfSymbolicLink(atPath: linkPath) else {
            state = fm.fileExists(atPath: linkPath) ? .taken : .notLinked
            return
        }
        state = destination == commandPath ? .linked : Self.isPilots(destination) ? .notLinked : .taken
    }

    /// A link Pilot made for another copy of itself (an older build's folder) is replaced; anything else is left alone.
    nonisolated static func isPilots(_ destination: String) -> Bool { destination.hasSuffix(".app/Contents/Helpers/pilot") }

    /// Links `~/.local/bin/pilot` to this bundle's command, making the folder when it is missing.
    func makeLink() {
        refresh()
        guard state == .notLinked else { return }
        let fm = FileManager.default
        do {
            try fm.createDirectory(at: folder, withIntermediateDirectories: true)
            // Not linked means free or an older Pilot's link: only the latter is there to remove.
            try? fm.removeItem(at: link)
            try fm.createSymbolicLink(at: link, withDestinationURL: command)
            problem = nil
            log.notice("control: linked \(self.link.path(percentEncoded: false), privacy: .public) to the bundle's pilot")
        } catch {
            problem = "\(link.path(percentEncoded: false)) not linked: \(error.localizedDescription)"
        }
        refresh()
    }

    /// Set up's Undo (T54): removes `~/.local/bin/pilot` only while it is this bundle's link; anything else stays.
    func removeLink() {
        refresh()
        guard state == .linked else { return }
        do {
            try FileManager.default.removeItem(at: link)
            problem = nil
            log.notice("control: unlinked \(self.link.path(percentEncoded: false), privacy: .public)")
        } catch {
            problem = "\(link.path(percentEncoded: false)) not unlinked: \(error.localizedDescription)"
        }
        refresh()
    }

    /// Reads the login shell's PATH (Pilot runs with launchd's short one), in a child, off the main thread.
    func readPath() async {
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        // Interactive too, so the rc file's PATH counts; the marker skips whatever the rc files print.
        let output = try? await ChildProcess.run(shell, ["-i", "-l", "-c", #"printf '\n\#(Self.marker)%s\n' "$PATH""#], timeout: .seconds(5))
        onPath = output.flatMap { Self.contains(shellOutput: $0, folder: folder) }
    }

    static let marker = "pilot-path:"

    /// Whether the PATH after the marker holds `folder`; nil when no marker line came back.
    static func contains(shellOutput: String, folder: URL) -> Bool? {
        guard let line = shellOutput.split(separator: "\n").last(where: { $0.hasPrefix(marker) }) else { return nil }
        let wanted = URL(filePath: folder.path(percentEncoded: false), directoryHint: .isDirectory).standardizedFileURL
        return line.dropFirst(marker.count).split(separator: ":").contains {
            URL(filePath: String($0), directoryHint: .isDirectory).standardizedFileURL == wanted
        }
    }
}
