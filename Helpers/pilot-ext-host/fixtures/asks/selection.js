"use strict";
// Reads getSelectedText once as the view opens, loading until Pilot answers: the text, or why there is none.
const { useEffect, useState } = require("react");
const { jsx } = require("react/jsx-runtime");
const { List, getSelectedText } = require("@raycast/api");

function Command() {
  const [row, setRow] = useState(null);
  useEffect(() => {
    getSelectedText().then((text) => setRow(`Selected: ${text}`), (error) => setRow(`No selection: ${error.message}`));
  }, []);
  return jsx(List, { isLoading: row === null, children: row === null ? [] : [jsx(List.Item, { title: row }, "row")] });
}

module.exports = { default: Command };
