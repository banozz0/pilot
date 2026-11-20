"use strict";
// Review 2's blocker 4: a run-time target (the unread app) waits while Mail's question is open; the call naming Mail is
// killed 2 s after mount, as runAppleScript's own timeout kills one. Mail's question stays, and answering it lets the
// waiting call go on: it never waits forever.
const { spawn, execFile } = require("child_process");
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

function killed(done) {
  const child = spawn(shim, ["-e", 'tell app "Mail" to activate']);
  child.on("error", (error) => done(error));
  child.on("close", (code, signal) => done(signal ? Object.assign(new Error(`killed by ${signal}`), { code: signal }) : null, "shim osascript ran"));
  setTimeout(() => child.kill(), 2000);
}

module.exports = {
  default: () => jsx(Calls, {
    calls: [
      ["Run-time target", (done) => execFile(shim, ["-e", 'set x to "Mail"', "-e", "tell application x to activate"], done)],
      ["Mail, killed at 2 s", killed],
    ],
  }),
};
