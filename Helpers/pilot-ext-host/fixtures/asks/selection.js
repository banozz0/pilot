"use strict";
// Reads getSelectedText once as the view opens, loading until Pilot answers: the text, or why there is none.
const { useEffect, useState } = require("react");
const { jsx } = require("react/jsx-runtime");
const { Action, ActionPanel, List, getSelectedText } = require("@raycast/api");
// A do-nothing action, so `pilot ext act` can open the view and read what it shows.
const again = jsx(ActionPanel, { children: jsx(Action, { title: "Again", onAction: () => {} }) });

function Command() {
  const [row, setRow] = useState(null);
  useEffect(() => {
    getSelectedText().then((text) => setRow(`Selected: ${text}`), (error) => setRow(`No selection: ${error.message}`));
  }, []);
  return jsx(List, { isLoading: row === null, children: row === null ? [] : [jsx(List.Item, { title: row, actions: again }, "row")] });
}

module.exports = { default: Command };
