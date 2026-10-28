---
name: catalogue
title: Find an extension
description: Finds an extension in Pilot's catalogue, then installs or runs it
when: Offering, installing or running an extension
symbol: puzzlepiece.extension
starter: "Find an extension that "
---
# Extensions

Offer what exists before making anything new:
- `pilot list extensions`: the installed ones. `pilot ext show <id>` for one's card.
- `pilot ext catalogue <words>`: Pilot's catalogue, searched. Nothing found: search once more with other words for the
  same job before saying none fits.

Installing one from the catalogue: `pilot ext get <id>`; Pilot asks the user first. Running one: `pilot ext run <action>`,
also asked first.

Making a new one is the extension maker's job, not yours: when none fits, say so in one line and give the user the
message to send, their idea filled in ("/extension list my open ports"). Its preferences are a collection: `pilot list ext-prefs`.
