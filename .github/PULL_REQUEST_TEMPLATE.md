<!--
Title: "Theme: <Name>", "Extension: <Name> <version>", with "update" after the kind when the catalogue has it already
("Extension update: Weather 1.3.2"); for a code change, "<area>: <what>".
Sections after the pr skill's template (Summary, Evidence, Merge Danger), from Dex Horthy's show-me skill (HumanLayer):
https://github.com/humanlayer/skills/blob/main/plugins/show-me/skills/show-me/SKILL.md
`pilot theme publish <id>` and `pilot ext publish <id>` write this body for you. Keep prose short; delete what does not apply.
-->

## Summary

<!--
Theme: one line (name, dark or light, wallpaper count, the apps it themes), then its palette:

| Role | Colour |
| --- | --- |
| Accent | `#E15A48` |
| Background | `#12101C` |
| Text | `#F0C4A8` |

and each wallpaper's licence line from PROVENANCE.md.

Extension: what it does, its commands and top bar or page items, then what it touches:
- Runs: its programs and the tools they need
- Network: every host it reaches
- Files: what it reads or writes outside its own folder
- Clipboard, Pilot actions
For an update, the version before and after and the files that changed.

Code: the smallest view that makes the point (a call tree, a diff sketch, a file tree).
-->

## Evidence

<!--
- Checks: the last line of `python3 catalogue/scripts/check.py`, and `python3 -m unittest discover -s catalogue/tests`
  for an extension; for code, the suites you ran.
- Preview: a screenshot, or the pack's own `preview` picture. Say which.
- Sent by: the Pilot build, or "by hand".
-->

## Merge Danger

**Door:** <!-- one-way or two-way -->

<!--
A theme is a two-way door: a revert takes it out of the gallery.
An extension is a one-way door for everyone who installs it: its programs run on their Mac as them and may reach the
network; a revert takes it out of the catalogue, not off their Macs, and what it ran, sent or wrote stays done.
-->

**Blast Radius:** <!-- one word: cosmetic, every install, the tap, ... -->

## Review

- [ ] Licence: every file, palette source and wallpaper is yours or under a licence that allows it (PROVENANCE.md); no code from Raycast, Vicinae, ClipBook or Alfred extensions
- [ ] No secrets: no tokens, keys, personal paths or account names in any file
- [ ] Scope: only the pack's folder and `catalogue/index.json` change (a code change: only what the title names)
- [ ] An extension's programs do only what the Summary says, with every host and file declared
