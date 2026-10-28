import Foundation
import Testing
@testable import PilotCore

/// Search the web in the default browser with its own default engine (Sven 2026-10-16): Safari's link, a Chromium
/// profile's template, a Firefox profile's search.json; Google for anything unread. Pure: sample settings, no browser.
@Suite("Web search engine")
struct WebSearchTests {
    @Test("An engine's address takes the words percent-encoded, & and # kept inside the query")
    func address() {
        #expect(WebSearch.google.url(for: "fish & chips #1")?.absoluteString == "https://www.google.com/search?q=fish%20%26%20chips%20%231")
        #expect(WebSearch.safari.url(for: "notes app")?.absoluteString == "x-web-search://?notes%20app")
    }

    @Test("Browsers by bundle id: Safari, the Chromium family with their own first engine, the Firefox family (Zen)")
    func families() {
        #expect(WebSearch.family(bundleID: "com.apple.Safari") == .safari)
        #expect(WebSearch.family(bundleID: "com.google.Chrome") == .chromium(folder: "Google/Chrome", standard: WebSearch.google))
        guard case .chromium(_, let edge) = WebSearch.family(bundleID: "com.microsoft.edgemac") else { Issue.record("Edge"); return }
        #expect(edge.name == "Bing")
        #expect(WebSearch.family(bundleID: "app.zen-browser.zen") == .firefox(folder: "zen"))
        #expect(WebSearch.family(bundleID: "com.example.unknown") == .other)
    }

    @Test("A Chromium profile's engine: Chrome's own placeholders dropped, the words where {searchTerms} was")
    func chromium() throws {
        let mirrored = #"{"default_search_provider_data":{"mirrored_template_url_data":{"short_name":"Google","keyword":"google.com","url":"{google:baseURL}search?q={searchTerms}&{google:RLZ}{google:originalQueryForSuggestion}{google:assistedQueryStats}{google:searchFieldtrialParameter}{google:language}sourceid=chrome&ie={inputEncoding}"}}}"#
        let google = try #require(WebSearch.chromium(preferences: Data(mirrored.utf8)))
        #expect(google.name == "Google")
        #expect(google.template == "https://www.google.com/search?q={query}&sourceid=chrome&ie=")
        #expect(google.url(for: "a b")?.absoluteString.hasPrefix("https://www.google.com/search?q=a%20b") == true)
        let picked = #"{"default_search_provider_data":{"template_url_data":{"short_name":"DuckDuckGo","url":"https://duckduckgo.com/?q={searchTerms}"}}}"#
        #expect(WebSearch.chromium(preferences: Data(picked.utf8)) == WebSearch.Engine(name: "DuckDuckGo", template: "https://duckduckgo.com/?q={query}"))
        #expect(WebSearch.chromium(preferences: Data(#"{"profile":{}}"#.utf8)) == nil)
        #expect(WebSearch.chromiumProfile(localState: Data(#"{"profile":{"last_used":"Profile 2"}}"#.utf8)) == "Profile 2")
        #expect(WebSearch.chromiumProfile(localState: nil) == "Default")
    }

    @Test("A Firefox profile: installs.ini names it, else profiles.ini's default; search.json's default engine, built in or added")
    func firefox() throws {
        let installs = "[6F193CCC56814779]\nDefault=Profiles/7tm5xpi8.Default (release)\nLocked=1\n"
        #expect(WebSearch.firefoxProfile(installs: installs, profiles: nil) == "Profiles/7tm5xpi8.Default (release)")
        let profiles = "[General]\nStartWithLastProfile=1\n\n[Profile1]\nName=other\nPath=Profiles/b\n\n[Profile0]\nName=default\nPath=Profiles/a\nDefault=1\n"
        #expect(WebSearch.firefoxProfile(installs: nil, profiles: profiles) == "Profiles/a")
        let builtIn = #"{"engines":[{"id":"google","_name":"Google","_isAppProvided":true},{"id":"ddg","_name":"DuckDuckGo","_isAppProvided":true}],"metaData":{"defaultEngineId":"ddg"}}"#
        #expect(WebSearch.firefox(searchJSON: Data(builtIn.utf8))?.name == "DuckDuckGo")
        let added = #"{"engines":[{"id":"k1","_name":"Kagi","_urls":[{"template":"https://kagi.com/search","params":[{"name":"q","value":"{searchTerms}"}]},{"template":"https://kagi.com/api/autosuggest?q={searchTerms}","type":"application/x-suggestions+json"}]}],"metaData":{"defaultEngineId":"k1"}}"#
        #expect(WebSearch.firefox(searchJSON: Data(added.utf8)) == WebSearch.Engine(name: "Kagi", template: "https://kagi.com/search?q={query}"))
        let older = #"{"engines":[],"metaData":{"current":"Bing"}}"#
        #expect(WebSearch.firefox(searchJSON: Data(older.utf8))?.name == "Bing")
        #expect(WebSearch.firefox(searchJSON: Data(#"{"engines":[],"metaData":{}}"#.utf8)) == nil, "no pick: the browser's own default")
        // Zen with nothing picked names the engine it ships with (as this Mac's Zen did, 2026-10-16).
        let shipped = #"{"engines":[{"id":"google"},{"id":"ddg"}],"metaData":{"appDefaultEngineId":"ddg","locale":"en-US"}}"#
        #expect(WebSearch.firefox(searchJSON: Data(shipped.utf8))?.name == "DuckDuckGo")
    }
}
