"use strict";
// A fixture command in the shape Raycast's build emits, written by hand. Delete the thing asks confirmAlert first; its
// primary action's onAction marks the Status row Deleted, the dismiss's Kept, and the promise's answer lands on the
// Answer row a turn later. Ask twice asks two alerts at once: the second waits for the first.
const { useState } = require("react");
const { jsx } = require("react/jsx-runtime");
const { Action, ActionPanel, Alert, List, confirmAlert } = require("@raycast/api");

function Command() {
  const [status, setStatus] = useState("Pending");
  const [answer, setAnswer] = useState("none yet");
  const ask = (title) => confirmAlert({
    title, message: "It cannot be undone.",
    primaryAction: { title: "Delete", style: Alert.ActionStyle.Destructive, onAction: () => setStatus(`Deleted (${title})`) },
    dismissAction: { title: "Keep", onAction: () => setStatus(`Kept (${title})`) },
  }).then((confirmed) => setAnswer(`${title}: ${confirmed}`));
  const row = (title, onAction, subtitle) => jsx(List.Item, {
    title, subtitle, actions: jsx(ActionPanel, { children: jsx(Action, { title, onAction }) }),
  }, title);
  return jsx(List, {
    children: [
      row("Delete the thing", () => { ask("Delete the thing?"); }),
      row("Ask twice", () => { ask("First?"); ask("Second?"); }),
      row("Status", () => {}, status),
      row("Answer", () => {}, answer),
    ],
  });
}

module.exports = { default: Command };
