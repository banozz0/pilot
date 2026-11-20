"use strict";
// A no-view command that says its arguments in its HUD line.
const { showHUD } = require("@raycast/api");

module.exports = { default: async (props) => { await showHUD(`arguments ${JSON.stringify(props.arguments)}`); } };
