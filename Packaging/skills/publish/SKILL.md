---
name: publish
title: Share an extension or theme
description: Sends an extension or theme you made to Pilot's catalogue as a pull request, for its owner to review
when: Sending a finished extension or theme to Pilot's catalogue
symbol: paperplane
starter: "Send my extension to the catalogue: "
---
# Sending an extension or theme to the catalogue

Read first:
- `pilot list extensions`: the installed extensions. Send only one the user made (with /extension or by hand), never
  one that came from the catalogue (`pilot ext catalogue` lists those).
- `pilot theme list`: the theme packs. Send only one the user made, imported or duplicated, never one of Pilot's own
  (Pilot refuses those) or one from the catalogue (`pilot theme catalogue`).
- `pilot get extensions.catalogueClone`: the folder of the user's clone of the catalogue's repo (one clone for both
  kinds). Empty means none is set: ask the user for the folder of their clone, then plan it with
  `pilot set extensions.catalogueClone <folder> --plan` and `pilot plan apply`.
- `gh` signed in (`gh auth login`): it opens the pull request.

Then `pilot ext publish <id>` or `pilot theme publish <id>`. Pilot asks the user first, naming the pack, the branch, the
repo and, when their GitHub account cannot push to the repo, their fork. On Allow it copies the pack into the clone on a
new branch, rebuilds and checks the catalogue's index, commits, makes or finds their fork when they need one (the clone's
remote `pilot-fork`), pushes that branch and opens a pull request. Answer with the pull request's link.

When it answers that a step failed (the check's problems, a branch that exists, a clone with changes, gh not signed in),
say what it said in plain words and the one fix. Change nothing in the clone yourself. Nothing reaches the catalogue
until its owner merges the pull request.
