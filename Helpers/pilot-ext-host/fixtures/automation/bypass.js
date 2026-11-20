"use strict";
// Every way T9's reviews 1 and 2 named Music past the check, each run through the shim (never the real osascript): AppleScript
// in another case, JXA with a space before its parenthesis, a login shell's -lc line, env, a shell line whose script comes in
// a variable, and a target built at run time. Each must ask, or be refused while Music is refused.
const { spawn, execFile, exec } = require("child_process");
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

function viaZsh(done) {
  const child = spawn("/bin/zsh", ["-lc", `'${shim}' -e 'tell app "Music" to playpause'`]);
  let out = "";
  child.stdout?.on("data", (d) => { out += d; });
  child.on("error", (error) => done(error));
  child.on("close", (code) => done(code === 0 ? null : new Error(`exit ${code}`), out));
}

module.exports = {
  default: () => jsx(Calls, {
    calls: [
      ["Case", (done) => execFile(shim, ["-e", 'Tell Application "Music" to playpause'], done)],
      ["JXA space", (done) => execFile(shim, ["-l", "JavaScript", "-e", 'Application ("Music").playpause()'], done)],
      ["zsh -lc", viaZsh],
      ["env", (done) => execFile("/usr/bin/env", [shim, "-e", 'tell app "Music" to playpause'], done)],
      ["Variable", (done) => exec(`'${shim}' -e "$S"`, { env: { ...process.env, S: 'tell app "Music" to playpause' } }, done)],
      ["Built at run time", (done) => execFile(shim, ["-e", 'set x to "Music"', "-e", "tell application x to playpause"], done)],
      // Review 2: a JXA comment's apostrophe that would open a false string over Application(name), and a shell line with
      // two osascript calls, the first a script file.
      ["Comment apostrophe", (done) => execFile(shim, ["-l", "JavaScript", "-e", "// Don't steal focus\nconst name = \"Music\"; Application(name).playpause(); const q = 'x';"], done)],
      ["Two scripts", (done) => exec(`'${shim}' scripts/music.applescript && '${shim}' -e 'tell app "Finder" to activate'`, { cwd: process.cwd() }, done)],
    ],
  }),
};
