import AppKit
import PilotCore
import SwiftUI
import WebApps

/// A site Pilot recommends making into an app (Sven 2026-10-10, replacing Omarchy's set): a well-known service people
/// keep open all day, with its own brand icon shipped in the app (`webapp-icons/<id>.png`, Scripts/webapp-icons.swift).
struct WebAppIdea: Identifiable {
    let id: String
    let name: String
    let link: String

    var host: String { SameSite.normalized(URL(string: link)?.host() ?? link) }

    /// Made already: a web app Pilot built opens this site.
    func isMade(hosts: Set<String>) -> Bool { hosts.contains { SameSite.normalized($0) == host } }

    /// The site's own icon, 128 px.
    @MainActor var icon: NSImage? { CatalogueIcons.image(id, in: "webapp-icons") }

    static let all: [WebAppIdea] = [
        WebAppIdea(id: "gmail", name: "Gmail", link: "https://mail.google.com"),
        WebAppIdea(id: "google-calendar", name: "Google Calendar", link: "https://calendar.google.com"),
        WebAppIdea(id: "google-drive", name: "Google Drive", link: "https://drive.google.com"),
        WebAppIdea(id: "whatsapp", name: "WhatsApp", link: "https://web.whatsapp.com"),
        WebAppIdea(id: "slack", name: "Slack", link: "https://app.slack.com"),
        WebAppIdea(id: "discord", name: "Discord", link: "https://discord.com/app"),
        WebAppIdea(id: "x", name: "X", link: "https://x.com"),
        WebAppIdea(id: "youtube", name: "YouTube", link: "https://www.youtube.com"),
        WebAppIdea(id: "spotify", name: "Spotify", link: "https://open.spotify.com"),
        WebAppIdea(id: "chatgpt", name: "ChatGPT", link: "https://chatgpt.com"),
        WebAppIdea(id: "claude", name: "Claude", link: "https://claude.ai"),
        WebAppIdea(id: "notion", name: "Notion", link: "https://www.notion.so"),
        WebAppIdea(id: "linear", name: "Linear", link: "https://linear.app"),
        WebAppIdea(id: "figma", name: "Figma", link: "https://www.figma.com"),
        WebAppIdea(id: "github", name: "GitHub", link: "https://github.com"),
    ]
}

/// Install › Web apps (design round 4 section 7, card agent-bo-95422897; wireframe mSEMT3YCZpU section 9): a paste-a-link
/// block that opens the build form on the link (wireframe wo-nZ-ZEKkY section 11, which says what a web app cannot do
/// before it builds), and every web app Pilot built, with Rebuild, Remove and Rebuild all. Remove asks as the menu's does,
/// then moves it to the Trash (card agent-bo-95422994); Rebuild gives it Pilot's newest web app (downloads, find,
/// notifications) and keeps its logins. Window top (Q355) sets what sits at the top of every web app's window.
struct WebAppsSettingsView: View {
    @Environment(\.ink) private var ink
    @Bindable private var window = WebAppWindow.shared
    @State private var apps = WebAppDirectory.list()
    /// The build form, on the link pasted (empty for none).
    @State private var creating: String?
    @State private var link = ""
    @State private var error: String?
    /// The app being rebuilt, or "all".
    @State private var rebuilding: String?
    @State private var rebuilt: String?

    var body: some View {
        KitPage(intro: "Any site as its own app, signed with Pilot's certificate, in ~/Applications.") {
            if ink.isInstrument {
                InstrumentPair { paste } right: { made }
            } else {
                paste; made
            }
            if let error { FinePrint(text: error, color: ink.red).padding(.top, 12) }
            if let rebuilt { FinePrint(text: rebuilt).padding(.top, 8) }
            windowTop
            ideas
        }
        .sheet(item: Binding(get: { creating.map(PastedLink.init) }, set: { creating = $0?.url }), onDismiss: { apps = WebAppDirectory.list() }) {
            NewWebAppForm(url: $0.url).floating()
        }
    }

