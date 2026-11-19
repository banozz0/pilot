"use strict";
// A fixture command in the shape Raycast's build emits, written by hand. Its one row's action fills 64 MiB buffers, kept
// and touched, up to a 768 MiB cap (past Pilot's 512 MB stop, never more), then spins for 3 s: the memory stop on a view
// that is open (a session), not a one-shot run.
const { useState } = require("react");
const { jsx } = require("react/jsx-runtime");
const { Action, ActionPanel, List } = require("@raycast/api");

const MIB = 1 << 20, CHUNK = 64 * MIB, CAP = 768 * MIB, HOLD_MS = 3000;
const kept = [];

function grow() {
  const start = Date.now();
  for (let used = 0; used < CAP; used += CHUNK) {
    const chunk = new Uint8Array(CHUNK);
    chunk.fill(1);
    kept.push(chunk);
  }
  while (Date.now() - start < HOLD_MS) { /* holds the memory */ }
}

function Command() {
  const [held, setHeld] = useState(0);
  return jsx(List, {
    children: jsx(List.Item, {
      id: "grow", title: held ? `Held ${held} MiB` : "Grow",
      actions: jsx(ActionPanel, { children: jsx(Action, { title: "Grow", onAction: () => { grow(); setHeld(kept.length * 64); } }) }),
    }, "grow"),
  });
}

module.exports = { default: Command };
