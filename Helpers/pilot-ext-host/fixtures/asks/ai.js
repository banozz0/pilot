"use strict";
// Asks AI.ask once as the view opens, if environment.canAccess(AI) says Pilot has it (Raycast's docs ask for the check),
// loading until the answer: each "data" piece, then the whole answer, or the error, on its own row.
const { useEffect, useState } = require("react");
const { jsx } = require("react/jsx-runtime");
const { AI, List, environment } = require("@raycast/api");

function Command() {
  const [state, setState] = useState({ loading: true, rows: [] });
  useEffect(() => {
    if (!environment.canAccess(AI)) return setState({ loading: false, rows: ["canAccess(AI): false"] });
    const pieces = [];
    const answer = AI.ask("Name three primary colours, comma-separated.", { creativity: "low" });
    answer.on("data", (piece) => pieces.push(piece));
    answer.then(
      (text) => setState({ loading: false, rows: ["canAccess(AI): true", `data pieces: ${pieces.length}`, `Answer: ${text}`] }),
      (error) => setState({ loading: false, rows: ["canAccess(AI): true", `Error: ${error.message}`] }),
    );
  }, []);
  return jsx(List, { isLoading: state.loading, children: state.rows.map((title) => jsx(List.Item, { title }, title)) });
}

module.exports = { default: Command };
