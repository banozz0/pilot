import AppKit
import Testing
@testable import Clipboard

/// SPEC.md, Testing Decisions: the clipboard filter, tested on a private named pasteboard.
@Suite("Clipboard capture")
@MainActor
struct CaptureTests {
    let pasteboard = NSPasteboard.makePrivate()
    let capture = ClipboardCapture()

    func copy(_ text: String, marking markers: [String] = []) {
        pasteboard.copy(text, marking: markers.map { NSPasteboard.PasteboardType($0) })
    }

    @Test("A plain copy is kept")
    func plainKept() throws {
        copy("hello pilot")
        let item = try #require(capture.capture(pasteboard, sourceApp: "com.apple.TextEdit"))
        #expect(item.kind == .text)
        #expect(item.text == "hello pilot")
        #expect(item.sourceApp == "com.apple.TextEdit")
    }

    @Test("A concealed copy (a password manager's) is skipped")
    func concealedSkipped() {
        copy("hunter2", marking: ["org.nspasteboard.ConcealedType"])
        #expect(capture.capture(pasteboard, sourceApp: "com.apple.TextEdit") == nil)
    }

    @Test("A transient copy is skipped")
    func transientSkipped() {
        copy("one-off", marking: ["org.nspasteboard.TransientType"])
        #expect(capture.capture(pasteboard, sourceApp: "com.apple.TextEdit") == nil)
    }

    @Test("A copy from an app on the ignore list is skipped; Bitwarden is on it by default")
    func ignoredAppSkipped() {
        copy("from the vault")
        #expect(capture.capture(pasteboard, sourceApp: "com.bitwarden.desktop") == nil)
        var custom = ClipboardCapture()
        custom.ignoredApps.insert("com.apple.TextEdit")
        #expect(custom.capture(pasteboard, sourceApp: "com.apple.TextEdit") == nil)
    }

    @Test("Rich text keeps its RTF and is searched by its plain text")
    func richText() throws {
        pasteboard.clearContents()
        let rtf = try NSAttributedString(string: "bold move").data(from: NSRange(location: 0, length: 9),
                                                                     documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf])
        pasteboard.setData(rtf, forType: .rtf)
        pasteboard.setString("bold move", forType: .string)
        let item = try #require(capture.capture(pasteboard, sourceApp: nil))
        #expect(item.kind == .richText)
        #expect(item.text == "bold move")
        #expect(item.contents == [["public.rtf": rtf, "public.utf8-plain-text": Data("bold move".utf8)]])
    }

    @Test("An image with no text is an image")
    func image() throws {
        let png = try pasteboard.copyPNG()
        pasteboard.setData(Data(repeating: 0, count: 64), forType: .tiff)
        let item = try #require(capture.capture(pasteboard, sourceApp: nil))
        #expect(item.kind == .image)
        #expect(item.contents == [["public.png": png]], "the TIFF beside a PNG is not kept")
    }

    @Test("With Save images off, an image is not kept and text still is")
    func saveImagesOff() throws {
        var noImages = ClipboardCapture()
        noImages.saveImages = false
        _ = try pasteboard.copyPNG()
        #expect(noImages.capture(pasteboard, sourceApp: nil) == nil)
        copy("still text")
        #expect(noImages.capture(pasteboard, sourceApp: nil)?.text == "still text")
    }

    @Test("Copied files are files, searched by their paths")
    func files() throws {
        pasteboard.clearContents()
        pasteboard.writeObjects([URL(fileURLWithPath: "/tmp/a.txt") as NSURL, URL(fileURLWithPath: "/tmp/b.png") as NSURL])
        let item = try #require(capture.capture(pasteboard, sourceApp: "com.apple.finder"))
        #expect(item.kind == .file)
        #expect(item.text == "/tmp/a.txt\n/tmp/b.png")
        #expect(item.contents.map { $0["public.file-url"].map { String(decoding: $0, as: UTF8.self) } }
            == ["file:///tmp/a.txt", "file:///tmp/b.png"], "one pasteboard item per file, as Finder pastes them")
    }

    @Test("A colour is a colour: a copied NSColor, or text that is a hex or rgb() colour")
    func colours() throws {
        pasteboard.clearContents()
        pasteboard.writeObjects([NSColor.systemRed])
        #expect(try #require(capture.capture(pasteboard, sourceApp: nil)).kind == .colour)
        for literal in ["#ff8800", "#F80", "rgb(255, 136, 0)", "rgba(0,0,0,0.5)"] {
            copy(literal)
            #expect(try #require(capture.capture(pasteboard, sourceApp: nil)).kind == .colour, "\(literal)")
        }
        copy("#hashtag")
        #expect(try #require(capture.capture(pasteboard, sourceApp: nil)).kind == .text)
    }

    @Test("A colour literal's value is what the panel's swatch shows: short hex doubled, alpha dropped, rgb() read")
    func colourValues() {
        #expect(ClipboardCapture.colourValue("#ff8800") == 0xFF8800)
        #expect(ClipboardCapture.colourValue(" #F80\n") == 0xFF8800)
        #expect(ClipboardCapture.colourValue("#ff880080") == 0xFF8800)
        #expect(ClipboardCapture.colourValue("rgb(255, 136, 0)") == 0xFF8800)
        #expect(ClipboardCapture.colourValue("rgba(0,0,0,0.5)") == 0)
        #expect(ClipboardCapture.colourValue("#hashtag") == nil)
    }
}
