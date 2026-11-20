"use strict";
// A fixture command in the shape Raycast's build emits (CommonJS, React and @raycast/api left to the host), written by
// hand so it needs no build. The root List counts Increment's presses; Open pushes the Pushed List with Action.Push and
// counts each pop through its onPop. The pushed view's Back row calls useNavigation().pop(), and its Deeper row pushes
// a Detail through useNavigation().push(), so the root's count shows its state survived each pop.
const { useState } = require("react");
const { jsx, jsxs } = require("react/jsx-runtime");
const { Action, ActionPanel, Detail, List, useNavigation } = require("@raycast/api");

function Deeper() {
  const { pop } = useNavigation();
  return jsx(Detail, {
    markdown: "# Deeper\nPushed by useNavigation().push().",
    actions: jsx(ActionPanel, { children: jsx(Action, { title: "Back", onAction: pop }) }),
  });
}

function Pushed() {
  const { push, pop } = useNavigation();
  const [count, setCount] = useState(0);
  return jsxs(List, {
    navigationTitle: "Pushed",
    children: [
      jsx(List.Item, {
        id: "pushed-count", title: `Pushed count: ${count}`,
        actions: jsx(ActionPanel, { children: jsx(Action, { title: "Increment", onAction: () => setCount((n) => n + 1) }) }),
      }, "pushed-count"),
      jsx(List.Item, {
        id: "back", title: "Back",
        actions: jsx(ActionPanel, { children: jsx(Action, { title: "Go back", onAction: pop }) }),
      }, "back"),
      jsx(List.Item, {
        id: "deeper", title: "Deeper",
        actions: jsx(ActionPanel, { children: jsx(Action, { title: "Push a detail", onAction: () => push(jsx(Deeper, {})) }) }),
      }, "deeper"),
    ],
  });
}

function Command() {
  const [count, setCount] = useState(0);
  const [pops, setPops] = useState(0);
  return jsxs(List, {
    children: [
      jsx(List.Item, {
        id: "root-count", title: `Root count: ${count}`, subtitle: `back ${pops} times`,
        actions: jsx(ActionPanel, { children: jsx(Action, { title: "Increment", onAction: () => setCount((n) => n + 1) }) }),
      }, "root-count"),
      jsx(List.Item, {
        id: "open", title: "Open",
        actions: jsx(ActionPanel, {
          children: jsx(Action.Push, { title: "Open pushed", target: jsx(Pushed, {}), onPop: () => setPops((n) => n + 1) }),
        }),
      }, "open"),
    ],
  });
}

module.exports = { default: Command };
