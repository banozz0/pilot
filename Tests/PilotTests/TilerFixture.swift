import Foundation
@testable import Pilot
import PilotCore
import PilotTiler

/// PILOT_SANDBOX_TILER=<folder> (sandbox E2E): a stand-in for Pilot's tiler, so `pilot workspace move` and a drop on the
/// Workspaces page move a file's windows, never the Mac's. `<folder>/windows.json` is its window list in the tiler's
/// listing shape (`[{"window-id", "app-name", "app-bundle-id", "app-pid", "workspace", "monitor-id", "window-layout",
/// "window-title"}]`, tree order), read at each ask; a move or a swap writes it back as the tiler would place the
/// windows, and every call is a line in `<folder>/commands.log`.
@MainActor
final class TilerFixture: TilerEngineRunning {
    let folder: URL
    var isRunning = true

    init(folder: URL) { self.folder = folder }

    static func install(_ folder: String?) {
        guard let folder else { return }
        TilerService.standIn = { TilerFixture(folder: URL(filePath: folder)) }
    }

    private var file: URL { folder.appending(path: "windows.json") }

    private func rows() throws -> [[String: Any]] {
        try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [[String: Any]] ?? []
    }

    func run(_ command: AeroCommand) async throws -> String {
        let log = folder.appending(path: "commands.log")
        let line = Data((command.arguments.joined(separator: " ") + "\n").utf8)
        if let handle = try? FileHandle(forWritingTo: log) { handle.seekToEndOfFile(); handle.write(line); try handle.close() }
        else { try line.write(to: log) }
        var rows = try rows()
        let index = { (id: Int) throws in
            guard let i = rows.firstIndex(where: { $0["window-id"] as? Int == id }) else { throw Refused(command: command.arguments) }
            return i
        }
        switch command {
        case .listWindows(.all):
            return String(decoding: try JSONSerialization.data(withJSONObject: rows), as: UTF8.self)
        case .listWindows(.workspace(let name)):
            return String(decoding: try JSONSerialization.data(withJSONObject: rows.filter { $0["workspace"] as? String == name }), as: UTF8.self)
        case .listWindows, .listVisibleWorkspaces:
            return "[]"
        case .moveWindow(let id, let workspace, _):
            // The tiler appends a moved window to the workspace's tree.
            var row = rows.remove(at: try index(id))
            row["workspace"] = workspace
            rows.append(row)
        case .swapWindows(let id, let other):
            let (a, b) = (try index(id), try index(other))
            let (wa, wb) = (rows[a]["workspace"], rows[b]["workspace"])
            rows.swapAt(a, b)
            rows[a]["workspace"] = wa
            rows[b]["workspace"] = wb
        default:
            return ""
        }
        try JSONSerialization.data(withJSONObject: rows, options: .prettyPrinted).write(to: file, options: .atomic)
        return ""
    }

    struct Refused: AeroCallRefusal { let command: [String] }

    func events() -> AsyncStream<AeroEvent> { AsyncStream { $0.finish() } }
    func apply(_ settings: TilerSettings) async throws {}
    func setLayouts(_ layouts: [String: WorkspaceLayout]) {}
    func arrange(_ workspace: String, as preset: LayoutPreset) async throws {}
    func start() async throws {}
    func stop() {}
}
