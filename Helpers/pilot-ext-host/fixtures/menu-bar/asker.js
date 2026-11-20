"use strict";
// A menu-bar command that asks as it renders: AI.ask and getSelectedText, each ending as its title says. A bar render
// must never ask (Q478): both fail at once there.
const { useEffect, useState } = require("react");
const { jsx } = require("react/jsx-runtime");
const { AI, MenuBarExtra, getSelectedText } = require("@raycast/api");

function Command() {
  const [said, setSaid] = useState(null);
  useEffect(() => {
    const started = Date.now();
    const ended = (p) => p.then((text) => `answered ${JSON.stringify(text)}`, (error) => `failed: ${error.message}`);
    Promise.all([ended(AI.ask("Say hi.")), ended(getSelectedText())])
      .then(([ai, selection]) => setSaid({ ai, selection, ms: Date.now() - started }));
  }, []);
  const title = said === null ? "Asking" : `AI ${said.ai.startsWith("failed") ? "failed" : "answered"} in ${said.ms} ms`;
  return jsx(MenuBarExtra, {
    title, isLoading: said === null,
    children: said === null ? null : [
      jsx(MenuBarExtra.Item, { title: `AI.ask ${said.ai}` }, "ai"),
      jsx(MenuBarExtra.Item, { title: `getSelectedText ${said.selection}` }, "selection"),
    ],
  });
}

module.exports = { default: Command };
