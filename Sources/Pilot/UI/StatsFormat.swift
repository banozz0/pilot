import Foundation
import PilotCore

// The readings' words, as Home shows them: shares, rates, sizes and ceilings.

/// How the readings are written, on PilotCore's own (SystemStats' decimal, memorySize, duration) where they exist.
enum StatsFormat {
    /// "9": a share as whole percent.
    static func percent(_ share: Double) -> String { "\(Int((share * 100).rounded()))" }

    /// "1.2" "MB/s", "340" "KB/s": bytes a second.
    static func rate(_ bytes: Double) -> (value: String, unit: String) {
        bytes >= 1_000_000 ? (String(format: "%.1f", bytes / 1_000_000), "MB/s") : ("\(Int((bytes / 1_000).rounded()))", "KB/s")
    }

    static func rateText(_ bytes: Double?) -> String { bytes.map { let r = rate($0); return "\(r.value) \(r.unit)" } ?? "–" }

    /// "7.4 GB", "245 GB", "618 MB": decimal, as Finder counts disks and transfers.
    static func bytes(_ bytes: Double) -> String { SystemStats.decimal(bytes) }

    /// "6.1 GB", "618 MB", "0 B": memory in units of 1024, as Activity Monitor counts it.
    static func memory(_ bytes: UInt64) -> String { bytes == 0 ? "0 B" : SystemStats.memorySize(bytes) }

    /// "1,020": a whole number with its thousands marked.
    static func whole(_ value: Double) -> String { Int(value.rounded()).formatted(.number.grouping(.automatic)) }

    /// "3 d 4 h", "1 h 20 min", "12 min".
    static func duration(_ seconds: TimeInterval) -> String { SystemStats.duration(minutes: Int(seconds / 60)) }

    /// The words for a moment `seconds` before now: "now", "35 s ago", "17 min ago", "3 h ago".
    static func ago(_ seconds: TimeInterval) -> String {
        switch seconds {
        case ..<3: "now"
        case ..<120: "\(Int(seconds.rounded())) s ago"
        case ..<7200: "\(Int((seconds / 60).rounded())) min ago"
        default: "\(Int((seconds / 3600).rounded())) h ago"
        }
    }

    /// Shares' chart ceilings, then rates' from 100 KB/s, then temperatures'.
    static let shareSteps = [0.1, 0.2, 0.4, 0.6, 0.8, 1]
    static let rateSteps = [0.1, 0.25, 0.5, 1, 2, 4, 8, 16, 32, 64, 128, 256, 512, 1024, 2048].map { $0 * 1_000_000 }
    static let heatSteps: [Double] = [60, 80, 100, 120]

    /// A chart's ceiling: the first of `steps` at or over its highest point with `headroom` above it, else the last.
    static func ceiling(_ values: [Double?], steps: [Double], headroom: Double = 1.1) -> Double {
        let top = values.compactMap(\.self).max() ?? 0
        return steps.first { $0 >= top * headroom } ?? steps[steps.count - 1]
    }

    /// "4 MB/s", "250 KB/s": a rate ceiling's label.
    static func rateLabel(_ bytes: Double) -> String {
        bytes >= 1_000_000 ? "\(whole(bytes / 1_000_000)) MB/s" : "\(whole(bytes / 1_000)) KB/s"
    }
}
