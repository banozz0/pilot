# Pilot

Pilot makes a Mac feel like [Omarchy](https://omarchy.org): one native menu-bar app that turns a key you rarely use
(Caps Lock, or one side of Control, Option or Command) into a Hyper key and runs every bind from it. It tiles windows
into workspaces, opens a Hyper+Space launcher menu, keeps a clipboard history, stamps sites into web apps, answers
quick AI questions and runs extensions, all from the keyboard. One app instead of Karabiner, Hammerspoon, yabai and skhd,
a launcher and a clipboard manager.

- macOS 27 or later, Apple silicon.
- Swift and AppKit; the tiler is ported from [AeroSpace](https://github.com/nikitabobko/AeroSpace), the terminal in bar
  drops is [Ghostty](https://ghostty.org)'s libghostty.

## Install

You need macOS 27 or later on a Mac with Apple silicon.

1. Download `Pilot.dmg` from this repository's Releases page, open it and drag Pilot to Applications.
2. Open Pilot. macOS says Apple could not verify it, because Pilot is open source and not notarized. Click Done.
3. Within the hour, open System Settings › Privacy & Security. Scroll to Security, click Open Anyway beside Pilot, then
   enter your login password.
4. Pilot opens its setup. Pick your layer key (Caps Lock is suggested: tapped alone it is Escape, and Shift+Caps Lock
   still types capitals), then grant what it asks for:
   - Accessibility. Pilot needs it to see your keys and move windows; nothing works without it.
   - Full Disk Access if you want file search in the menu, and System Events for sleep, restart and dark mode.
   - The microphone for dictation and an AI provider for Quick AI, both optional.
   - Input Monitoring only if Pilot asks, when you bind a mouse's media buttons.
   - Screen Recording when you first take a screenshot or recording with Pilot, or turn on Menu bar › Other apps ›
     Show exact menu bar items. macOS applies it after Pilot reopens: click Quit & Reopen.
5. Updates install from inside Pilot. You won't see this warning again, and your permissions stay: every update is
   signed with the same certificate, so macOS knows it is the same app.

From Terminal instead of steps 2–3: `xattr -dr com.apple.quarantine /Applications/Pilot.app`. Check the download
against the `.sha256` beside it on the Releases page: `shasum -a 256 -c Pilot.dmg.sha256`.

Hyper+Space opens the menu; its Learn › Keybindings lists every bind, and the Binds page in Pilot's window changes any
of them. Password fields are blind to every key tap on macOS, Pilot's included: your binds do not work while one has
focus.

## Build from source

You need Xcode 27 with its Metal toolchain (`xcodebuild -downloadComponent MetalToolchain`),
[Zig](https://ziglang.org/download/) at the version Ghostty's tag pins (0.15.2 for v1.3.1), stable
[Rust](https://rustup.rs) and Python 3.

```sh
# 1. libghostty, from Ghostty's own source: about 10 minutes the first time, seconds after that.
ZIG=/path/to/zig Scripts/build-ghosttykit.sh
# 2. The file index helper (Rust), and its tests if you like.
cargo build --release --manifest-path Helpers/pilot-files/Cargo.toml
# 3. The app bundle, into build/Pilot.app (PILOT_DEV=1: a build of your own, with no updates).
PILOT_DEV=1 SIGN_ID="<your code-signing identity>" Scripts/build-app.sh
open build/Pilot.app
```

`build-ghosttykit.sh` finds Zig through `ZIG`, then `zig@0.15` from Homebrew. `build-app.sh` runs the first two steps
itself too (seconds once they are built), then builds the Swift targets, the dictation helper and the bundle, and fails
a release bundle over the size budget in `Scripts/lean-budgets.json`. A release needs `SPARKLE_ED_KEY`, the public key its
updates are signed with, or `PILOT_DEV=1` for a build without updates. `swift build` and `swift test` work on their
own once libghostty is built.

### Signing and permissions

`build-app.sh` signs with `SIGN_ID`, by default the `Pilot Release` certificate releases are signed with, and stops
when that identity is not in your keychain. Name your own (a self-signed Code Signing certificate from Keychain Access ›
Certificate Assistant, or an Apple Development identity), or sign ad hoc with `SIGN_ID=-`.

macOS ties Accessibility and Full Disk Access to the app's signature. With a real identity the grants survive every
rebuild. An ad-hoc signature is new on every build, so macOS treats each build as a different app: after a rebuild,
Pilot's keys stop working until you remove Pilot from System Settings › Privacy & Security › Accessibility (and Full
Disk Access) and allow it again. Use an identity if you rebuild often.

## The pilot command

General's pilot command row links `pilot` into `~/.local/bin`. `pilot help` lists what it reads and changes: binds,
settings, actions and the app's state, from a terminal or a script.

## Contributing and licence

See [CONTRIBUTING.md](CONTRIBUTING.md). Pilot is under the MIT licence ([LICENSE](LICENSE)); third-party code, assets
and trademarks are listed in [NOTICE](NOTICE).

## Files

<!-- file-map:start depth=3 fold=tests,fixtures — generated by agents automation/bin/file-map; edit only a folder's # comment -->
```text
pilot/
├── .github/                                 # 3 files
│   └── ISSUE_TEMPLATE/                      # 3 files
│       ├── bug.yml
│       ├── config.yml                       # Pilot's Send feedback opens issues/new?template=bug.yml or idea.yml with the title and th…
│       └── idea.yml
├── Helpers/                                 # bundled helpers built outside SwiftPM's main graph
│   ├── pilot-dictate/                       # dictation (WhisperKit, FluidAudio)
│   │   ├── Sources/                         # 3 files
│   │   ├── Tests/                           # 2 files
│   │   ├── FluidAudio-LICENSE.txt
│   │   ├── Package.resolved
│   │   ├── Package.swift                    # swift-tools-version:6.2
│   │   └── WhisperKit-LICENSE.txt
│   ├── pilot-files/                         # Rust file index (Cardinal's engine, vendored)
│   │   ├── src/                             # 6 files
│   │   ├── tests/                           # 1 file
│   │   ├── vendor/                          # 100 files
│   │   ├── Cargo.lock                       # This file is automatically @generated by Cargo.
│   │   └── Cargo.toml                       # pilot-files: the menu's file index (card agent-bo-95422765), a helper Pilot.app runs from…
│   └── pilot-media/                         # pauses and resumes playing media while Pilot dictates
│       ├── pilot-media.m                    # pilot-media: pauses and resumes what is playing while Pilot dictates (Dictation › Pause m…
│       └── pilot-media.pl                   # pilot-media.pl <pilot-media.dylib> pause|play: runs pilot-media.m's function of that name…
├── Packaging/                               # Info.plist, licences and bundled resources
│   ├── AppIcon.icon/                        # the app icon, an Icon Composer document; build-app.sh compiles it with actool
│   │   ├── Assets/                          # 4 files
│   │   └── icon.json
│   ├── catalogue-icons/                     # 73 files
│   │   ├── 1password.png
│   │   ├── antigravity-cli.png
│   │   ├── appcleaner.png
│   │   ├── bitwarden.png
│   │   ├── brave-origin.png
│   │   ├── brave.png
│   │   ├── btop.png
│   │   ├── bun.png
│   │   ├── chatgpt.png
│   │   ├── claude-code.png
│   │   ├── claude.png
│   │   ├── clojure.png
│   │   ├── codex.png
│   │   ├── composer.png
│   │   ├── coteditor.png
│   │   ├── cursor.png
│   │   ├── deno.png
│   │   ├── dotnet-sdk.png
│   │   ├── dropbox.png
│   │   ├── elixir.png
│   │   ├── emacs.png
│   │   ├── empryo.png
│   │   ├── firefox.png
│   │   ├── geforce-now.png
│   │   ├── gh.png
│   │   ├── ghostex.png
│   │   ├── ghostty.png
│   │   ├── go.png
│   │   ├── google-chrome.png
│   │   ├── helix.png
│   │   ├── herdr.png
│   │   ├── hermes-context.png
│   │   ├── hermes-desktop.png
│   │   ├── heroic.png
│   │   ├── iina.png
│   │   ├── keka.png
│   │   ├── kitty.png
│   │   ├── lm-studio.png
│   │   ├── localsend.png
│   │   ├── macvim.png
│   │   ├── microsoft-edge.png
│   │   ├── microsoft-office.png
│   │   ├── minecraft.png
│   │   ├── neovim.png
│   │   ├── node.png
│   │   ├── nordvpn.png
│   │   ├── obsidian.png
│   │   ├── ollama.png
│   │   ├── opam.png
│   │   ├── openclaw.png
│   │   ├── opencode.png
│   │   ├── orbstack.png
│   │   ├── orca.png
│   │   ├── perplexity.png
│   │   ├── php.png
│   │   ├── retroarch.png
│   │   ├── ruby.png
│   │   ├── rustup.png
│   │   ├── scala.png
│   │   ├── signal.png
│   │   ├── spotify.png
│   │   ├── steam.png
│   │   ├── sublime-text.png
│   │   ├── symfony-cli.png
│   │   ├── t3-code.png
│   │   ├── tailscale.png
│   │   ├── temurin.png
│   │   ├── uv.png
│   │   ├── videorc.png
│   │   ├── visual-studio-code.png
│   │   ├── zed.png
│   │   ├── zen.png
│   │   └── zig.png
│   ├── dmg/                                 # the DMG window: layout.json (size, icon centres), its background at 1x and @2x and the sc…
│   │   ├── background.png
│   │   ├── background@2x.png
│   │   ├── draw-background.swift            # Draws the DMG window's background (SH24, Sven's pick A: the Hyper keycap is the arrow) fr…
│   │   └── layout.json
│   ├── ext-template/                        # extension starter templates (list, detail, bar)
│   │   ├── bar/                             # 2 files
│   │   ├── detail/                          # 2 files
│   │   ├── list/                            # 2 files
│   │   └── no-view/                         # 2 files
│   ├── folder-designs/                      # 39 files
│   │   ├── archive-small.png
│   │   ├── archive.heic
│   │   ├── archive.png
│   │   ├── blueprint-small.png
│   │   ├── blueprint.heic
│   │   ├── blueprint.png
│   │   ├── candy-small.png
│   │   ├── candy.heic
│   │   ├── candy.png
│   │   ├── code-small.png
│   │   ├── code.heic
│   │   ├── code.png
│   │   ├── graphite-small.png
│   │   ├── graphite.heic
│   │   ├── graphite.png
│   │   ├── kraft-small.png
│   │   ├── kraft.heic
│   │   ├── kraft.png
│   │   ├── lagoon-small.png
│   │   ├── lagoon.heic
│   │   ├── lagoon.png
│   │   ├── mint-small.png
│   │   ├── mint.heic
│   │   ├── mint.png
│   │   ├── music-small.png
│   │   ├── music.heic
│   │   ├── music.png
│   │   ├── paper-small.png
│   │   ├── paper.heic
│   │   ├── paper.png
│   │   ├── plain-small.png
│   │   ├── plain.heic
│   │   ├── plain.png
│   │   ├── sunset-small.png
│   │   ├── sunset.heic
│   │   ├── sunset.png
│   │   ├── terminal-small.png
│   │   ├── terminal.heic
│   │   └── terminal.png
│   ├── Fonts/                               # bundled fonts and the upscaler model
│   │   ├── BricolageGrotesque/              # 2 files
│   │   ├── Fraunces/                        # 2 files
│   │   ├── Fredoka/                         # 2 files
│   │   ├── Geist/                           # 2 files
│   │   ├── GeistMono/                       # 2 files
│   │   ├── InstrumentSerif/                 # 2 files
│   │   ├── JetBrainsMono/                   # 2 files
│   │   ├── Nunito/                          # 2 files
│   │   ├── Recursive/                       # 2 files
│   │   ├── Syne/                            # 2 files
│   │   ├── Unbounded/                       # 2 files
│   │   └── YoungSerif/                      # 2 files
│   ├── skills/                              # the AI's skills, one SKILL.md each: binds, layouts, settings, catalogue, /extension…
│   │   ├── binds/                           # Looks at the apps you open most and suggests free Hyper keys for them; binds mouse button…
│   │   ├── catalogue/                       # Finds an extension in Pilot's catalogue, then installs or runs it
│   │   ├── explain/                         # Tells you what a key runs, and whether macOS uses it too
│   │   ├── extension/                       # Writes, tests and installs a new Hyper+Space command from your idea
│   │   ├── layouts/                         # Builds a workspace that opens your apps side by side, laid out how you like
│   │   ├── preset/                          # Makes a new key preset on Pilot default from what you ask for: smaller, or built around k…
│   │   ├── publish/                         # Sends an extension you made to Pilot's catalogue as a pull request, for its owner to revi…
│   │   ├── settings/                        # Finds a setting by what it does and changes it, old value to new
│   │   └── troubleshoot/                    # Checks Pilot's status and tells you the cause and the fix
│   ├── Upscale/                             # bundled fonts and the upscaler model
│   │   └── realesr-general-x4v3.mlpackage/  # 3 files
│   ├── webapp-icons/                        # 15 files
│   │   ├── chatgpt.png
│   │   ├── claude.png
│   │   ├── discord.png
│   │   ├── figma.png
│   │   ├── github.png
│   │   ├── gmail.png
│   │   ├── google-calendar.png
│   │   ├── google-drive.png
│   │   ├── linear.png
│   │   ├── notion.png
│   │   ├── slack.png
│   │   ├── spotify.png
│   │   ├── whatsapp.png
│   │   ├── x.png
│   │   └── youtube.png
│   ├── AeroSpace-LICENSE.txt
│   ├── CodexBar-LICENSE.txt
│   ├── drive-catalogue.json
│   ├── emoji.json
│   ├── FluidAudio-NOTICES.txt
│   ├── gemoji-LICENSE.txt
│   ├── Ghostty-THIRD-PARTY.txt
│   ├── Info.plist
│   ├── install-catalogue.json
│   ├── Kokoro-LICENSE.txt
│   ├── Omarchy-LICENSE.txt
│   ├── Parakeet-LICENSE.txt
│   ├── pilot-agent-shell                    # Pilot's gate on every shell command its AI agents run (spec pilot-ai-helper T17, ADR 0013…
│   ├── pilot-agent.md
│   ├── Real-ESRGAN-LICENSE.txt
│   ├── RealESRGAN-CoreML-LICENSE.txt
│   ├── Snapzy-LICENSE.txt
│   ├── Sparkle-LICENSE.txt
│   ├── themes.json
│   ├── Whisper-LICENSE.txt
│   └── WhisperKit-NOTICES.txt
├── Scripts/                                 # build-app.sh, release.sh (the DMG; dmg-settings.py lays out its window with dmgbuild), ru…
│   ├── build-app.sh                         # Builds Pilot.app into build/ and signs it. TCC trusts a signed bundle, never a bare binar…
│   ├── build-ghosttykit.sh                  # Bar drops T11: libghostty from Ghostty's own source at Sven's tag, Sentry and libintl off…
│   ├── catalogue-icons.swift                # Install's catalogue pictures (C5, Sven 2026-10-09: "every catalogue app shows a real icon…
│   ├── chat-frames.swift                    # The scroll stitch's chat frames (SH9): Tests/PilotCoreTests/ScrollFrames/chat-0040, -0051…
│   ├── convert-upscaler.py                  # Converts Real-ESRGAN's realesr-general-x4v3 (SRVGGNetCompact, BSD-3, xinntao) to the Core…
│   ├── dmg-settings.py                      # dmgbuild's settings for Pilot's DMG (SH25), read by Scripts/release.sh:
│   ├── emoji-json.py                        # Packaging/emoji.json from github/gemoji's db/emoji.json (MIT, its notice in Packaging/gem…
│   ├── folder-designs.py                    # Draws Pilot's folder designs (P54) into Packaging/folder-designs: <id>.heic, the 1024 px…
│   ├── lean-budgets.json
│   ├── lean-check.py                        # Pilot's lean budgets (SPEC story 142): fails when the app's size, idle RAM, idle CPU or l…
│   ├── publish-tree.sh                      # The public tree (SH9; Sven, Q321: a new public repo, one commit, from the code of the day…
│   ├── release.sh                           # A release a stranger downloads (SH4, notes §9): the signed release build in a DMG, the DM…
│   ├── run.sh                               # Builds and (re)launches Pilot.app, streaming its log. Ctrl+C stops the stream, not the ap…
│   ├── rust-licenses.py                     # Rust-crates-LICENSES.txt: every crates.io crate linked into pilot-files, the file index,…
│   └── webapp-icons.swift                   # The recommended web apps' brand icons (Sven 2026-10-10: "each with its real brand icon"):…
├── site/                                    # the public site (SH13), the vault site-generator's output: pages, fonts/
│   ├── fonts/                               # 4 files
│   │   ├── Geist-OFL.txt
│   │   ├── Geist.ttf
│   │   ├── GeistMono-OFL.txt
│   │   └── GeistMono.ttf
│   ├── ai.html
│   ├── captures.html
│   ├── clipboard.html
│   ├── dictation.html
│   ├── extensions.html
│   ├── index.html
│   ├── keys.html
│   ├── launcher.html
│   ├── menubar.html
│   ├── pilot-film-poster.jpg
│   ├── pilot-film.mp4
│   ├── privacy.html
│   ├── webapps.html
│   └── windows.html
├── Sources/                                 # 759 files
│   ├── CGhostty/                            # libghostty's embedder header for the bar drop's terminal
│   │   ├── ghostty.h                        # Ghostty embedding API. The documentation for the embedding API is
│   │   ├── LICENSE
│   │   └── module.modulemap                 # Ghostty's embedder API, MIT (Mitchell Hashimoto, Ghostty contributors): include/ghostty.h…
│   ├── Clipboard/                           # clipboard history store (pasteboard into SQLite)
│   │   ├── AutoRedact.swift
│   │   ├── ClipActions.swift                # Written from scratch for Pilot; ClipBook's item actions are the behaviour reference (clip…
│   │   ├── ClipboardCapture.swift           # Written from scratch for Pilot; Maccy (MIT, github.com/p0deje/Maccy) is the design refere…
│   │   ├── ClipboardOCR.swift               # Written from scratch for Pilot (card agent-bo-95423070); Raycast's and SuperCmd's image t…
│   │   ├── ClipboardPanel.swift
│   │   ├── ClipboardSettings.swift
│   │   ├── ClipboardStore.swift
│   │   ├── ClipboardWatcher.swift
│   │   ├── ClipQuery.swift
│   │   ├── PasteSequence.swift              # Written from scratch for Pilot (card agent-bo-95423071); Raycast's and SuperCmd's paste o…
│   │   ├── PasteSteps.swift                 # Written from scratch for Pilot (Sven, build 36: a Return on picks with an image among the…
│   │   ├── PlainPaste.swift                 # Written from scratch for Pilot (card agent-bo-95423072); Raycast's and SuperCmd's paste a…
│   │   └── SubjectCutout.swift              # Written for Pilot (P72); Snapzy's Capture Subject (BSD-3) is the behaviour reference, non…
│   ├── ImageScale/                          # resize and upscale; Real-ESRGAN runs in the PilotUpscale child
│   │   ├── Pixels.swift
│   │   ├── Resize.swift
│   │   └── Upscale.swift
│   ├── Pilot/                               # the menu-bar app: event tap, onboarding, observers, UI
│   │   ├── Apps/                            # 22 files
│   │   ├── Binds/                           # 2 files
│   │   ├── Captures/                        # 26 files
│   │   ├── Control/                         # 64 files
│   │   ├── Drive/                           # 10 files
│   │   ├── Engine/                          # 27 files
│   │   ├── Install/                         # 5 files
│   │   ├── Look/                            # 6 files
│   │   ├── Notes/                           # 7 files
│   │   ├── QuickAI/                         # 12 files
│   │   ├── Setup/                           # 5 files
│   │   ├── Snippets/                        # 1 file
│   │   ├── Speech/                          # 3 files
│   │   ├── System/                          # 47 files
│   │   ├── Terminal/                        # 2 files
│   │   ├── TopBar/                          # 15 files
│   │   ├── UI/                              # 164 files
│   │   ├── Windows/                         # 10 files
│   │   ├── Workspaces/                      # 9 files
│   │   └── PilotApp.swift
│   ├── PilotCLI/                            # the `pilot` command, over the running app's control socket
│   │   ├── main.swift
│   │   └── TextAnswer.swift
│   ├── PilotCore/                           # pure logic: layer state machine, keys, action registry, extensions
│   │   ├── Abilities.swift
│   │   ├── ActionRegistry.swift
│   │   ├── Activity.swift
│   │   ├── AgentInstructions.swift
│   │   ├── AIChat.swift
│   │   ├── AISkill.swift
│   │   ├── AIToolLoop.swift
│   │   ├── Aliases.swift
│   │   ├── AppCommands.swift
│   │   ├── AppConfigs.swift
│   │   ├── AppLifecycle.swift               # One app's lifecycle as seen in a change to the running apps (card agent-bo-95422739). NSW…
│   │   ├── AppLink.swift
│   │   ├── AppsShowAs.swift
│   │   ├── AppWindow.swift
│   │   ├── Backdrop.swift
│   │   ├── BarActions.swift
│   │   ├── BarDrop.swift
│   │   ├── BarEditing.swift
│   │   ├── BarItems.swift
│   │   ├── BarPanelPlacement.swift
│   │   ├── BarParts.swift
│   │   ├── BarTone.swift
│   │   ├── BindAI.swift
│   │   ├── BindNudges.swift
│   │   ├── BindSearch.swift
│   │   ├── BindsKeyboard.swift
│   │   ├── BindsMap.swift
│   │   ├── BindsPage.swift
│   │   ├── BindStore.swift
│   │   ├── Bitwarden.swift
│   │   ├── BitwardenFill.swift
│   │   ├── BitwardenSession.swift
│   │   ├── Brightness.swift
│   │   ├── BrightnessKeys.swift
│   │   ├── Calculator.swift
│   │   ├── CalculatorWorld.swift
│   │   ├── CaptureFiles.swift
│   │   ├── CaptureHistory.swift
│   │   ├── CaptureSelection.swift
│   │   ├── CaptureTrim.swift
│   │   ├── ChildProcess.swift
│   │   ├── ChipMenu.swift
│   │   ├── Clean.swift
│   │   ├── ClockMonth.swift
│   │   ├── ColourAnswer.swift
│   │   ├── ColourChoice.swift
│   │   ├── CombineLayout.swift
│   │   ├── ControlCollections.swift
│   │   ├── ControlGate.swift
│   │   ├── ControlPlan.swift
│   │   ├── ControlProtocol.swift
│   │   ├── ControlVerbs.swift
│   │   ├── Convert.swift
│   │   ├── ConvertBatch.swift
│   │   ├── CrashReports.swift
│   │   ├── CurrencyRates.swift
│   │   ├── DefaultApps.swift
│   │   ├── Defocus.swift
│   │   ├── DesktopIcons.swift
│   │   ├── DictationKey.swift
│   │   ├── DiskEject.swift
│   │   ├── DriveCatalogue.swift
│   │   ├── DriveRoute.swift
│   │   ├── Dropdown.swift
│   │   ├── DropKeys.swift
│   │   ├── EmojiGrid.swift
│   │   ├── EmojiSearch.swift
│   │   ├── Extension.swift
│   │   ├── ExtensionActionKey.swift
│   │   ├── ExtensionAI.swift
│   │   ├── ExtensionCatalogue.swift
│   │   ├── ExtensionCheck.swift
│   │   ├── ExtensionInstaller.swift
│   │   ├── ExtensionList.swift
│   │   ├── ExtensionRun.swift
│   │   ├── ExtensionSession.swift
│   │   ├── ExtensionsPage.swift
│   │   ├── ExtensionStorage.swift
│   │   ├── ExtensionSurfaces.swift
│   │   ├── Feedback.swift
│   │   ├── FileAction.swift
│   │   ├── FileFilters.swift
│   │   ├── FileKinds.swift
│   │   ├── Floating.swift
│   │   ├── FolderLooks.swift
│   │   ├── Frecency.swift
│   │   ├── FullKeyboard.swift
│   │   ├── Ghostty.swift
│   │   ├── Giphy.swift
│   │   ├── Helpers.swift
│   │   ├── HoldOverlay.swift
│   │   ├── HyperLayer.swift
│   │   ├── Install.swift
│   │   ├── InstallSearch.swift
│   │   ├── JSONValue.swift
│   │   ├── Key.swift
│   │   ├── KeybindingsOrder.swift
│   │   ├── KeyboardLayouts.swift
│   │   ├── KeyboardLock.swift
│   │   ├── KeySwap.swift
│   │   ├── KillProcess.swift
│   │   ├── LaunchAtLogin.swift
│   │   ├── LayerKey.swift
│   │   ├── LayoutPreset.swift
│   │   ├── LearnConfigs.swift
│   │   ├── LinkGuard.swift
│   │   ├── LoginItems.swift
│   │   ├── LowBattery.swift                 # Low-battery alerts (Sven, Q394: "my Keychron just ran out of battery and there was no way…
│   │   ├── MarkedBlock.swift
│   │   ├── Markup.swift
│   │   ├── Menu.swift
│   │   ├── MenuBar.swift                    # The menu-bar icon's text (stories 73 and 36): the focused workspace, a dash while the til…
│   │   ├── MenuBarPageModel.swift
│   │   ├── MenuBarStats.swift
│   │   ├── MenuGroups.swift
│   │   ├── MenuIcon.swift
│   │   ├── MenuItemSearch.swift
│   │   ├── MenuLayoutStyle.swift
│   │   ├── MenuPanelSize.swift
│   │   ├── MenuRoot.swift
│   │   ├── MenuRowActions.swift
│   │   ├── MouseDrag.swift
│   │   ├── MouseKeys.swift
│   │   ├── MyBinds.swift
│   │   ├── NightShift.swift                 # Night Shift's on and off, as the app reaches it: Apple's private CoreBrightness client, a…
│   │   ├── NoteAttachments.swift
│   │   ├── Notes.swift
│   │   ├── NotesFolder.swift
│   │   ├── NotesWelcome.swift
│   │   ├── Notifications.swift
│   │   ├── Onboarding.swift                 # First-run onboarding (stories 1, 2, 40, 94, 103 and 104; SPEC.md, Onboarding; wireframe z…
│   │   ├── PilotBlock.swift
│   │   ├── PilotDefault.swift
│   │   ├── PilotFolder.swift
│   │   ├── PilotStyle.swift
│   │   ├── PilotTheme.swift
│   │   ├── PinState.swift
│   │   ├── PixelRuler.swift
│   │   ├── PlainComboShadow.swift           # What a plain combo takes from macOS or from typing (story 51): the warning on the Binds s…
│   │   ├── PlanCLI.swift
│   │   ├── PopoverMetrics.swift
│   │   ├── Power.swift
│   │   ├── QuickAI.swift
│   │   ├── QuickAIRoute.swift
│   │   ├── QuickEvent.swift
│   │   ├── Quicklinks.swift
│   │   ├── RecordingClock.swift             # A recording's timeline with pauses cut out (spec `capture.html` CP13). ScreenCaptureKit s…
│   │   ├── RemapConflict.swift
│   │   ├── Reminders.swift
│   │   ├── Remove.swift
│   │   ├── Reports.swift
│   │   ├── Rescue.swift
│   │   ├── Rings.swift
│   │   ├── ScriptCommand.swift
│   │   ├── ScrollStitch.swift               # A scrolling capture's stitcher (spec `capture.html` CP11; Q159, and Sven's build 52: auto…
│   │   ├── SelectionPill.swift
│   │   ├── SelectionPrompt.swift
│   │   ├── SettingsSchema.swift
│   │   ├── SettingsSearch.swift
│   │   ├── SMCValue.swift
│   │   ├── Snapshot.swift
│   │   ├── Snippets.swift
│   │   ├── SpeedTest.swift
│   │   ├── SpokenList.swift                 # Names as a sentence lists them: "Slack", "Slack and Discord", "Slack, Discord and Mail";…
│   │   ├── StatsHistory.swift
│   │   ├── StatsOverview.swift
│   │   ├── StatsViews.swift
│   │   ├── StatusLights.swift
│   │   ├── Stickers.swift
│   │   ├── SymbolicHotKeys.swift
│   │   ├── SystemStats.swift
│   │   ├── TiledKey.swift
│   │   ├── TilerCommand.swift
│   │   ├── TileResize.swift
│   │   ├── TilerRunning.swift
│   │   ├── TopBar.swift
│   │   ├── TopBarBackground.swift
│   │   ├── Translate.swift
│   │   ├── Transparency.swift               # Transparency (Sven, 2026-10-08, design round 15, artifact Eh93LMpjwRxNRWnc8VHN47 section…
│   │   ├── Update.swift
│   │   ├── VideoEdit.swift
│   │   ├── WallpaperCycle.swift
│   │   ├── WebSearch.swift
│   │   ├── WindowBorder.swift
│   │   ├── WindowGeometry.swift
│   │   ├── WorkspacePageDrafts.swift
│   │   ├── WorkspacePreset.swift
│   │   ├── Workspaces.swift
│   │   ├── WorkspaceScroll.swift            # Hyper+scroll steps through workspaces (Omarchy ideas T2, Q95): one mouse-wheel notch is o…
│   │   └── WorkspaceSwipe.swift             # A three-finger sideways swipe on a trackpad moves to the next or previous workspace (card…
│   ├── PilotGate/                           # the agents' one rule for a `pilot` call (shared by the API loop and PilotMCP)
│   │   └── AgentGate.swift
│   ├── PilotMCP/                            # Codex's MCP server running one gated `pilot` call
│   │   └── main.swift
│   ├── PilotText/                           # child process: clipboard image text (Vision)
│   │   └── main.swift                       # pilot-text: the clipboard's image text read in a process of its own (story 142). Pilot ha…
│   ├── PilotTiler/                          # the tiler, AeroSpace's engine (MIT), behind TilerService
│   │   ├── calls/                           # 4 files
│   │   ├── Common/                          # 20 files
│   │   ├── config/                          # 1 file
│   │   ├── layout/                          # 6 files
│   │   ├── model/                           # 7 files
│   │   ├── mouse/                           # 6 files
│   │   ├── tree/                            # 17 files
│   │   ├── util/                            # 11 files
│   │   ├── appActivation.swift              # Pilot (spec scrolling-layout T7, 2026-10-12): how the focus hand-off brings another app f…
│   │   ├── focus.swift                      # Vendored from AeroSpace (MIT, nikitabobko/AeroSpace) at 74a1bf17: Sources/AppBundle/focus…
│   │   ├── focusCache.swift                 # Vendored from AeroSpace (MIT, nikitabobko/AeroSpace) at 74a1bf17: Sources/AppBundle/focus…
│   │   ├── getNativeFocusedWindow.swift     # Vendored from AeroSpace (MIT, nikitabobko/AeroSpace) at 74a1bf17: Sources/AppBundle/getNa…
│   │   ├── GlobalObserver.swift             # Vendored from AeroSpace (MIT, nikitabobko/AeroSpace) at 74a1bf17: Sources/AppBundle/Globa…
│   │   ├── LICENSE
│   │   ├── normalizeLayoutReason.swift      # Vendored from AeroSpace (MIT, nikitabobko/AeroSpace) at 74a1bf17: Sources/AppBundle/norma…
│   │   ├── PilotSettings.swift
│   │   ├── runLoop.swift                    # Vendored from AeroSpace (MIT, nikitabobko/AeroSpace) at 74a1bf17: Sources/AppBundle/runLo…
│   │   ├── ShownDesktop.swift
│   │   ├── TilerEngine.swift
│   │   ├── TilerEvents.swift
│   │   ├── TilerFault.swift
│   │   ├── TilerSettings.swift
│   │   ├── WindowHomes.swift
│   │   ├── windowLevelCache.swift           # Vendored from AeroSpace (MIT, nikitabobko/AeroSpace) at 74a1bf17: Sources/AppBundle/windo…
│   │   ├── WindowSlots.swift
│   │   └── WorkspaceArrangement.swift
│   ├── PilotTilerPrivateApi/                # the private window APIs the tiler calls
│   │   ├── include/                         # 1 file
│   │   ├── LICENSE
│   │   └── private.m                        # Vendored from AeroSpace (MIT, nikitabobko/AeroSpace) at 74a1bf17: Sources/PrivateApi/incl…
│   ├── PilotUpscale/                        # resize and upscale; Real-ESRGAN runs in the PilotUpscale child
│   │   └── main.swift                       # pilot-upscale: Real-ESRGAN in a process of its own (Q248). Core ML's model, its Neural En…
│   ├── PilotWebApp/                         # Install → Web App and the stamped web-app template
│   │   └── main.swift                       # The web-app template: one binary, stamped per site by the WebApps module; the site lives…
│   └── WebApps/                             # Install → Web App and the stamped web-app template
│       ├── DockBadge.swift
│       ├── Downloads.swift
│       ├── FindInPage.swift
│       ├── Notifications.swift
│       ├── Run.swift
│       ├── SameSite.swift
│       ├── SiteIcon.swift
│       ├── WebAppDirectory.swift
│       ├── WebAppRebuild.swift
│       ├── WebAppSpec.swift
│       ├── WebAppStamper.swift
│       └── WindowTop.swift
├── Tests/                                   # one suite per target, plus Fixtures/
├── .gitignore
├── .gitleaks.toml                           # gitleaks' default rules, less what is no secret in Pilot: a key combo after the word "key…
├── CONTRIBUTING.md                          # Contributing to Pilot
├── GLOSSARY.md                              # Pilot — domain glossary
├── LICENSE
├── NOTICE
├── Package.resolved
├── Package.swift                            # swift-tools-version:6.2
└── README.md                                # Pilot
```
<!-- file-map:end -->
