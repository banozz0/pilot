import Foundation
import Security

/// Stamps one web app: the PilotWebApp template binary in a fresh bundle whose Info.plist names the site,
/// signed so macOS keeps one identity across re-stamps (story 86).
public enum WebAppStamper {
    /// Where Scripts/build-app.sh puts the template inside Pilot.app.
    public static var bundledTemplate: URL { Bundle.main.bundleURL.appending(path: "Contents/Helpers/\(WebAppSpec.executable)") }
    public static var applicationsFolder: URL { FileManager.default.homeDirectoryForCurrentUser.appending(path: "Applications") }

    /// Install → Web App: fetches the site's icon and stamps the app into ~/Applications, signed as Pilot is.
    public static func install(_ spec: WebAppSpec, template: URL = bundledTemplate,
                               into folder: URL = applicationsFolder) async throws -> URL {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return try stamp(spec, template: template, into: folder, icon: await SiteIcon.fetchICNS(for: spec.url),
                         signingIdentity: SigningIdentity.resolve())
    }

    /// Builds `<folder>/<name>.app` (or `fileName`), replacing an earlier stamp of that name. `icon` is .icns data. Anything
    /// else there, an app Pilot did not stamp or one put there while the icon was fetched, is kept and the stamp refused.
    @discardableResult
    public static func stamp(_ spec: WebAppSpec, template: URL, into folder: URL, icon: Data?,
                             signingIdentity: String, fileName: String? = nil) throws -> URL {
        let fm = FileManager.default
        let fileName = fileName ?? spec.appFileName
        let staging = folder.appending(path: ".\(fileName).stamping")
        try? fm.removeItem(at: staging)
        defer { try? fm.removeItem(at: staging) }

        let contents = staging.appending(path: "Contents")
        try fm.createDirectory(at: contents.appending(path: "MacOS"), withIntermediateDirectories: true)
        try fm.createDirectory(at: contents.appending(path: "Resources"), withIntermediateDirectories: true)
        try fm.copyItem(at: template, to: contents.appending(path: "MacOS/\(WebAppSpec.executable)"))
        let plist = try PropertyListSerialization.data(fromPropertyList: spec.infoPlist(hasIcon: icon != nil),
                                                       format: .xml, options: 0)
        try plist.write(to: contents.appending(path: "Info.plist"))
        try Data("APPL????".utf8).write(to: contents.appending(path: "PkgInfo"))
        if let icon { try icon.write(to: contents.appending(path: "Resources/\(WebAppSpec.iconName).icns")) }

        let signed = try run("/usr/bin/codesign", ["--force", "--sign", signingIdentity, "--identifier", spec.bundleID, staging.path])
        guard signed.status == 0 else { throw WebAppError.stampFailed("codesign: \(signed.output)") }

        let app = folder.appending(path: fileName)
        if fm.fileExists(atPath: app.path) {
            guard WebAppDirectory.read(app) != nil else {
                throw WebAppError.stampFailed("\(app.path) is not a Pilot web app, so it was kept; pick another name")
            }
            _ = try fm.replaceItemAt(app, withItemAt: staging)
        } else {
            try fm.moveItem(at: staging, to: app)
        }
        return app
    }
}

extension WebAppStamper {
    /// Settings › Web apps → Rebuild (card agent-bo-95422813): the app stamped again with the newest template, from its
    /// own Info.plist (name, site, browser, extra hosts) and its own icon, in place and under its own file name. A site
    /// that would give another bundle id, or a data store other than the one the app has, is refused: its logins would
    /// stay behind. The icon is never fetched again.
    @discardableResult
    public static func rebuild(_ app: InstalledWebApp, template: URL = bundledTemplate, signingIdentity: String) throws -> URL {
        // The data store the app has now, as its Info.plist says, against the one the stamp would give it.
        let stored = (NSDictionary(contentsOf: app.location.appending(path: "Contents/Info.plist"))?[WebAppKey.dataStoreID] as? String)
        // No stored id means the app uses WebKit's default store; giving it one would leave its logins behind too.
        guard app.spec.bundleID == app.bundleID, stored == app.spec.dataStoreID.uuidString else {
            throw WebAppError.stampFailed("\(app.name) would come back with another bundle id or data store and lose its logins; it was not rebuilt")
        }
        let icon = try? Data(contentsOf: app.location.appending(path: "Contents/Resources/\(WebAppSpec.iconName).icns"))
        return try stamp(app.spec, template: template, into: app.location.deletingLastPathComponent(), icon: icon,
                         signingIdentity: signingIdentity, fileName: app.location.lastPathComponent)
    }
}

/// The certificate Pilot itself is signed with, so every stamp keeps one identity (SPEC.md, the Web apps line).
/// Falls back to the first Apple Development identity in the keychain when Pilot's own certificate is not a
/// keychain identity (a test runner, or a release on a stranger's Mac), and to ad hoc when there is none.
public enum SigningIdentity {
    public static func resolve() -> String {
        let listed = (try? run("/usr/bin/security", ["find-identity", "-v", "-p", "codesigning"]))?.output ?? ""
        let identities = listed.matches(of: /"([^"]+)"/).map { String($0.1) }
        if let own = ownCertificateName(), identities.contains(own) { return own }
        return identities.first { $0.hasPrefix("Apple Development") } ?? "-"
    }

    static func ownCertificateName() -> String? {
        var code: SecCode?
        var staticCode: SecStaticCode?
        var info: CFDictionary?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code,
              SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode,
              SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let certificates = (info as? [String: Any])?[kSecCodeInfoCertificates as String] as? [SecCertificate],
              let leaf = certificates.first else { return nil }
        return SecCertificateCopySubjectSummary(leaf) as String?
    }
}
