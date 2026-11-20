"use strict";
// A fixture command in the shape Raycast's build emits (CommonJS, React and @raycast/api left to the host), written by
// hand so it needs no build. Its Counter row's Increment adds one to the count its title shows, Reset sets it back to 0;
// the Remounts row is keyed by the count, so each press makes it a new element and its old handler id goes stale.
const { useState } = require("react");
const { jsx, jsxs } = require("react/jsx-runtime");
const { Action, ActionPanel, List } = require("@raycast/api");

function Command() {
  const [count, setCount] = useState(0);
  const increment = jsx(Action, { title: "Increment", onAction: () => setCount((n) => n + 1) });
  return jsxs(List, {
    children: [
      jsx(List.Item, {
        id: "counter", title: `Count: ${count}`, subtitle: "presses so far",
        actions: jsxs(ActionPanel, {
          children: [increment, jsx(ActionPanel.Section, { children: jsx(Action, { title: "Reset", onAction: () => setCount(0) }) })],
        }),
      }, "counter"),
      jsx(List.Item, {
        id: `remounts-${count}`, title: "Remounts",
        actions: jsx(ActionPanel, { children: jsx(Action, { title: "Increment too", onAction: () => setCount((n) => n + 1) }) }),
      }, `remounts-${count}`),
    ],
  });
}

module.exports = { default: Command };
