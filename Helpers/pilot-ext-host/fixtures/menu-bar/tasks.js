"use strict";
// A menu-bar command in the shape Raycast's build emits (CommonJS, React and @raycast/api left to the host), written by
// hand. It loads for 0.3 s (isLoading), then its title counts the open tasks; its menu has a section of them, Mark one
// done (Option: Mark all done) and a submenu. An interval keeps ticking the whole run, so only the extra's own
// readiness ends a bar render. Its launchType is a row, so a bar render and an open popover each show theirs.
const { useEffect, useState } = require("react");
const { jsx, jsxs } = require("react/jsx-runtime");
const { Icon, MenuBarExtra, environment } = require("@raycast/api");

function Command() {
  const [open, setOpen] = useState(null);
  useEffect(() => {
    const load = setTimeout(() => setOpen(3), 300);
    const tick = setInterval(() => {}, 1000);
    return () => { clearTimeout(load); clearInterval(tick); };
  }, []);
  const count = open ?? 0;
  return jsxs(MenuBarExtra, {
    title: open === null ? "Tasks" : `${count} open`, icon: Icon.Checkmark, isLoading: open === null, tooltip: "Open tasks",
    children: [
      jsx(MenuBarExtra.Section, {
        title: "Open",
        children: Array.from({ length: count }, (_, n) => jsx(MenuBarExtra.Item, { title: `Task ${n + 1}` }, `task-${n}`)),
      }),
      jsx(MenuBarExtra.Section, {
        children: [
          jsx(MenuBarExtra.Item, {
            title: "Mark one done", icon: Icon.Checkmark, onAction: (event) => setOpen((n) => Math.max(0, (n ?? 0) - 1)),
            alternate: jsx(MenuBarExtra.Item, { title: "Mark all done", onAction: () => setOpen(0) }),
          }, "done"),
          jsx(MenuBarExtra.Separator, {}, "sep"),
          jsx(MenuBarExtra.Item, { title: `Launched: ${environment.launchType}` }, "launch"),
        ],
      }),
      jsxs(MenuBarExtra.Submenu, {
        title: "More",
        children: [jsx(MenuBarExtra.Item, { title: "Reset to 3", onAction: (event) => setOpen(event && event.type === "left-click" ? 3 : -1) }, "reset")],
      }),
    ],
  });
}

module.exports = { default: Command };
