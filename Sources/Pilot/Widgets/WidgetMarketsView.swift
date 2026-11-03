import PilotCore
import SwiftUI

/// The Markets widget's tile in the look kit (Sven Q729: design A for one symbol, C for several, D's line for a Strip, up
/// and down in the theme's good and problem colours), on the panel's veil inside its hairline edge as DeskKitPanel draws.
/// One symbol: Large is the overview (its line against the day's open close, price, change, high and low, range keys
/// that take clicks); Wide the line with the price beside it; Square the price, change and a small line; Strip one line.
/// Several: Large and Wide rows, each a small line, the price and the change (Wide in two columns when it holds them);
/// Square the top rows; Strip a still ticker line, as many as fit. A click on a symbol (its row, figures or chart) opens
/// its TradingView page in the default browser; the range keys keep showing their range.
struct WidgetMarketsPanel: View {
    @Environment(\.deskKit) private var kit
    @Environment(\.widgetFit) private var fit
    let board: MarketsBoard

    var body: some View {
        let strip = fit.size == .strip
        Group {
            if let message = board.message {
                if strip {
                    HStack(spacing: 10) {
                        DeskKitHead(title: "Markets", meta: nil).fixedSize()
                        Text(message).font(kit.sans(12)).foregroundStyle(kit.text2).lineLimit(1)
                    }
                } else {
                    VStack(alignment: .leading, spacing: 10) {
                        DeskKitHead(title: "Markets", meta: nil)
                        Text(message).font(kit.sans(12)).foregroundStyle(kit.text2).fixedSize(horizontal: false, vertical: true)
                    }
                }
            } else if board.symbols.count == 1 {
                MarketsOne(board: board, symbol: board.symbols[0])
            } else {
                MarketsSeveral(board: board)
            }
        }
        .padding(.top, strip ? 8 : 12).padding(.bottom, strip ? 8 : 14).padding(.horizontal, 14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: strip ? .leading : .topLeading)
        .background(kit.veil)
        .overlay(RoundedRectangle(cornerRadius: DeskKit.radius, style: .continuous).strokeBorder(kit.edge, lineWidth: 1))
    }
}

/// What one symbol shows over the board's range: its figures, words and tone.
private struct MarketsFigures {
    let symbol: WidgetMarkets.Symbol, quote: WidgetMarkets.Quote?, range: WidgetMarkets.Range
    var moved: (percent: Double?, change: Double?, high: Double?, low: Double?) {
        quote?.moved(range) ?? (nil, nil, nil, nil)
    }
    var up: Bool? { moved.percent.map { $0 >= 0 } }
    var price: String { quote.map { Markets.figure($0.price) } ?? "–" }
    var name: String { quote.map { $0.name.isEmpty ? symbol.exchange : $0.name } ?? symbol.exchange }
    /// "+1.91%", or "+1,284.30 +1.91%" with its money.
    func change(money: Bool) -> String {
        guard let percent = moved.percent else { return "–" }
        let share = Markets.signed(percent, digits: 2) + "%"
        guard money, let change = moved.change else { return share }
        return Markets.signed(change, money: true, like: quote?.price) + " " + share
    }
    var highLow: String? {
        guard let high = moved.high, let low = moved.low else { return nil }
        return "H \(Markets.short(high)) · L \(Markets.short(low))"
    }
    /// What a Large's corner names: Crypto, Stock, Fund, FX, Index.
    var kind: String { quote.flatMap { WidgetMarkets.kinds[$0.type] } ?? (symbol.kind == "stock" ? "Stock" : "") }
}

/// Numbers as the tile writes them, and a symbol's mark.
enum Markets {
    /// A price: two decimals from 10 up, four under, four significant digits under 1; a change in its price's decimals.
    static func figure(_ value: Double, like price: Double? = nil) -> String {
        let size = abs(price ?? value)
        if size >= 10 { return value.formatted(.number.precision(.fractionLength(2))) }
        if size >= 1 { return value.formatted(.number.precision(.fractionLength(4))) }
        return value.formatted(.number.precision(.significantDigits(1...4)))
    }

