// Vendored from AeroSpace (MIT, nikitabobko/AeroSpace) at 74a1bf17: Sources/AppBundle/util/NSRunningApplicationEx.swift
import AppKit

extension NSRunningApplication {
    var idForDebug: String {
        "PID: \(processIdentifier) ID: \(bundleIdentifier ?? executableURL?.description ?? "")"
    }
}
