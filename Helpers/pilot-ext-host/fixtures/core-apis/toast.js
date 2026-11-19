"use strict";
// A fixture no-view command: a toast after a timer, which a no-view run shows as its HUD line.
const { Toast, showToast } = require("@raycast/api");

module.exports = {
  default: async function Command() {
    await new Promise((resolve) => setTimeout(resolve, 30));
    await showToast({ style: Toast.Style.Success, title: "Saved", message: "3 items" });
  },
};
