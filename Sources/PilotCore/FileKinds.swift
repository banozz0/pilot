import Foundation

/// One kind of file or link the Default apps page sets the app for (card agent-bo-95422842, Sven 2026-10-05: "configure
/// what app opens each kind of file", as Finder's Open With › Change All does).
public struct FileKind: Equatable, Sendable {
    public let id: String, name: String
    /// What the default is read from, the first, and changed for, each: a file type, or links (https and http together).
    public let handlers: [DefaultHandler]
    /// What macOS does on a change that the row says first: it asks Sven to confirm a new browser.
    public let confirmNote: String?

    public init(id: String, name: String, handlers: [DefaultHandler], confirmNote: String? = nil) {
        self.id = id; self.name = name; self.handlers = handlers; self.confirmNote = confirmNote
    }

    /// "Web links (http, https)" read as its title, "Web links", and what it covers, "http, https"; nil for a bare name.
    public var title: String { split.title }
    public var detail: String? { split.detail }

    private var split: (title: String, detail: String?) {
        guard name.hasSuffix(")"), let open = name.lastIndex(of: "(") else { return (name, nil) }
        return (String(name[..<open]).trimmingCharacters(in: .whitespaces), String(name[name.index(after: open)..<name.index(before: name.endIndex)]))
    }

    /// The Pilot roles whose app follows this default (web links → browser), found again after a change.
    public var roles: [AppRole] { AppRole.allCases.filter { !Set($0.defaultHandlers).isDisjoint(with: handlers) } }
}

public enum FileKinds {
    public struct Group: Sendable {
        public let name: String
        public let kinds: [FileKind]
    }

    private static func type(_ id: String, _ name: String) -> FileKind { FileKind(id: id, name: name, handlers: [.contentType(id)]) }

    public static let groups: [Group] = [
        Group(name: "Text", kinds: [type("public.plain-text", "Plain text (.txt)")]),
        Group(name: "Markdown", kinds: [type("net.daringfireball.markdown", "Markdown (.md)")]),
        Group(name: "JSON, YAML and TOML", kinds: [type("public.json", "JSON (.json)"), type("public.yaml", "YAML (.yaml, .yml)"),
                                                   type("public.toml", "TOML (.toml)")]),
        Group(name: "Source code", kinds: [
            type("public.swift-source", "Swift (.swift)"), type("public.python-script", "Python (.py)"),
            type("com.netscape.javascript-source", "JavaScript (.js)"), type("public.shell-script", "Shell script (.sh)"),
            type("public.c-source", "C (.c)"), type("public.source-code", "Other source code"),
        ]),
        Group(name: "Images", kinds: [type("public.png", "PNG"), type("public.jpeg", "JPEG"), type("public.heic", "HEIC"),
                                      type("com.compuserve.gif", "GIF"), type("org.webmproject.webp", "WebP"), type("public.svg-image", "SVG")]),
        Group(name: "PDF", kinds: [type("com.adobe.pdf", "PDF")]),
        Group(name: "Video", kinds: [type("public.mpeg-4", "MP4 video (.mp4)"), type("com.apple.quicktime-movie", "QuickTime movie (.mov)")]),
        Group(name: "Audio", kinds: [type("public.mp3", "MP3"), type("public.mpeg-4-audio", "MPEG-4 audio (.m4a)"),
                                     type("com.microsoft.waveform-audio", "WAV"), type("org.xiph.flac", "FLAC")]),
        Group(name: "Archives", kinds: [type("public.zip-archive", "Zip (.zip)"), type("org.gnu.gnu-zip-archive", "Gzip (.gz)"),
                                        type("public.tar-archive", "Tar (.tar)"), type("org.7-zip.7-zip-archive", "7-Zip (.7z)")]),
        Group(name: "Links", kinds: [
            FileKind(id: "web", name: "Web links (http, https)", handlers: AppRole.browser.defaultHandlers + [.url("http://example.com")],
                     confirmNote: "macOS asks you to confirm a new web browser."),
            FileKind(id: "mail", name: "Mail links (mailto)", handlers: AppRole.mail.defaultHandlers, confirmNote: "macOS may ask you to confirm."),
        ]),
    ]
}
