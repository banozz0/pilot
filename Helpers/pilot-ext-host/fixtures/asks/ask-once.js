"use strict";
// AI.ask from a no-view command: its answer, or its error, as its HUD line.
const { AI, showHUD } = require("@raycast/api");

module.exports = {
  default: async () => {
    try { await showHUD(`Answer: ${await AI.ask("Say yes.")}`); } catch (error) { await showHUD(`AI.ask failed: ${error.message}`); }
  },
};
