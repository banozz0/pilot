import Testing
@testable import PilotCore

/// First-run onboarding's Permissions (stories 1, 2, 40, 94, 103, 104; card agent-bo-95422091; wireframe zu046xD_ceo;
/// every grant shown, Sven 2026-10-28).
@Suite("Onboarding")
struct OnboardingTests {
    typealias Status = Onboarding.Status

    @Test("A fresh Mac: only the row with nothing to switch off is done, and Continue is locked")
    func fresh() {
        let s = Status()
        #expect(Onboarding.Row.allCases.filter { Onboarding.isDone($0, s) } == [.conflicts])
        #expect(!Onboarding.canContinue(s))
    }

    @Test("Continue unlocks on Accessibility alone; every other row can be left for Settings (card agent-bo-95423043)")
    func continueUnlocks() {
        var s = Status()
        #expect(!Onboarding.canContinue(s))
        s.accessibility = true
        #expect(Onboarding.canContinue(s))
        // Nothing else locks it: System Events, clashes and launch at login.
        s.clashes = 1
        #expect(Onboarding.canContinue(s))
    }

    /// R3 (2026-10-10): Pilot's tiler is the only one, so onboarding offers no other tiler to install or allow.
    @Test("Permissions offers no tiler of its own: no Install row, no second grant; Accessibility alone is needed")
    func noTilerRows() {
        #expect(Onboarding.Row.allCases == [.accessibility, .systemEvents, .fullDiskAccess, .conflicts, .microphone, .screenRecording,
                                            .inputMonitoring, .notifications, .bluetooth, .location, .calendars, .reminders])
        #expect(Onboarding.Row.rows(.required) == [.accessibility])
        #expect(Onboarding.Row.rows(.whenUsed) == [.bluetooth, .location, .calendars, .reminders])
    }

    @Test("The microphone row ticks with its grant, says it is only for Pilot's own dictation, and never locks Continue (story 194)")
    func microphone() {
        var s = Status(accessibility: true)
        #expect(!Onboarding.isDone(.microphone, s) && Onboarding.canContinue(s))
        s.microphone = true
        #expect(Onboarding.isDone(.microphone, s))
        #expect(Onboarding.Row.microphone.detail(s) == "for Pilot's own dictation; skip it if you never dictate")
    }

    @Test("The optional rows say what skipping them costs (card agent-bo-95423043)")
    func skipCosts() {
        #expect(Onboarding.Row.systemEvents.detail(Status()) == "for dark mode, sleep and log out; skipped, each asks the first time")
    }

    @Test("Each later row ticks itself: no clash left, a grant given")
    func laterRows() {
        var s = Status(clashes: 1)
        #expect(!Onboarding.isDone(.conflicts, s) && !Onboarding.isDone(.screenRecording, s))
        s.clashes = 0; s.screenRecording = true
        #expect(Onboarding.isDone(.conflicts, s) && Onboarding.isDone(.screenRecording, s))
        #expect(Onboarding.Row.conflicts.detail(Status(clashes: 2)).hasPrefix("2 macOS shortcuts would fight Pilot's keys"))
    }

    @Test("Full Disk Access comes after System Events, ticks once granted, and never locks Continue (card agent-bo-95422768)")
    func fullDiskAccess() {
        #expect(Onboarding.Row.allCases.prefix(3) == [.accessibility, .systemEvents, .fullDiskAccess])
        #expect(Onboarding.Row.fullDiskAccess.title == "Allow Pilot Full Disk Access")
        #expect(Onboarding.Row.fullDiskAccess.detail(Status()).contains("Desktop, Documents and Downloads"))
        var s = Status(accessibility: true, systemEvents: true)
        #expect(!Onboarding.isDone(.fullDiskAccess, s))
        #expect(Onboarding.canContinue(s))
        s.fullDiskAccess = true
        #expect(Onboarding.isDone(.fullDiskAccess, s))
    }

    @Test("Welcome offers every layer key, Caps Lock first and suggested; Try it starts with nothing ticked")
    func welcomeAndTryIt() {
        #expect(Onboarding.hyperChoices == LayerKey.allCases && Onboarding.hyperChoices.first == .capsLock)
        #expect(Onboarding.hyperDetail(.capsLock).hasPrefix("suggested") && Onboarding.hyperDetail(.leftOption) == LayerKey.leftOption.note)
        let t = Onboarding.TryIt(menuOpens: 0)
        #expect(!t.held && !t.menuOpened)
    }

    @Test("Try it counts only menu opens after it starts: the Install confirm step's panel during Extras never ticks it")
    func tryItBaseline() {
        var t = Onboarding.TryIt(menuOpens: 3)   // three opens already, one of them Install's confirm step
        t.see(menuOpens: 3)
        #expect(!t.menuOpened)
        t.see(menuOpens: 4)
        #expect(t.menuOpened)
    }

    @Test("System Events not running (-600) keeps the row as it was; allowed is 0, refused is -1743")
    func systemEventsAnswer() {
        #expect(Onboarding.systemEvents(answer: 0, last: false))
        #expect(!Onboarding.systemEvents(answer: -1743, last: true))
        #expect(Onboarding.systemEvents(answer: -600, last: true))
        #expect(!Onboarding.systemEvents(answer: -600, last: false))
    }
}
