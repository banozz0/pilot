"use strict";
// Finder, through execFileSync at mount: a sync call cannot wait for an answer, so the first one fails while Pilot asks.
const { execFileSync } = require("child_process");

function once(done) {
  try { done(null, execFileSync(shim, ["-e", 'tell application "Finder" to get name of every disk'])); } catch (error) { done(error); }
}
// Each command is one file in the shape Raycast's build emits (CommonJS, React and @raycast/api
// left to the host). Every call runs shim/osascript by its absolute path, so no PATH lookup can reach the real one.
const { useEffect, useState } = require("react");
const { jsx } = require("react/jsx-runtime");
const { List } = require("@raycast/api");

const shim = `${process.cwd()}/shim/osascript`;

/** A List with one row per call: its name, then what the shim printed or the error it failed with; loading while one
 *  waits, as an extension running AppleScript at mount is, so Pilot takes the answer after it (the ask, or the rows). */
function Calls({ calls }) {
  const [rows, setRows] = useState(() => calls.map(([name]) => ({ name, said: "waiting" })));
  useEffect(() => {
    calls.forEach(([name, run], i) => {
      run((error, stdout) => {
        const said = error ? `error ${error.code ?? ""}: ${error.message}` : String(stdout).trim();
        setRows((now) => now.map((r, j) => (j === i ? { name, said } : r)));
      });
    });
  }, []);
  return jsx(List, { isLoading: rows.some((r) => r.said === "waiting"), children: rows.map((r) => jsx(List.Item, { id: r.name, title: r.name, subtitle: r.said }, r.name)) });
}


module.exports = { default: () => jsx(Calls, { calls: [["Finder (sync)", once]] }) };
