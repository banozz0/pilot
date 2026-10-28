import Foundation
import Testing
@testable import PilotCore

/// Menu Rail and Classic T3: a typed hex answers with its colour.
@Suite("ColourAnswer")
struct ColourAnswerTests {
    @Test("A hex or rgb() answers once, Return copies the hex in capitals, with the five spellings")
    func answers() {
        for text in ["#2bc4f0", "  #2BC4F0 ", "#2bc4f0ff", "rgb(43, 196, 240)", "rgba(43,196,240,0.5)"] {
            let rows = RootAnswers.entries(for: text, now: .now)
            #expect(rows.count == 1, "\(text)")
            #expect(rows.first?.target == .copy("#2BC4F0"), "\(text)")
            #expect(rows.first?.isAnswer == true, "\(text)")
        }
        #expect(ColourAnswer.formats(0x2BC4F0) == ["#2BC4F0", "rgb(43, 196, 240)", "hsl(193, 87%, 55%)", "hsb(193, 82%, 94%)",
                                                   "Color(red: 0.169, green: 0.769, blue: 0.941)"])
        #expect(RootAnswers.entries(for: "#fff", now: .now).map(\.target) == [.copy("#FFFFFF")])
        #expect(ColourAnswer.formats(0xFFFFFF) == ["#FFFFFF", "rgb(255, 255, 255)", "hsl(0, 0%, 100%)", "hsb(0, 0%, 100%)",
                                                   "Color(red: 1.000, green: 1.000, blue: 1.000)"])
        #expect(ColourAnswer.formats(0x000000)[3] == "hsb(0, 0%, 0%)")
    }

    @Test("A short, bad or bare hex gives no answer")
    func refuses() {
        for text in ["#12", "#zzz", "2bc4f0", "#2bc4f", "rgb(43, 196)", "#2bc4f0 is blue"] {
            #expect(ColourAnswer.entries(for: text).isEmpty, "\(text)")
            #expect(ColourAnswer.value(text) == nil, "\(text)")
        }
        #expect(RootAnswers.entries(for: "#12", now: .now).isEmpty)
        #expect(RootAnswers.entries(for: "#zzz", now: .now).isEmpty)
    }
}