    /// A high or a low: whole from 10,000 up.
    static func short(_ value: Double) -> String {
        abs(value) >= 10_000 ? value.formatted(.number.precision(.fractionLength(0))) : figure(value)
    }

    /// "+1.91", "−0.62" (a true minus); a change in money in the decimals of the price it is `like`.
    static func signed(_ value: Double, digits: Int = 2, money: Bool = false, like price: Double? = nil) -> String {
        let body = money ? figure(abs(value), like: price) : abs(value).formatted(.number.precision(.fractionLength(digits)))
        return (value < 0 ? "−" : "+") + body
    }

    /// A symbol's mark: a coin's sign (₿, Ξ), a currency pair's first money (€, $, £), a metal's element, else its
    /// first letter.
    static func mark(_ symbol: WidgetMarkets.Symbol, _ quote: WidgetMarkets.Quote?) -> String {
        let s = symbol.symbol
        for (code, sign) in [("BTC", "₿"), ("ETH", "Ξ"), ("XAU", "Au"), ("XAG", "Ag"), ("XPT", "Pt")] where s.hasPrefix(code) { return sign }
        if quote?.asset == "forex" || quote?.type == "forex", let sign = money[String(s.prefix(3))] { return sign }
        return String(s.prefix(1))
    }

    private static let money = ["EUR": "€", "USD": "$", "GBP": "£", "JPY": "¥", "CHF": "₣", "CNY": "¥", "INR": "₹", "KRW": "₩"]
}

/// A click on a symbol: its TradingView page in the default browser.
private struct MarketsOpens: ViewModifier {
    let symbol: WidgetMarkets.Symbol

    func body(content: Content) -> some View {
        content.contentShape(.rect)
            .onTapGesture(perform: open)
            .help("Open \(symbol.symbol) on TradingView")
            .accessibilityAddTraits(.isLink).accessibilityAction(.default, open)
    }

    private func open() { if let page = symbol.page { NSWorkspace.shared.open(page) } }
}

private extension View {
    func opens(_ symbol: WidgetMarkets.Symbol) -> some View { modifier(MarketsOpens(symbol: symbol)) }
}

/// `.mk`: a symbol's mark in a ring on the meter's track.
private struct MarketsMark: View {
    @Environment(\.deskKit) private var kit
    let text: String, side: CGFloat

    var body: some View {
        Text(text).font(kit.mono(side * 0.46, .semibold)).foregroundStyle(kit.text2).lineLimit(1).minimumScaleFactor(0.6)
            .frame(width: side, height: side)
            .background(Circle().fill(kit.track))
            .overlay(Circle().strokeBorder(kit.edge, lineWidth: 1))
            .accessibilityHidden(true)
    }
}

/// `.chg`: the change in the theme's good or problem colour.
private struct MarketsChange: View {
    @Environment(\.deskKit) private var kit
    let figures: MarketsFigures
    var money = false, size: CGFloat = 11

    var body: some View {
        Text(figures.change(money: money)).font(kit.mono(size)).monospacedDigit().lineLimit(1)
            .foregroundStyle(figures.up.map { $0 ? kit.good : kit.problem } ?? kit.text3)
    }
}

/// `.chart`: the line over its range, scaled to its own low and high (and the day's previous close, a dashed rule, when
/// `previous`), with a fade under it and a dot at its latest when `full`; a spark is the line alone.
private struct MarketsChart: View {
    @Environment(\.deskKit) private var kit
    let points: [Double]
    var previous: Double? = nil
    let up: Bool?
    var full = true

