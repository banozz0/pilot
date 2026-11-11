#!/usr/bin/env swift
// Prints Notification Center's Accessibility tree as the JSON Scripts/notifications-proof.py reads, words replaced by
// placeholders of the same length, so the fixture can be refreshed against the real macOS without keeping any text.
// Read-only: no press, no move, no notification posted. Needs an unlocked screen and a process with Accessibility.
//   swift Scripts/notification-shape.swift > Scripts/notifications-proof/shape-27.json
import AppKit
import ApplicationServices

func attr(_ e: AXUIElement, _ k: String) -> CFTypeRef? { var v: CFTypeRef?; return AXUIElementCopyAttributeValue(e, k as CFString, &v) == .success ? v : nil }
func text(_ e: AXUIElement, _ k: String) -> String? {
    guard let v = attr(e, k) else { return nil }
    return v as? String ?? (v as? NSAttributedString)?.string
}
func point(_ e: AXUIElement) -> [Double]? {
    guard let v = attr(e, "AXPosition") else { return nil }
    var p = CGPoint.zero
    return AXValueGetValue(v as! AXValue, .cgPoint, &p) ? [p.x, p.y] : nil
}

var lineNumber = 0
/// The same words always get the same placeholder, so "App, Title, Body" still lines up with its labelled lines.
var masks: [String: String] = [:]
func mask(_ words: String, _ label: String) -> String {
    if let done = masks[words] { return done }
    lineNumber += 1
    let done = "\(label)-\(lineNumber)-" + String(repeating: "x", count: max(0, words.count - 8))
    masks[words] = done
    return done
}
/// Every comma-separated part that isn't already a placeholder goes too: a layout with no labelled lines keeps no words.
func maskDescription(_ words: String) -> String {
    var out = words
    for (real, fake) in masks.sorted(by: { $0.key.count > $1.key.count }) { out = out.replacingOccurrences(of: real, with: fake) }
    return out.components(separatedBy: ", ").enumerated().map { index, part in
        if masks.values.contains(part) { return part }
        // macOS 27's Persistent layout runs the app into the title: "App Title, Body".
        if let fake = masks.values.first(where: { part.hasSuffix(" " + $0) }) {
            return mask(String(part.dropLast(fake.count + 1)), "App") + " " + fake
        }
        return mask(part, index == 0 ? "App" : "Text")
    }.joined(separator: ", ")
}

/// Notification Center's own action names stay; an app's button can carry personal words, so it goes.
func maskAction(_ raw: String) -> String {
    guard raw.hasPrefix("Name:") else { return raw }
    let name = String(raw.dropFirst(5).prefix { $0 != "\n" })
    let own: Set<String> = ["Close", "Clear All", "Show", "Show Details", "Hide Details", "Clear", "Options"]
    return own.contains(name) ? raw : "Name:" + mask(name, "Action") + raw.dropFirst(5 + name.count)
}

func node(_ e: AXUIElement, _ depth: Int) -> [String: Any] {
    var out: [String: Any] = [:]
    let role = text(e, "AXRole") ?? "?"
    out["role"] = role
    if let v = text(e, "AXSubrole"), !v.isEmpty { out["subrole"] = v }
    if let v = text(e, "AXIdentifier"), !v.isEmpty { out["identifier"] = (v.count > 20 ? "uuid-\(abs(v.hashValue))" : v) }
    if let v = point(e) { out["position"] = v }
    var names: CFArray?
    AXUIElementCopyActionNames(e, &names)
    let actions = (names as? [String]) ?? []
    if !actions.isEmpty { out["actions"] = actions.map(maskAction) }
    guard depth < 12 else { return out }
    let kids = attr(e, "AXChildren") as? [AXUIElement] ?? []
    let built = kids.map { node($0, depth + 1) }
    if !built.isEmpty { out["children"] = built }
    if role == "AXStaticText", let v = text(e, "AXValue") { out["value"] = mask(v, (out["identifier"] as? String) ?? "Text") }
    if let v = text(e, "AXAttributedDescription"), !v.isEmpty { out["description"] = maskDescription(v) }
    return out
}

guard AXIsProcessTrusted() else { fatalError("this process has no Accessibility grant") }
guard let nc = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.notificationcenterui").first else { fatalError("Notification Center isn't running") }
let app = AXUIElementCreateApplication(nc.processIdentifier)
AXUIElementSetMessagingTimeout(app, 2)
let windows = (attr(app, "AXWindows") as? [AXUIElement] ?? []).map { node($0, 0) }
var tree: [String: Any] = ["provenance": "Captured by Scripts/notification-shape.swift on macOS \(ProcessInfo.processInfo.operatingSystemVersionString)",
                           "role": "AXApplication", "expanded": (attr(app, "AXExpanded") as? Bool) ?? false, "windows": windows]
print(String(decoding: try JSONSerialization.data(withJSONObject: tree, options: [.prettyPrinted, .sortedKeys]), as: UTF8.self))
