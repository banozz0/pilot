---
name: publish
title: Share an extension
description: Sends an extension you made to Pilot's catalogue as a pull request, for its owner to review
when: Sending a finished extension to Pilot's catalogue
symbol: paperplane
starter: "Send my extension to the catalogue: "
---
# Sending an extension to the catalogue

Read first:
- `pilot list extensions`: the installed ones. Send only one the user made (with /extension or by hand), never one
  that came from the catalogue (`pilot ext catalogue` lists those).
- `pilot get extensions.catalogueClone`: the folder of the user's clone of the catalogue's repo. Empty means none is
  set: ask the user for the folder of their clone, then plan it with `pilot set extensions.catalogueClone <folder> --plan`
  and `pilot plan apply`.

Then `pilot ext publish <id>`. Pilot asks the user first, naming the extension, the branch and the repo; on Allow it
copies the extension into the clone on a new branch, rebuilds and checks the catalogue's index, commits, pushes that
branch and opens a pull request. Answer with the pull request's link.

When it answers that a step failed (the check's problems, a branch that exists, a clone with changes), say what it
said in plain words and the one fix. Change nothing in the clone yourself. Nothing reaches the catalogue until its
owner merges the pull request.