    var body: some View {
        let colour = up.map { $0 ? kit.good : kit.problem } ?? kit.text2
        GeometryReader { box in
            let plot = Plot(points: points, previous: previous, size: box.size, inset: full ? 3 : 1)
            ZStack {
                if full, let y = plot.previousY {
                    Path { $0.move(to: CGPoint(x: 0, y: y)); $0.addLine(to: CGPoint(x: box.size.width, y: y)) }
                        .stroke(kit.text3.opacity(0.7), style: StrokeStyle(lineWidth: 1, dash: [2, 3]))
                }
                if full {
                    plot.area.fill(LinearGradient(colors: [colour.opacity(0.24), colour.opacity(0)], startPoint: .top, endPoint: .bottom))
                }
                plot.line.stroke(colour, style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
                if full, let last = plot.last { Circle().fill(kit.accent).frame(width: 6, height: 6).position(last) }
            }
        }
        .accessibilityHidden(true)
    }

    /// The line's points in the box.
    struct Plot {
        let line: Path, area: Path, last: CGPoint?, previousY: CGFloat?

        init(points: [Double], previous: Double?, size: CGSize, inset: CGFloat) {
            guard points.count > 1 else { (line, area, last, previousY) = (Path(), Path(), nil, nil); return }
            let all = previous.map { points + [$0] } ?? points
            var low = all.min()!, high = all.max()!
            let span = high - low
            if span == 0 { low -= 1; high += 1 } else { low -= span * 0.08; high += span * 0.08 }
            let step = (size.width - 2 * inset) / CGFloat(points.count - 1)
            let y = { (v: Double) in inset + (size.height - 2 * inset) * CGFloat(1 - (v - low) / (high - low)) }
            let xy = points.enumerated().map { CGPoint(x: inset + CGFloat($0.offset) * step, y: y($0.element)) }
            var line = Path()
            line.addLines(xy)
            var area = line
            area.addLine(to: CGPoint(x: xy.last!.x, y: size.height))
            area.addLine(to: CGPoint(x: xy[0].x, y: size.height))
            area.closeSubpath()
            (self.line, self.area, last, previousY) = (line, area, xy.last, previous.map(y))
        }
    }
}

/// `.tabs`: the range keys, the board's in the text over an accent rule; a press shows that range.
private struct MarketsKeys: View {
    @Environment(\.deskKit) private var kit
    let board: MarketsBoard

    var body: some View {
        HStack(spacing: 2) {
            ForEach(WidgetMarkets.Range.allCases, id: \.self) { range in
                let on = range == board.range
                Button { board.pick(range) } label: {
                    Text(range.rawValue).font(kit.mono(9.5, .medium)).tracking(0.57).foregroundStyle(on ? kit.text : kit.text3)
                        .padding(.horizontal, 6).padding(.top, 3).padding(.bottom, 2)
                        .overlay(alignment: .bottom) { if on { kit.accent.frame(height: 1.5) } }
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Show \(range.rawValue)").accessibilityAddTraits(on ? .isSelected : [])
            }
        }
        .fixedSize()
    }
}

/// One symbol, by class.
private struct MarketsOne: View {
    @Environment(\.deskKit) private var kit
    @Environment(\.widgetFit) private var fit
    let board: MarketsBoard
    let symbol: WidgetMarkets.Symbol

