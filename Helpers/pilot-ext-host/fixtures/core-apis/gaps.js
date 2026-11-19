"use strict";
// A fixture no-view command: it uses six things Pilot lacks, each in its own try, so the gap recorder writes them all
// and `pilot ext gaps core-apis` lists them; then it says how many threw.
const api = require("@raycast/api");
const fs = require("fs");

module.exports = {
  default: async function Command() {
    const tries = [
      () => api.getSelectedText(),
      () => api.AI.ask("hello"),
      () => api.notInRaycastEither(),
      () => fs.watch("/tmp"),
      () => Buffer.from("x"),
      () => require("http"),
    ];
    let threw = 0;
    for (const attempt of tries) {
      try { await attempt(); } catch { threw += 1; }
    }
    await api.showHUD(`${threw} of ${tries.length} threw`);
  },
};