    private var paste: some View {
        KitBlock(title: "New web app", symbol: "link", focused: true, fill: true) {
            VStack(alignment: .leading, spacing: 10) {
                TextField("Link", text: $link, prompt: Text(verbatim: "Paste a link, e.g. https://x.com").foregroundStyle(ink.muted))
                    .pilotField().onSubmit { creating = link }
                HStack {
                    Text("Name and icon come from the site.").font(ink.ui(11.5)).foregroundStyle(ink.muted)
                    Spacer()
                    Button("Make app…") { creating = link }.buttonStyle(.pilotPrimary)
                }
                ink.line.frame(height: 1).padding(.vertical, 4)
                VStack(alignment: .leading, spacing: 7) {
                    fact("checkmark.circle", ink.mark(ink.green), "Its own Dock icon, window and logins, apart from your browser")
                    fact("checkmark.circle", ink.mark(ink.green), "Downloads, find in page and notifications")
                    ForEach(WebAppSpec.limits, id: \.self) { fact("minus.circle", ink.muted, $0) }
                    fact("questionmark.circle", ink.muted, WebAppSpec.unverified)
                }
            }
            .padding(.vertical, 10)
        }
    }

    private var windowTop: some View {
        KitBlock(title: "Window", symbol: "macwindow") {
            BlockRow(first: true) {
                Text("Window top")
                InfoMark(text: "Nothing on top: the page fills the window; close with ⌘W, move with Hyper+drag. Buttons on hover: "
                    + "the same, and pointing at the top-left corner shows the window buttons. Slim strip: the window buttons on a "
                    + "strip in the page's colour. Standard: macOS's title bar with the page's title.")
                Spacer()
                Segments(selection: $window.top, options: WindowTop.allCases.map { ($0, $0.title) }, label: "Window top")
            }
            FinePrint(text: "Open web apps change at once. One made before this version needs Rebuild once.").padding(.vertical, 8)
        }
    }

    /// One thing a web app does or does not do, under the link.
    private func fact(_ symbol: String, _ colour: Color, _ text: String) -> some View {
        Label { Text(text).foregroundStyle(ink.text2) } icon: { Image(systemName: symbol).foregroundStyle(colour) }
            .font(ink.ui(12))
    }

    /// Sites Pilot recommends making into apps: one click opens the build form on the site.
    private var ideas: some View {
        let hosts = Set(apps.compactMap { $0.url.host() })
        return KitBlock(title: "Recommended", symbol: "star") {
            Text("Popular sites as apps").foregroundStyle(ink.muted)
        } content: {
            CardGrid(minimum: 200, spacing: 8, stretch: true) {
                ForEach(WebAppIdea.all) { idea in
                    let made = idea.isMade(hosts: hosts)
                    Button { link = idea.link; creating = idea.link } label: {
                        VStack(alignment: .leading, spacing: 0) {
                            HStack(alignment: .top) {
                                if let icon = idea.icon {
                                    Image(nsImage: icon).resizable().interpolation(.high).frame(width: 44, height: 44)
                                        .clipShape(.rect(cornerRadius: 10, style: .continuous)).accessibilityHidden(true)
                                } else {
                                    KitTile(symbol: "globe", colour: .neutral, size: 44, letter: String(idea.name.prefix(1)))
                                }
                                Spacer(minLength: 6)
                                if made { Chip(text: "made", color: ink.green) }
                                else { Image(systemName: "plus").font(ink.ui(13, .semibold)).foregroundStyle(ink.mark(ink.accentInk)) }
                            }
                            Spacer(minLength: 16)
                            Text(idea.name).font(ink.ui(14, .semibold)).foregroundStyle(ink.text).lineLimit(1)
                            Text(idea.host).font(ink.ui(11.5)).foregroundStyle(ink.muted).lineLimit(1).padding(.top, 2)
                        }
                        .padding(14)
                        .frame(minHeight: 128)
                        .innerCard()
                    }
                    .buttonStyle(.kitPress).disabled(made)
                    .accessibilityLabel(made ? "\(idea.name), made" : "Make \(idea.name) into an app")
                }
            }
            .padding(.vertical, 10)
        }
    }

    private var made: some View {
        KitBlock(title: "Your web apps", symbol: "app.badge", fill: true) {
            if apps.count > 1 {
                AccentLink(title: rebuilding == "all" ? "Rebuilding…" : "Rebuild all", chevron: "arrow.clockwise") { Task { await rebuild(apps, as: "all") } }
                    .disabled(rebuilding != nil)
            }
        } content: {
            if apps.isEmpty {
                EmptyState(title: "No web apps yet", line: "Paste a link to make the first one.").padding(.vertical, 8)
            }
            ForEach(Array(apps.enumerated()), id: \.element.id) { i, app in
                BlockRow(first: i == 0) {
                    let letter = String(app.name.prefix(1)).uppercased()
                    if ink.isInstrument { InstrumentAppIcon(bundle: nil, size: 22, letter: letter) } else {
                        Text(letter).font(ink.ui(11, .semibold)).foregroundStyle(ink.onAccent)
                            .frame(width: 22, height: 22).background(ink.accent, in: .rect(cornerRadius: 6))
                            .accessibilityHidden(true)
                    }
                    VStack(alignment: .leading, spacing: 1) {
                        Text(app.name).lineLimit(1)
                        Text("\(app.url.host ?? "") · ~/Applications/\(app.location.lastPathComponent)").font(ink.ui(11)).foregroundStyle(ink.muted).lineLimit(1)
                    }
                    Spacer()
                    Button(rebuilding == app.id ? "Rebuilding…" : "Rebuild") { Task { await rebuild([app], as: app.id) } }
                        .buttonStyle(.pilot).disabled(rebuilding != nil)
                    Button("Remove") { InstallModule.remove(app) { apps = WebAppDirectory.list() } }.buttonStyle(.pilotDestructive)
                }
            }
        }
    }

