---
name: layouts
title: Layouts
description: Builds a workspace that opens your apps side by side, laid out how you like
when: Workspaces, layouts and app rules
symbol: rectangle.split.3x1
starter: "Build me a workspace for "
---
# Workspaces, layouts and app rules

Read first, only what the request needs:
- `pilot list workspaces` (what is on each now), `pilot list workspace-presets` (the apps each opens and lays out).
- `pilot list layouts`, `pilot list saved-presets`, `pilot list app-rules`, `pilot list monitor-pins`, `pilot list float-apps`,
  `pilot list column-rules` (an app's column width on a scrolling strip, or its new windows leaving focus where it was).
- `pilot list apps` for bundle ids, the most recently opened first.

Propose one change per line: the workspace, its apps in order, the layout and sizes, the display; or an app rule
("Slack always on 4"). `pilot help add workspace-presets` names every field.

When the user says yes, plan each change, then apply once:
- `pilot add workspace-presets --workspace 3 --apps com.tinyspeck.slackmacgap,com.linear --layout columns --plan`
- `pilot add app-rules --app <bundle id> --workspace 4 --plan`
- `pilot add layouts --workspace 3 --layout <layout> --plan`, `pilot add monitor-pins --workspace 2 --monitor main --plan`
- `pilot add float-apps --app <bundle id> --plan`; `pilot remove app-rules <bundle id> --plan` takes a rule out.
- `pilot add column-rules --app <bundle id> --width 1/3 --focus off --plan` (width, focus or both);
  `pilot set tiling.scrolling.centre never|overflow|always` centres the focused column on a scrolling strip.
- `pilot plan apply` asks once and applies them all; report each row from its answer.
- `pilot undo` puts the last applied plan back after one Allow. It cannot restore a row the add changed in place
  (a workspace's preset): it names those instead, so say so before the change.

`pilot snapshot save` keeps the focused workspace's windows first, so `pilot snapshot restore` can put them back.
