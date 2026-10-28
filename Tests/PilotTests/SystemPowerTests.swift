import PilotCore
import Testing
@testable import Pilot

/// The Power item's real runner: the login framework's lock call resolves (never called here); Power's popover hangs
/// from the item in either bar.
@Suite("System power")
@MainActor
struct SystemPowerTests {
    @Test("The lock call is found in the login framework, so Lock screen (the item and the bind) posts no key")
    func lockCall() {
        #expect(SystemModule.lockCall != nil)
    }

    @Test("Eject all takes external drives, cards and disk images, never the start-up disk, /System/Volumes or a share")
    func ejectAll() {
        func v(_ name: String, ejectable: Bool = false, removable: Bool = false, isInternal: Bool = true, local: Bool = true, root: Bool = false,
               path: String? = nil) -> DiskEject.Volume {
            DiskEject.Volume(name: name, path: path ?? "/Volumes/\(name)", ejectable: ejectable, removable: removable, isInternal: isInternal,
                             local: local, root: root)
        }
        let all = [v("Macintosh HD", root: true, path: "/"), v("Data", path: "/System/Volumes/Data"), v("Backup", isInternal: false),
                   v("SD", ejectable: true, removable: true), v("Pilot.dmg", ejectable: true), v("Share", ejectable: true, isInternal: false, local: false),
                   v("Second partition")]
        #expect(DiskEject.ejectable(all).map(\.name) == ["Backup", "SD", "Pilot.dmg"])
        #expect(DiskEject.said(ejected: 0, stuck: []) == "Nothing to eject")
        #expect(DiskEject.said(ejected: 3, stuck: []) == "Ejected 3")
        #expect(DiskEject.said(ejected: 2, stuck: [.init(name: "Backup", holders: ["Preview"])]) == "Ejected 2. “Backup” is in use by Preview")
        #expect(DiskEject.said(ejected: 0, stuck: [.init(name: "SD", holders: []), .init(name: "Backup", holders: [])])
                == "“SD” is in use, and 1 more stayed")
    }
}
