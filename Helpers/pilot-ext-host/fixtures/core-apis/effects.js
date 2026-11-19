"use strict";
// A fixture no-view command: each effect Raycast performs on the Mac, which the host hands Pilot as an ADR 0010 action
// line (copy, paste, open, show in Finder), and a HUD; `pilot ext run` answers them unperformed.
const { Clipboard, open, showHUD, showInFinder } = require("@raycast/api");

module.exports = {
  default: async function Command() {
    await Clipboard.copy("copied by core-apis");
    await Clipboard.paste({ text: "pasted by core-apis" });
    await open("https://example.com/opened");
    await showInFinder("/tmp/fixture/shown.txt");
    await showHUD("effects sent");
  },
};
