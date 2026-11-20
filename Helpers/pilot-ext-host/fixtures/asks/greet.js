"use strict";
// Shows each of its arguments as a row, as props.arguments hands them over.
const { jsx } = require("react/jsx-runtime");
const { List } = require("@raycast/api");

function Command(props) {
  const rows = Object.entries(props.arguments).map(([name, value]) => `${name}: ${JSON.stringify(value)}`);
  return jsx(List, { children: rows.map((title) => jsx(List.Item, { title }, title)) });
}

module.exports = { default: Command };
