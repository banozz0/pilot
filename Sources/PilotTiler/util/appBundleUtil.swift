// Vendored from AeroSpace (MIT, nikitabobko/AeroSpace) at 74a1bf17: Sources/AppBundle/util/appBundleUtil.swift
import AppKit
import Foundation
import os

let signposter = OSSignposter(subsystem: "dev.banozz.pilot.tiler", category: .pointsOfInterest)

let myPid = NSRunningApplication.current.processIdentifier
let lockScreenAppBundleId = "com.apple.loginwindow"

/// Every window the engine parked or resized goes back to a visible centred frame on its monitor: on stop, and after a
/// fault (AeroSpace's beforeTermination).
@MainActor
func unparkAllWindows() {
    // Pilot (card agent-bo-95423038): popups, Pilot's top bars among them, were never laid out, so there is nothing to undo.
    for window in MacWindow.allWindowsMap.values where window.parent !== macosPopupWindowsContainer {
        let monitor = window.macApp.getAxRectForTermination(window.windowId)?.center.monitorApproximation ?? mainMonitorInfo
        let monitorVisibleRect = monitor.visibleRect
        let windowSize = window.lastFloatingSize ?? CGSize(width: monitorVisibleRect.width, height: monitorVisibleRect.height)
        // Pilot: on its own monitor; AeroSpace's offset without the monitor's corner put a second monitor's windows on the main one.
        let point = monitorVisibleRect.center - CGPoint(x: windowSize.width / 2, y: windowSize.height / 2)
        window.macApp.setAxFrameForTermination(window.windowId, point, windowSize)
    }
}

func - (a: CGPoint, b: CGPoint) -> CGPoint {
    CGPoint(x: a.x - b.x, y: a.y - b.y)
}

func + (a: CGPoint, b: CGPoint) -> CGPoint {
    CGPoint(x: a.x + b.x, y: a.y + b.y)
}

extension CGPoint: ConvenienceMutable {}

extension CGPoint {
    func distance(toOuterFrame rect: Rect) -> CGFloat {
        // Subtract 1 from maxX/maxY because the right/bottom bounds are
        // exclusive.
        let dx = max(rect.minX - x, 0, x - (rect.maxX - 1))
        let dy = max(rect.minY - y, 0, y - (rect.maxY - 1))
        return CGPoint(x: dx, y: dy).vectorLength
    }

    func coerce(in rect: Rect) -> CGPoint? {
        guard let xRange = rect.minX.until(incl: rect.maxX - 1) else { return nil }
        guard let yRange = rect.minY.until(incl: rect.maxY - 1) else { return nil }
        return CGPoint(x: x.coerce(in: xRange), y: y.coerce(in: yRange))
    }

    func addingXOffset(_ offset: CGFloat) -> CGPoint { CGPoint(x: x + offset, y: y) }
    func addingYOffset(_ offset: CGFloat) -> CGPoint { CGPoint(x: x, y: y + offset) }
    func addingOffset(_ orientation: Orientation, _ offset: CGFloat) -> CGPoint { orientation == .h ? addingXOffset(offset) : addingYOffset(offset) }

    func getProjection(_ orientation: Orientation) -> Double { orientation == .h ? x : y }

    var vectorLength: CGFloat { sqrt(x * x + y * y) }

    var monitorApproximation: MonitorInfo { monitorInfos.minBy { distance(toOuterFrame: $0.rect) } ?? mainMonitorInfo }

    var withYAxisFlipped: CGPoint {
        consuming get {
            self.y = mainMonitorInfo.height - self.y
            return self
        }
    }
}

extension CGFloat {
    func div(_ denominator: Int) -> CGFloat? {
        denominator == 0 ? nil : self / CGFloat(denominator)
    }

    func coerce(in range: ClosedRange<CGFloat>) -> CGFloat {
        switch true {
            case self > range.upperBound: range.upperBound
            case self < range.lowerBound: range.lowerBound
            default: self
        }
    }
}

extension CGPoint: @retroactive Hashable { // todo migrate to self written Point
    public func hash(into hasher: inout Hasher) {
        hasher.combine(x)
        hasher.combine(y)
    }
}

@inlinable
func checkCancellation(_ cm: CancellationMode = .cancellable) throws(CancellationError) {
    if cm == .cancellable && Task.isCancelled {
        throw CancellationError()
    }
}

public enum CancellationMode: Equatable, Sendable {
    case cancellable
    case nonCancellable
}
