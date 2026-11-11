import Testing
@testable import PilotCore

@Suite("Remap conflicts")
struct RemapConflictTests {
    private let capsToF18 = KeyMappingEntry(src: 0x7_0000_0039, dst: 0x7_0000_006D)

    @Test("Pilot's own Caps Lock to F18 entry is no conflict")
    func ownEntry() {
        #expect(!RemapConflict.exists(layerKeys: [.capsLock], userKeyMapping: [capsToF18], own: [capsToF18]))
    }

    @Test("A mapping Pilot did not write on the chosen key is a conflict; one on another key is not")
    func foreignEntry() {
        let capsToEscape = KeyMappingEntry(src: 0x7_0000_0039, dst: 0x7_0000_0029)
        #expect(RemapConflict.exists(layerKeys: [.capsLock], userKeyMapping: [capsToEscape], own: [capsToF18]))
        let rightOptToF19 = KeyMappingEntry(src: 0x7_0000_00E6, dst: 0x7_0000_006E)
        #expect(RemapConflict.exists(layerKeys: [.rightOption], userKeyMapping: [rightOptToF19], own: [capsToF18]))
        #expect(!RemapConflict.exists(layerKeys: [.rightCommand], userKeyMapping: [rightOptToF19], own: [capsToF18]))
    }

    @Test("Pilot's set is F18 while Caps Lock is a layer key plus both entries of each swap; removing a swap keeps the rest and foreign entries (Q406)")
    func swapSet() {
        let capsCtrl = KeySwap(.capsLock, .leftControl), escTab = KeySwap(.escape, .tab)
        #expect(capsCtrl.entries == [KeyMappingEntry(src: 0x7_0000_0039, dst: 0x7_0000_00E0), KeyMappingEntry(src: 0x7_0000_00E0, dst: 0x7_0000_0039)])
        #expect(SwapKey.f1.hidUsage == 0x7_0000_003A && SwapKey.f12.hidUsage == 0x7_0000_0045 && SwapKey.f13.hidUsage == 0x7_0000_0068
                && SwapKey.f20.hidUsage == 0x7_0000_006F && !SwapKey.allCases.contains { $0.hidUsage == LayerKey.f18Usage })
        let both = KeyMappingEntry.pilotSet(layerKeys: [.rightCommand], swaps: [capsCtrl, escTab], foreign: [])
        #expect(both == capsCtrl.entries + escTab.entries)
        #expect(KeyMappingEntry.pilotSet(layerKeys: [.capsLock], swaps: [escTab], foreign: []) == [capsToF18] + escTab.entries)
        let foreign = KeyMappingEntry(src: 0x7_0000_00E4, dst: 0x7_0000_0029)
        let written = KeyMappingEntry.merged([foreign], own: [capsToF18], next: [capsToF18] + both)
        #expect(written == [foreign, capsToF18] + both)
        // Caps Lock ↔ Left Control removed: Pilot owns what it wrote and the swap left.
        let own = KeyMappingEntry.pilotOwned(written: [capsToF18] + both, swaps: [escTab])
        #expect(own == Set(written).subtracting([foreign]))
        #expect(KeyMappingEntry.merged(written, own: own, next: [capsToF18] + escTab.entries) == [foreign, capsToF18] + escTab.entries)
        #expect(KeyMappingEntry.merged(written, own: own, next: []) == [foreign])
        // Pilot's own swap on a key is no conflict when that key becomes Hyper.
        #expect(!RemapConflict.exists(layerKeys: [.capsLock], userKeyMapping: written, own: own))
    }

    @Test("A swap on a Hyper key is refused and waits, saying why; a key swapped already or another tool's is refused too (Q407)")
    func swapRefusals() {
        let capsCtrl = KeySwap(.capsLock, .leftControl)
        #expect(capsCtrl.refusal(joining: [], layerKeys: [.capsLock], foreign: [])
                == "Caps Lock is your Hyper key. Pick another Hyper key on the Pilot page first.")
        #expect(KeySwap(.escape, .rightOption).hyperProblem([.capsLock, .rightOption]) == "Right Option is a Hyper key. Pick another Hyper key on the Pilot page first.")
        #expect(KeyMappingEntry.pilotSet(layerKeys: [.capsLock], swaps: [capsCtrl], foreign: []) == [capsToF18])
        #expect(KeySwap(.escape, .leftControl).refusal(joining: [capsCtrl], layerKeys: [.rightCommand], foreign: []) == "Left Control is already swapped.")
        let escToTab = KeyMappingEntry(src: 0x7_0000_0029, dst: 0x7_0000_002B)
        #expect(KeySwap(.escape, .delete).refusal(joining: [], layerKeys: [.capsLock], foreign: [escToTab])?.hasPrefix("Another tool remaps Escape") == true)
        #expect(KeySwap(.escape, .escape).refusal(joining: [], layerKeys: [.capsLock], foreign: []) == "Pick two different keys.")
        #expect(KeySwap(.tab, .f19).refusal(joining: [capsCtrl], layerKeys: [.capsLock], foreign: [escToTab]) == nil)
        #expect(KeySwap.parse(["capsLock:leftControl", "return:f5", "capsLock:capsLock", "nope"]) == [capsCtrl, KeySwap(.returnKey, .f5)])
    }

    @Test("hidutil's per-service output parses to its distinct entries")
    func parseHidutil() {
        let out = """
        RegistryID  Key                   Value
        100000858   UserKeyMapping   (
                {
                HIDKeyboardModifierMappingDst = 30064771181;
                HIDKeyboardModifierMappingSrc = 30064771129;
            },
                {
                HIDKeyboardModifierMappingDst = 30064771113;
                HIDKeyboardModifierMappingSrc = 30064771300;
            }
        )
        10000082d   UserKeyMapping   (
                {
                HIDKeyboardModifierMappingDst = 30064771181;
                HIDKeyboardModifierMappingSrc = 30064771129;
            }
        )
        1000005e1   UserKeyMapping   (null)
        """
        #expect(KeyMappingEntry.parse(hidutil: out) == [capsToF18, KeyMappingEntry(src: 0x7_0000_00E4, dst: 0x7_0000_0029)])
        #expect(KeyMappingEntry.parse(hidutil: "1000005e1   UserKeyMapping   (null)") == [])
    }
}
