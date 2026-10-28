---
name: binds
title: Binds
description: Looks at the apps you open most and suggests free Hyper keys for them; binds mouse buttons and Hyper + scroll too
when: Suggesting or making binds, on keys or mouse buttons
symbol: command
starter: "Suggest Hyper binds for the apps I use most."
---
# Suggesting and making binds

When the user asks for a new preset, or for a set of keys built around one group (the arrows, the number row), that is
the /preset job: read `pilot guide preset` and do it in this same reply. Never call it a separate step.

Read first, each once:
- `pilot actions --find "<words>"`: one call with a word for every job the user named, in Pilot's words: capture
  (screenshots), scroll, record, display (monitors), float, tile, workspace, tab, zoom, note, terminal, an app's name.
  Pilot's own actions come first: captures (screenshots,
  scrolling captures, screen recording), windows (focus, swap, float or tile, halves, displays, the app's next window),
  workspaces, quick notes, the terminal drop, tabs (`drive.nextTab`, `drive.moveTabLeft`), the next app as Command-Tab
  (`apps.nextApp`), zoom in the app in front (`drive.zoomIn`) or of the whole screen (`system.screenZoom`). Offer
  another app only for a job no Pilot action does.
- An app or a web app only when the user asks to open it. A word in the ask that is also an app's name is a job, not
  that app: "a bind to zoom" is the zoom actions, never zoom.us.
- `pilot list apps`: the installed apps, the most recently opened first, with bundle ids, for the apps the user names.
- `pilot keys --free`: the Hyper keys no action holds. `pilot keys --free --mods shift` for Hyper+Shift.
- `pilot help bind routes` only for a menu item, keystroke or shell id no action covers.

Propose every bind the user asked for, one line each: key, then what it does; five when they named no number. Take
free keys first, the mnemonic letter first (L for Linear, then the next free letter of its name). When the user names
keys that are held (as the arrows), use them anyway: say which action each one takes the key from, and plan it with
`--replace`. An app opens with `apps.open:<bundle id>`, a web page with `apps.web:<https url>`.

When the user says yes:
1. `pilot bind <action> <key> --plan` for each one (add `--mods shift` for Hyper+Shift, `--replace` for a held key).
   Nothing changes yet.
2. `pilot plan apply`: Pilot shows every row on one card and the user allows them once.
3. Report each row from apply's answer: key, action, and any row that failed with its reason.

Other changes plan the same way: `pilot unbind <action> --plan`, `pilot bind <action> --reset --plan`.
`pilot plan` shows what waits; `pilot plan clear` drops it. To check one key: `pilot key hyper+k`.
If the user wants the binds back as they were, `pilot undo` puts the last applied plan back after one Allow.

## Mouse buttons

A mouse bind plans and applies as a key bind does, with the trigger quoted as one word:
- Back is "Mouse 4", Forward "Mouse 5", the wheel click "Mouse 3" (Wheel click on Binds › Mouse).
- A button alone is its plain press: `pilot bind <action> "Mouse 4" --plain --plan`. Hyper + the button drops `--plain`.
- The wheel binds under Hyper only: "Mouse Scroll Up" and "Mouse Scroll Down", no `--plain`.
- `pilot list mouse` reads every mouse bind. Read it first: `--replace` takes a held trigger, and says whose it was.
- `pilot remove mouse "<trigger>" --plan` frees one, the trigger as the list spells it (`unbind` is for keys); then `pilot plan apply`.
  Undo cannot bind a removed one back: `pilot bind` it again.
- A ring (the Ring menu) opens with `rings.open:<ring>`, held: on a key, or on a button's hold, `"Mouse 4 Hold" --plain`, which keeps
  the button's click. `pilot list rings` lists the rings and their wedges; `pilot add rings --ring <id> --place 0-7 --action <id>` sets one.

What stays the user's to do on Binds › Mouse: a button that sends a key or a media key, which the page catches from the
mouse itself, and a button the Mac never hears (Learn says so). Mouse 1 and 2, the left and right clicks, are never
bound, and plain scrolling stays scrolling. Say so in one line when asked for one of these.

## Swapped keys

Binds › Swap keys swaps two keys so each types the other, while Pilot runs (Caps Lock ↔ Left Control and the like).
`pilot list key-swaps` reads them, with why one waits; `pilot add key-swaps --keys capsLock:leftControl` and
`pilot remove key-swaps capsLock:leftControl` each ask Allow. A Hyper key cannot be swapped: the user picks another
Hyper key in General first.
