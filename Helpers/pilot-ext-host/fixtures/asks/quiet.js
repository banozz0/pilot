"use strict";
// A view that never asks Pilot for anything: its run reads no selection and asks no AI.
const { jsx } = require("react/jsx-runtime");
const { Action, ActionPanel, List } = require("@raycast/api");
const again = jsx(ActionPanel, { children: jsx(Action, { title: "Again", onAction: () => {} }) });

module.exports = { default: () => jsx(List, { children: jsx(List.Item, { title: "Nothing read", actions: again }, "row") }) };
