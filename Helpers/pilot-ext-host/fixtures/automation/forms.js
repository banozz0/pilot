"use strict";
// One call per way a script names its app: on stdin (as a runAppleScript helper hands it over), a script file naming a
// bundle id, JXA's Application("…"), a target chosen at run time, and System Events, which is asked like any other.
const { spawn, execFile } = require("child_process");

function viaStdin(script, done) {
  const child = spawn(shim, ["-l", "AppleScript"]);
  let out = "";
  child.stdout.on("data", (d) => { out += d; });
  child.on("error", (error) => done(error));
  child.on("close", (code) => done(code === 0 ? null : new Error(`exit ${code}`), out));
  child.stdin.end(script);
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


module.exports = {
  default: () => jsx(Calls, {
    calls: [
      ["Stdin: Reminders", (done) => viaStdin('tell application "Reminders" to count reminders', done)],
      ["File: com.apple.iCal", (done) => execFile(shim, ["scripts/calendar.applescript"], { cwd: process.cwd() }, done)],
      ["JXA: Safari", (done) => execFile(shim, ["-l", "JavaScript", "-e", 'Application("Safari").windows.length'], done)],
      ["Run-time target", (done) => execFile(shim, ["-e", 'set x to "Mail"', "-e", "tell application x to activate"], done)],
      ["System Events", (done) => execFile(shim, ["-e", 'tell application "System Events" to get name of every process'], done)],
    ],
  }),
};
