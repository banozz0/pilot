"use strict";
// A no-view command naming TextEdit: no view is open to ask in, so it fails with its HUD saying why.
const { execFile } = require("child_process");
const { showHUD } = require("@raycast/api");
const shim = `${process.cwd()}/shim/osascript`;

module.exports = {
  default: () => new Promise((resolve) => {
    execFile(shim, ["-e", 'tell application "TextEdit" to get name of every document'], (error, stdout) => {
      showHUD(error ? `error ${error.code}: ${error.message}` : String(stdout).trim()).then(resolve);
    });
  }),
};
