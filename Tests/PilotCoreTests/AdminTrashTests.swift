import Foundation
import Synchronization
import Testing
@testable import PilotCore

/// An App Store app is root's, so its plain move to the Trash is refused and macOS asks for an administrator, as Finder
/// does (AdminTrash). No test can own a folder as root, so a folder of its own without write permission stands in: moving
/// it to another folder is refused the same way (EACCES on its ".."). osascript is a fake: nothing here asks or reaches
/// ~/.Trash.
@Suite("Admin Trash")
struct AdminTrashTests {
    let root: URL, app: URL, trash: URL

    init() throws {
        root = FileManager.default.temporaryDirectory.appending(path: "admin-trash-\(UUID().uuidString)")
        app = root.appending(path: "Applications/WhatsApp.app")
        trash = root.appending(path: ".Trash")
        try FileManager.default.createDirectory(at: app.appending(path: "Contents"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: trash, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: app.path)
    }

    func cleanUp() {
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: app.path)
        for case let url as URL in FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil) ?? .init() {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        }
        try? FileManager.default.removeItem(at: root)
    }

    /// The fake administrator: records osascript's arguments, then moves item 1 to item 2 as root's mv would.
    final class Admin: Sendable {
        let calls = Mutex<[[String]]>([])
        let answer: @Sendable ([String]) throws -> Void
        init(_ answer: @escaping @Sendable ([String]) throws -> Void = Admin.move) { self.answer = answer }
        var run: AdminTrash.Run { { arguments in self.calls.withLock { $0.append(arguments) }; try self.answer(arguments); return "" } }
        @Sendable static func move(_ arguments: [String]) throws {
            let tail = Array(arguments.suffix(3)), item = tail[0]
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: item)
            try FileManager.default.moveItem(atPath: item, toPath: tail[1])
        }
    }

    @Test("the plain move of a folder without write permission is refused for permission")
    func plainMoveIsRefused() {
        defer { cleanUp() }
        #expect {
            try FileManager.default.moveItem(at: app, to: trash.appending(path: "WhatsApp.app"))
        } throws: { AdminTrash.refused($0) }
    }

    @Test("only a permission refusal asks: EPERM, a missing file and other errors don't")
    func whichErrorsAsk() {
        defer { cleanUp() }
        let posix = { (code: Int32) in NSError(domain: NSPOSIXErrorDomain, code: Int(code)) }
        let cocoa = { (code: Int, under: NSError?) in
            NSError(domain: NSCocoaErrorDomain, code: code, userInfo: under.map { [NSUnderlyingErrorKey: $0] } ?? [:])
        }
        #expect(AdminTrash.refused(cocoa(NSFileWriteNoPermissionError, posix(EACCES))))
        #expect(AdminTrash.refused(cocoa(NSFileWriteNoPermissionError, nil)))
        #expect(AdminTrash.refused(posix(EACCES)))
        #expect(AdminTrash.refused(NSError(domain: NSOSStatusErrorDomain, code: -5000)))
        #expect(!AdminTrash.refused(cocoa(NSFileWriteNoPermissionError, posix(EPERM))))
        #expect(!AdminTrash.refused(cocoa(NSFileNoSuchFileError, posix(ENOENT))))
        #expect(!AdminTrash.refused(CocoaError(.fileWriteOutOfSpace)))
    }

    @Test("refused, the administrator's mv moves it into the Trash: paths as argv, never in the script")
    func movesAsAdministrator() async throws {
        defer { cleanUp() }
        let admin = Admin()
        let went = try await AdminTrash.move(app, into: trash, run: admin.run)
        #expect(went == trash.appending(path: "WhatsApp.app"))
        #expect(FileManager.default.fileExists(atPath: went.appending(path: "Contents").path))
        #expect(!FileManager.default.fileExists(atPath: app.path))
        let arguments = try #require(admin.calls.withLock { $0.first })
        #expect(arguments == AdminTrash.script.flatMap { ["-e", $0] }
                + [app.path(percentEncoded: false), went.path(percentEncoded: false), "Pilot wants to move WhatsApp.app to the Trash."])
        #expect(arguments.dropLast(3).allSatisfy { !$0.contains("WhatsApp") })
        #expect(AdminTrash.script[1].contains("with administrator privileges") && AdminTrash.script[1].contains("/bin/mv -n"))
    }

    @Test("a name taken in the Trash gets the time, as Finder adds it, then a number")
    func freeName() throws {
        defer { cleanUp() }
        let now = try #require(Calendar.current.date(from: DateComponents(year: 2026, month: 11, day: 12, hour: 17, minute: 33, second: 5)))
        try FileManager.default.createDirectory(at: trash.appending(path: "WhatsApp.app"), withIntermediateDirectories: false)
        #expect(AdminTrash.free("WhatsApp.app", in: trash, now: now).lastPathComponent == "WhatsApp 17.33.05.app")
        try FileManager.default.createDirectory(at: trash.appending(path: "WhatsApp 17.33.05.app"), withIntermediateDirectories: false)
        #expect(AdminTrash.free("WhatsApp.app", in: trash, now: now).lastPathComponent == "WhatsApp 17.33.05 2.app")
    }

    @Test("a cancelled password leaves the app where it was")
    func cancelled() async {
        defer { cleanUp() }
        let admin = Admin { _ in throw ChildProcess.Failure(tool: "osascript", status: 1, message: "execution error: User canceled. (-128)") }
        await #expect(throws: AdminTrash.Cancelled(name: "WhatsApp.app")) { try await AdminTrash.move(app, into: trash, run: admin.run) }
        #expect(FileManager.default.fileExists(atPath: app.appending(path: "Contents").path))
        #expect(AdminTrash.Cancelled(name: "WhatsApp.app").localizedDescription
                == "WhatsApp.app stays where it is: the administrator password was cancelled")
    }

    @Test("an mv that left the item where it was is a failure, not a Trash")
    func notMoved() async {
        defer { cleanUp() }
        let admin = Admin { _ in }
        await #expect(throws: AdminTrash.Problem.self) { try await AdminTrash.move(app, into: trash, run: admin.run) }
    }

    @Test("an isolated test run never asks: the plain refusal is thrown as it was")
    func neverAsksInTests() async {
        defer { cleanUp() }
        let admin = Admin()
        await #expect { try await AdminTrash.trash(app, plain: { try FileManager.default.moveItem(at: $0, to: trash.appending(path: "x")); return $0 }, run: admin.run) }
            throws: { AdminTrash.refused($0) }
        #expect(admin.calls.withLock { $0.isEmpty })
        #expect(FileManager.default.fileExists(atPath: app.path))
    }
}
