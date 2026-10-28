// Vendored from AeroSpace (MIT, nikitabobko/AeroSpace) at 74a1bf17: Sources/Common/model/MonitorDescription.swift
public enum MonitorDescription: Equatable, Sendable {
    case sequenceNumber(Int)
    case main
    case secondary
    case pattern(CaseInsensitiveRegex)
    /// Pilot: a display by its UUID (NSScreen.displayUUID), so a workspace pin survives replugging (N7).
    case displayId(String)

    public static func pattern(_ raw: String) -> MonitorDescription? {
        switch CaseInsensitiveRegex.new(raw) {
            case .success(let regex): .pattern(regex)
            case .failure: nil
        }
    }
}

public func parseMonitorDescription(_ raw: String) -> ResOrStr<MonitorDescription> {
    if let int = Int(raw) {
        return int >= 1
            ? .success(.sequenceNumber(int))
            : .failure("Monitor sequence numbers uses 1-based indexing. Values less than 1 are illegal")
    }
    if raw == "main" {
        return .success(.main)
    }
    if raw == "secondary" {
        return .success(.secondary)
    }

    return raw.isEmpty
        ? .failure("Empty string is an illegal monitor description")
        : CaseInsensitiveRegex.new(raw).map(MonitorDescription.pattern)
}
