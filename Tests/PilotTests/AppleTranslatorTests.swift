import Foundation
import Testing
import Translation
@testable import Pilot

/// The real translator (card agent-bo-95422773): Apple's on-device translation, no network service. Opt-in like every
/// live test, and only where the English–Spanish pair is downloaded, as on Sven's Mac: on a loaded Mac the on-device
/// model takes minutes. TranslateTests covers the action on a fake translator in every run.
@Suite("Apple translator")
struct AppleTranslatorTests {
    static func installed() async -> Bool {
        await LanguageAvailability().status(from: Locale.Language(identifier: "es"), to: Locale.Language(identifier: "en")) == .installed
    }

    @Test("Spanish turns into English on the Mac itself", .enabled(if: ProcessInfo.processInfo.environment["PILOT_LIVE"] == "1"),
          .enabled { await installed() })
    func translates() async throws {
        let english = try await AppleTranslator().translate("¿dónde está la estación?", from: "es", to: "en")
        #expect(english.lowercased().contains("station"))
    }
}
