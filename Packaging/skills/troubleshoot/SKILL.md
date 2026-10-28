---
name: troubleshoot
title: Something is off
description: Checks Pilot's status and tells you the cause and the fix
when: Something in Pilot does not work
symbol: stethoscope
starter: "Check Pilot's status and tell me the cause and the fix."
---
# Troubleshooting

Read first:
- `pilot status --part hyper,switch,permissions,engine,problems,presses`: the Hyper key, Pilot's switch, permissions,
  the key engine, open problems, and the last presses.
- `pilot conflicts` when a plain combo does nothing; `pilot key <combo>` for one key.
- `pilot list helpers` when a feature needs a tool (Homebrew, mas, npm).
- `pilot log --last 10m`: Pilot's own errors and warnings, newest first; `--last 1h` reaches further back.
- `pilot crash`: the newest crash report of Pilot or its helpers from the last 7 days, by name and date, or none.
- `pilot uninstall --list`: everything Pilot put on this Mac (speech models, caches, data, Pilot itself) with sizes, when disk
  space is the question. Removing is the user's, in General › Uninstall… (`pilot open general`); never trash files yourself.

Answer with the cause in one line and the one fix: a setting (plan it: `pilot set <key> <value> --plan`, then
`pilot plan apply`), a bind, or the page where the user grants a permission (`pilot open <page>`). A permission is the
user's to grant; never try to work around one.

When `pilot crash` names a report, say so with its process and date ("<process> left a crash report on <date>: <report>") and offer to show it in
Finder; on the user's yes, `pilot crash --reveal`. The report stays on this Mac: never read its contents into the chat
and never upload or send it unless the user says yes; it may hold paths from their Mac.

When the cause is Pilot's own bug (not a setting, a bind or a permission), say so and offer to report it. When the user
says yes: `pilot bug "<short title>" --what "<what happens, and what should>" --steps "<1. … 2. …>"`. Pilot asks the
user, then opens its bug form on GitHub filled in with this Mac's facts; it is sent only when the user presses Submit
there. When `pilot crash` named a report, tell the user they may attach it on that form (its Crash report field: drag
the file from the Finder window `pilot crash --reveal` opens); attaching it is their choice. Write only what this chat
found: never a name, a home folder or a log line the user did not paste.
