import AppKit
import PilotCore
import SwiftUI

// Trigger › Define (Q596; the designer's round 2, layout C, pilot-1.1-previews-2.html): the word's rows under their
// headings on the left (meanings, synonyms, its translation), the entry and the picked row in full on the right, the
// sources under them. Sven's picks on that page may change the layout: the two columns are DefineRows and DefineEntry,
// and the keys are DefineKeys alone.

/// What Define shows for the word typed: its entry, the word it was translated from, and whether synonyms are still asked.
struct DefineShown: Equatable {
    /// What was typed, and the word looked up: the same, or its English when the typed word is in another language.
    var typed: String
    var word: String
    var entry: DictionaryEntry?
    /// The typed word's language by name when it was translated into English first ("Spanish"); nil when it was English.
    var from: String?
    /// The online dictionary has not answered yet.
    var asking = true
}

/// Define's keys (layout C's foot), in one place: Return pastes the picked row into the app the menu opened over, → defines
/// a synonym or a suggestion, ⌘Return says the word in Pilot's voice, Escape goes back.
enum DefineKeys {
    enum Act { case paste, define(String), say }

    /// The act for a key on `row`; nil leaves the key to the menu (→ is the caret's on any other row).
    static func act(_ code: UInt16, _ flags: NSEvent.ModifierFlags, on row: MenuEntry?) -> Act? {
        let command = flags.contains(.command)
        guard let row, row.home == .define else { return code == 36 && command || code == 76 && command ? .say : nil }
        switch code {
        case 36 where command, 76 where command: return .say
        case 36, 76:
            // A suggestion is a word to define, not text to paste; Search the web is the menu's own row.
            if row.section == Define.didYouMean, let word = Define.definable(row) { return .define(word) }
            if case .copy = row.target { return .paste }
            return nil
        case 124 where flags.isDisjoint(with: [.command, .option, .control, .shift]):
            return Define.definable(row).map(Act.define)
        default: return nil
        }
    }

    static func foot(_ row: MenuEntry?, frontApp: String?) -> [KeyHint] {
        let say: KeyHint = ("⌘↵", "say"), back: KeyHint = ("Esc", "back")
        guard let row else { return [say, back] }
        if row.section == Define.didYouMean { return [("↵", "define it"), say, back] }
        guard case .copy = row.target else { return [("↵", row.returnLabel), say, back] }
        let paste: KeyHint = ("↵", "paste to \(frontApp ?? "the app")")
        return Define.definable(row) == nil ? [paste, say, back] : [paste, ("→", "define it"), say, back]
    }
}

/// The two columns on the panel's card: the rows on the left, the entry and the picked row on the right.
struct DefinePane: View {
    @Environment(\.style) private var style
    @Bindable var model: MenuModel

    /// The card's room under the search line.
    static let height: CGFloat = 330
    /// Where the rest comes from, under the entry's dictionary.
    static let sources = "synonyms: dictionaryapi.dev · translation: Apple, on this Mac"

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 12, style: .continuous)
        Group {
            if let shown = model.define {
                HStack(spacing: 0) {
                    DefineRows(model: model, shown: shown).frame(width: 300)
                    Rectangle().fill(style.color(\.line2)).frame(width: 1)
                    DefineEntry(model: model, shown: shown)
                }
            } else {
                Text(placeholder).font(style.font(\.row, size: 14 / style.scale)).foregroundStyle(style.color(\.text3))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(height: Self.height - 24)
        .background(style.color(\.raised), in: shape)
        .overlay { shape.strokeBorder(style.color(\.line2)) }
        .clipShape(shape)
        .padding(.horizontal, 10).padding(.vertical, 12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .allowsHitTesting(model.nav.actions == nil)
    }

    private var placeholder: String {
        model.nav.query.trimmingCharacters(in: .whitespaces).count >= MenuNavigator.minimumQuery ? "Looking it up…" : "Type a word to define it."
    }
}

/// The rows under their headings; a click picks one, as ↑ and ↓ do.
struct DefineRows: View {
    @Environment(\.style) private var style
    @Bindable var model: MenuModel
    let shown: DefineShown

    var body: some View {
        let nav = model.nav, rows = nav.rows
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    if shown.entry == nil { note("No definition for “\(shown.typed)”") }
                    ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                        VStack(alignment: .leading, spacing: 0) {
                            if index == 0 || rows[index - 1].section != row.section {
                                if row.section == Define.web, shown.asking, shown.entry != nil { asking }
                                InstrumentEyebrow(text: row.section ?? "").padding(.horizontal, 12).padding(.top, index == 0 ? 0 : 10).padding(.bottom, 4)
                            }
                            line(row, on: index == nav.selection).id(index)
                                .contentShape(.rect)
                                .onTapGesture { model.nav.point(at: index) }
                        }
                    }
                }
                .padding(.vertical, 12).padding(.horizontal, 6)
            }
            .onChange(of: nav.selection) { _, new in proxy.scrollTo(new) }
        }
    }

    private var asking: some View {
        VStack(alignment: .leading, spacing: 4) {
            InstrumentEyebrow(text: Define.synonyms).padding(.top, 10)
            Text("Asking dictionaryapi.dev…").styleText(\.caption).foregroundStyle(style.color(\.text3))
        }
        .padding(.horizontal, 12)
    }

    private func note(_ text: String) -> some View {
        Text(text).styleText(\.caption).foregroundStyle(style.color(\.text2)).padding(.horizontal, 12).padding(.bottom, 8)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func line(_ row: MenuEntry, on: Bool) -> some View {
        HStack(spacing: 8) {
            Image(systemName: Self.symbol(row)).font(style.font(\.caption)).foregroundStyle(style.color(on ? \.text : \.text3)).frame(width: 16)
            Text(row.title).font(style.font(\.row, size: 13 / style.scale)).foregroundStyle(style.color(\.text)).lineLimit(1)
            Spacer(minLength: 4)
            if let detail = row.detail {
                Text(detail).styleText(\.caption).foregroundStyle(style.color(\.text3)).lineLimit(1)
            }
        }
        .padding(.horizontal, 8).frame(height: 28)
        .background { if on { RoundedRectangle(cornerRadius: 7, style: .continuous).fill(style.color(\.accentSoft)) } }
    }

    static func symbol(_ row: MenuEntry) -> String {
        switch row.section {
        case Define.meanings: "book"
        case Define.synonyms: "square.stack"
        case Define.didYouMean: "questionmark.circle"
        case Define.web: "magnifyingglass"
        default: "globe"
        }
    }
}

