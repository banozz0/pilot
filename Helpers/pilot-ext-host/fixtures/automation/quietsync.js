"use strict";
// Review 2's blocker 3: a no-view command whose call is sync (execFileSync naming Preview). It cannot wait, so it throws
// while Pilot asks; the run must still end on the consent alert, not an error line.
const { execFileSync } = require("child_process");
const { showHUD } = require("@raycast/api");
const shim = `${process.cwd()}/shim/osascript`;

module.exports = {
  default: async () => {
    const out = execFileSync(shim, ["-e", 'tell application "Preview" to get name of every document']);
    await showHUD(String(out).trim());
  },
};
