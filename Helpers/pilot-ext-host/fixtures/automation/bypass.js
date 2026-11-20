"use strict";
// T9's regression corpus: every way reviews 1 to 3 named Music past the check, each run through the shim (never the
// real osascript), plus runAppleScript's own shapes. Run while Music is refused, each call must fail: by Music's refusal
// when Pilot reads it in full (its app named), else as the unread app, which cannot stand beside a refusal. None may run.
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

const music = 'tell app "Music" to playpause';

module.exports = {
  default: () => jsx(Calls, {
    calls: [
      // Read in full: Music by name.
      ["Case", (done) => execFile(shim, ["-e", 'Tell Application "Music" to playpause'], done)],
      ["runAppleScript", (done) => viaStdin(shim, [], 'tell application "Music" to playpause', done, utilsEnv)],
      ["runAppleScript -ss", (done) => viaStdin(shim, ["-ss"], 'tell application "Music" to playpause', done, utilsEnv)],
      ["runAppleScript JXA", (done) => viaStdin(shim, ["-l", "JavaScript", "-", "x"], 'Application("Music").playpause()', done, utilsEnv)],
      // Review 1: wrappers and targets built at run time.
      ["JXA space", (done) => execFile(shim, ["-l", "JavaScript", "-e", 'Application ("Music").playpause()'], done)],
      ["zsh -fc", (done) => viaStdin("/bin/zsh", ["-fc", `'${shim}' -e '${music}'`], "", done)],
      ["env", (done) => execFile("/usr/bin/env", [shim, "-e", music], done)],
      ["Variable", (done) => exec(`'${shim}' -e "$S"`, { env: { ...process.env, S: music } }, done)],
      ["Built at run time", (done) => execFile(shim, ["-e", 'set x to "Music"', "-e", "tell application x to playpause"], done)],
      // Review 2: a comment's apostrophe, two scripts on one shell line.
      ["Comment apostrophe", (done) => execFile(shim, ["-l", "JavaScript", "-e", "// Don't steal focus\nconst name = \"Music\"; Application(name).playpause(); const q = 'x';"], done)],
      ["Two scripts", (done) => exec(`'${shim}' scripts/music.applescript && '${shim}' -e 'tell app "Finder" to activate'`, { cwd: process.cwd() }, done)],
      // Review 3: xargs, -l inside a script line, a quoted name over lines, JXA's doShellScript.
      ["xargs path", (done) => viaStdin("/usr/bin/xargs", [shim], "scripts/music.applescript", done, { cwd: process.cwd() })],
      ["xargs -e", (done) => viaStdin("/usr/bin/xargs", [shim, "-e"], music, done)],
      ["-l in a line", (done) => execFile(shim, ["-e", 'set x to "Music" -- -l javascript', "-e", "tell application x to playpause"], done)],
      ["Name over lines", (done) => execFile(shim, ["-e", '"application (\'Notes........"\nset x to "Music"\ntell application x to playpause\n"\')"'], done)],
      ["doShellScript", (done) => execFile(shim, ["-l", "JavaScript", "-e", 'Application.currentApplication().doShellScript("osascript scripts/music.applescript")'], done)],
      // And the rest of the class: a joined name, a computed JXA name, a script file, a nested osascript.
      ["Joined name", (done) => execFile(shim, ["-e", 'tell application "Mu" & "sic" to playpause'], done)],
      ["Computed JXA", (done) => execFile(shim, ["-l", "JavaScript", "-e", 'this["Appli" + "cation"]("Music").playpause()'], done)],
      ["Script file", (done) => execFile(shim, ["scripts/music.applescript"], { cwd: process.cwd() }, done)],
      ["do shell script", (done) => execFile(shim, ["-e", 'do shell script "osascript -e \'tell app \\"Music\\" to playpause\'"'], done)],
    ],
  }),
};