    var body: some View {
        let figures = MarketsFigures(symbol: symbol, quote: board.quotes[symbol.key], range: board.range)
        let line = board.lines[symbol.key] ?? []
        let previous = board.range == .day ? figures.quote?.previous : nil
        switch fit.size {
        case .large:
            VStack(alignment: .leading, spacing: 8) {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 9) {
                        MarketsMark(text: Markets.mark(symbol, figures.quote), side: 24)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(symbol.symbol).font(kit.mono(12, .semibold)).tracking(0.24).foregroundStyle(kit.text)
                            Text([figures.name, figures.quote?.currency].compactMap { $0 }.joined(separator: " · "))
                                .font(kit.sans(10.5)).foregroundStyle(kit.text3)
                        }
                        .lineLimit(1)
                        Spacer(minLength: 0)
                        Text(figures.kind.uppercased()).font(kit.mono(9.5)).tracking(0.86).foregroundStyle(kit.text3).lineLimit(1)
                    }
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(figures.price).font(kit.mono(28, .light)).tracking(-0.84).monospacedDigit().foregroundStyle(kit.text)
                            .lineLimit(1).minimumScaleFactor(0.6)
                        if let currency = figures.quote?.currency { Text(currency).font(kit.mono(10)).foregroundStyle(kit.text3) }
                        MarketsChange(figures: figures, money: true)
                    }
                    chart(line, previous, figures)
                }
                .opens(symbol)
                HStack(spacing: 8) {
                    MarketsKeys(board: board)
                    Spacer(minLength: 0)
                    if let highLow = figures.highLow { Text(highLow).font(kit.mono(9.5)).foregroundStyle(kit.text3).lineLimit(1) }
                }
            }
        case .wide:
            HStack(spacing: 14) {
                VStack(alignment: .leading, spacing: 5) {
                    VStack(alignment: .leading, spacing: 5) {
                        HStack(spacing: 7) {
                            MarketsMark(text: Markets.mark(symbol, figures.quote), side: 20)
                            Text(symbol.symbol).font(kit.mono(12, .semibold)).foregroundStyle(kit.text).lineLimit(1)
                        }
                        Text(figures.price).font(kit.mono(24, .light)).tracking(-0.72).monospacedDigit().foregroundStyle(kit.text)
                            .lineLimit(1).minimumScaleFactor(0.5)
                        MarketsChange(figures: figures, size: 11)
                    }
                    .opens(symbol)
                    Spacer(minLength: 0)
                    if let highLow = figures.highLow { Text(highLow).font(kit.mono(9.5)).foregroundStyle(kit.text3).lineLimit(1).minimumScaleFactor(0.8) }
                    MarketsKeys(board: board).padding(.horizontal, -6)
                }
                .frame(width: min(150, max(110, fit.width * 0.4)), alignment: .leading)
                chart(line, previous, figures).opens(symbol)
            }
        case .square:
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 7) {
                    MarketsMark(text: Markets.mark(symbol, figures.quote), side: 18)
                    Text(symbol.symbol).font(kit.mono(11.5, .semibold)).foregroundStyle(kit.text).lineLimit(1)
                    Spacer(minLength: 0)
                    Text(board.range.rawValue).font(kit.mono(9.5)).foregroundStyle(kit.text3)
                }
                Text(figures.price).font(kit.mono(24, .light)).tracking(-0.72).monospacedDigit().foregroundStyle(kit.text)
                    .lineLimit(1).minimumScaleFactor(0.5).padding(.top, 4)
                MarketsChange(figures: figures, size: 11)
                if line.count > 1 { MarketsChart(points: line, up: figures.up, full: false).padding(.top, 6) } else { Spacer(minLength: 0) }
            }
            .opens(symbol)
        case .strip:
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                MarketsMark(text: Markets.mark(symbol, figures.quote), side: 18).alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 4 }
                Text(symbol.symbol).font(kit.mono(12, .semibold)).foregroundStyle(kit.text)
                Text(figures.price).font(kit.mono(17, .light)).monospacedDigit().foregroundStyle(kit.text)
                MarketsChange(figures: figures, money: true, size: 11)
                Spacer(minLength: 0)
            }
            .lineLimit(1)
            .accessibilityElement(children: .combine)
            .opens(symbol)
        }
    }

    /// The chart; nothing while its line is asked; else a quiet line saying why there is none.
    @ViewBuilder private func chart(_ line: [Double], _ previous: Double?, _ figures: MarketsFigures) -> some View {
        if line.count > 1 {
            MarketsChart(points: line, previous: previous, up: figures.up).frame(maxHeight: .infinity).frame(minHeight: 30)
        } else if !board.loaded.contains(symbol.key) {
            Color.clear.frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            Text(board.errors[symbol.key] == nil && figures.quote != nil && board.range == .day ? "Its line fills in as prices are read."
                 : "No line for \(board.range.rawValue): no free source keeps its history.")
                .font(kit.mono(10)).foregroundStyle(kit.text3).frame(maxWidth: .infinity, maxHeight: .infinity)
                .multilineTextAlignment(.center)
        }
    }
}

/// Several symbols, by class.
private struct MarketsSeveral: View {
    @Environment(\.deskKit) private var kit
    @Environment(\.widgetFit) private var fit
    let board: MarketsBoard