    /// Card agent-bo-95422813: WebAppRebuild does the work off the main thread; this says how it went.
    private func rebuild(_ targets: [InstalledWebApp], as label: String) async {
        rebuilding = label
        let outcomes = await WebAppRebuild.all(targets)
        rebuilding = nil
        for outcome in outcomes { alog.notice("web app rebuild \(outcome.name, privacy: .public): \(outcome.failure ?? "done", privacy: .public)") }
        let done = outcomes.filter { $0.failure == nil }.map(\.name)
        rebuilt = done.isEmpty ? nil : "Rebuilt \(done.joined(separator: ", ")). Open it again to use it."
        error = outcomes.compactMap(\.failure).joined(separator: "\n").nilIfEmpty
        apps = WebAppDirectory.list()
    }
}

/// Install › Web app: a URL and a name; the limits sit above Create app, so they are read before building.
struct NewWebAppForm: View {
    @Environment(\.dismiss) private var dismiss
    @State private var url: String
    @State private var name = ""
    @State private var nameEdited = false
    @State private var building = false
    @State private var built: URL?
    @State private var error: String?

    /// `url` is the link pasted on Install › Web apps; its name is fetched from the page at once.
    init(url: String = "") { _url = State(initialValue: url) }

    var body: some View {
        Form {
            Section("Web app") {
                TextField("URL", text: $url, prompt: Text("https://x.com"))
                    .onSubmit(suggestName)
                TextField("Name", text: Binding(get: { name }, set: { name = $0; nameEdited = true }),
                          prompt: Text("from the page title"))
                LabeledContent("Icon", value: "From the site")
            }
            Section("Not inside web apps") {
                ForEach(WebAppSpec.limits, id: \.self) { Text($0) }
                Text(WebAppSpec.unverified).foregroundStyle(Theme.muted)
            }
            if let built {
                Section {
                    HStack {
                        Text("Done: \(built.lastPathComponent) in ~/Applications")
                        Spacer()
                        Button("Open") { NSWorkspace.shared.openApplication(at: built, configuration: .init()) }
                    }
                }
            }
            if let error { Text(error).foregroundStyle(Theme.red) }
        }
        .formStyle(.grouped)
        .frame(width: 440)
        .onChange(of: url) { built = nil; error = nil }
        .onAppear { if !url.isEmpty { suggestName() } }
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button(built == nil ? "Cancel" : "Close") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button(building ? "Building…" : "Create app", action: create)
                    .disabled(building || url.isEmpty)
            }
        }
        // After the toolbar, so its buttons keep the system's look too.
        .pilotSheet()
    }

    /// Fills the name from the page once the URL is entered, unless it was typed by hand.
    private func suggestName() {
        guard !nameEdited, let page = URL(string: url), page.host != nil else { return }
        Task {
            let suggested = await WebAppSpec.suggestedName(for: page)
            if !nameEdited { name = suggested }
        }
    }

    private func create() {
        building = true
        error = nil
        Task {
            defer { building = false }
            do {
                if name.isEmpty, let page = URL(string: url) { name = await WebAppSpec.suggestedName(for: page) }
                let spec = try WebAppSpec(name: name, url: url)
                built = try await WebAppStamper.install(spec)
                alog.notice("web app built: \(spec.bundleID, privacy: .public) at \(built?.path ?? "", privacy: .public)")
            } catch {
                self.error = "Could not build it: \(String(describing: error))"
                alog.error("web app build failed: \(String(describing: error), privacy: .public)")
            }
        }
    }
}

/// The link the build form opens on.
private struct PastedLink: Identifiable {
    let url: String
    var id: String { url }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
