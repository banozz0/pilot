import Foundation
import PilotCore
import SwiftUI

/// The GitHub widget's data (`"data": {"github": true}`, P82, Sven Q726/Q728): a user's contribution calendar, the one gh
/// is signed in as or the one picked in Edit widget, read by `gh api graphql` in a child, off the main thread, never with
/// a token Pilot reads. A read is kept in Pilot's own folder (WidgetData/) and is good for an hour: a placement shows it
/// and reads again only once it is an hour old, while it shows; nothing reads while none shows, and the Widgets page's
/// preview shows the kept read alone. One read at a time for a user serves every placement.
@MainActor
enum WidgetGitHub {
    /// The setting that names the user: empty for gh's own.
    static let userName = "user"
    nonisolated static let every: Duration = .seconds(3600)
    /// How soon a read that failed is tried again: gh signed in, or the network back.
    static let retry: Duration = .seconds(600)
    nonisolated static let timeout: Duration = .seconds(30)

    /// What a tile shows: the calendar (fresh or kept), why it is not fresh, or a line while there is neither.
    struct Shown: Equatable, Sendable {
        var calendar: GitHubContributions?
        var problem: GitHubContributions.Failure?
        var note: String?
    }

    static var folder: URL { PilotFolder.support.appending(path: "WidgetData", directoryHint: .isDirectory) }
    private static var reading: [String: Task<Shown, Never>] = [:]

    /// The setting as typed, without spaces or a leading @.
    static func user(_ value: JSONValue?) -> String {
        var name = (value?.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if name.hasPrefix("@") { name.removeFirst() }
        return name
    }

    /// The placement's loop while it shows: the kept read or a new one, then a sleep until it is an hour old (ten
    /// minutes after a failure). `told` hears each answer's problem, for `pilot status --part widgets`.
    static func feed(_ model: WidgetTileModel, user: String, told: (String?) -> Void) async {
        while !Task.isCancelled {
            let shown = await read(user)
            if Task.isCancelled { return }
            (model.contributions, model.blocks, model.message) = (shown, [], nil)
            told(shown.problem?.line)
            try? await Task.sleep(for: wait(shown))
        }
    }

    /// The Widgets page's look: the kept read only, nothing run.
    static func preview(_ model: WidgetTileModel, user: String) async {
        let file = cacheFile(user)
        let kept = await Task.detached(priority: .utility) { WidgetGitHub.kept(file) }.value
        model.contributions = Shown(calendar: kept, note: kept == nil ? "Read by gh once placed" : nil)
    }

    /// `user`'s calendar, shared with a read under way.
    static func read(_ user: String) async -> Shown {
        if let task = reading[user] { return await task.value }
        let file = cacheFile(user)
        let task = Task.detached(priority: .utility) { await fetch(user, file: file) }
        reading[user] = task
        let shown = await task.value
        reading[user] = nil
        return shown
    }

    static func wait(_ shown: Shown) -> Duration {
        guard shown.problem == nil, let read = shown.calendar?.read else { return retry }
        return max(every - .seconds(Date().timeIntervalSince(read)), .seconds(60))
    }

    static func cacheFile(_ user: String) -> URL {
        folder.appending(path: "github-\(user.isEmpty ? "me" : user.lowercased()).json")
    }

    nonisolated static func kept(_ file: URL) -> GitHubContributions? {
        (try? Data(contentsOf: file)).flatMap { try? JSONDecoder().decode(GitHubContributions.self, from: $0) }
    }

    /// The kept read while under an hour old, else gh's answer, kept; a failure keeps the last read beside its reason.
    nonisolated static func fetch(_ user: String, file: URL, gh: String? = ghPath) async -> Shown {
        guard user.isEmpty || GitHubContributions.isLogin(user) else { return Shown(problem: .badLogin(user)) }
        let kept = WidgetGitHub.kept(file)
        if let kept, Date().timeIntervalSince(kept.read) < every.inSeconds { return Shown(calendar: kept) }
        guard let gh else { return Shown(calendar: kept, problem: .missing) }
        var environment = ChildProcess.toolEnvironment(gh)
        environment["GH_PROMPT_DISABLED"] = "1"; environment["GH_NO_UPDATE_NOTIFIER"] = "1"; environment["NO_COLOR"] = "1"
        do {
            let answer = try await ChildProcess.data(gh, GitHubContributions.arguments(user: user), environment: environment, timeout: timeout)
            guard let calendar = GitHubContributions(answer: answer, read: Date()) else { return Shown(calendar: kept, problem: .failed("gh's answer was not a calendar")) }
            try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? JSONEncoder().encode(calendar).write(to: file, options: .atomic)
            return Shown(calendar: calendar)
        } catch let failure as ChildProcess.Failure {
            return Shown(calendar: kept, problem: .init(status: failure.status, said: failure.message, user: user))
        } catch {
            return Shown(calendar: kept, problem: .failed(String(describing: error)))
        }
    }

    nonisolated static let ghPath = ["/opt/homebrew/bin/gh", "/usr/local/bin/gh"].first(where: FileManager.default.isExecutableFile(atPath:))
}

/// The contributions in the kit's panel (design A, Q728): cells in five shades of the theme's signal colour, Sunday-first
/// weeks as GitHub draws them, the newest at the right, as many weeks as the width holds. By class: Large has the user,
/// the year's total, the months over the grid, Mon/Wed/Fri beside it, and the weeks and the Less-More legend under it.
/// Wide is the same without the months and the days, so it holds fewer weeks. Square is a compact grid under the total.
/// Strip is the total, then a row of recent weeks, each one cell shaded by its total. A failure shows its reason and its
/// fix; one beside a kept read takes the weeks' place under the grid.
struct DeskKitContributions: View {
    @Environment(\.deskKit) private var kit
    @Environment(\.widgetFit) private var fit
    let shown: WidgetGitHub.Shown