    var body: some View {
        let rows = board.symbols.map { MarketsFigures(symbol: $0, quote: board.quotes[$0.key], range: board.range) }
        switch fit.size {
        case .strip:
            // Design D's ticker line, still: as many as fit, the rest faded out at the right.
            HStack(spacing: 0) {
                ForEach(rows.indices, id: \.self) { i in
                    if i > 0 { kit.edge.frame(width: 1, height: 18).accessibilityHidden(true) }
                    HStack(alignment: .firstTextBaseline, spacing: 7) {
                        MarketsMark(text: Markets.mark(rows[i].symbol, rows[i].quote), side: 16)
                            .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 4 }
                        Text(rows[i].symbol.symbol).font(kit.mono(11, .semibold)).foregroundStyle(kit.text)
                        Text(rows[i].price).font(kit.mono(11)).monospacedDigit().foregroundStyle(kit.text2)
                        MarketsChange(figures: rows[i], size: 10.5)
                    }
                    .lineLimit(1).fixedSize()
                    .padding(.horizontal, 12)
                    .accessibilityElement(children: .combine)
                    .opens(rows[i].symbol)
                }
            }
            .padding(.horizontal, -12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .clipped()
            .mask(LinearGradient(stops: [.init(color: .black, location: 0), .init(color: .black, location: 0.92), .init(color: .clear, location: 1)],
                                 startPoint: .leading, endPoint: .trailing))
        case .square:
            VStack(alignment: .leading, spacing: 6) {
                DeskKitHead(title: "Markets", meta: board.range.rawValue)
                GeometryReader { box in
                    // The top rows its height holds whole.
                    let fits = max(1, Int((box.size.height + 1) / 27))
                    VStack(spacing: 0) {
                        ForEach(rows.prefix(fits).indices, id: \.self) { i in
                            if i > 0 { kit.edge.frame(height: 1).accessibilityHidden(true) }
                            HStack(alignment: .firstTextBaseline, spacing: 6) {
                                Text(rows[i].symbol.symbol).font(kit.mono(11, .semibold)).foregroundStyle(kit.text).lineLimit(1).truncationMode(.tail)
                                Spacer(minLength: 4)
                                VStack(alignment: .trailing, spacing: 0) {
                                    Text(rows[i].price).font(kit.mono(11)).monospacedDigit().foregroundStyle(kit.text)
                                    MarketsChange(figures: rows[i], size: 9.5)
                                }
                                .lineLimit(1).fixedSize()
                            }
                            .frame(height: 26)
                            .accessibilityElement(children: .combine)
                            .opens(rows[i].symbol)
                        }
                    }
                }
            }
        case .wide, .large:
            VStack(alignment: .leading, spacing: 6) {
                DeskKitHead(title: "Markets", meta: "\(rows.count) · \(board.range.rawValue)")
                ScrollView(.vertical) {
                    if fit.size == .wide, fit.width >= 360, rows.count > 3 {
                        let half = (rows.count + 1) / 2
                        HStack(alignment: .top, spacing: 16) {
                            column(Array(rows[..<half]), names: false)
                            column(Array(rows[half...]), names: false)
                        }
                    } else {
                        column(rows, names: true)
                    }
                }
                .scrollIndicators(.never).scrollBounceBehavior(.basedOnSize)
            }
        }
    }

