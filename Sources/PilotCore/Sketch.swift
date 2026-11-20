import Foundation

/// A sketch drawn in a note (pilot-ui-redesign T28, Open question 8, Sven 2026-11-19): an SVG in the notes folder's
/// attachments/, linked as `![Sketch](attachments/sketch-<stamp>.svg)` on a line of its own, so any Markdown viewer shows
/// the picture. Its strokes are the SVG's own `<path>`s, each marked with its tool, so Pilot reads them back and the canvas
/// reopens the sketch for editing. Ink with no colour is `currentColor`: Pilot draws it in the note's text colour, so a
/// sketch made in dark mode reads in light mode too. The eraser is the canvas's: it removes strokes, so none is stored.
public struct Sketch: Equatable, Sendable, Codable {
    public enum Tool: String, Equatable, Sendable, Codable, CaseIterable {
        case pen, marker
    }

    /// A point in the sketch's own points, origin top left, as the SVG's viewBox.
    public struct Point: Equatable, Sendable, Codable {
        public var x: Double
        public var y: Double

        public init(_ x: Double, _ y: Double) { self.x = x; self.y = y }

        /// `[x, y]` in JSON, so a stroke's points read as a list of pairs.
        public init(from decoder: any Decoder) throws {
            var pair = try decoder.unkeyedContainer()
            x = try pair.decode(Double.self)
            y = try pair.decode(Double.self)
            guard pair.isAtEnd else { throw SketchError.unreadable("a point is [x, y]") }
        }

        public func encode(to encoder: any Encoder) throws {
            var pair = encoder.unkeyedContainer()
            try pair.encode(x)
            try pair.encode(y)
        }
    }

    public struct Stroke: Equatable, Sendable, Codable {
        public var tool: Tool
        /// `#rrggbb`, or nil for the note's text colour (`currentColor`).
        public var ink: String?
        /// The line's width in points.
        public var width: Double
        public var points: [Point]

        public init(tool: Tool = .pen, ink: String? = nil, width: Double = Sketch.penWidth, points: [Point]) {
            self.tool = tool; self.ink = ink; self.width = width; self.points = points
        }

        /// The points as drawn, in the SVG and on screen: a single point is a line to itself, so its round cap draws a dot.
        public var drawn: [Point] { points.count == 1 ? points + points : points }
    }

    /// The canvas's size in points: the note's width when drawn, and the SVG's viewBox.
    public var width: Double
    public var height: Double
    public var strokes: [Stroke]

    public init(width: Double, height: Double, strokes: [Stroke] = []) {
        self.width = width; self.height = height; self.strokes = strokes
    }

    public static let penWidth: Double = 2
    public static let markerWidth: Double = 12
    /// A marker stroke's opacity, so text and pen under it still read.
    public static let markerOpacity: Double = 0.35
    /// The alt words a sketch's link carries.
    public static let alt = "Sketch"

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

    // MARK: SVG out

    /// The sketch as an SVG document: one `<path>` per stroke, its tool in its class, in drawing order.
    public func svg() -> String {
        var out = """
        <?xml version="1.0" encoding="UTF-8"?>
        <svg xmlns="http://www.w3.org/2000/svg" width="\(Self.number(width))" height="\(Self.number(height))" \
        viewBox="0 0 \(Self.number(width)) \(Self.number(height))" data-pilot-sketch="1">

        """
        for stroke in strokes {
            let opacity = stroke.tool == .marker ? " stroke-opacity=\"\(Self.number(Self.markerOpacity))\"" : ""
            out += "<path class=\"pilot-\(stroke.tool.rawValue)\" d=\"\(Self.d(stroke.drawn))\" fill=\"none\" "
                + "stroke=\"\(stroke.ink ?? "currentColor")\"\(opacity) stroke-width=\"\(Self.number(stroke.width))\" "
                + "stroke-linecap=\"round\" stroke-linejoin=\"round\"/>\n"
        }
        return out + "</svg>\n"
    }

    /// `M x y L x y …`.
    static func d(_ points: [Point]) -> String {
        points.enumerated().map { i, p in "\(i == 0 ? "M" : "L")\(number(p.x)) \(number(p.y))" }.joined(separator: " ")
    }

    /// At most two decimals, no trailing zeros: the same point always writes the same text.
    static func number(_ value: Double) -> String {
        var s = String(format: "%.2f", value)
        while s.hasSuffix("0") { s.removeLast() }
        if s.hasSuffix(".") { s.removeLast() }
        return s == "-0" ? "0" : s
    }

    // MARK: SVG in

    /// Reads a sketch Pilot wrote back from its SVG: its size from the viewBox, a stroke from each of its marked paths.
    /// An SVG Pilot did not write (no `data-pilot-sketch`) is refused, so the canvas never opens a picture it cannot keep.
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

    /// Writes over a sketch's file in place, as the canvas's Done does on a sketch reopened: its link stays the same.
    public func write(to url: URL) throws {
        try Data(validated().svg().utf8).write(to: url, options: .atomic)
    }

    /// Saves a new sketch into `folder`/attachments/ as `sketch-<stamp>.svg` (a name taken gets "-2") and answers the
    /// Markdown that shows it: `![Sketch](attachments/sketch-<stamp>.svg)`.
    public func save(in folder: URL, now: Date) throws -> String {
        let link = try NoteAttachments.save(Data(validated().svg().utf8), named: "sketch-\(NoteAttachments.stamp(now))", ext: "svg", in: folder, now: now)
        guard link.hasPrefix("![](") else { throw SketchError.unreadable("unexpected link \(link)") }
        return "![\(Self.alt)](" + link.dropFirst(4)
    }

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
