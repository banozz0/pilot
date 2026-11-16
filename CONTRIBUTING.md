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

## The catalogue

Pilot's extensions and themes come from `catalogue/` in this repo, and anyone can send one.

- **Layout:** one folder per pack, named by its id: `catalogue/extensions/<id>/` (an `extension.json` and its programs)
  and `catalogue/themes/<id>/` (a `manifest.json`, its wallpapers, its preview and an optional `PROVENANCE.md`).
  `catalogue/index.json` is what Pilot reads; never edit it by hand, `catalogue/scripts/build-index.py` writes it.
- **How to send one:** fork the repo, add or change your pack's folder, then run, from the repo's root:

  ```sh
  python3 catalogue/scripts/build-index.py
  python3 catalogue/scripts/check.py
  python3 -m unittest discover -s catalogue/tests
  PILOT_EXT_PYTHON=/usr/bin/python3 python3 -m unittest discover -s catalogue/tests
  ```

  and open a pull request that changes only `catalogue/`. Pilot does these steps with `pilot ext publish <id>` or
  `pilot theme publish <id>` (or /publish in Ask Pilot) when your GitHub account can push here; sending from your own
  fork that way is in debug builds (`swift build`) only for now. Its pull request is titled `Theme: <Name>` or
  `Extension: <Name> <version>` (`update` after the kind when the catalogue has it) and its body, shown on Allow before
  anything is pushed, fills `.github/PULL_REQUEST_TEMPLATE.md`'s sections from the pack; opening one by hand, fill them
  yourself.
- **Checks:** every pull request that touches `catalogue/` runs `check.py`, rebuilds the index and compares it, and
  runs the catalogue's tests on macOS's own `/usr/bin/python3`. A pull request from a fork that changes `catalogue/`
  may change nothing else: send a fix to `Sources/` on its own.
- **Review:** every pack is read in full by Pilot's maintainer before it is merged, and so is every update to one, the
  whole change and not only the version. A change to a pack someone else first sent is flagged for that read. An
  extension is a program that runs with its user's rights, so it is read as code.
- **What gets refused:**
  - Both kinds: symlinks, hidden files or folders, bidirectional or invisible Unicode controls in any text file, and a
    title that looks like another's of its kind.
  - Extensions: Python 3 standard library only, each program starting `#!/usr/bin/env python3` and running on
    macOS's `/usr/bin/python3` (3.9), printing only protocol lines on stdout and never logging titles, clipboard text
    or secrets; a `version` x.y.z, a plain-words description and one or two `examples`; at most 200 files, 2 MB a
    file and 10 MB in all. Ideas from other launchers' extensions are fine; their code is not.
  - Themes: only the manifest keys Pilot knows, each once; no `customMappings`; no executable file; images PNG, JPEG
    or HEIC by their bytes, at most 16384 pixels a side and 50 million in all; no `url(`, `@import` or `://` in the
    manifest; at most 300 files, 8 MB a file and 40 MB in all. Name yourself with one `Pack by: @your-login` line in
    `PROVENANCE.md`, and say there where each wallpaper comes from: send only pictures you may share.
