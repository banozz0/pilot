import Foundation
import UniformTypeIdentifiers

/// A Markdown file as GitHub shows a README (Pilot 1.0.2, Sven: "preview of repo files show <h1> instead of heading"), as
/// one HTML page for the file previews (MarkdownPreview): CommonMark's blocks and inlines with GitHub's tables, task
/// lists, strikethrough, bare links and alerts, and the HTML GitHub allows. Raw HTML passes through an allowlist: tags
/// GitHub keeps, a few attributes each, links only to http, https, mailto or an anchor; scripts, styles and frames go
/// with their contents. A local image comes inline as a data URI, read inside the file's root alone; a remote one shows
/// its alt text, as the page loads nothing (its CSP allows no source but data: images).
public enum MarkdownHTML {
    /// The tags GitHub's sanitizer keeps.
    static let tags: Set<String> = [
        "h1", "h2", "h3", "h4", "h5", "h6", "div", "br", "b", "i", "strong", "em", "a", "pre", "code", "img", "tt", "ins", "del",
        "sup", "sub", "p", "ol", "ul", "table", "thead", "tbody", "tfoot", "blockquote", "dl", "dt", "dd", "kbd", "q", "samp", "var",
        "hr", "ruby", "rt", "rp", "li", "tr", "td", "th", "s", "strike", "summary", "details", "caption", "figure", "figcaption",
        "abbr", "cite", "dfn", "mark", "small", "span", "time", "wbr", "picture", "source", "u",
    ]
    /// Tags dropped with everything inside them.
    static let dropped: Set<String> = ["script", "style", "iframe", "object", "embed", "textarea", "title", "noscript", "template",
                                       "svg", "math", "select", "frame", "frameset", "noembed", "xmp", "plaintext", "head"]
    /// The attributes kept, any tag; `src`, `srcset` and `href` are checked on their own.
    static let attributes: Set<String> = ["align", "title", "alt", "width", "height", "open", "start", "colspan", "rowspan", "name",
                                          "id", "media", "datetime", "valign"]
    /// CommonMark's HTML block tags (its type 6): a line opening with one starts raw HTML that runs to a blank line.
    static let blockTags: Set<String> = [
        "address", "article", "aside", "base", "basefont", "blockquote", "body", "caption", "center", "col", "colgroup", "dd",
        "details", "dialog", "dir", "div", "dl", "dt", "fieldset", "figcaption", "figure", "footer", "form", "frame", "frameset",
        "h1", "h2", "h3", "h4", "h5", "h6", "head", "header", "hr", "html", "iframe", "legend", "li", "link", "main", "menu",
        "menuitem", "nav", "noframes", "ol", "optgroup", "option", "p", "param", "picture", "search", "section", "summary", "table",
        "tbody", "td", "tfoot", "th", "thead", "title", "tr", "track", "ul",
    ]

    /// Tags with no closing tag.
    static let void: Set<String> = ["img", "br", "source", "wbr", "hr"]

    /// A Markdown file by its name: the one test every preview uses to pick this renderer.
    public static func isMarkdown(_ url: URL) -> Bool { ["md", "markdown", "mdown", "mkd", "mdx"].contains(url.pathExtension.lowercased()) }

    /// The most text a preview renders, in UTF-8 bytes; a longer file shows its source (MarkdownPreview's hosts).
    public static let renderCap = 200_000

    public static func renders(_ text: String) -> Bool { text.utf8.count <= renderCap }

    /// Lines longer than this skip the block patterns and are paragraph text (round 3): no line-level regex ever sees
    /// more than 4 KB, so none of them can run long, whatever its backtracking.
    static let longLine = 4096

    static func long(_ line: some StringProtocol) -> Bool { line.utf8.count > longLine }

    /// What an image's `src` becomes: a URL the page may load (a data URI), or nil for its alt text.
    public typealias Images = (String) -> String?

    /// One render's work (Pilot 1.0.2 review, round 2): every loop in the parse spends steps, everything it writes spends
    /// bytes, and a cancelled render counts as spent. Past either limit every loop stops and the page is nil, so the
    /// preview shows the file's source: no input, however it is built, runs the parse long or grows its output big.
    /// Local images are counted by their own caps (localImages), not here.
    final class Budget {
        static let steps = 10_000_000, bytes = 4 << 20
        let maxSteps: Int, maxBytes: Int
        private(set) var steps = 0, bytes = 0, spent = false
        private var checked = 0

        init(steps: Int = Budget.steps, bytes: Int = Budget.bytes) { (maxSteps, maxBytes) = (steps, bytes) }

        /// Spends `n` steps; false once the budget is spent. A cancelled task is seen every 8,192 steps.
        @discardableResult func step(_ n: Int = 1) -> Bool {
            steps += n
            if steps > maxSteps { spent = true }
            if steps - checked > 8192 { checked = steps; if Task.isCancelled { spent = true } }
            return !spent
        }

        /// Spends `n` bytes of output; false once the budget is spent.
        @discardableResult func emit(_ n: Int) -> Bool {
            bytes += n
            if bytes > maxBytes { spent = true }
            return !spent
        }

        /// `text`, its bytes spent.
        func emit(_ text: String) -> String { emit(text.utf8.count); return text }
    }

    /// `markdown` as the body of a page; nil once `budget` is spent.
    static func body(_ markdown: String, images: @escaping Images, budget: Budget = Budget()) -> String? {
        var lines = markdown.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
            .components(separatedBy: "\n").map(expandTabs)
        budget.step(lines.count + markdown.utf8.count)
        let front = budget.emit(frontMatter(&lines))
        let refs = references(&lines, budget: budget)
        // Only an image read from disk is given back here, as localImages' own caps hold it; a data: src the file wrote
        // itself is output like any other text (round 3: one used 19,000 times would otherwise pass the budget).
        let counted: Images = { src in
            let found = images(src)
            if let found, !src.trimmingCharacters(in: .whitespaces).lowercased().hasPrefix("data:") { budget.emit(-found.utf8.count) }
            return found
        }
        var parser = Parser(refs: refs, images: counted, budget: budget)
        let html = front + parser.blocks(lines[...])
        return budget.spent ? nil : html
    }

    /// A skill's or an agent's YAML front matter, taken off the top, as GitHub shows it: a table of its keys, else the
    /// YAML as code.
    static func frontMatter(_ lines: inout [String]) -> String {
        guard lines.first == "---", let end = lines.dropFirst().firstIndex(where: { $0 == "---" || $0 == "..." }) else { return "" }
        let yaml = lines[1..<end]
        lines.removeSubrange(0...end)
        let pairs = yaml.map { long($0) ? nil : $0.firstMatch(of: Self.yamlPair) }
        guard !pairs.isEmpty, pairs.allSatisfy({ $0 != nil }) else {
            return "<pre><code class=\"language-yaml\">\(escape(yaml.joined(separator: "\n")))</code></pre>\n"
        }
        let keys = pairs.map { "<th>\(escape($0!.1))</th>" }.joined(), values = pairs.map { "<td>\(escape($0!.2))</td>" }.joined()
        return "<table class=\"front\">\n<thead><tr>\(keys)</tr></thead>\n<tbody><tr>\(values)</tr></tbody>\n</table>\n"
    }