    var body: some View {
        if let calendar = shown.calendar {
            if fit.size == .strip { strip(calendar) } else { panel(calendar) }
        } else if shown.problem == nil, let note = shown.note, fit.size != .strip {
            // Before a first read (the Widgets page's preview): the grid it will draw, every cell empty, no total.
            panel(Self.blank, note: note)
        } else {
            empty
        }
    }

    private func shade(_ level: Int) -> Color {
        level <= 0 ? kit.track : kit.accent.opacity([0.3, 0.5, 0.75, 1][min(level, 4) - 1])
    }

    private func total(_ calendar: GitHubContributions) -> String { calendar.total.formatted() }

    // MARK: Panel

    /// The head's and the foot's lines, which the grid's room leaves out.
    private static let headHeight: CGFloat = 20, footHeight: CGFloat = 12, spacing: CGFloat = 8

    /// The last year's weeks to today, every day empty, as "GitHub".
    private static let blank: GitHubContributions = {
        let today = Calendar(identifier: .gregorian).startOfDay(for: Date()), calendar = Calendar(identifier: .gregorian)
        let formatter = DateFormatter(); formatter.dateFormat = "yyyy-MM-dd"; formatter.locale = Locale(identifier: "en_US_POSIX")
        let weekday = calendar.component(.weekday, from: today) - 1
        let weeks = (0..<53).map { week in
            (0..<7).compactMap { day -> GitHubContributions.Day? in
                let back = (52 - week) * 7 + weekday - day
                guard back >= 0, let date = calendar.date(byAdding: .day, value: -back, to: today) else { return nil }
                return .init(date: formatter.string(from: date), weekday: day, count: 0, level: 0)
            }
        }
        return GitHubContributions(login: "GitHub", total: 0, weeks: weeks.filter { !$0.isEmpty }, read: .distantPast)
    }()

    private func panel(_ calendar: GitHubContributions, note: String? = nil) -> some View {
        let large = fit.size == .large, square = fit.size == .square
        return GeometryReader { box in
            let grid = GridFit(width: box.size.width, height: box.size.height - Self.headHeight - Self.footHeight - 2 * Self.spacing,
                               weeks: calendar.weeks.count, days: large, months: large)
            VStack(alignment: .leading, spacing: Self.spacing) {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text((large ? "\(calendar.login) · contributions" : calendar.login).uppercased())
                        .font(kit.mono(9.5, .medium)).foregroundStyle(kit.text2).tracking(0.855).truncationMode(.tail)
                        .accessibilityAddTraits(.isHeader)
                    Spacer(minLength: 0)
                    Text(note == nil ? total(calendar) : "–").font(kit.mono(square ? 15 : 16, .light)).monospacedDigit().foregroundStyle(kit.text).fixedSize()
                    if !square { Text(large ? "in the last year" : "last year").font(kit.mono(9.5)).foregroundStyle(kit.text3).fixedSize() }
                }
                .lineLimit(1).frame(height: Self.headHeight)
                self.grid(Array(calendar.weeks.suffix(grid.weeks)), grid, total: calendar.total)
                Spacer(minLength: 0)
                HStack(spacing: 8) {
                    if let note {
                        Text(note).truncationMode(.tail).help(note)
                    } else if let problem = shown.problem {
                        Text(problem.line).foregroundStyle(kit.amber).truncationMode(.tail).help(problem.fix)
                    } else {
                        Text(grid.weeks == 1 ? "1 week" : "\(grid.weeks) weeks")
                    }
                    Spacer(minLength: 0)
                    legend(words: !square)
                }
                .font(kit.mono(9.5)).foregroundStyle(kit.text3).lineLimit(1).frame(height: Self.footHeight)
            }
        }
    }

    private func legend(words: Bool) -> some View {
        HStack(spacing: 3) {
            if words { Text("Less").padding(.trailing, 2) }
            ForEach(0..<5, id: \.self) { level in
                RoundedRectangle(cornerRadius: 2, style: .continuous).fill(shade(level)).frame(width: 9, height: 9)
            }
            if words { Text("More").padding(.leading, 2) }
        }
        .fixedSize()
        .accessibilityElement().accessibilityLabel("Fewer to more contributions")
    }

