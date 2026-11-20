"use strict";
// confirmAlert from a no-view command, which has no panel to ask in.
const { confirmAlert, showHUD } = require("@raycast/api");

module.exports = { default: async () => { if (await confirmAlert({ title: "Go on?" })) await showHUD("Went on"); } };
