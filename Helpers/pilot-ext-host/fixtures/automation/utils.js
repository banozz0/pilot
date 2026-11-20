"use strict";
// runAppleScript's own shape (@raycast/utils 2.3.3, read 2026-11-20): osascript by name with -ss or nothing, -l JavaScript
// for JXA, `-` before arguments, a small PATH, and the script on stdin. Here the shim stands in for osascript. Read in full,
// each asks for its app by name: Notes, then Reminders.
const { spawn } = require("child_process");
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
/** A call handed its script, or anything else, on stdin, as runAppleScript and xargs take theirs. */
function viaStdin(file, args, input, done, options = {}) {
  const child = spawn(file, args, options);
  let out = "";
  child.stdout?.on("data", (d) => { out += d; });
  child.on("error", (error) => done(error));
  child.on("close", (code) => done(code === 0 ? null : new Error(`exit ${code}`), out));
  child.stdin?.end(input);
}

/** The PATH runAppleScript gives its child. */
const utilsEnv = { env: { PATH: "/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin" } };

module.exports = {
  default: () => jsx(Calls, {
    calls: [
      ["Notes", (done) => viaStdin(shim, ["-ss"], 'tell application "Notes" to get name of every note', done, utilsEnv)],
      ["Reminders JXA", (done) => viaStdin(shim, ["-l", "JavaScript", "-", "x"], 'Application("Reminders").lists.length', done, utilsEnv)],
    ],
  }),
};