/// The word's entry in full, as the Mac's dictionary holds it: its head (the word, its syllables, ⌘↩ to say it, the
/// pronunciation), each part of speech's numbered meanings with their examples, the origin and the dictionary's name. The
/// picked meaning is lit and scrolled to; a picked synonym or translation shows in full above the meanings. A word with
/// no entry shows the picked suggestion's entry instead.
struct DefineEntry: View {
    @Environment(\.style) private var style
    @Bindable var model: MenuModel
    let shown: DefineShown

    var body: some View {
        let picked = model.nav.selected
        let guess = shown.entry == nil ? picked.flatMap(Define.definable).flatMap { model.defineGlossary[$0.lowercased()] } : nil
        let lit = picked?.section == Define.meanings ? shown.entry?.senses.firstIndex { $0.meaning == picked?.title } : nil
        VStack(alignment: .leading, spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        if let from = shown.from {
                            Text("\(from) → \(shown.word)").styleText(\.caption).foregroundStyle(style.color(\.text2)).padding(.bottom, 6)
                        }
                        if let entry = shown.entry {
                            head(entry, say: true)
                            if let picked, picked.home == .define, picked.section != Define.meanings {
                                pickedBlock(picked).padding(.top, 12)
                                InstrumentRule().padding(.vertical, 12)
                            }
                            article(entry, lit: lit)
                        } else if let guess {
                            InstrumentEyebrow(text: Define.didYouMean).padding(.bottom, 4)
                            head(guess, say: false)
                            article(guess, lit: nil)
                            Button("Define \(guess.word) ↩") { model.defineAct?(.define(guess.word)) }
                                .buttonStyle(.plain).styleText(\.caption).foregroundStyle(style.color(\.accent)).padding(.top, 10)
                        } else {
                            Text("No definition for “\(shown.typed)”").font(style.font(\.row, size: 15 / style.scale))
                                .foregroundStyle(style.color(\.text2))
                        }
                    }
                    .id(Self.top)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 18).padding(.vertical, 14)
                }
                .onChange(of: model.nav.selection, initial: true) {
                    proxy.scrollTo(lit.map { AnyHashable($0) } ?? AnyHashable(Self.top), anchor: lit == nil ? .top : .center)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private static let top = "top"

    /// The word large in the theme's display face, its syllables beside it, the pronunciation under it.
    private func head(_ entry: DictionaryEntry, say: Bool) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(entry.word).font(style.font(\.display, size: 26 / style.scale)).foregroundStyle(style.color(\.text)).lineLimit(1)
                if let syllables = entry.syllables {
                    Text(syllables).styleText(\.caption).foregroundStyle(style.color(\.text3)).lineLimit(1)
                }
                Spacer(minLength: 0)
                if say {
                    Button { model.defineAct?(.say) } label: {
                        Image(systemName: "speaker.wave.2").font(style.font(\.caption)).foregroundStyle(style.color(\.text2))
                    }
                    .buttonStyle(.plain).accessibilityLabel("Say it")
                }
            }
            if let ipa = entry.pronunciation {
                Text(ipa).styleText(\.mono).foregroundStyle(style.color(\.text2)).lineLimit(1)
                    .padding(.horizontal, 7).frame(height: 20)
                    .background(style.color(\.line), in: RoundedRectangle(cornerRadius: style.radii.chip, style: .continuous))
            }
        }
    }

    /// Each part of speech in a chip over its numbered meanings, the origin, then the dictionary's name.
    private func article(_ entry: DictionaryEntry, lit: Int?) -> some View {
        let groups = entry.senses.indices.reduce(into: [[Int]]()) { groups, i in
            if let last = groups.last?.last, entry.senses[last].partOfSpeech == entry.senses[i].partOfSpeech { groups[groups.count - 1].append(i) } else { groups.append([i]) }
        }
        return VStack(alignment: .leading, spacing: 0) {
            ForEach(groups, id: \.self) { group in
                let partOfSpeech = entry.senses[group[0]].partOfSpeech
                if !partOfSpeech.isEmpty {
                    Text(partOfSpeech.uppercased()).styleText(\.eyebrow).foregroundStyle(style.color(\.accentText))
                        .padding(.horizontal, 7).frame(height: 18)
                        .background(style.color(\.accentSoft), in: RoundedRectangle(cornerRadius: style.radii.chip, style: .continuous))
                        .padding(.top, 14).padding(.bottom, 6)
                }
                ForEach(Array(group.enumerated()), id: \.element) { n, i in
                    sense(entry.senses[i], number: group.count > 1 ? n + 1 : nil, lit: i == lit).id(i)
                }
            }
            if let origin = entry.origin {
                InstrumentEyebrow(text: "Origin").padding(.top, 14).padding(.bottom, 4)
                Text(origin).styleText(\.caption).foregroundStyle(style.color(\.text2)).fixedSize(horizontal: false, vertical: true)
            }
            Label(entry.dictionary ?? "The Mac's dictionary", systemImage: "book.closed").styleText(\.caption)
                .foregroundStyle(style.color(\.text3)).padding(.top, 14)
            Text(DefinePane.sources).styleText(\.caption).foregroundStyle(style.color(\.text3)).padding(.top, 2)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// One meaning: its number and label, the meaning, its examples in italic under a hairline.
    private func sense(_ sense: DictionaryEntry.Sense, number: Int?, lit: Bool) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            if let number {
                Text("\(number)").styleText(\.caption).foregroundStyle(style.color(\.text3)).frame(width: 12, alignment: .trailing)
            }
            VStack(alignment: .leading, spacing: 3) {
                if let note = sense.note { Text(note).styleText(\.caption).foregroundStyle(style.color(\.text3)) }
                Text(sense.meaning).font(style.font(\.row, size: 14 / style.scale)).foregroundStyle(style.color(\.text))
                    .fixedSize(horizontal: false, vertical: true)
                ForEach(sense.examples.prefix(3), id: \.self) { example in
                    Text(example).font(style.font(\.row, size: 13 / style.scale).italic()).foregroundStyle(style.color(\.text2))
                        .fixedSize(horizontal: false, vertical: true).padding(.leading, 9)
                        .overlay(alignment: .leading) { Rectangle().fill(style.color(\.line2)).frame(width: 2) }
                }
            }
        }
        .padding(.horizontal, 6).padding(.vertical, 5)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background { if lit { RoundedRectangle(cornerRadius: 7, style: .continuous).fill(style.color(\.accentSoft)) } }
        .padding(.horizontal, -6)
    }

    /// The picked synonym (its own first meaning, Define it →) or translation, in full.
    @ViewBuilder
    private func pickedBlock(_ row: MenuEntry) -> some View {
        let word = Define.definable(row)
        VStack(alignment: .leading, spacing: 6) {
            InstrumentEyebrow(text: "picked · \(row.section?.lowercased() ?? "")")
            if let word {
                Text(word).font(style.font(\.row, size: 17 / style.scale).weight(.semibold)).foregroundStyle(style.color(\.text))
                if let first = model.defineGlossary[word.lowercased()]?.senses.first { sense(first, number: nil, lit: false) }
            } else {
                Text(row.title).font(style.font(\.row, size: 15 / style.scale)).foregroundStyle(style.color(\.text)).lineLimit(3)
            }
            HStack(spacing: 14) {
                if case .copy = row.target { Button("Paste ↩") { model.defineAct?(.paste) } }
                if let word { Button("Define \(word) →") { model.defineAct?(.define(word)) } }
            }
            .buttonStyle(.plain).styleText(\.caption).foregroundStyle(style.color(\.accent))
        }
    }
}
