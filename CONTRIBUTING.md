# Contributing to Pilot

Thanks for helping. Pilot is one person's daily driver first, so small, focused changes land fastest.

- **Bugs and ideas:** open an issue with the Bug report or Idea form; Pilot's Send feedback fills in your Mac and
  Pilot version. Check any log you paste for anything private first.
- **Before a big change,** open an issue to agree on it: a new action, setting or page, or a change to how binds or the
  tiler behave.
- **Build and test:** see the README's Build from source. `swift build`, then `swift test --filter <Suite>` for the
  suites your change touches, and the whole `swift test` once before you open the pull request. The Rust helper has
  its own: `cargo test --manifest-path Helpers/pilot-files/Cargo.toml`.
- **Keep the house rules:**
  - The event tap owns every bind. Reach another app through its CLI, URL scheme or menu item, never by posting key
    events to fire its own hotkey.
  - AppleScript runs in a child `osascript`, never on the main thread, where it stalls the tap.
  - Match the code around you: its naming, comments and size. Pilot keeps its memory and size inside
    `Scripts/lean-budgets.json`.
- **Vendored code:** changes to `Sources/PilotTiler/` (from AeroSpace), `Sources/CGhostty/` (from Ghostty) or
  `Helpers/pilot-files/vendor/` (from Cardinal) keep their licence notices.
- **Pull requests:** one change each, with what it does, why, and how you checked it. By opening one you agree that
  your contribution is under the MIT licence in [LICENSE](LICENSE).
