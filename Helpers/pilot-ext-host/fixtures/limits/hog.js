"use strict";
// A fixture command in the shape Raycast's build emits (CommonJS, React and @raycast/api left to the host), written by
// hand so it needs no build. It fills 64 MiB buffers, kept and touched so they count in the footprint, up to a cap of
// 768 MiB (past Pilot's 512 MB stop, never more, so a broken stop cannot swap the Mac), then spins for 3 s before its
// first commit. Pilot should kill it at the stop long before that commit.
const { jsx } = require("react/jsx-runtime");
const { List } = require("@raycast/api");

const MIB = 1 << 20, CHUNK = 64 * MIB, CAP = 768 * MIB, HOLD_MS = 3000;
const kept = [];

function Command() {
  const start = Date.now();
  for (let used = 0; used < CAP; used += CHUNK) {
    const chunk = new Uint8Array(CHUNK);
    chunk.fill(1);
    kept.push(chunk);
  }
  while (Date.now() - start < HOLD_MS) { /* holds the memory; a stop from inside JavaScript would never run */ }
  return jsx(List, { children: jsx(List.Item, { title: `Held ${kept.length * 64} MiB` }) });
}

module.exports = { default: Command };
