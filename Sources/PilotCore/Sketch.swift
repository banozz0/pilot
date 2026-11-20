import Foundation

/// A sketch a note already holds (pilot-ui-redesign T28; drawing sketches removed, Sven 2026-11-20): an SVG Pilot wrote
/// in the notes folder's attachments/, linked as `![Sketch](attachments/sketch-<stamp>.svg)`. ImageIO reads no SVG, so
/// Pilot reads its strokes (the SVG's own marked `<path>`s) and draws it as the note's picture; nothing writes one any
/// more. Ink with no colour is `currentColor`: Pilot draws it in the note's text colour, so it reads in light and dark.
public struct Sketch: Equatable, Sendable {
    public enum Tool: String, Equatable, Sendable, CaseIterable {
        case pen, marker
    }

    /// A point in the sketch's own points, origin top left, as the SVG's viewBox.
    public struct Point: Equatable, Sendable {
        public var x: Double
        public var y: Double

        public init(_ x: Double, _ y: Double) { self.x = x; self.y = y }
    }

    public struct Stroke: Equatable, Sendable {
        public var tool: Tool
        /// `#rrggbb`, or nil for the note's text colour (`currentColor`).
        public var ink: String?
        /// The line's width in points.
        public var width: Double
        public var points: [Point]

        public init(tool: Tool = .pen, ink: String? = nil, width: Double = Sketch.penWidth, points: [Point]) {
            self.tool = tool; self.ink = ink; self.width = width; self.points = points
        }

        /// The points as drawn: a single point is a line to itself, so its round cap draws a dot.
        public var drawn: [Point] { points.count == 1 ? points + points : points }
    }

    /// Its size in points: the SVG's viewBox.
    public var width: Double
    public var height: Double
    public var strokes: [Stroke]

    public init(width: Double, height: Double, strokes: [Stroke] = []) {
        self.width = width; self.height = height; self.strokes = strokes
    }

    public static let penWidth: Double = 2
    /// A marker stroke's opacity, so text and pen under it still read.
    public static let markerOpacity: Double = 0.35

    /// Whether an attachment's name or link is an SVG, the one kind a sketch is.
    public static func isSVG(_ name: String) -> Bool { name.lowercased().hasSuffix(".svg") }

    /// Refuses what the SVG could not hold or draw: no room, a number that is not finite, a colour that is not `#rrggbb`.
    public func validated() throws -> Sketch {
        guard width.isFinite, height.isFinite, width > 0, height > 0 else { throw SketchError.unreadable("width and height must be above 0") }
        for stroke in strokes {
            guard stroke.width.isFinite, stroke.width > 0 else { throw SketchError.unreadable("a stroke's width must be above 0") }
            guard !stroke.points.isEmpty else { throw SketchError.unreadable("a stroke needs at least one point") }
            guard stroke.points.allSatisfy({ $0.x.isFinite && $0.y.isFinite }) else { throw SketchError.unreadable("a point is not a number") }
            if let ink = stroke.ink, !OmarchyThemes.isColour(ink) { throw SketchError.unreadable("ink \(ink) is not #rrggbb") }
        }
        return self
    }

    // MARK: SVG in

    /// Reads a sketch Pilot wrote back from its SVG: its size from the viewBox, a stroke from each of its marked paths.
    /// An SVG Pilot did not write (no `data-pilot-sketch`) is refused.
    public init(svg data: Data) throws {
        let reader = SketchReader()
        let parser = XMLParser(data: data)
        parser.delegate = reader
        parser.shouldResolveExternalEntities = false
        guard parser.parse(), let size = reader.size else { throw SketchError.unreadable("not an SVG Pilot can read") }
        guard reader.isSketch else { throw SketchError.unreadable("not a sketch Pilot wrote") }
        self = try Sketch(width: size.width, height: size.height, strokes: reader.strokes).validated()
    }

    public static func load(from url: URL) throws -> Sketch { try Sketch(svg: Data(contentsOf: url)) }

    /// The sketch an attachment holds, or nil when it is no SVG or not one Pilot wrote.
    public static func read(at url: URL) -> Sketch? { isSVG(url.lastPathComponent) ? try? load(from: url) : nil }

    /// A path's `d` as Pilot writes it: `M` then `L`s, absolute, numbers apart by spaces or commas.
    static func points(_ d: String) -> [Point]? {
        var numbers: [Double] = []
        for word in d.split(whereSeparator: { $0 == " " || $0 == "," || $0.isNewline }) {
            let number = word.first == "M" || word.first == "L" ? word.dropFirst() : word[...]
            guard number.isEmpty || Double(number) != nil else { return nil }
            if let n = Double(number) { numbers.append(n) }
        }
        guard !numbers.isEmpty, numbers.count.isMultiple(of: 2) else { return nil }
        return stride(from: 0, to: numbers.count, by: 2).map { Point(numbers[$0], numbers[$0 + 1]) }
    }
}

public enum SketchError: Error, LocalizedError, Equatable {
    case unreadable(String)

    public var errorDescription: String? {
        switch self { case .unreadable(let why): why }
    }
}

/// Reads a sketch's SVG: the root's viewBox and the marked paths, in order.
private final class SketchReader: NSObject, XMLParserDelegate {
    var isSketch = false
    var size: (width: Double, height: Double)?
    var strokes: [Sketch.Stroke] = []

    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?,
                attributes: [String: String] = [:]) {
        switch name {
        case "svg" where size == nil:
            isSketch = attributes["data-pilot-sketch"] != nil
            let box = (attributes["viewBox"] ?? "").split(separator: " ").compactMap { Double($0) }
            if box.count == 4 { size = (box[2], box[3]) }
        case "path":
            guard let tool = attributes["class"].flatMap({ $0.hasPrefix("pilot-") ? Sketch.Tool(rawValue: String($0.dropFirst(6))) : nil }),
                  var points = attributes["d"].flatMap(Sketch.points),
                  let width = attributes["stroke-width"].flatMap(Double.init) else { return }
            // A dot is written as a line to itself: read back as the one point it was.
            if points.count == 2, points[0] == points[1] { points.removeLast() }
            let ink = attributes["stroke"].flatMap { $0 == "currentColor" ? nil : $0 }
            strokes.append(Sketch.Stroke(tool: tool, ink: ink, width: width, points: points))
        default: break
        }
    }
}
