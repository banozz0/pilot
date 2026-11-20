"use strict";
// A view that never asks Pilot for anything: its run reads no selection and asks no AI.
const { jsx } = require("react/jsx-runtime");
const { List } = require("@raycast/api");

module.exports = { default: () => jsx(List, { children: jsx(List.Item, { title: "Nothing read" }, "row") }) };
