# pilot — agent brief

Written to be public: banozz0/pilot carries this file, so nothing private goes in it. Pilot makes a Mac feel like Omarchy: one native Swift/AppKit menu-bar app (macOS 27+; SwiftPM targets 26, so binaries record the 26 SDK) owning the Hyper key, every bind,
tiling and workspaces (`Sources/PilotTiler`, from AeroSpace, MIT; ADRs 0007, 0011), the Hyper+Space launcher menu, web apps, clipboard, Quick AI
and extensions. Sven's daily driver first, a milestone per app he can uninstall (Karabiner, Hammerspoon, yabai+skhd, Vicinae, ClipBook).
The build contract and build order is SPEC.md and the decisions are numbered ADRs, both kept in Sven's vault (`Projects/Pilot/Pilot spec.md`, `Projects/Pilot/ADRs/`); code comments cite them. `GLOSSARY.md` is the glossary.

Sven's own agents: the rest of this brief (his Mac, his vault, threads and slots) is the vault note `Projects/Pilot/Pilot agent brief.md`. Read it before any work.

## Commands
- `swift build` and `swift test`, at most 4 jobs (`-j 4`). Opt-in tests are env-gated: `PILOT_LIVE=1`, `PILOT_FOCUS=1` (the `.pilotFocus`
  tests take the keyboard or show a window), and renders with `CFFIXED_USER_HOME=<tmp> PILOT_RENDER_DIR=<tmp> swift test --filter <X>Renders`.
- No new unit, component or UI tests unless Sven asks (2026-10-17; `tdd` is off here); existing ones stay.
  The one exception: the designer may add env-gated offscreen `<X>Renders` tests (Sven, 2026-10-17, Q67).
  Prove behaviour end to end through the `pilot` command against a sandbox, output quoted. Acting verbs (`run`, keys, system, wallpaper,
  install, `files`, `model`, `permit`, `ai ask`, `theme apply`, `wifi`/`bluetooth` switching) act on the Mac they run on, and `set` asks Allow on screen.
- Once before landing, after the full `swift test`: `Scripts/lean-check.py` (size; `idle` reads Pilot and may only lower a budget (the ratchet), `launch`/`all` relaunch Pilot).
- `Scripts/build-app.sh` (release, signed, checks the size budget; a release needs `SPARKLE_ED_KEY` or `PILOT_DEV=1`, which `run.sh` sets; `CONFIG=debug` for debug) once per change, before land, never per edit; `Scripts/run.sh`
  builds, relaunches and streams the log. Rust file helper: `cargo test --manifest-path Helpers/pilot-files/Cargo.toml`.

## Shape and rules
- A HID-level CGEventTap makes the layer key (Caps Lock via F18, or one side of Control, Option or Command) Hyper and runs every bind in-process (ADR 0001).
  Binds: `~/Library/Application Support/Pilot/binds.json`, schema 1 (`BindStore.version`); Cockpit reads it. `Helpers/pilot-files` is the file
  index (Cardinal's MIT engine, vendored, licence kept); `pilot-text` reads clipboard image text (Vision) in a child. Register each action in its module: id, label, default key, tier.
- A tap that switches itself off (the selection pill's, `QuickAI/SelectionTools.swift`) re-enables only on `.tapDisabledByTimeout`: its own `tapEnable(false)` delivers `.tapDisabledByUserInput`, and re-disabling there spins the main thread (build 59, 55% CPU).
  After a build that arms a new tap, sample idle CPU with that setting on: `/usr/bin/top -l 4 -s 3 -pid <pid> -stats pid,cpu`.
- The tap owns the binds. Reach another app through its CLI, URL scheme or menu item; never post key events to fire its hotkey (ADR 0001).
- Permissions: Accessibility is the one onboarding waits for; its Access screen names every other grant for later and reads none
  (pilot-1.1 T54); Try it's Allow the rest (GrantWalk) asks them one at a time on its press, each read only once its step comes (T58). Screen Recording's state is read only at a capture press, while Show exact menu bar items is on, while
  Window pictures is Stills (the default) or Live, at Allow the rest's Screen Recording ask and while that step waits after it, or for `pilot status --part onboarding` (ADR 0012); no capture API
  runs before a press but Stills' and Live's. Password fields are blind to the tap: show it, never work around it.
- System Events is the one automation target; run AppleScript in a child `osascript`, never `NSAppleScript` on the main thread (it stalls the tap).
- Tiling is Pilot's tiler alone; `~/.aerospace.toml` is an import, never written. Clipboard: no ClipBook or Vicinae code; Maccy (MIT) is the reference.
- Prove a bind or setting without hands with the `pilot` command first (`pilot help`, `get`, `list`, `actions`; ADR 0013); `pilot://` links
  stay for presses (press, open, alert, …), documented on `application(_:open:)` in `Sources/Pilot/PilotApp.swift`; pages are `AppPage`. Presses,
  command routes and `pilot run` act on the front app: links carry `&token=$(cat ~/Library/Application\ Support/Pilot/link-token)` and always `app=`, `pilot run` always `--app`, or the key lands in the front window. Log: `/usr/bin/log stream --predicate 'subsystem == "dev.banozz.pilot"'`.
- Stay lean inside `Scripts/lean-budgets.json` (story 142); a budget rises only on Sven's yes. Pilot runs with `MallocSpaceEfficient=1` from Info.plist's `LSEnvironment`: only a LaunchServices launch (`open`, login item) gets it.
- `site/` is generated from Sven's vault: never edit it by hand.

## Extensions
ADR 0010 (extensions speak JSON lines, Pilot draws) is the contract, with every amendment; manifest rules are `Sources/PilotCore/Extension.swift`.
A catalogue extension is one self-contained folder. Its programs are Python 3 stdlib only, `#!/usr/bin/env python3`, executable, and run on
macOS's own `/usr/bin/python3` (3.9); they print only protocol lines on stdout and never log item titles, clipboard text or secrets.
Licence: ideas only, never code, from Raycast, Vicinae, ClipBook or Alfred extensions.

## Where things are

The file map (every file with its own first line) is kept in Sven's vault, not in README.md, because this repo is public; Sven's `file-map` tool rewrites it after files are added, moved or renamed.
