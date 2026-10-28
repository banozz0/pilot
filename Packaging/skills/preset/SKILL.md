---
name: preset
title: New preset
description: Makes a new key preset on Pilot default from what you ask for: smaller, or built around keys you pick
when: Making a new bind preset: a smaller one, or one built around keys the user names (the arrows)
symbol: keyboard
starter: "Make me a small key preset with only the keys I use."
---
# A new preset

Make a NEW preset on Pilot default, shaped by what the user asked: smaller than the one they have, or built around
keys they name (the arrows, the number row). My binds and Pilot default are never changed: never `--copy`, and never
plan a bind while either is active.

Read first, each once:
- `pilot list presets`: the names taken and the active one.
- `pilot list apps`: the installed apps, the most recently opened first, with bundle ids.
- `pilot keys --free --base pilot`: the Hyper keys a new preset on Pilot default leaves free (`--mods shift` for Hyper+Shift).
- `pilot actions --find "<words>"`: one call with a word for every job the user named, in Pilot's words: capture
  (screenshots), scroll, record, display (monitors), float, tile, workspace, tab, zoom, note, terminal. Pilot's own
  actions come first: captures (screenshots, scrolling captures, screen recording), windows (focus, swap, float or
  tile, halves, displays, the app's next window), workspaces, quick notes, the terminal drop, tabs (`drive.nextTab`,
  `drive.moveTabLeft`), the next app as Command-Tab (`apps.nextApp`), zoom (`drive.zoomIn`, `system.screenZoom`). Another app only for a job no Pilot action does, and an app or a web app only when the user
  asks to open it: a word that is also an app's name ("zoom") is a job, not that app.

1. When the user already said what they want (jobs, apps or keys), skip to step 2. Only when they gave nothing to go
   on, ask in one short message, numbered, each with your guess: the apps they open by key (from the top of the apps
   list), the window moves and captures they use, and the preset's name.
2. Show the whole preset before anything changes: its name (your guess when they gave none), then "Pilot default,
   plus:" and one line per key (key, then what it does), as many as the user asked for. Pilot default already holds
   the Pilot menu, workspaces and moving between windows: list one of those only to move it to a new key. Free keys first, the mnemonic letter first (L for Linear). A key the user names is theirs in a new preset even
   when Pilot default holds it: take it with `--replace` and say on its line what it takes the key from. An app opens
   with `apps.open:<bundle id>`, a web page with `apps.web:<https url>`. End with: say yes to make it, or change any line.
3. On yes: `pilot add presets --name "<their name>" --base pilot --plan`, then `pilot plan apply`. One Allow makes it
   and switches to it; the keys set in the preset they leave stay with that one.
4. `pilot list presets` must show the new one active; if not, stop and say so. Then `pilot bind <action> <key> --plan`
   for each line (add `--mods shift` for Hyper+Shift, `--replace` for a held key), and `pilot plan apply`: one more Allow.
5. Report the preset's name and each key from apply's answer, any row that failed with its reason, and that Binds ›
   Presets switches between presets.

If the user denies the second Allow, they are on the new preset with Pilot default's keys: say so, and that
`pilot bind --preset <id>` (one Allow) goes back to the one they had. `pilot undo` puts the last applied keys back;
the preset itself goes with `pilot remove presets <id>`, after its own Allow.