    private func grid(_ weeks: [[GitHubContributions.Day]], _ grid: GridFit, total: Int) -> some View {
        let label = kit.mono(8.5), dim = kit.text3
        return Canvas { context, _ in
            for (i, week) in weeks.enumerated() {
                for day in week {
                    let cell = CGRect(x: grid.left + CGFloat(i) * grid.step, y: grid.top + CGFloat(day.weekday) * grid.step, width: grid.cell, height: grid.cell)
                    context.fill(Path(roundedRect: cell, cornerRadius: grid.cell * 0.22, style: .continuous), with: .color(shade(day.level)))
                }
            }
            if grid.months {
                for month in GitHubContributions.months(weeks) where month.week < weeks.count - 1 {
                    context.draw(Text(month.name).font(label).foregroundStyle(dim), at: CGPoint(x: grid.left + CGFloat(month.week) * grid.step, y: 0), anchor: .topLeading)
                }
            }
            if grid.days {
                for (row, name) in [(1, "Mon"), (3, "Wed"), (5, "Fri")] {
                    context.draw(Text(name).font(label).foregroundStyle(dim), at: CGPoint(x: 0, y: grid.top + CGFloat(row) * grid.step + grid.cell / 2), anchor: .leading)
                }
            }
        }
        .frame(width: grid.width, height: grid.height, alignment: .topLeading)
        .accessibilityElement().accessibilityLabel("\(total.formatted()) contributions in the last year, \(weeks.count) weeks shown")
    }

    // MARK: Strip

    private func strip(_ calendar: GitHubContributions) -> some View {
        HStack(alignment: .center, spacing: 10) {
            VStack(alignment: .leading, spacing: 1) {
                Text(total(calendar)).font(kit.mono(20, .light)).monospacedDigit().foregroundStyle(kit.text)
                Text(calendar.login.uppercased()).font(kit.mono(9)).tracking(0.855).foregroundStyle(shown.problem == nil ? kit.text3 : kit.amber)
                    .help(shown.problem?.line ?? "")
            }
            .lineLimit(1).fixedSize()
            GeometryReader { box in
                let cell = min(14, box.size.height), gap: CGFloat = 3
                let count = max(1, Int((box.size.width + gap) / (cell + gap)))
                let levels = GitHubContributions.weekLevels(Array(calendar.weeks.suffix(count)))
                HStack(spacing: gap) {
                    ForEach(levels.indices, id: \.self) { i in
                        RoundedRectangle(cornerRadius: cell * 0.22, style: .continuous).fill(shade(levels[i])).frame(width: cell, height: cell)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .trailing)
                .accessibilityElement().accessibilityLabel("\(calendar.total.formatted()) contributions in the last year, the last \(levels.count) weeks")
            }
        }
    }

    // MARK: No calendar

    private var empty: some View {
        let line = shown.problem?.line ?? shown.note ?? "Reading your contributions…"
        return Group {
            if fit.size == .strip {
                HStack(spacing: 10) {
                    DeskKitHead(title: "GitHub", meta: nil).fixedSize()
                    Text(line).font(kit.sans(12)).foregroundStyle(kit.text2)
                    if let fix = shown.problem?.fix { Text(fix).font(kit.mono(10.5)).foregroundStyle(kit.text3) }
                }
                .lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
            } else {
                VStack(alignment: .leading, spacing: 10) {
                    DeskKitHead(title: "GitHub", meta: nil)
                    Text(line).font(kit.sans(12)).foregroundStyle(kit.text2).fixedSize(horizontal: false, vertical: true)
                    if let fix = shown.problem?.fix {
                        Text(fix).font(kit.mono(10.5)).foregroundStyle(kit.text3).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
        }
    }
}

/// The grid's cells in the room it has: as big as the height lets seven rows be, up to 11 points, then as many weeks as
/// the width holds; the months take a line over it and the days a column beside it.
struct GridFit {
    let cell, gap: CGFloat, weeks: Int, days: Bool, months: Bool
    var step: CGFloat { cell + gap }
    var left: CGFloat { days ? 24 : 0 }
    var top: CGFloat { months ? 12 : 0 }
    var width: CGFloat { left + CGFloat(weeks) * step - gap }
    var height: CGFloat { top + 7 * step - gap }

    init(width: CGFloat, height: CGFloat, weeks all: Int, days: Bool, months: Bool, most: CGFloat = 11) {
        self.days = days; self.months = months
        let room = height - (months ? 12 : 0)
        var gap: CGFloat = 3
        var cell = min(most, ((room + gap) / 7 - gap).rounded(.down))
        if cell < 9 { gap = 2; cell = min(most, ((room + gap) / 7 - gap).rounded(.down)) }
        cell = max(cell, 4)
        self.cell = cell; self.gap = gap
        self.weeks = max(1, min(all, Int((width - (days ? 24 : 0) + gap) / (cell + gap))))
    }
}
