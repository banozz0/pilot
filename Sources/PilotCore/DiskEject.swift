import Foundation

/// Eject all disks (Sven, Q386, from Toolbox for Mac): every external drive, SD card and mounted disk image ejected at
/// once, and one line saying how it went. Which volumes count and what the line says are here; the eject is the app's.
public enum DiskEject {
    /// A mounted volume as macOS describes it.
    public struct Volume: Equatable, Sendable {
        public let name: String
        public let path: String
        public let ejectable: Bool
        public let removable: Bool
        public let isInternal: Bool
        public let local: Bool
        public let root: Bool

        public init(name: String, path: String, ejectable: Bool, removable: Bool, isInternal: Bool, local: Bool, root: Bool) {
            self.name = name; self.path = path; self.ejectable = ejectable; self.removable = removable
            self.isInternal = isInternal; self.local = local; self.root = root
        }
    }

    /// A volume that stayed: its name and the apps macOS says hold it open, none when it named none.
    public struct Stuck: Equatable, Sendable {
        public let name: String
        public let holders: [String]
        public init(name: String, holders: [String]) { self.name = name; self.holders = holders }
    }

    /// The volumes Eject all takes: ejectable or removable or not internal, but never the start-up disk, a volume under
    /// /System/Volumes or a network share (those are not disks).
    public static func ejectable(_ volumes: [Volume]) -> [Volume] {
        volumes.filter { v in
            !v.root && v.local && !v.path.hasPrefix("/System/Volumes/") && (v.ejectable || v.removable || !v.isInternal)
        }
    }

    /// The HUD's line: how many went, then the first that stayed with what holds it when macOS named it.
    public static func said(ejected: Int, stuck: [Stuck]) -> String {
        let done = ejected > 0 ? "Ejected \(ejected)" : nil
        guard let first = stuck.first else { return done ?? "Nothing to eject" }
        let holders = first.holders.prefix(2).joined(separator: " and ")
        var busy = holders.isEmpty ? "“\(first.name)” is in use" : "“\(first.name)” is in use by \(holders)"
        if stuck.count > 1 { busy += ", and \(stuck.count - 1) more stayed" }
        return [done, busy].compactMap(\.self).joined(separator: ". ")
    }
}
