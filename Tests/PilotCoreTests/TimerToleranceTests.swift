import Foundation
import Testing

/// Pilot stays lean (story 142): a repeating timer with no tolerance wakes the Mac on its exact tick, apart from every
/// other wake-up, so each one sets a tolerance within a few lines of being made (P9).
@Suite("Timer tolerance")
struct TimerToleranceTests {
    @Test("Every repeating timer in Sources sets a tolerance")
    func everyRepeatingTimer() throws {
        let sources = URL(filePath: #filePath).deletingLastPathComponent().appending(path: "../../Sources").standardized
        var bare: [String] = []
        for case let file as URL in FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil)! where file.pathExtension == "swift" {
            let lines = try String(contentsOf: file, encoding: .utf8).split(separator: "\n", omittingEmptySubsequences: false)
            for (n, line) in lines.enumerated() where line.range(of: #"Timer(\.scheduledTimer)?\(.*repeats: true"#, options: .regularExpression) != nil {
                if !lines[n...].prefix(6).contains(where: { $0.contains(".tolerance = ") }) { bare.append("\(file.lastPathComponent):\(n + 1)") }
            }
        }
        #expect(bare == [], "these repeating timers set no tolerance: \(bare)")
    }
}
