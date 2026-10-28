import PilotCore
import SwiftUI

/// Launcher › Abilities (story 155, task C7; was Binds › Abilities): every ability Pilot has, grouped by module with what
/// the menu answers when typed first, each with one line of what it does, its key or Set key, and Try where running it
/// from here is safe. An ability's own settings sit under its row (page map, Sven 2026-10-17, as Raycast keeps a
/// command's): Repos under lazygit, the GIFs folder and GIPHY under Stickers and GIFs, Passwords under Generate a
/// password; they show wherever the row is drawn, under More abilities too, so a search keeps them, and their words
/// find the row. Abilities ship minimal (Sven 2026-10-10): one that drives a single app waits under More abilities until
/// it is added, and its app is on this Mac.
struct AbilitiesList: View {
    @Environment(Engine.self) private var engine
    private var abilities: AbilitySettings { .shared }
    /// The window's search, until the list's own box is typed in.
    let search: String
    /// Opens Binds' editor on an action.
    let setKey: (String) -> Void
    @State private var query: String

    init(search: String = "", query: String = "", setKey: @escaping (String) -> Void) {
        self.search = search
        self.setKey = setKey
        _query = State(initialValue: query)
    }

    var body: some View {
        let typed = query.isEmpty ? search : query
        let all = engine.allBindActions.map(Self.withSettingWords)
        let groups = Abilities.groups(actions: all.filter { engine.isListed($0.id) }, store: engine.binds.store, menu: AppsModule.menuID, search: typed)
        let more = Abilities.addable(actions: all, listed: engine.isListed, has: abilities.has, search: typed)
        KitPage(intro: "Everything Pilot can do: what it does, its key, and Try to see it now.") {
            SearchBox(prompt: "Search abilities", text: $query).padding(.vertical, 8)
            if groups.isEmpty && more.isEmpty { EmptyState(title: "No ability matches", line: "Try another word.") }
            ForEach(groups) { group in
                KitBlock(title: group.title, symbol: Self.symbol(group.module),
                         note: group.module == nil ? "Open the menu and type: it answers as you go." : nil) {
                    ForEach(group.abilities) { ability in
                        BlockRow(first: ability.id == group.abilities.first?.id) {
                            AbilityRow(ability: ability, setKey: setKey, clear: { engine.clearKey($0) },
                                       remove: removable(ability) ? { abilities.remove(ability.id) } : nil) { run(ability) }
                        }
                        settings(ability.id)
                    }
                }
            }
            if !more.isEmpty {
                KitBlock(title: "More abilities", symbol: "plus.circle", note: "Each drives one app on this Mac; add the ones you use.") {
                    ForEach(more) { ability in
                        BlockRow(first: ability.id == more.first?.id) { MoreAbilityRow(ability: ability) { abilities.add(ability.id) } }
                        // Not added, its settings still show: they were always on Your menu before the page map.
                        settings(ability.id)
                    }
                }
            }
        }
    }

    /// The settings under an ability's row, set in from it; most abilities have none.
    @ViewBuilder private func settings(_ id: String) -> some View {
        switch id {
        case "apps.lazygit": FoldersBlock(.repos).padding(.leading, Self.settingsInset)
        case "typed.stickers": FoldersBlock(.gifs).padding(.leading, Self.settingsInset)
        case "apps.generatePassword":
            PasswordsBlock().padding(.leading, Self.settingsInset)
        default: EmptyView()
        }
    }

    /// How far an ability's settings sit in from its row.
    static let settingsInset: CGFloat = 22

    /// The words of the settings under lazygit and Generate a password, which a search finds the row by (Stickers and GIFs'
    /// own line names its GIFs folder and GIPHY).
    static let settingWords = ["apps.lazygit": "repos folder", "apps.generatePassword": "length symbols passwords clear after"]

    static func withSettingWords(_ action: BindsPage.ActionInfo) -> BindsPage.ActionInfo {
        guard let words = settingWords[action.id] else { return action }
        var action = action
        action.keywords = [action.keywords, words].compactMap { $0 }.joined(separator: " ")
        return action
    }

    /// An added optional ability with no key goes back under More abilities; one with a key stays while it holds it.
    private func removable(_ ability: Abilities.Ability) -> Bool { Abilities.optional[ability.id] != nil && ability.key == nil }

    private func run(_ ability: Abilities.Ability) {
        if let action = ability.action { engine.action(action)?.run() } else if let typing = ability.typing { PilotMenu.shared.open(typing: typing) }
    }

    /// A group's glyph: its module's as Home's keyboard draws it, or the menu's search for what it answers when typed.
    static func symbol(_ module: String?) -> String {
        module.map { HomeBinds.moduleSymbols[BindsKeyboard.module($0)] } ?? "magnifyingglass"
    }
}

/// One ability: its name over what it does, then its key and its × (or No key), Set key or Change, and Try.
private struct AbilityRow: View {
    @Environment(\.ink) private var ink
    let ability: Abilities.Ability
    let setKey: (String) -> Void
    /// The ×: the action is left with no key.
    let clear: (String) -> Void
    var remove: (() -> Void)?
    let tryIt: () -> Void

    var body: some View {
        AbilityText(ability: ability)
        Spacer(minLength: 8)
        if let key = ability.key {
            Kbd(text: key)
            if let action = ability.action {
                IconButton(symbol: "xmark", label: "Clear the key of \(ability.name)", size: 20, glyph: 9) { clear(action) }
            }
        } else { Text("No key").font(ink.ui(12)).foregroundStyle(ink.muted) }
        if let action = ability.action {
            Button(ability.key == nil ? "Set key" : "Change") { setKey(action) }.buttonStyle(.pilot)
                .accessibilityLabel("\(ability.key == nil ? "Set key for" : "Change the key of") \(ability.name)")
        }
        if ability.canTry {
            Button("Try", action: tryIt).buttonStyle(.pilot).accessibilityLabel("Try \(ability.name)")
        }
        if let remove {
            Button("Remove", action: remove).buttonStyle(.pilot).accessibilityLabel("Remove \(ability.name) from your abilities")
        }
    }
}

/// An optional ability not added yet: its name over what it does, and Add.
private struct MoreAbilityRow: View {
    let ability: Abilities.Ability
    let add: () -> Void

    var body: some View {
        AbilityText(ability: ability)
        Spacer(minLength: 8)
        Button("Add", action: add).buttonStyle(.pilot).accessibilityLabel("Add \(ability.name) to your abilities")
    }
}

private struct AbilityText: View {
    @Environment(\.ink) private var ink
    let ability: Abilities.Ability

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(ability.name).foregroundStyle(ink.text)
            Text(ability.what).font(ink.ui(12)).foregroundStyle(ink.muted).fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 4)
    }
}
