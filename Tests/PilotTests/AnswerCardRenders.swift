#if DEBUG
import AppKit
import Foundation
import PilotCore
import SwiftUI
import Testing
@testable import Pilot

/// The Rail's answer cards (menu Rail and Classic T7, frames B4–B6), Tokyo Night and Porcelain: a conversion, a translation in
/// Translate and a typed colour, each with the Ask Quick AI row under its card. What the card reads from its row and that it
/// fits the panel are checked always; the pictures are opt-in like the other renders:
/// `CFFIXED_USER_HOME=/tmp/pilot-rh PILOT_RENDER_DIR=/tmp/pilot-renders swift test --filter AnswerCardRenders`
extension SharedLook {
@MainActor
@Suite("Answer card renders")
struct AnswerCardRenders {
    nonisolated static let env = ProcessInfo.processInfo.environment
    static let day = Date(timeIntervalSince1970: 1_791_028_800)

    @Test("A conversion's card: what was typed on the left, the result Return copies on the right with its unit apart")
    func conversion() throws {
        let row = try #require(Calculator.entries(for: "22 km to mi").first)
        let card = try #require(MenuAnswer(row, query: "22 km to mi", branch: nil))
        #expect(card.kind == .calculation && card.eyebrow == "Calculator")
        #expect(card.expression == "22 km to mi" && card.expressionChip == "Expression")
        guard case .copy(let copied) = row.target else { Issue.record("the answer copies nothing"); return }
        #expect("\(card.value) \(card.unit ?? "")" == copied, "the card shows what Return copies")
        #expect(card.unit == "mi" && card.note == nil)
        let sumRow = try #require(Calculator.entries(for: "12*7+3").first)
        let sum = try #require(MenuAnswer(sumRow, query: "12*7+3", branch: nil))
        #expect(sum.value == "87" && sum.unit == nil && sum.resultChip == "Result")
    }

    @Test("Money keeps its rates' day under the card; a time reads Time; a translation names its languages")
    func notes() throws {
        let money = MenuEntry(title: "43.2 USD", target: .copy("43.2 USD"), detail: "= 40 EUR · rates from 2026-10-14 · Return copies",
                              isAnswer: true)
        let card = try #require(MenuAnswer(money, query: "40 eur in usd", branch: nil))
        #expect(card.expression == "40 EUR" && card.value == "43.2" && card.unit == "USD")
        #expect(card.resultChip == "Money" && card.note == "rates from 2026-10-14")
        let time = MenuEntry(title: "17:00", target: .copy("17:00"), detail: "Time in Tokyo now, Thu 15 Oct · Return copies", isAnswer: true)
        let clock = try #require(MenuAnswer(time, query: "time in tokyo", branch: nil))
        #expect(clock.expression == "time in tokyo" && clock.resultChip == "Time" && clock.note == "Time in Tokyo now, Thu 15 Oct")
        let said = try #require(MenuAnswer(Self.translation, query: "tr buenos días", branch: nil))
        #expect(said.kind == .translation && said.expression == "buenos días")
        #expect(said.expressionChip == "Spanish · detected" && said.resultChip == "English" && said.value == "Good morning")
    }

    @Test("A typed colour's card copies the hex, in the Rail and in Classic; rows that copy nothing get no card")
    func colourAndNone() throws {
        let row = try #require(ColourAnswer.entries(for: "#2bc4f0").first)
        let card = try #require(MenuAnswer(row, query: "#2bc4f0", branch: nil))
        #expect(card.kind == .colour(0x2BC4F0) && card.value == "#2BC4F0" && card.eyebrow == "Colour")
        let ramp = AnswerInk.ramp(0x2BC4F0)
        #expect(ramp.count == 7 && ramp[3] == 0x2BC4F0)
        #expect(ramp.map { Contrast.luminance(Contrast.rgb($0)) } == ramp.map { Contrast.luminance(Contrast.rgb($0)) }.sorted(by: >),
                "lightest to darkest")
        #expect(Contrast.ratio(AnswerInk.ink(on: 0x2BC4F0), 0x2BC4F0) >= 4.5)
        #expect(Contrast.ratio(AnswerInk.ink(on: 0x1E1E2E), 0x1E1E2E) >= 4.5)
        let reminder = MenuEntry(title: "Remind me", target: .action("x"), detail: "at 17:00 · Return sets it", isAnswer: true)
        #expect(MenuAnswer(reminder, query: "remind me at 5pm", branch: nil) == nil)
        let ask = MenuNavigator.fallbacks("#2bc4f0", after: [row], via: nil)
        #expect(ask.count == 2 && MenuAnswer(ask[0], query: "#2bc4f0", branch: nil) == nil, "the Ask row stays a row")
        let states = try Dictionary(uniqueKeysWithValues: Self.states())
        let hex = try #require(states["B6-colour"])
        #expect(hex.answerCard(hex.nav.rows[0], at: 0) != nil && hex.answerCard(hex.nav.rows[1], at: 1) == nil)
        hex.layout = .classic
        #expect(hex.answerCard(hex.nav.rows[0], at: 0) != nil, "Classic draws the card too (T8)")
    }

