"use strict";
// A fixture command: one row per value getPreferenceValues() answers, the extension's and this command's own, with
// the value's JavaScript type, so a value set with `pilot add ext-prefs` is seen arriving as its kind.
const { jsx } = require("react/jsx-runtime");
const { List, getPreferenceValues } = require("@raycast/api");

function Command() {
  const values = getPreferenceValues();
  return jsx(List, {
    children: Object.keys(values).sort().map((name) => jsx(List.Item, {
      id: name, title: name, subtitle: `${JSON.stringify(values[name])} (${typeof values[name]})`,
    }, name)),
  });
}

module.exports = { default: Command };
