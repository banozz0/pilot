// Vendored from AeroSpace (MIT, nikitabobko/AeroSpace) at 74a1bf17: Sources/AppBundle/model/MonitorDescriptionEx.swift

extension MonitorDescription {
    @MainActor func resolveMonitor(sortedMonitors: [MonitorInfo]) -> MonitorInfo? {
        switch self {
            case .sequenceNumber(let number): sortedMonitors.getOrNil(atIndex: number - 1)
            case .main: mainMonitorInfo
            case .pattern(let regex): sortedMonitors.first { $0.name.contains(caseInsensitiveRegex: regex) }
            case .displayId(let id): sortedMonitors.first { $0.displayId == id } // Pilot
            case .secondary:
                sortedMonitors.takeIf { $0.count == 2 }?
                    .first { $0.rect.topLeftCorner != mainMonitorInfo.rect.topLeftCorner }
        }
    }
}
