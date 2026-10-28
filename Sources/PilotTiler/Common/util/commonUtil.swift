// Vendored from AeroSpace (MIT, nikitabobko/AeroSpace) at 74a1bf17: Sources/Common/util/commonUtil.swift
import AppKit
import Darwin
import Foundation

@TaskLocal
public var refreshSessionEvent: RefreshSessionEvent? = nil

public func bugPrompt(
    _ __message: String = "",
    isDie: Bool = false,
    file: StaticString = #fileID,
    line: Int = #line,
    column: Int = #column,
    function: String = #function,
) -> String {
    let _message = __message.contains("\n") ? "\n" + __message.prefixLines(with: "    ") : __message
    let thread = Thread.current
    return """
        Please report to:
            https://github.com/nikitabobko/AeroSpace/discussions/categories/potential-bugs
            Please describe what you did to trigger this error

        Message: \(_message)
        Version: Pilot tiler, AeroSpace 74a1bf17
        refreshSessionEvent: \(refreshSessionEvent.prettyDescription)
        Date: \(Date.now)
        Thread name: \(thread.name.prettyDescription)
        Is main thread: \(thread.isMainThread)
        axTaskLocalAppThreadToken: \(axTaskLocalAppThreadToken.prettyDescription)
        macOS version: \(ProcessInfo().operatingSystemVersionString)
        Coordinate: \(file):\(line):\(column) \(function)
        die: \(isDie)
        Monitor count: \(NSScreen.screens.count)
        Displays have separate spaces: \(NSScreen.screensHaveSeparateSpaces)

        Stacktrace:
        \(getStringStacktrace())
        """
}

/// AeroSpace ended the process here. In Pilot an internal error is a `TilerFault`: Pilot's handler sees it, the
/// session boundary recovers (TilerFault.swift).
/// Pilot names: AeroSpace's dieT, die, check and orDie are raiseFaultT, raiseFault, ensure and orFault, so nothing reads
/// as a crash; they throw.
public func raiseFaultT<T>(
    _ __message: String = "",
    file: StaticString = #fileID,
    line: Int = #line,
    column: Int = #column,
    function: String = #function,
) throws(TilerFault) -> T {
    throw fault(__message, file: file, line: line, column: column, function: function)
}

/// A `TilerFault` already shown to Pilot's handler, for a caller that hands it on instead of throwing it.
public func fault(
    _ message: String,
    file: StaticString = #fileID,
    line: Int = #line,
    column: Int = #column,
    function: String = #function,
) -> TilerFault {
    let fault = TilerFault(
        message: message,
        report: bugPrompt(message, isDie: true, file: file, line: line, column: column, function: function),
    )
    tilerFaultHandler(fault)
    return fault
}

public enum RefreshSessionEvent: Sendable, CustomStringConvertible {
    case configAutoReload
    case globalObserver(String)
    case globalObserverLeftMouseUp
    case menuBarButton
    case hotkeyBinding
    case startup
    case pilotCall(String)
    case resetManipulatedWithMouse
    case ax(String)
    case focusFollowsMouse
    /// Pilot: a live swap's preview laid in mid-drag (card agent-bo-95423034); only the tree changed, so no complete refresh after.
    case dragPreview
    /// Pilot: a held inner gap's split laid out mid-drag (card agent-bo-95423035); the release refreshes once.
    case gapResize

    public var isStartup: Bool {
        if case .startup = self { return true } else { return false }
    }

    public var isFocusFollowsMouse: Bool {
        if case .focusFollowsMouse = self { return true } else { return false }
    }

    public var description: String {
        switch self {
            case .ax(let str): "ax(\(str))"
            case .configAutoReload: "configAutoReload"
            case .globalObserver(let str): "globalObserver(\(str))"
            case .globalObserverLeftMouseUp: "globalObserverLeftMouseUp"
            case .hotkeyBinding: "hotkeyBinding"
            case .menuBarButton: "menuBarButton"
            case .resetManipulatedWithMouse: "resetManipulatedWithMouse"
            case .pilotCall(let name): "pilotCall(\(name))"
            case .startup: "startup"
            case .focusFollowsMouse: "focusFollowsMouse"
            case .dragPreview: "dragPreview"
            case .gapResize: "gapResize"
        }
    }
}

// periphery:ignore

public func getStringStacktrace() -> String { Thread.callStackSymbols.joined(separator: "\n") }

@inlinable public func raiseFault(
    _ message: String = "",
    file: StaticString = #fileID,
    line: Int = #line,
    column: Int = #column,
    function: String = #function,
) throws(TilerFault) -> Never {
    try raiseFaultT(message, file: file, line: line, column: column, function: function)
}

public func ensure(
    _ condition: Bool,
    _ message: @autoclosure () -> String = "",
    file: StaticString = #fileID,
    line: Int = #line,
    column: Int = #column,
    function: String = #function,
) throws(TilerFault) {
    if !condition {
        try raiseFault(message(), file: file, line: line, column: column, function: function)
    }
}

/// `ensure` for code that cannot throw (deinit, `==`, a continuation body): the fault reaches Pilot's handler and the
/// engine carries on.
public func checkSoft(
    _ condition: Bool,
    _ message: @autoclosure () -> String = "",
    file: StaticString = #fileID,
    line: Int = #line,
    column: Int = #column,
    function: String = #function,
) {
    if !condition {
        _ = fault(message(), file: file, line: line, column: column, function: function)
    }
}

/// Pilot: computed once; AeroSpace looked the class up on every read.
public let isUnitTest: Bool = NSClassFromString("XCTestCase") != nil

extension Int {
    public func toDouble() -> Double { Double(self) }
}

extension String {
    public func removePrefix(_ prefix: String) -> String {
        hasPrefix(prefix) ? String(dropFirst(prefix.count)) : self
    }
}

/// 'id' stands for 'identity'. It's a common name in functional programming
public func id<T>(_ t: T) -> T { t }
