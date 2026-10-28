import Foundation
import OSLog

/// A JSON file in Pilot.app's Resources, parsed once: `empty`, with a log line, when it is missing or does not parse
/// (the install and drive catalogues, Omarchy's themes).
enum BundledJSON {
    static func load<T>(_ name: String, log: Logger, empty: T, parse: (Data) throws -> T) -> T {
        guard let url = url(name, "json") else {
            log.error("\(name, privacy: .public).json: not in the app's Resources")
            return empty
        }
        do { return try parse(Data(contentsOf: url)) } catch {
            log.error("\(name, privacy: .public).json: \(String(describing: error), privacy: .public)")
            return empty
        }
    }

    /// A file in the app's Resources (in `folder` there), else in the offscreen renders' copy of them.
    static func url(_ name: String, _ ext: String, in folder: String? = nil) -> URL? {
        Bundle.main.url(forResource: name, withExtension: ext, subdirectory: folder) ?? overridden([folder, "\(name).\(ext)"].compactMap(\.self).joined(separator: "/"))
    }

    /// The offscreen renders' copy of the app's Resources (PILOT_RESOURCES, a folder), which the test bundle lacks; a
    /// debug build only.
    private static func overridden(_ path: String) -> URL? {
        #if DEBUG
        ProcessInfo.processInfo.environment["PILOT_RESOURCES"].map { URL(filePath: $0).appending(path: path) }
        #else
        nil
        #endif
    }
}
