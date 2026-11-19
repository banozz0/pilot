"use strict";
// A fixture command: one row saying whether the password preference reached getPreferenceValues(), with its length
// and its sha256's first 8 hex digits, never the value itself.
const { jsx } = require("react/jsx-runtime");
const { List, getPreferenceValues } = require("@raycast/api");
const crypto = require("crypto");

function Command() {
  const { token } = getPreferenceValues();
  const subtitle = token ? `${token.length} characters, sha256 ${crypto.createHash("sha256").update(token).digest("hex").slice(0, 8)}` : "none";
  return jsx(List, { children: jsx(List.Item, { id: "token", title: token ? "Has a token" : "No token", subtitle }, "token") });
}

module.exports = { default: Command };
