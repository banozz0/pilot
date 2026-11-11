import Foundation
import PilotCore

extension SettingsSchema {
    /// The Stats page's keys, on the stores the page binds to: its layout, what every card shows (the page's Show) and
    /// each card's own pick, both in the layout picked now as on the page, and Busiest's helpers under their app.
    func registerStats(views: StatsViewsStore, bar: BarItemsStore) {
        registerStatsBar(bar)
        let cards: [SettingKey] = StatsCard.allCases.map { card in
            .choice("stats.card.\(card.rawValue)", "The \(card.rawValue) card shows as, in the layout picked now", page: "stats",
                    StatsView.allCases, standard: StatsViews.default(card, in: .comfortable),
                    read: { views.views.view(card) }, write: { views.set($0, for: card) })
        }
        register(cards + [
            .choice("stats.layout", "Layout", page: "stats", StatsDensity.allCases, standard: .comfortable,
                    read: { views.views.layout }, write: { views.setLayout($0) }),
            // The page's Show picks none while the cards differ; the command reads that as mixed, which it cannot set.
            .choice("stats.show", "Every card shows as (mixed while they differ)", page: "stats", StatsView.allCases.map(\.rawValue),
                    standard: StatsViews().shared?.rawValue ?? "mixed", read: { views.views.shared?.rawValue ?? "mixed" },
                    write: { word in StatsView(rawValue: word).map(views.setAll) }),
        ])
    }

    /// The shared bar setting, registered without starting the live Stats views.
    func registerStatsBar(_ bar: BarItemsStore) {
        register([
            .bool("stats.combineProcesses", "Busiest by memory counts an app's helpers under the app", page: "stats", standard: false,
                  read: { bar.settings.combineProcesses }, write: { value throws(ControlError) in try bar.requireWritable(); bar.settings.combineProcesses = value }),
        ])
    }
}
