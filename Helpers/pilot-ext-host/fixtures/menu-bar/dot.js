"use strict";
// An icon-only menu-bar command: no title, its icon the asset dot.png, its menu one row.
const { jsx } = require("react/jsx-runtime");
const { MenuBarExtra, open } = require("@raycast/api");

function Command() {
  return jsx(MenuBarExtra, {
    icon: "dot.png",
    children: jsx(MenuBarExtra.Item, { title: "Open the docs", onAction: () => open("https://developers.raycast.com") }),
  });
}

module.exports = { default: Command };