    /// The page: its theme's CSS in the head, the CSP that loads nothing, the body; nil when the file is too big or too
    /// costly to render (Budget), so its source shows instead.
    public static func page(_ markdown: String, css: String, images: @escaping Images) -> String? {
        guard renders(markdown), let body = body(markdown, images: images) else { return nil }
        return """
        <!doctype html><html><head><meta charset="utf-8">
        <meta http-equiv="Content-Security-Policy" content="default-src 'none'; img-src data:; style-src 'unsafe-inline'; base-uri 'none'; form-action 'none'">
        <style>\(css)</style></head><body><article class="markdown">\(body)</article></body></html>
        """
    }

    /// Reads a file's local images as data URIs: `src` resolved from `folder`, kept inside `root` once links are followed,
    /// an image by its type, at most `cap` bytes each and `total` in all; anything with a scheme or `//` is remote (nil).
    public static func localImages(folder: URL, root: URL, cap: Int = 2 << 20, total: Int = 8 << 20) -> Images {
        let inside = root.standardizedFileURL.resolvingSymlinksInPath().path
        var spent = 0
        return { src in
            let src = src.trimmingCharacters(in: .whitespaces)
            if src.lowercased().hasPrefix("data:image/") { return src }
            guard !src.isEmpty, !src.hasPrefix("//"), scheme(src) == nil else { return nil }
            let path = String(src.prefix { $0 != "?" && $0 != "#" })
            let decoded = path.removingPercentEncoding ?? path
            let url = (decoded.hasPrefix("/") ? root.appendingPathComponent(decoded) : folder.appendingPathComponent(decoded))
                .standardizedFileURL.resolvingSymlinksInPath()
            guard url.path.hasPrefix(inside + "/"), let type = UTType(filenameExtension: url.pathExtension), type.conforms(to: .image),
                  let values = try? url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey]), values.isRegularFile == true,
                  let size = values.fileSize, size <= cap, spent + size <= total,
                  let data = try? Data(contentsOf: url) else { return nil }
            spent += data.count
            return "data:\(type.preferredMIMEType ?? "image/png");base64,\(data.base64EncodedString())"
        }
    }

    // MARK: Helpers

    static func expandTabs(_ line: String) -> String {
        guard line.contains("\t") else { return line }
        var out = "", column = 0
        for c in line {
            if c == "\t" { let n = 4 - column % 4; out += String(repeating: " ", count: n); column += n }
            else { out.append(c); column += 1 }
        }
        return out
    }

    static func escape(_ text: some StringProtocol) -> String {
        var out = ""
        out.reserveCapacity(text.count)
        for c in text {
            switch c {
            case "&": out += "&amp;"
            case "<": out += "&lt;"
            case ">": out += "&gt;"
            case "\"": out += "&quot;"
            default: out.append(c)
            }
        }
        return out
    }

    /// `text` escaped, its entities kept: `&nbsp;` stays one, a bare & is escaped.
    static func escapeKeepingEntities(_ text: some StringProtocol) -> String {
        var out = "", rest = Substring(text)
        while let amp = rest.firstIndex(of: "&") {
            out += escape(rest[..<amp])
            let after = rest[amp...]
            if let entity = after.prefixMatch(of: entityPattern) { out += after[entity.range]; rest = after[entity.range.upperBound...] }
            else { out += "&amp;"; rest = after.dropFirst() }
        }
        return out + escape(rest)
    }

    // Regexes kept compiled: a literal in a loop builds its program again each pass (60,000 tags took 7.8 s).
    nonisolated(unsafe) static let yamlPair = /^([A-Za-z0-9_-]+):[ \t]*(.*)$/
    nonisolated(unsafe) static let anyTag = /<[^>]*>/
    nonisolated(unsafe) static let size = /[0-9]{1,5}(?:%|px)?/
    nonisolated(unsafe) static let entityPattern = /&(?:#[0-9]{1,7}|#[xX][0-9a-fA-F]{1,6}|[A-Za-z][A-Za-z0-9]{1,31});/

    /// A URL's scheme, lowercased, control characters and spaces ignored as browsers do; nil for a relative one.
    static func scheme(_ url: String) -> String? {
        let plain = String(url.unicodeScalars.filter { $0.value > 0x20 }.map(Character.init)).lowercased()
        guard let colon = plain.firstIndex(of: ":") else { return nil }
        let head = plain[..<colon]
        guard let first = head.first, first.isLetter, head.allSatisfy({ $0.isLetter || $0.isNumber || "+.-".contains($0) }) else { return nil }
        return String(head)
    }

    /// A link the page may follow: http, https, mailto, an anchor or a relative path; one whose first part holds an & or
    /// a : may hide a scheme behind an entity (`java&#09;script:`), so it is none of these.
    static func safeHref(_ url: String) -> Bool {
        guard let scheme = scheme(url) else { return !url.prefix { !"/?#".contains($0) }.contains { $0 == "&" || $0 == ":" } }
        return ["http", "https", "mailto"].contains(scheme)
    }

    /// A heading's anchor as GitHub makes it: lowercased, punctuation dropped, spaces as hyphens.
    static func slug(_ html: String) -> String {
        let text = html.replacing(anyTag, with: "").replacing(entityPattern, with: "").lowercased()
        return String(text.compactMap { c -> Character? in
            if c.isLetter || c.isNumber || c == "-" || c == "_" { return c }
            return c == " " ? "-" : nil
        })
    }

    /// The link reference definitions (`[ref]: url "title"`), taken out of `lines`, outside code fences.
    static func references(_ lines: inout [String], budget: Budget) -> [String: (url: String, title: String?)] {
        var refs: [String: (url: String, title: String?)] = [:], kept: [String] = [], fence: String?
        let pattern = /^ {0,3}\[([^\]]+)\]:\s*<?([^\s>]+)>?(?:\s+(?:"([^"]*)"|'([^']*)'|\(([^)]*)\)))?\s*$/
        for line in lines where budget.step(line.utf8.count + 1) {
            let trimmed = line.drop { $0 == " " }
            if let open = fence { if trimmed.hasPrefix(open) { fence = nil }; kept.append(line); continue }
            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") { fence = String(trimmed.prefix(3)); kept.append(line); continue }
            if !long(line), let m = line.wholeMatch(of: pattern) {
                let key = m.1.lowercased().split(whereSeparator: \.isWhitespace).joined(separator: " ")
                if refs[key] == nil { refs[key] = (String(m.2), (m.3 ?? m.4 ?? m.5).map(String.init)) }
                continue
            }
            kept.append(line)
        }
        lines = kept
        return refs
    }

    // MARK: Raw HTML

    nonisolated(unsafe) static let tagPattern = /<(\/?)([A-Za-z][A-Za-z0-9-]*)((?:\s+[^\s"'>\/=]+(?:\s*=\s*(?:"[^"]*"|'[^']*'|[^\s"'=<>`]+))?)*)\s*(\/?)>/
    nonisolated(unsafe) static let attributePattern = /([^\s"'>\/=]+)(?:\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s"'=<>`]+)))?/

    /// Raw HTML through the allowlist: comments and dropped tags gone, every other tag rebuilt from what it may keep.
    /// Linear: a tag is matched only inside its window from `<` to the next `<` or `>` (a quoted `<` leaves it text), and
    /// a dropped tag with no closing tag left is never looked for again.
    /// Each pass spends the bytes it moves past and writes on `budget`, and stops once it is spent.
    static func sanitize(_ html: some StringProtocol, images: Images, budget: Budget) -> String {
        var out = "", rest = Substring(html), unclosed: Set<String> = []
        func pass(_ next: Substring) { budget.step(rest.utf8.count - next.utf8.count + 1); rest = next }
        while budget.step(), let lt = rest.firstIndex(of: "<") {
            out += budget.emit(escapeKeepingEntities(rest[..<lt]))
            let at = rest[lt...]
            if at.hasPrefix("<!--") {
                pass(at.range(of: "-->").map { at[$0.upperBound...] } ?? "")
                continue
            }
            let stop = at.dropFirst().firstIndex { $0 == "<" || $0 == ">" }
            guard let stop, at[stop] == ">", at.utf8.distance(from: at.startIndex, to: stop) < longLine, let m = at[...stop].wholeMatch(of: tagPattern) else {
                out += budget.emit("&lt;"); pass(at.dropFirst()); continue
            }
            let name = m.2.lowercased(), closing = !m.1.isEmpty
            pass(at[at.index(after: stop)...])
            if dropped.contains(name) {
                // Dropped with what is inside it; a stray closing tag is only dropped, and leaves later ones be.
                if !closing, !unclosed.contains(name) {
                    if let end = rest.range(of: "</\(name)", options: .caseInsensitive) {
                        let after = rest[end.upperBound...]
                        pass(after.firstIndex(of: ">").map { after[after.index(after: $0)...] } ?? "")
                    } else { budget.step(rest.utf8.count); unclosed.insert(name) }
                }
                continue
            }
            out += budget.emit(tag(name, attributes: String(m.3), closing: closing, images: images))
        }
        return out + budget.emit(escapeKeepingEntities(rest))
    }

    /// One allowed tag rebuilt, or nothing for one GitHub drops; an img whose src does not load becomes its alt text.
    static func tag(_ name: String, attributes raw: String, closing: Bool, images: Images) -> String {
        guard tags.contains(name) else { return "" }
        if closing { return void.contains(name) ? "" : "</\(name)>" }
        var kept: [String] = [], alt = "", loads = false
        for m in raw.matches(of: attributePattern) {
            let key = m.1.lowercased(), value = String(m.2 ?? m.3 ?? m.4 ?? "")
            switch key {
            case "href":
                guard name == "a", safeHref(value) else { continue }
                kept.append("href=\"\(escapeKeepingEntities(value))\"")
            case "src":
                guard name == "img", let src = images(value) else { continue }
                loads = true
                kept.append("src=\"\(escape(src))\"")
            case "srcset":
                // A data URI holds commas of its own: it goes whole, its width or density left off.
                let first = value.lowercased().hasPrefix("data:image/") ? value.split(separator: " ").first
                    : value.split(separator: ",").first?.split(separator: " ").first
                guard name == "source", let first, let src = images(String(first)) else { return "" }
                kept.append("srcset=\"\(escape(src))\"")
            case "width", "height":
                guard value.wholeMatch(of: size) != nil else { continue }
                kept.append("\(key)=\"\(value)\"")
            case "align", "valign":
                guard ["left", "center", "right", "justify", "top", "middle", "bottom"].contains(value.lowercased()) else { continue }
                kept.append("\(key)=\"\(value.lowercased())\"")
            case "alt":
                alt = value
                kept.append("alt=\"\(escapeKeepingEntities(value))\"")
            default:
                guard attributes.contains(key) else { continue }
                kept.append(m.2 == nil && m.3 == nil && m.4 == nil ? key : "\(key)=\"\(escapeKeepingEntities(value))\"")
            }
        }
        if name == "img", !loads {
            return alt.isEmpty ? "" : "<span class=\"alt\">\(escapeKeepingEntities(alt))</span>"
        }
        if name == "a" { kept.append("rel=\"noreferrer\"") }
        return "<\(name)\(kept.isEmpty ? "" : " " + kept.joined(separator: " "))>"
    }

    // MARK: Blocks

    struct Parser {
        let refs: [String: (url: String, title: String?)]
        let images: Images
        let budget: Budget
        /// How deep quotes, lists and links may nest before the rest shows as plain text: a hostile README of 100,000 `>`
        /// would otherwise recurse past the stack and take Pilot, and its tap, down with it.
        static let maxDepth = 32
        var depth = 0

        nonisolated(unsafe) static let setext = /^ {0,3}(=+|-+)[ \t]*$/
        nonisolated(unsafe) static let alert = /\[!(NOTE|TIP|IMPORTANT|WARNING|CAUTION)\]/.ignoresCase()
        nonisolated(unsafe) static let task = /^\[([ xX])\](?: |$)/
        nonisolated(unsafe) static let autolink = /<([A-Za-z][A-Za-z0-9+.-]{1,31}:[^\s<>]*)>/
        nonisolated(unsafe) static let email = /<([A-Za-z0-9.!#$%&'*+\/=?^_`{|}~-]+@[A-Za-z0-9](?:[A-Za-z0-9-]*[A-Za-z0-9])?(?:\.[A-Za-z0-9](?:[A-Za-z0-9-]*[A-Za-z0-9])?)+)>/
        // Round 3: no two adjacent quantifiers share a run of spaces (a lazy capture before [ \t]+#+ and [ \t]*$ was
        // quadratic on one long line); closing #s and an info string are trimmed in Swift.
        nonisolated(unsafe) static let atxPattern = /^ {0,3}(#{1,6})(?:[ \t]+(.*))?$/
        nonisolated(unsafe) static let rule = /^ {0,3}(?:(?:\*[ \t]*){3,}|(?:-[ \t]*){3,}|(?:_[ \t]*){3,})$/
        nonisolated(unsafe) static let fencePattern = /^( {0,3})(`{3,}|~{3,})(.*)$/
        nonisolated(unsafe) static let itemPattern = /^( {0,3})([-+*]|[0-9]{1,9}[.)])( {1,}|$)(.*)$/
        nonisolated(unsafe) static let delimiterRow = /^ {0,3}\|?[ \t]*:?-+:?[ \t]*+(?:\|[ \t]*:?-+:?[ \t]*+)*\|?[ \t]*$/
        nonisolated(unsafe) static let htmlStart = /^ {0,3}<(\/?)([A-Za-z][A-Za-z0-9-]*)(?:[\s\/>]|$)/
        nonisolated(unsafe) static let htmlLine = /^ {0,3}(?:<[A-Za-z][A-Za-z0-9-]*(?:\s+[^\s"'>\/=]+(?:\s*=\s*(?:"[^"]*"|'[^']*'|[^\s"'=<>`]+))?)*\s*\/?>|<\/[A-Za-z][A-Za-z0-9-]*\s*>)[ \t]*$/

        static func indent(_ line: String) -> Int { line.prefix { $0 == " " }.count }
        static func blank(_ line: String) -> Bool { line.allSatisfy { $0 == " " } }

        /// A heading line: its level and its words, closing #s dropped; never a line over 4 KB.
        static func atx(_ line: String) -> (level: Int, text: String)? {
            guard !long(line), let m = line.wholeMatch(of: atxPattern) else { return nil }
            var text = (m.2 ?? "").trimmingCharacters(in: [" ", "\t"])
            let hashes = text.reversed().prefix { $0 == "#" }.count
            if hashes > 0 {
                let rest = text.dropLast(hashes)
                if rest.isEmpty || rest.last == " " || rest.last == "\t" { text = rest.trimmingCharacters(in: [" ", "\t"]) }
            }
            return (m.1.count, text)
        }

        /// A fence line: its indent, its marker and its info string's first word; a ``` fence's info holds no backtick.
        static func fence(_ line: String) -> (indent: Int, marker: Substring, language: String)? {
            guard !long(line), let m = line.wholeMatch(of: fencePattern) else { return nil }
            let info = m.3.trimmingCharacters(in: [" ", "\t"])
            if m.2.first == "`", info.contains("`") { return nil }
            return (m.1.count, m.2, info.split(separator: " ").first.map(String.init) ?? "")
        }

        /// A list item line; never a line over 4 KB.
        static func item(_ line: String) -> Regex<(Substring, Substring, Substring, Substring, Substring)>.Match? {
            long(line) ? nil : line.wholeMatch(of: itemPattern)
        }

        /// The lines as blocks; a tight list's paragraphs come without their <p>.
        mutating func blocks(_ lines: ArraySlice<String>, tight: Bool = false) -> String {
            guard depth < Self.maxDepth else { return budget.emit("<p>\(escape(lines.joined(separator: "\n")))</p>\n") }
            depth += 1
            defer { depth -= 1 }
            var out = "", paragraph: [String] = [], i = lines.startIndex
            func taken() -> String {
                defer { paragraph = [] }
                return inline(paragraph.map { $0.drop { $0 == " " } }.joined(separator: "\n").trimmingCharacters(in: .whitespaces))
            }
            func flush() {
                guard !paragraph.isEmpty else { return }
                let text = taken()
                out += tight ? text + "\n" : "<p>\(text)</p>\n"
                budget.emit(8)
            }
            // Every line spends its length (the checks on it are each linear in it); a spent budget, a closed preview
            // among them, stops the parse here and in every loop below.
            while i < lines.endIndex, budget.step(lines[i].utf8.count + 1) {
                let line = lines[i]
                if Self.blank(line) { flush(); i += 1; continue }
                if long(line) { paragraph.append(line); i += 1; continue }
                // Setext headings: the paragraph above a row of = or -.
                if !paragraph.isEmpty, let level = line.wholeMatch(of: Self.setext).map({ $0.1.first == "=" ? 1 : 2 }) {
                    let text = taken()
                    out += budget.emit("<h\(level) id=\"\(escape(slug(text)))\">\(text)</h\(level)>\n")
                    i += 1; continue
                }
                if Self.indent(line) >= 4, paragraph.isEmpty {
                    var code: [String] = []
                    while i < lines.endIndex, budget.step(lines[i].utf8.count + 1), Self.blank(lines[i]) || Self.indent(lines[i]) >= 4 { code.append(String(lines[i].dropFirst(min(4, Self.indent(lines[i]))))); i += 1 }
                    while code.last.map(Self.blank) == true { code.removeLast() }
                    out += budget.emit("<pre><code>\(escape(code.joined(separator: "\n")))</code></pre>\n")
                    continue
                }
                if let (spaces, marker, language) = Self.fence(line) {
                    flush()
                    var code: [String] = []
                    i += 1
                    while i < lines.endIndex, budget.step(lines[i].utf8.count + 1) {
                        let l = lines[i], t = l.drop { $0 == " " }
                        if Self.indent(l) < 4, t.hasPrefix(marker), t.allSatisfy({ $0 == marker.first || $0 == " " }) { i += 1; break }
                        code.append(String(l.dropFirst(min(spaces, Self.indent(l)))))
                        i += 1
                    }
                    let lang = language.isEmpty ? "" : " class=\"language-\(escape(language))\""
                    out += budget.emit("<pre><code\(lang)>\(escape(code.joined(separator: "\n")))</code></pre>\n")
                    continue
                }
                if let (level, words) = Self.atx(line) {
                    flush()
                    let text = inline(words)
                    out += budget.emit("<h\(level) id=\"\(escape(slug(text)))\">\(text)</h\(level)>\n")
                    i += 1; continue
                }
                if line.wholeMatch(of: Self.rule) != nil { flush(); out += budget.emit("<hr>\n"); i += 1; continue }
                if line.drop(while: { $0 == " " }).hasPrefix(">"), Self.indent(line) < 4 {
                    flush()
                    var quoted: [String] = []
                    while i < lines.endIndex, budget.step(lines[i].utf8.count + 1) {
                        let l = lines[i], t = l.drop { $0 == " " }
                        if t.hasPrefix(">") { var q = t.dropFirst(); if q.first == " " { q = q.dropFirst() }; quoted.append(String(q)) }
                        else if !Self.blank(l), let last = quoted.last, !Self.blank(last), !starts(l) { quoted.append(l) }
                        else { break }
                        i += 1
                    }
                    out += quote(quoted)
                    continue
                }
                if let html = htmlBlock(lines, at: &i, interrupting: !paragraph.isEmpty) { flush(); out += html; continue }
                if i + 1 < lines.endIndex, line.contains("|"), !long(lines[i + 1]), lines[i + 1].wholeMatch(of: Self.delimiterRow) != nil,
                   Self.cells(line).count == Self.cells(lines[i + 1]).count {
                    flush()
                    out += table(lines, at: &i)
                    continue
                }
                if let m = Self.item(line), paragraph.isEmpty || Self.interrupts(m) {
                    flush()
                    out += list(lines, at: &i)
                    continue
                }
                paragraph.append(line)
                i += 1
            }
            flush()
            return out
        }

        /// A list item may break a paragraph only with words, an ordered one only from 1.
        static func interrupts(_ m: Regex<(Substring, Substring, Substring, Substring, Substring)>.Match) -> Bool {
            guard !m.4.trimmingCharacters(in: .whitespaces).isEmpty else { return false }
            let marker = m.2
            return marker.first.map { "-+*".contains($0) } == true || marker.dropLast() == "1"
        }

        /// A line that starts a block of its own, so it is no paragraph's lazy continuation.
        func starts(_ line: String) -> Bool {
            guard !long(line) else { return false }
            return Self.atx(line) != nil || line.wholeMatch(of: Self.rule) != nil || Self.fence(line) != nil
                || line.drop(while: { $0 == " " }).hasPrefix(">") || Self.item(line) != nil
                || line.prefixMatch(of: Self.htmlStart).map { Self.blockTagLine($0) } == true
        }

        static func blockTagLine(_ m: Regex<(Substring, Substring, Substring)>.Match) -> Bool { blockTags.contains(m.2.lowercased()) }

        /// A blockquote, or one of GitHub's alerts (`> [!NOTE]`) with its title.
        mutating func quote(_ quoted: [String]) -> String {
            if let first = quoted.first?.trimmingCharacters(in: .whitespaces),
               let m = first.wholeMatch(of: Self.alert) {
                let kind = m.1.lowercased()
                budget.emit(80)
                return "<div class=\"alert alert-\(kind)\"><p class=\"alert-title\">\(kind.prefix(1).uppercased() + kind.dropFirst())</p>\n"
                    + blocks(quoted.dropFirst()[...]) + "</div>\n"
            }
            budget.emit(27)
            return "<blockquote>\n\(blocks(quoted[...]))</blockquote>\n"
        }

        /// Raw HTML from a line opening with a block tag, a comment or (not breaking a paragraph) a lone tag, to the blank
        /// line after it; script, style, pre and textarea run to their closing tag.
        mutating func htmlBlock(_ lines: ArraySlice<String>, at i: inout Int, interrupting: Bool) -> String? {
            let line = lines[i], trimmed = line.drop { $0 == " " }
            guard !long(line), Self.indent(line) < 4, trimmed.hasPrefix("<") else { return nil }
            func until(_ end: String) -> String {
                var taken: [String] = []
                while i < lines.endIndex, budget.step(lines[i].utf8.count + 1) {
                    taken.append(lines[i]); i += 1
                    if taken.last!.range(of: end, options: .caseInsensitive) != nil { break }
                }
                return taken.joined(separator: "\n")
            }
            if trimmed.hasPrefix("<!--") { _ = until("-->"); return "" }
            let start = line.prefixMatch(of: Self.htmlStart)
            let name = start.map { $0.2.lowercased() } ?? ""
            if ["script", "style", "pre", "textarea"].contains(name), start?.1.isEmpty == true {
                return sanitize(until("</\(name)>"), images: images, budget: budget) + "\n"
            }
            guard (start.map(Self.blockTagLine) == true) || (!interrupting && line.wholeMatch(of: Self.htmlLine) != nil) else { return nil }
            var taken: [String] = []
            while i < lines.endIndex, budget.step(lines[i].utf8.count + 1), !Self.blank(lines[i]) { taken.append(lines[i]); i += 1 }
            return sanitize(taken.joined(separator: "\n"), images: images, budget: budget) + "\n"
        }

        /// A row's cells, its outer pipes dropped and `\|` kept in a cell.
        static func cells(_ line: String) -> [String] {
            var row = line.trimmingCharacters(in: .whitespaces)
            if row.hasPrefix("|") { row.removeFirst() }
            if row.hasSuffix("|"), !row.hasSuffix("\\|") { row.removeLast() }
            var cells: [String] = [], cell = "", escaped = false, code = false
            for c in row {
                if c == "|", !escaped, !code { cells.append(cell.trimmingCharacters(in: .whitespaces)); cell = ""; continue }
                if c == "`" { code.toggle() }
                if escaped, c == "|" { cell.removeLast() }
                escaped = c == "\\" && !escaped
                cell.append(c)
            }
            return cells + [cell.trimmingCharacters(in: .whitespaces)]
        }

        /// A GitHub table: its header, its alignments, its rows to a blank line or a block of another kind.
        mutating func table(_ lines: ArraySlice<String>, at i: inout Int) -> String {
            let head = Self.cells(lines[i])
            let aligns = Self.cells(lines[i + 1]).map { cell -> String in
                switch (cell.hasPrefix(":"), cell.hasSuffix(":")) {
                case (true, true): " align=\"center\""
                case (false, true): " align=\"right\""
                case (true, false): " align=\"left\""
                default: ""
                }
            }
            i += 2
            // Each cell spends a step and its bytes, a padded one too: a header 25,000 cells wide over 50,000 rows stops at
            // the budget, not at 11 GB.
            var out = budget.emit("<table>\n<thead><tr>")
            for (n, cell) in head.enumerated() where budget.step() { budget.emit(9 + aligns[n].utf8.count); out += "<th\(aligns[n])>\(inline(cell))</th>" }
            out += budget.emit("</tr></thead>\n")
            var body = ""
            while i < lines.endIndex, budget.step(lines[i].utf8.count + 1), !Self.blank(lines[i]), !starts(lines[i]) {
                let row = Self.cells(lines[i])
                body += budget.emit("<tr>")
                for n in aligns.indices where budget.step() { budget.emit(9 + aligns[n].utf8.count); body += "<td\(aligns[n])>\(n < row.count ? inline(row[n]) : "")</td>" }
                body += budget.emit("</tr>\n")
                i += 1
            }
            return out + (body.isEmpty ? "" : "<tbody>\n\(body)</tbody>\n") + "</table>\n"
        }

        /// A list from its first item: each item's lines are those indented past its marker, blank ones and lazy ones;
        /// loose when a blank line parts its items or an item's blocks; `[ ]` and `[x]` make task items.
        mutating func list(_ lines: ArraySlice<String>, at i: inout Int) -> String {
            guard let first = Self.item(lines[i]) else { return "" }
            let ordered = !"-+*".contains(first.2.first!), kind = first.2.last!
            let start = ordered ? Int(first.2.dropLast()) ?? 1 : 1
            var items: [[String]] = [], loose = false
            while i < lines.endIndex, budget.step(lines[i].utf8.count + 1), let m = Self.item(lines[i]), m.2.last == kind, ordered == !"-+*".contains(m.2.first!),
                  lines[i].wholeMatch(of: Self.rule) == nil {
                let gap = m.3.count > 4 ? 1 : max(m.3.count, 1)
                let width = m.1.count + m.2.count + gap
                var item = [m.3.count > 4 ? String(repeating: " ", count: m.3.count - 1) + m.4 : String(m.4)]
                i += 1
                var blankRun = false
                while i < lines.endIndex, budget.step(lines[i].utf8.count + 1) {
                    let l = lines[i]
                    if Self.blank(l) { item.append(""); blankRun = true; i += 1; continue }
                    if Self.indent(l) >= width { item.append(String(l.dropFirst(width))); blankRun = false; i += 1; continue }
                    if !blankRun, !starts(l), !(item.last.map(Self.blank) ?? true) { item.append(l); i += 1; continue }
                    break
                }
                // Blank lines between items, or inside one between its blocks, make the list loose.
                var trailing = 0
                while item.count > 1, item.last.map(Self.blank) == true { item.removeLast(); trailing += 1 }
                if trailing > 0, i < lines.endIndex, Self.item(lines[i])?.2.last == kind { loose = true }
                if item.dropFirst().contains(where: Self.blank) { loose = true }
                items.append(item)
                if trailing > 0, !(i < lines.endIndex && Self.item(lines[i])?.2.last == kind) { break }
            }
            let tag = ordered ? "ol" : "ul"
            var out = ordered && start != 1 ? "<ol start=\"\(start)\">\n" : "<\(tag)>\n"
            for var item in items where budget.step() {
                var task = ""
                if let m = item[0].prefixMatch(of: Self.task) {
                    task = "<input type=\"checkbox\" disabled\(m.1 == " " ? "" : " checked")> "
                    item[0] = String(item[0][m.range.upperBound...])
                }
                let inner = blocks(item[...], tight: !loose).trimmingCharacters(in: .newlines)
                budget.emit(28 + task.utf8.count)
                out += task.isEmpty ? "<li>\(inner)</li>\n" : "<li class=\"task\">\(task)\(inner)</li>\n"
            }
            return out + "</\(tag)>\n"
        }

        // MARK: Inlines

        /// A paragraph's characters with what one pass finds in them: each code span's closing run and each `[`'s `]`,
        /// so no character is scanned again for each mark that might start there (Pilot 1.0.2 review: a hostile README
        /// of `[` or backticks was quadratic).
        struct Marks {
            let chars: [Character]
            let budget: Budget
            /// A backtick run's start → the start of the run that closes its code span.
            var codeEnd: [Int: Int] = [:]
            /// A `[` → its `]`, outside code spans and escapes.
            var close: [Int: Int] = [:]

            init(_ chars: [Character], budget: Budget) {
                self.chars = chars
                self.budget = budget
                // Both passes below and the cursor walk are each linear in the characters.
                guard budget.step(3 * chars.count + 1) else { return }
                // Code spans: each run closes at the next run of its length; a per-length cursor only moves forward. A
                // backslash before a run keeps its first backtick from opening a span, but a run closes one whatever is
                // before it, as a backslash inside a span is a backslash (`cd C:\`).
                var runs: [(at: Int, length: Int, escaped: Bool)] = [], i = 0
                while i < chars.count {
                    var escaped = false
                    if chars[i] == "\\" {
                        guard i + 1 < chars.count, chars[i + 1] == "`" else { i += 2; continue }
                        escaped = true
                        i += 1
                    }
                    guard chars[i] == "`" else { i += 1; continue }
                    var n = 0
                    while i + n < chars.count, chars[i + n] == "`" { n += 1 }
                    runs.append((i, n, escaped)); i += n
                }
                var byLength: [Int: [Int]] = [:]
                for (k, run) in runs.enumerated() { byLength[run.length, default: []].append(k) }
                var cursor: [Int: Int] = [:], done = -1
                for (k, run) in runs.enumerated() where run.at > done {
                    let (at, length) = run.escaped ? (run.at + 1, run.length - 1) : (run.at, run.length)
                    guard length > 0, let same = byLength[length] else { continue }
                    var c = cursor[length] ?? 0
                    while c < same.count, same[c] <= k { c += 1 }
                    cursor[length] = c
                    guard c < same.count else { continue }
                    codeEnd[at] = runs[same[c]].at
                    done = runs[same[c]].at
                }
                // Brackets, a stack over the text with code spans and escapes stepped over.
                var open: [Int] = []
                i = 0
                while i < chars.count {
                    switch chars[i] {
                    case "\\": i += 2; continue
                    case "`":
                        var n = 0
                        while i + n < chars.count, chars[i + n] == "`" { n += 1 }
                        i = codeEnd[i].map { $0 + n } ?? i + n
                        continue
                    case "[": open.append(i)
                    case "]": if let o = open.popLast() { close[o] = i }
                    default: break
                    }
                    i += 1
                }
            }

            /// The index after a raw tag from its `<`, scanning only to the next `<` or `>`: windows from one `<` to the
            /// next never overlap, so every character is looked at once. A tag whose quoted value holds a `<` stays text.
            func tagEnd(from lt: Int) -> Int? {
                var j = lt + 1
                defer { budget.step(j - lt) }
                while j < chars.count, j - lt < longLine {
                    if chars[j] == ">" { return j + 1 }
                    if chars[j] == "<" { return nil }
                    j += 1
                }
                return nil
            }

            /// Where `</name` next starts at or after `from`, any case.
            func closing(_ name: String, from: Int) -> Int? {
                let want = Array("</" + name)
                var j = from
                defer { budget.step(j - from + 1) }
                while j + want.count <= chars.count {
                    if chars[j] == "<", chars[j + 1] == "/", (0..<want.count).allSatisfy({ chars[j + $0].lowercased() == String(want[$0]) }) { return j }
                    j += 1
                }
                return nil
            }
        }

        /// Inline text: code spans, escapes, links and images, autolinks, raw HTML through the allowlist, entities, line
        /// breaks, then emphasis by CommonMark's delimiter rules. Links nested past `maxDepth` stay as their words.
        /// `level` starts at the block depth, so quotes, lists and links share one cap of 32 and the stack stays shallow.
        func inline(_ text: String, level: Int? = nil) -> String {
            let level = level ?? depth
            guard level <= Self.maxDepth else { return budget.emit(escapeKeepingEntities(text)) }
            // Every piece spends its bytes as it is made: a reference used 25,000 times stops at the budget.
            var nodes: [Node] = [], plain = ""
            func words() { if !plain.isEmpty { nodes.append(.text(budget.emit(plain))); plain = "" } }
            func push(_ html: String) { words(); nodes.append(.html(budget.emit(html))) }
            let marks = Marks(Array(text), budget: budget), chars = marks.chars
            var i = 0, comments = 0, unclosed: Set<String> = []
            while i < chars.count, budget.step() {
                let c = chars[i]
                switch c {
                case "\\" where i + 1 < chars.count:
                    let next = chars[i + 1]
                    if next == "\n" { push("<br>\n"); i += 2; continue }
                    if next.isASCII, next.isPunctuation || next.isSymbol { plain += escape(String(next)); i += 2; continue }
                    plain += "\\"; i += 1
                case "`":
                    var run = 0
                    while i + run < chars.count, chars[i + run] == "`" { run += 1 }
                    budget.step(run)
                    if let end = marks.codeEnd[i], budget.step(end - i) {
                        var code = String(chars[(i + run)..<end]).replacingOccurrences(of: "\n", with: " ")
                        if code.count > 1, code.first == " ", code.last == " ", code.contains(where: { $0 != " " }) { code = String(code.dropFirst().dropLast()) }
                        push("<code>\(escape(code))</code>")
                        i = end + run
                    } else { plain += String(repeating: "`", count: run); i += run }
                case "!" where i + 1 < chars.count && chars[i + 1] == "[":
                    if let (html, next) = link(marks, at: i + 1, image: true, level: level) { push(html); i = next } else { plain += "!"; i += 1 }
                case "[":
                    if let (html, next) = link(marks, at: i, image: false, level: level) { push(html); i = next } else { plain += "["; i += 1 }
                case "<":
                    if chars[i...].starts(with: "<!--") {
                        // A comment runs to its -->; once none is left, no later one is looked for.
                        if comments >= 0, let end = (min(i + 4, chars.count)..<max(i + 4, chars.count - 2)).first(where: { chars[$0] == "-" && chars[$0 + 1] == "-" && chars[$0 + 2] == ">" }) {
                            i = end + 3
                        } else { comments = -1; plain += "&lt;"; i += 1 }
                        continue
                    }
                    guard let end = marks.tagEnd(from: i) else { plain += "&lt;"; i += 1; continue }
                    let raw = String(chars[i..<end])
                    if let m = raw.wholeMatch(of: Self.autolink), safeHref(String(m.1)) {
                        push("<a href=\"\(escape(m.1))\" rel=\"noreferrer\">\(escape(m.1))</a>")
                    } else if let m = raw.wholeMatch(of: Self.email) {
                        push("<a href=\"mailto:\(escape(m.1))\">\(escape(m.1))</a>")
                    } else if let m = raw.wholeMatch(of: tagPattern) {
                        let name = m.2.lowercased(), closing = !m.1.isEmpty
                        if dropped.contains(name) {
                            // Dropped with what is inside it, as in a block of HTML.
                            // A stray closing tag is only dropped: it never marks its name as left open.
                            i = end
                            if !closing, !unclosed.contains(name) {
                                if let stop = marks.closing(name, from: end) { i = marks.tagEnd(from: stop) ?? stop + name.count + 2 } else { unclosed.insert(name) }
                            }
                            continue
                        }
                        push(tag(name, attributes: String(m.3), closing: closing, images: images))
                    } else { plain += "&lt;"; i += 1; continue }
                    i = end
                case "&":
                    let rest = String(chars[i..<min(chars.count, i + 40)])
                    if let m = rest.prefixMatch(of: entityPattern) { plain += m.0; i += m.0.count } else { plain += "&amp;"; i += 1 }
                case "\n":
                    let hard = plain.hasSuffix("  ")
                    while plain.hasSuffix(" "), budget.step() { plain.removeLast() }
                    if hard { push("<br>\n") } else { plain += "\n" }
                    i += 1
                case "*", "_", "~":
                    var run = 0
                    while i + run < chars.count, chars[i + run] == c { run += 1 }
                    budget.step(run)
                    let before = i > 0 ? chars[i - 1] : " ", after = i + run < chars.count ? chars[i + run] : " "
                    let (open, close) = Self.flanking(c, before: before, after: after)
                    words()
                    nodes.append(.delimiter(Delimiter(char: c, count: run, original: run, open: open, close: close)))
                    i += run
                case let c where (c == "h" || c == "w") && (i == 0 || !(chars[i - 1].isLetter || chars[i - 1].isNumber || chars[i - 1] == "/"))
                    && (chars[i...].starts(with: "http://") || chars[i...].starts(with: "https://") || chars[i...].starts(with: "www.")):
                    // A bare link runs to a space or a <, its closing punctuation left out; it is taken whole, so the
                    // next look starts past it.
                    var end = i
                    while end < chars.count, !chars[end].isWhitespace, chars[end] != "<" { end += 1 }
                    budget.step(2 * (end - i))
                    var url = String(chars[i..<end])
                    // Its parens counted once, the count kept as each ) comes off: http://x and 190,000 ) is linear.
                    var opens = 0, closes = 0
                    for ch in url { if ch == "(" { opens += 1 } else if ch == ")" { closes += 1 } }
                    while let last = url.last, budget.step() {
                        if "?!.,:*_~'\"".contains(last) { url.removeLast() }
                        else if last == ")", closes > opens { url.removeLast(); closes -= 1 }
                        else { break }
                    }
                    // Nothing after the scheme: what the scan passed is words, so no later look covers it again.
                    if url.count > (url.hasPrefix("https") ? 8 : url.hasPrefix("http") ? 7 : 4) {
                        let href = url.hasPrefix("www.") ? "http://" + url : url
                        push("<a href=\"\(escape(href))\" rel=\"noreferrer\">\(escape(url))</a>")
                        i += url.count
                    } else { plain += escape(String(chars[i..<end])); i = end }
                default:
                    plain += escape(String(c)); i += 1
                }
            }
            words()
            return Self.emphasis(nodes, budget: budget)
        }

        /// A `[text](url "title")`, `[text][ref]`, `[ref]` or the image forms of these, from its `[`: its HTML and the index
        /// after it. Its `]` comes from the paragraph's one bracket pass; its words are inlines one level down.
        func link(_ marks: Marks, at open: Int, image: Bool, level: Int) -> (String, Int)? {
            let chars = marks.chars
            guard let close = marks.close[open] else { return nil }
            var url: String?, title: String?, next = close + 1
            if next < chars.count, chars[next] == "(", let (u, t, end) = Self.destination(chars, from: next + 1, budget: budget) {
                (url, title, next) = (u, t, end)
            } else {
                // A reference: looked up only by a label of at most 999 characters (CommonMark's limit), so brackets that
                // pair but make no link copy nothing (100,000 [ then 100,000 ] was quadratic).
                guard !refs.isEmpty else { return nil }
                var key = (open + 1)..<close
                if next < chars.count, chars[next] == "[", let end = marks.close[next] {
                    if end > next + 1 { key = (next + 1)..<end }
                    next = end + 1
                }
                guard key.count <= 999, budget.step(key.count),
                      let ref = refs[String(chars[key]).lowercased().split(whereSeparator: \.isWhitespace).joined(separator: " ")] else { return nil }
                (url, title) = (ref.url, ref.title)
            }
            // The words are copied only now, once the link is known.
            guard let url, budget.step(close - open) else { return nil }
            let label = String(chars[(open + 1)..<close])
            let titled = title.map { " title=\"\(escapeKeepingEntities($0))\"" } ?? ""
            if image {
                let alt = Self.plainText(label)
                guard let src = images(url) else { return (alt.isEmpty ? "" : "<span class=\"alt\">\(escape(alt))</span>", next) }
                return ("<img src=\"\(escape(src))\" alt=\"\(escape(alt))\"\(titled)>", next)
            }
            let href = safeHref(url) ? " href=\"\(escapeKeepingEntities(url))\"" : ""
            return ("<a\(href)\(titled) rel=\"noreferrer\">\(inline(label, level: level + 1))</a>", next)
        }

        /// A link's `url "title")` after its `(`: the url, its title, the index after the `)`. The url stops at a space,
        /// its closing `)`, a `[` or a `]`, and a title at 1,024 characters, so a run of `[](` or `](` costs each its own
        /// few characters; what it reads it spends.
        static func destination(_ chars: [Character], from start: Int, budget: Budget) -> (String, String?, Int)? {
            var j = start
            defer { budget.step(j - start + 1) }
            func spaces() { while j < chars.count, chars[j].isWhitespace { j += 1 } }
            spaces()
            var url = ""
            if j < chars.count, chars[j] == "<" {
                j += 1
                while j < chars.count, chars[j] != ">" { if chars[j] == "\n" || chars[j] == "<" { return nil }; url.append(chars[j]); j += 1 }
                guard j < chars.count else { return nil }
                j += 1
            } else {
                var depth = 0
                while j < chars.count, !chars[j].isWhitespace, chars[j] != "[", chars[j] != "]" {
                    let c = chars[j]
                    if c == "\\", j + 1 < chars.count { url.append(chars[j + 1]); j += 2; continue }
                    if c == "(" { depth += 1 }
                    if c == ")" { if depth == 0 { break }; depth -= 1 }
                    url.append(c); j += 1
                }
            }
            spaces()
            var title: String?
            if j < chars.count, let closer = ["\"": "\"", "'": "'", "(": ")"][String(chars[j])] {
                j += 1
                var t = "", length = 0
                while j < chars.count, String(chars[j]) != closer { length += 1; if length > 1024 { return nil }; t.append(chars[j]); j += 1 }
                guard j < chars.count else { return nil }
                j += 1
                title = t
                spaces()
            }
            guard j < chars.count, chars[j] == ")" else { return nil }
            return (url, title, j + 1)
        }

        /// An image's alt: its label's words with the marks dropped.
        static func plainText(_ label: String) -> String {
            // One pass (round 3: the old pattern rescanned to the end for each ]( with no ) after it): marks dropped,
            // a ](…) dropped to its ), and once no ) is left none is looked for again.
            let chars = Array(label)
            var out = "", i = 0, parens = true
            while i < chars.count {
                let c = chars[i]
                if "*_`~[".contains(c) || (c == "!" && i + 1 < chars.count && chars[i + 1] == "[") { i += 1; continue }
                if c == "]" {
                    if parens, i + 1 < chars.count, chars[i + 1] == "(" {
                        if let close = chars[(i + 2)...].firstIndex(of: ")") { i = close + 1; continue }
                        parens = false
                    }
                    i += 1; continue
                }
                out.append(c); i += 1
            }
            return out
        }

        // MARK: Emphasis

        enum Node {
            case text(String), html(String), delimiter(Delimiter)
        }

        struct Delimiter {
            let char: Character
            var count: Int
            let original: Int
            let open: Bool, close: Bool
            var opens: [String] = [], closes: [String] = []
        }

        /// CommonMark's flanking rules: whether a run may open or close emphasis.
        static func flanking(_ c: Character, before: Character, after: Character) -> (Bool, Bool) {
            let punct = { (x: Character) in x.isPunctuation || x.isSymbol }
            let left = !after.isWhitespace && (!punct(after) || before.isWhitespace || punct(before))
            let right = !before.isWhitespace && (!punct(before) || after.isWhitespace || punct(after))
            guard c == "_" else { return (left, right) }
            return (left && (!right || punct(before)), right && (!left || punct(after)))
        }

        /// CommonMark's emphasis pass: each closing run takes the nearest opener of its kind on a stack, the rule of three
        /// kept, runs between them dropped from the stack; a closer that finds none raises its kind's floor (openers
        /// bottom), so no opener is looked at twice for that kind. `~` and `~~` strike only their own length.
        static func emphasis(_ nodes: [Node], budget: Budget) -> String {
            var nodes = nodes
            var stack: [Int] = [], floor: [String: Int] = [:]
            func get(_ i: Int) -> Delimiter { if case .delimiter(let d) = nodes[i] { return d }; fatalError("not a delimiter") }
            for ci in nodes.indices where budget.step() {
                guard case .delimiter(var closer) = nodes[ci] else { continue }
                if closer.close {
                    let kind = "\(closer.char)\(closer.open)\(closer.original % 3)"
                    while closer.count > 0, budget.step() {
                        var k = stack.count - 1, found: Int?
                        while k >= 0, budget.step(), stack[k] > floor[kind, default: -1] {
                            let opener = get(stack[k])
                            if opener.char == closer.char, opener.count > 0 {
                                if closer.char == "~" {
                                    if opener.count == closer.count, closer.count <= 2 { found = k; break }
                                } else if !((opener.close || closer.open) && (opener.original + closer.original) % 3 == 0
                                            && !(opener.original % 3 == 0 && closer.original % 3 == 0)) {
                                    found = k; break
                                }
                            }
                            k -= 1
                        }
                        guard let k = found else { floor[kind] = stack.last ?? -1; break }
                        let oi = stack[k]
                        var opener = get(oi)
                        let used = closer.char == "~" ? closer.count : (opener.count >= 2 && closer.count >= 2 ? 2 : 1)
                        let tag = closer.char == "~" ? "del" : used == 2 ? "strong" : "em"
                        opener.count -= used; closer.count -= used
                        opener.opens.insert("<\(tag)>", at: 0); closer.closes.append("</\(tag)>")
                        budget.emit(2 * tag.utf8.count + 5)
                        nodes[oi] = .delimiter(opener)
                        stack.removeSubrange((opener.count > 0 ? k + 1 : k)...)
                    }
                }
                nodes[ci] = .delimiter(closer)
                if closer.open, closer.count > 0 { stack.append(ci) }
            }
            return nodes.map { node in
                switch node {
                case .text(let t), .html(let t): return t
                case .delimiter(let d):
                    // The run's unmatched characters are output too.
                    budget.emit(d.count)
                    return d.closes.joined() + String(repeating: d.char, count: d.count) + d.opens.joined()
                }
            }.joined()
        }
    }
}
