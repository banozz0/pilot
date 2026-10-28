import Foundation

/// A fresh defaults suite name for one test: a plist path in the temporary folder, which macOS purges, so test runs
/// never pile files into ~/Library/Preferences (card agent-bo-95422835). Open it with `UserDefaults(suiteName:)`;
/// reopening the same name reads back what was saved.
func testSuite() -> String {
    NSTemporaryDirectory() + "dev.banozz.pilot.test.\(UUID().uuidString)"
}
