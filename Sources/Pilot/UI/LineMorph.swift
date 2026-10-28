import AppKit
import SwiftUI

/// Line's morph (menu-morph T2; Sven Q149, Q165): Classic's root, 431 wide, grows into the 750 search on the first typed
/// character, and back when the query empties or Escape leaves a branch for the root. One object throughout: the search
/// field is never rebuilt, so a key always lands in it at once; only the plate's frame and two lists' opacities move.
///
/// The timeline (the round-2 page, ~/pages/pilot-menu-morph.html), from the key's own runloop turn:
///   plate   200 ms on cubic-bezier(0.2, 0, 0, 1), its top edge and centre fixed; back 160 ms
///   root    Classic's list fades out over 60 ms, pinned to the plate's left edge
///   results the 750 list, laid out at its final width from the start and clipped by the plate, fades in from 30 ms over
///           130 ms and rises 6 pt
/// Reduce Motion: the plate takes its new size at once; the root fades out over 60 ms, then the results in over 60.
/// The window holds the plate's size at rest; for the morph only it holds the union of both sizes so the plate can grow
/// inside it, and takes the new size once the plate has settled (MenuSizer), so no click outside the plate is
/// ever swallowed by a clear margin except in those 200 ms.
enum LineMorph {
    static let grow = 0.2, back = 0.16, reduceFade = 0.12
    /// How long after a morph starts the window takes the plate's size: the morph's length and one frame.
    static func settle(back: Bool) -> TimeInterval { (back ? Self.back : grow) + 0.02 }

    /// The plate's frame animation for a morph to the root (`back`) or away from it.
    static func plate(back: Bool, reduce: Bool) -> Animation? {
        reduce ? nil : .timingCurve(0.2, 0, 0, 1, duration: back ? Self.back : grow)
    }

    /// Classic's root list: out over 60 ms; in, on the way back, from 40 ms over 100.
    static func root(reduce: Bool) -> AnyTransition {
        .asymmetric(insertion: .opacity.animation(.easeOut(duration: reduce ? reduceFade / 2 : 0.1).delay(reduce ? reduceFade / 2 : 0.04)),
                    removal: .opacity.animation(.easeOut(duration: reduce ? reduceFade / 2 : 0.06)))
    }

    /// The 750 list: in from 30 ms over 130, rising 6 pt (Reduce Motion: opacity alone, after the root has gone); out over 50.
    static func results(reduce: Bool) -> AnyTransition {
        let rise: AnyTransition = reduce ? .opacity : .opacity.combined(with: .offset(y: 6))
        return .asymmetric(insertion: rise.animation(reduce ? .easeOut(duration: reduceFade / 2).delay(reduceFade / 2)
                                                            : .timingCurve(0.2, 0, 0, 1, duration: 0.13).delay(0.03)),
                           removal: .opacity.animation(.easeOut(duration: reduce ? reduceFade / 2 : 0.05)))
    }

    /// The window's size for the face going to `new` from the window's `held` size: the new size at once, unless a morph
    /// runs or an earlier one still settles (and Reduce Motion is off), when the window holds the union of both and
    /// `settle` is the size to take when the face has settled.
    static func window(holding held: CGSize, to new: CGSize, morph: Bool, settling: Bool, reduce: Bool) -> (now: CGSize, settle: CGSize?) {
        guard !reduce, morph || settling, held != new || settling else { return (new, nil) }
        return (CGSize(width: max(held.width, new.width), height: max(held.height, new.height)), new)
    }
}
