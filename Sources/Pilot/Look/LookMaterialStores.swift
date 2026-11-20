import Foundation
import PilotCore

/// Look's Material (LookMaterial, W77) on the stores it reads and sets: the top bar's Background, the dock's style and
/// Look's Glass and Blur. The Look page and `pilot get|set look.material` go through it; a render passes its own stores.
@MainActor
struct LookMaterialStores {
    let look: Look
    let bar: BarItemsStore
    /// Nil before the engine is up (a render): the dock reads its standard style and a pick leaves it.
    let dock: DockController?

    /// `look`'s Material on the shared bar and the engine's dock.
    static func of(_ look: Look) -> LookMaterialStores { .init(look: look, bar: .shared, dock: Engine.shared?.dock) }

    /// The stored switches, never what is drawn now: Reduce transparency or Transparency 0 % draw Glass solid
    /// without making the material read Custom.
    var surfaces: LookMaterial.Surfaces {
        .init(bar: bar.background, dock: dock?.settings.style ?? DockSettings().style, glass: look.glass, blur: look.glassBlur)
    }

    var material: LookMaterial { LookMaterial(surfaces) }

    /// Sets every surface to `material`; Custom refuses, as it is only read. A bar that cannot save refuses before any
    /// surface changes.
    func pick(_ material: LookMaterial) throws(ControlError) {
        guard let surfaces = material.surfaces else {
            throw ControlError(.badValue, "custom is read only: the material reads custom once a surface was changed on its own; pick glass, solid or clear")
        }
        try bar.requireWritable()
        // Only what differs, so a pick redraws no bar or window that already wore it.
        if bar.background != surfaces.bar { bar.background = surfaces.bar }
        if let dock, dock.settings.style != surfaces.dock { dock.settings.style = surfaces.dock }
        if look.glass != surfaces.glass { look.glass = surfaces.glass }
        if let blur = surfaces.blur, look.glassBlur != blur { look.glassBlur = blur }
    }
}
