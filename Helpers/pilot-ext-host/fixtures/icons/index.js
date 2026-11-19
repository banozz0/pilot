"use strict";
// A fixture command in the shape Raycast's build emits (CommonJS, React and @raycast/api left to the host), written by
// hand so it needs no build. One row per kind of icon a Raycast row takes: an Icon name alone and in an object with a
// tint, a name Pilot has no symbol for, an emoji, an asset PNG, and remote pictures from the `base` preference's server
// (one small, one past 64 KB, one past the download cap, one that is not a picture with an Icon fallback, one missing).
const { jsx } = require("react/jsx-runtime");
const { Color, Icon, List, getPreferenceValues } = require("@raycast/api");

function Command() {
  const base = getPreferenceValues().base || "http://127.0.0.1:8765";
  const rows = [
    ["Icon name", Icon.Checkmark],
    ["Icon with a tint", { source: Icon.Trash, tintColor: Color.Red }],
    ["Light and dark", { source: { light: Icon.Sun, dark: Icon.Moon } }],
    ["Unknown name", "NoSuchIcon"],
    ["Emoji", "🎨"],
    ["Asset PNG", "dot.png"],
    ["Remote small", `${base}/small.png`],
    ["Remote past 64 KB", `${base}/big.png`],
    ["Remote past the download cap", `${base}/huge.png`],
    ["Not a picture, with a fallback", { source: `${base}/text.png`, fallback: Icon.Globe }],
    ["Missing asset", "missing.png"],
  ];
  return jsx(List, { children: rows.map(([title, icon]) => jsx(List.Item, { id: title, title, icon }, title)) });
}

module.exports = { default: Command };