    /// `.qrow`s on hairlines: mark, symbol over its name, a spark, price over change.
    private func column(_ rows: [MarketsFigures], names: Bool) -> some View {
        VStack(spacing: 0) {
            ForEach(rows.indices, id: \.self) { i in
                if i > 0 { kit.edge.frame(height: 1).accessibilityHidden(true) }
                HStack(spacing: names ? 10 : 8) {
                    // Two columns leave the marks out, so the symbol keeps its room.
                    if names { MarketsMark(text: Markets.mark(rows[i].symbol, rows[i].quote), side: 20) }
                    VStack(alignment: .leading, spacing: 1) {
                        Text(rows[i].symbol.symbol).font(kit.mono(12, .semibold)).foregroundStyle(kit.text)
                        if names { Text(rows[i].name).font(kit.sans(10.5)).foregroundStyle(kit.text3) }
                    }
                    .lineLimit(1).truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    if let line = board.lines[rows[i].symbol.key], line.count > 1 {
                        MarketsChart(points: line, up: rows[i].up, full: false).frame(width: names ? 46 : 34, height: 16)
                    }
                    VStack(alignment: .trailing, spacing: 1) {
                        Text(rows[i].price).font(kit.mono(11.5)).monospacedDigit().foregroundStyle(kit.text)
                        MarketsChange(figures: rows[i], size: 10)
                    }
                    .lineLimit(1).fixedSize()
                }
                .padding(.vertical, 6)
                .accessibilityElement(children: .combine)
                .opens(rows[i].symbol)
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }
}

/// Edit widget's Symbols (Sven Q729: like the Launcher's): the picked symbols moved up or down or removed, then
/// TradingView's search through the Markets extension, as Sven types, a click adding one; at most WidgetMarkets.most.
struct WidgetMarketsEditor: View {
    @Environment(\.ink) private var ink
    @Binding var value: JSONValue?
    @State private var query = ""
    @State private var found: [WidgetMarkets.Found] = []
    @State private var why: String?
    /// The names the search gave, for the picked list's titles.
    @State private var names: [String: String] = [:]

    var body: some View {
        let keys = Binding<[String]>(get: { WidgetMarkets.symbols(value).map(\.key) }, set: { value = .array($0.map(JSONValue.string)) })
        let taken = Set(keys.wrappedValue), full = taken.count >= WidgetMarkets.most
        let titles = keys.wrappedValue.compactMap(WidgetMarkets.Symbol.init).map { symbol in
            WidgetEditChoices.Pick(id: symbol.key, title: [symbol.symbol, names[symbol.key] ?? symbol.exchange].joined(separator: " · "), group: "")
        }
        VStack(alignment: .leading, spacing: 6) {
            ScrollView(.vertical) { WidgetPicksList(picks: keys, choices: titles, empty: "No symbols yet.", missing: "") }
                .frame(maxHeight: 150).fixedSize(horizontal: false, vertical: true)
            Text("One symbol draws its chart. Two or more draw a list.").font(ink.ui(11)).foregroundStyle(ink.muted)
            TextField("Add a symbol: BTC, AAPL, EURUSD, SPX", text: $query).pilotField().disabled(full)
            if !query.trimmingCharacters(in: .whitespaces).isEmpty {
                ScrollView(.vertical) {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(found.filter { !taken.contains($0.key) }, id: \.key) { pick in
                            Button { keys.wrappedValue.append(pick.key); names[pick.key] = pick.name; query = "" } label: {
                                HStack(spacing: 6) {
                                    Image(systemName: "plus.circle").foregroundStyle(ink.muted)
                                    Text(pick.symbol).font(ink.ui(12.5, .semibold)).foregroundStyle(ink.text).lineLimit(1)
                                    Text(pick.name).font(ink.ui(12)).foregroundStyle(ink.text2).lineLimit(1)
                                    Spacer(minLength: 6)
                                    Text(pick.group).font(ink.ui(11)).foregroundStyle(ink.muted).lineLimit(1)
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.borderless).disabled(full)
                        }
                        if let why { Text(why).font(ink.ui(12)).foregroundStyle(ink.muted) }
                        else if found.isEmpty { Text("Searching TradingView…").font(ink.ui(12)).foregroundStyle(ink.muted) }
                    }
                }
                .frame(height: 140)
            }
        }
        .task(id: query) {
            let text = query.trimmingCharacters(in: .whitespaces)
            (found, why) = ([], nil)
            guard !text.isEmpty else { return }
            // As Sven types: the search after a pause, an older one dropped.
            try? await Task.sleep(for: .milliseconds(350))
            guard !Task.isCancelled else { return }
            switch await WidgetMarkets.search(text) {
            case .success(let listings) where !Task.isCancelled: (found, why) = (listings, listings.isEmpty ? "TradingView finds nothing for \(text)." : nil)
            case .failure(let problem) where !Task.isCancelled: why = problem.text
            default: break
            }
        }
    }
}
