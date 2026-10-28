import AppKit
import Darwin
import PilotCore

/// Eject all disks (system.ejectAll, Q386): reads the mounted volumes, ejects each through NSWorkspace off the main
/// thread, and says how it went (DiskEject.said). A volume that stays is asked of the kernel for the processes with
/// files open on it, so the line can name the app holding it; nothing else is read.
@MainActor
enum EjectDisks {
    /// One run at a time; a second press while one runs is dropped.
    private static var running = false

    static func run() {
        guard !running else { return }
        running = true
        Task {
            let line = await Task.detached(priority: .userInitiated) { ejectAll() }.value
            running = false
            slog.notice("eject all: \(line, privacy: .public)")
            HUD.tip(line, seconds: 4)
        }
    }

    nonisolated private static let keys: [URLResourceKey] = [.volumeLocalizedNameKey, .volumeIsEjectableKey, .volumeIsRemovableKey,
                                                 .volumeIsInternalKey, .volumeIsLocalKey, .volumeIsRootFileSystemKey]

    /// Every mounted volume as DiskEject reads it.
    nonisolated private static func volumes() -> [(DiskEject.Volume, URL)] {
        let urls = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: keys, options: [.skipHiddenVolumes]) ?? []
        return urls.compactMap { url in
            guard let v = try? url.resourceValues(forKeys: Set(keys)) else { return nil }
            return (DiskEject.Volume(name: v.volumeLocalizedName ?? url.lastPathComponent, path: url.path(percentEncoded: false),
                                     ejectable: v.volumeIsEjectable ?? false, removable: v.volumeIsRemovable ?? false,
                                     isInternal: v.volumeIsInternal ?? true, local: v.volumeIsLocal ?? false, root: v.volumeIsRootFileSystem ?? false), url)
        }
    }

    /// Ejects each, in turn. A volume already gone counts as ejected: ejecting one partition takes its siblings with it.
    nonisolated private static func ejectAll() -> String {
        let all = volumes()
        let picked = Set(DiskEject.ejectable(all.map(\.0)).map(\.path))
        var ejected = 0, stuck: [DiskEject.Stuck] = []
        for (volume, url) in all where picked.contains(volume.path) {
            do {
                try NSWorkspace.shared.unmountAndEjectDevice(at: url)
                ejected += 1
            } catch {
                if !FileManager.default.fileExists(atPath: volume.path) { ejected += 1; continue }
                slog.error("eject \(volume.name, privacy: .public): \(String(describing: error), privacy: .public)")
                stuck.append(DiskEject.Stuck(name: volume.name, holders: holders(of: volume.path)))
            }
        }
        return DiskEject.said(ejected: ejected, stuck: stuck)
    }

    /// The apps (else the processes) with files open on the volume at `path`, as the kernel lists them; Pilot left out.
    nonisolated private static func holders(of path: String) -> [String] {
        var pids = [pid_t](repeating: 0, count: 256)
        let bytes = proc_listpidspath(UInt32(PROC_ALL_PIDS), 0, path, UInt32(PROC_LISTPIDSPATH_PATH_IS_VOLUME), &pids, Int32(pids.count * MemoryLayout<pid_t>.size))
        guard bytes > 0 else { return [] }
        let own = getpid()
        var names: [String] = []
        for pid in pids.prefix(Int(bytes) / MemoryLayout<pid_t>.size) where pid > 0 && pid != own {
            let name = NSRunningApplication(processIdentifier: pid)?.localizedName ?? SecureInputMonitor.processName(pid)
            if let name, !names.contains(name) { names.append(name) }
        }
        return names
    }
}
