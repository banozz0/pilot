import AppKit
import PilotCore
import SwiftUI

/// Stickers and GIFs' switch (Sven 2026-10-12): what GIPHY is asked for, its GIFs or its stickers, as two chips under the
/// search; Tab or a click flips it and the menu keeps the pick. The folder's pictures and the emoji list under both. At its
/// right, while GIPHY's rows are listed, its attribution: the logo beside "Powered by GIPHY" (its API terms, T39), in
/// every menu style, as each draws this bar.
struct GiphyKindBar: View {
    @Bindable var model: MenuModel
    /// Its height in Instrument, chips and padding, which the panel adds over the list (MenuPanelSize.instrument).
    static let instrumentHeight: CGFloat = 38

    var body: some View {
        HStack(spacing: 6) {
            ForEach(Giphy.Kind.allCases, id: \.self) { kind in
                let on = model.giphyKind == kind
                Button { model.pickGiphy(kind) } label: {
                    Chip(text: kind.title, on: on, count: on ? nil : "Tab", symbol: kind == .gifs ? "play.rectangle" : "sparkles")
                }
                .buttonStyle(.plain)
                .help("GIPHY's \(kind.title.lowercased()); Tab switches")
                .accessibilityLabel("GIPHY \(kind.title)\(on ? ", shown" : "; Tab")")
            }
            Spacer(minLength: 0)
            if model.showsGiphyAttribution { GiphyAttribution() }
        }
        .lineLimit(1)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("GIPHY GIFs or stickers")
    }
}

/// GIPHY's logo beside "Powered by GIPHY", as its attribution marks pair them (developers.giphy.com/docs/api, "approved
/// official logo marks"): the mark is cut from its Poweredby_640px-White_HorizLogo.png and scaled, never redrawn; its black
/// page reads on light and dark menus alike.
struct GiphyAttribution: View {
    @Environment(\.style) private var style

    var body: some View {
        HStack(spacing: 6) {
            if let mark = Self.mark { Image(nsImage: mark).resizable().interpolation(.high).frame(width: 10, height: 12) }
            Text(Giphy.attribution).styleText(\.caption).foregroundStyle(style.color(\.text3)).fixedSize()
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Giphy.attribution)
    }

    /// The mark at 40 by 48 pixels (four times its 10 by 12 points), 955 bytes, in the source so no bundle copy is needed.
    static let mark: NSImage? = Data(base64Encoded: markPNG).flatMap(NSImage.init(data:))
    private static let markPNG = "iVBORw0KGgoAAAANSUhEUgAAACgAAAAwCAYAAABjezibAAAAAXNSR0IArs4c6QAAAERlWElmTU0AKgAAAAgAAYdpAAQAAAABAAAAGgAAAAAAA6ABAAMAAAABAAEAAKACAAQAAAABAAAAKKADAAQAAAABAAAAMAAAAAAqdrrvAAADJUlEQVRYCe2Zz2sTQRTHv7M7SZPUNgGxtcVCTr3kUEqVInjwoH+AJw/+D/4B4k38IwTx4k2QQg/2VvAgFBQPYqp4EPXS0lpSUtPmx2bX9zbJ7mQnTbtpuuxhB5Z9O3k779PvvJnOzIqNjcfO0tICHMfBpRRTwPpSgXz1G5ACgoLYFOvR5ibe7+ycGVLOzFzB3FyeHC8JkJCsaxZkLucCukQEmDbNM+HYwbgs4dTowRhhpJBSbcmzDc+6uCFgmnp77SD1KYFkmX7o+4tsB5mfuxCWDTdhTnnxvNU2JV32Tw1FwdnXLWQv5vP4e3ICg+vpOrEs/Dg87GchdzH56YkjV4r0A2NSEh/VYdx8Duwf9Zq78P3e9Xm8uXsfaLe9tmoEZNkkAhVhGNg+OMCd9XUElZU175WuwdJXjjtX8LcRn6u5uvbmZCrl1xHgdDrtPyvWKSmodIfiPKppGAPaU3OQbJ56BhU9ewd5RVDHgMHu5bCDFYwAqC8Ewc1ms3i6vOwNEkED5/P+fowAaSJ/trrqcxPgy3I5JoA9rO6odh8JkLs8ki52hwgF5PlueOlMOx1A+jdH7pEANkmZar0OW5kHg6AOTFqwZLxqzsGjphkN4NbeHm6vrQ1dMRVSN1CaeuADwsC36mQ0gP9aLWxXKl7wQUZeFlCgCbtXBAEeNkQ0gL2gw+4pSjhaOnqFzchy0Is61OCJuuV5sIK2046PglJkMJ8t8XLFhSQ9UbV24gOYMadx6+pDwuvkIS/Djm3aKniaxsJgOCUR6ckfNrEA1Fc0MQPUVUoAdU3C1SQKhtNL904U1DUJV5MoGE4v3TtRUNckXE2iYDi9dO9EQV2TcDWJguH00r0TBXVNwtVICN4H9C4yBR3gtK1wrYzDm85tDOXcnjftjCbRmAKa9CGHTvfd06fmBLCwCEzQITp7RVFog97KFbE76+/p+BSk2uDn1x8dlFb8bxEsJp/T8T0ivo4GvCNWhgSZztsXvC8mCocvRSrjfJ+plDfGYiqng50NMWEpyGOJMfZGJLizGVNVcOxhRmiQmYRBXfzhHfDrOwHGjJDg8HUL/wG+b8/71IcwsQAAAABJRU5ErkJggg=="
}