    @Test("Each card is the selection Return copies, the Ask row under it (none under tr's, T40), beside the slim rail, and fits unscrolled")
    func fits() throws {
        for (name, model) in try Self.states() {
            let rows = model.nav.rows, alone = name == "B5-translation"
            // Then only the search offers a typed search ends with (Search files for …); tr's answer stands alone (T40).
            let offers = rows.dropFirst(2).allSatisfy { $0.target.isSearchOffer }
            #expect(alone ? rows.allSatisfy(\.isAnswer) : offers, "\(name): \(rows.map(\.title))")
            #expect(rows.first?.isAnswer == true && model.nav.selected?.id == rows.first?.id, "\(name)")
            #expect(alone || rows.dropFirst().first?.title == "Ask AI", "\(name)")
            #expect(model.railBand == .slim && model.instrumentSize.width == MenuPanelSize.width, "\(name)")
            // The eyebrow, the card (a colour's: 118 swatch, 8, 16 ramp, 24 inset), its insets, the Ask row and the
            // list's own insets, under the search line and over the foot.
            let card: CGFloat = name.contains("colour") ? 118 + 8 + 16 + 24 : 158
            let list = MenuPanelSize.instrumentHeading + card + 10 + (alone ? 0 : MenuPanelSize.instrumentWideRow) + 12
            #expect(MenuPanelSize.railChrome + list <= model.instrumentSize.height, "\(name)")
        }
    }

    @Test("The cards render in Tokyo Night and Porcelain, frames B4–B6", .enabled(if: env["PILOT_RENDER_DIR"] != nil && env["CFFIXED_USER_HOME"] != nil))
    func render() throws {
        let home = try #require(Self.env["CFFIXED_USER_HOME"])
        try #require(NSHomeDirectory() == home, "the home directory did not move; refusing to touch Sven's data")
        testApp()
        let faces = DisplayFaces.directory
        DisplayFaces.directory = LookThemeTests.fonts
        defer { DisplayFaces.directory = faces }
        let look = Look.shared
        let (style, theme) = (look.style, look.themeID)
        defer { look.style = style; look.themeID = theme }
        look.style = .instrument
        for themeID in ["tokyo-night", "porcelain"] {
            look.themeID = themeID
            let dir = URL(fileURLWithPath: try #require(Self.env["PILOT_RENDER_DIR"]))
                .appendingPathComponent("answer-cards-\(themeID == "tokyo-night" ? "dark" : "light")")
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            for (name, model) in try Self.states() {
                try InstrumentMenuRenders.render(MenuView(model: model), name, in: dir)
            }
            // The Ask row picked: the card lets go of the tick.
            let (_, ask) = try #require(Self.states().first)
            _ = ask.nav.handle(.down)
            try InstrumentMenuRenders.render(MenuView(model: ask), "B4-conversion-ask", in: dir)
        }
    }

    /// Translate's answer as the translator gives it, never the live engine.
    static let translation = MenuEntry(title: "Good morning", target: .copy("Good morning"), home: .translate,
                                       detail: "Spanish → English · Return copies", isAnswer: true)

    /// Each frame's state: the Rail, the answer and its Ask row as the panel provides them.
    static func states() throws -> [(String, MenuModel)] {
        let built = try RailMenuRenders.built()
        func model(_ nav: MenuNavigator) -> MenuModel {
            let m = MenuModel(nav: nav)
            m.layout = .rail
            return m
        }
        func root(_ query: String) -> MenuNavigator {
            var nav = MenuNavigator(entries: built)
            nav.query = query
            nav.provide(.answer, RootAnswers.entries(for: query, now: day))
            return nav
        }
        // At the root, as Sven types it (acceptance check 5) and MenuPanel.translate provides it.
        var translate = MenuNavigator(entries: built)
        translate.query = "tr buenos días"
        translate.provide(.answer, home: .translate, [translation])
        return [("B4-conversion", model(root("22 km to mi"))), ("B5-translation", model(translate)), ("B6-colour", model(root("#2bc4f0")))]
    }
}
}
#endif
