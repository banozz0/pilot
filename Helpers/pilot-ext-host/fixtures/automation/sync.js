"use strict";
// Finder, through execFileSync at mount: a sync call cannot wait for an answer, so it fails with EAGAIN while Pilot asks.
const { execFileSync } = require("child_process");
// Each command is one file in the shape Raycast's build emits (CommonJS, React and @raycast/api left to the host).
// Every call runs shim/osascript by its absolute path, so no PATH lookup can reach the real one.
const { useEffect, useState } = require("react");
const { jsx } = require("react/jsx-runtime");
const { List } = require("@raycast/api");

const shim = `${process.cwd()}/shim/osascript`;

/** One row: the call's name, then what the shim printed or the error it failed with; loading while it waits, as an
 *  extension running AppleScript at mount is, so Pilot takes the answer after it (the ask, or the row). */
function Call({ name, run }) {
  const [said, setSaid] = useState("waiting");
  useEffect(() => {
    run((error, stdout) => setSaid(error ? `error ${error.code ?? ""}: ${error.message}` : String(stdout).trim()));
  }, []);
  return jsx(List, { isLoading: said === "waiting", children: jsx(List.Item, { id: name, title: name, subtitle: said }) });
}

function once(done) {
  try { done(null, execFileSync(shim, ["-e", 'tell application "Finder" to get name of every disk'])); } catch (error) { done(error); }
}

module.exports = { default: () => jsx(Call, { name: "Finder (sync)", run: once }) };
