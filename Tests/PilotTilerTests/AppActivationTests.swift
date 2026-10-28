// Spec scrolling-layout T7: the focus hand-off brings the app forward way by way, confirming the app is in front after
// each before it stops, and a newer press stops it.
import Foundation
@testable import PilotTiler
import Testing

@MainActor
@Suite struct AppActivationTests {
    /// A hand-off on a fake macOS: `allowed` are the ways it allows, `frontAfter` how many polls after an allowed way the
    /// app shows in front (none: never), `newerPressAt` the poll at which a newer press arrives, `newerPressDuring` the
    /// way during whose call it arrives.
    private func handOff(allowed: Set<AppActivation>, frontAfter: [AppActivation: Int] = [:], frontAtStart: Bool = false,
                         newerPressAt poll: Int? = nil, newerPressDuring during: AppActivation? = nil)
        async -> (tried: [AppActivation], outcome: AppActivation.Outcome)
    {
        var tried: [AppActivation] = [], polls = 0, frontAt: Int?, current = true
        let outcome = await AppActivation.bringForward(
            isCurrent: { current },
            isFront: { frontAtStart || frontAt.map { polls >= $0 } == true },
            pause: {
                polls += 1
                if polls == poll { current = false }
            },
        ) { way in
            tried.append(way)
            if way == during { current = false }
            if allowed.contains(way), let after = frontAfter[way] { frontAt = polls + after }
            return allowed.contains(way)
        }
        return (tried, outcome)
    }

    /// Build 44: macOS refused plain activation of another app; SkyLight goes first and the public ways follow, in order.
    @Test func theOrderIsSkyLightThenThePublicWays() async {
        #expect(AppActivation.order == [.skyLight, .fromFront, .axFrontmost, .plain])
        let (tried, outcome) = await handOff(allowed: [])
        #expect(tried == AppActivation.order && outcome.landed == nil && !outcome.superseded)
        #expect(outcome.steps.allSatisfy { !$0.allowed && !$0.front }, "a refused way is not waited on")
    }

    /// Allowed is not front: an allowed way the app never comes forward from is waited out, then the next is tried.
    @Test func anAllowedWayIsConfirmedInFrontBeforeItStops() async {
        let (tried, outcome) = await handOff(allowed: [.skyLight, .fromFront, .axFrontmost], frontAfter: [.axFrontmost: 3])
        #expect(tried == [.skyLight, .fromFront, .axFrontmost])
        #expect(outcome.steps == [.init(way: .skyLight, allowed: true, front: false), .init(way: .fromFront, allowed: true, front: false),
                                  .init(way: .axFrontmost, allowed: true, front: true)])
        #expect(outcome.landed == .axFrontmost)
    }

    @Test func theFirstWayThatPutsItInFrontEndsIt() async {
        let (tried, outcome) = await handOff(allowed: Set(AppActivation.order), frontAfter: [.skyLight: 1])
        #expect(tried == [.skyLight] && outcome.landed == .skyLight)
    }

    /// The same app already in front (a window of the app Sven is in): nothing is tried.
    @Test func anAppAlreadyInFrontNeedsNoWay() async {
        let (tried, outcome) = await handOff(allowed: Set(AppActivation.order), frontAtStart: true)
        #expect(tried.isEmpty && outcome.steps.isEmpty && outcome.line == "already front")
    }

    /// Several presses a second (the 21:52 log): a newer press stops the older hand-off mid-wait, and it tries no more ways,
    /// so it never brings forward an app Sven has already moved past.
    @Test func aNewerPressStopsTheHandOff() async {
        let (tried, outcome) = await handOff(allowed: Set(AppActivation.order), newerPressAt: 2)
        #expect(tried == [.skyLight] && outcome.superseded && outcome.landed == nil)
        #expect(outcome.line == "superseded by a newer focus or another app in front")
    }

    /// Moody v2: a newer press (or Cmd-Tab to another app) while a way's call is under way stops it right after the call,
    /// before the app it brought forward counts as front and before any further way.
    @Test(arguments: [true, false]) func aNewerPressDuringAWayStopsItThere(allowed: Bool) async {
        let (tried, outcome) = await handOff(allowed: allowed ? [.skyLight, .fromFront] : [], frontAfter: [.skyLight: 0],
                                             newerPressDuring: .skyLight)
        #expect(tried == [.skyLight] && outcome.superseded && outcome.steps.isEmpty && outcome.landed == nil)
    }

    /// The hand-off log names each way with allowed or refused, front or not, then how it ended.
    @Test func theLogNamesEachStep() async {
        let (_, landed) = await handOff(allowed: [.fromFront, .axFrontmost], frontAfter: [.axFrontmost: 0])
        #expect(landed.line == "SkyLight refused; from the front app allowed, not front; AX frontmost allowed, front; front by AX frontmost")
        let (_, refused) = await handOff(allowed: [])
        #expect(refused.line == "SkyLight refused; from the front app refused; AX frontmost refused; plain refused; not front after every way")
    }
}
