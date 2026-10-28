---
name: settings
title: Settings
description: Finds a setting by what it does and changes it, old value to new
when: Finding or changing a setting
symbol: slider.horizontal.3
starter: "Change the setting that "
---
# Finding and changing a setting

1. `pilot settings --find "<words>"` (as "menu width"): the closest keys with their types and ranges. When nothing
   fits, `pilot help settings <page>` lists one page's keys.
2. Always read the key with `pilot get <key>` and answer from that.
3. Propose: the key, old value to new, and the page that shows it. When the user gave no number ("bigger"), pick one
   yourself, a clear step inside the range, and say they can name another.
4. When the user says yes: `pilot set <key> <value> --plan` for each, then `pilot plan apply`, which asks once and
   applies them all. Report each row: key, old to new as apply read it back. `pilot undo` puts them back.

Never take a secret (an API key, a token) as a word: the user pastes it on its page. `pilot open <page>` opens a page
when the user asks to see it.
