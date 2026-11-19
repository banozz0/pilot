"use strict";
// A fixture command in the shape Raycast's build emits, written by hand. It spins for 3 s in a synchronous loop before
// its first commit, so neither a loading state nor the host's own 1.7 s deadline can answer: Pilot's 2 s deadline must
// stop it and show the error row.
const { jsx } = require("react/jsx-runtime");
const { List } = require("@raycast/api");

function Command() {
  const start = Date.now();
  while (Date.now() - start < 3000) { /* never yields */ }
  return jsx(List, { children: jsx(List.Item, { title: "Too late" }) });
}

module.exports = { default: Command };
