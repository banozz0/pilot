"use strict";
// Notes again, from another extension: one extension's Allow is not another's, so this one is asked too.
const { execFile } = require("child_process");
const { useEffect, useState } = require("react");
const { jsx } = require("react/jsx-runtime");
const { List } = require("@raycast/api");

function Command() {
  const [said, setSaid] = useState("waiting");
  useEffect(() => {
    execFile(`${process.cwd()}/shim/osascript`, ["-e", 'tell application "Notes" to get name of every note'], (error, stdout) => {
      setSaid(error ? `error ${error.code}: ${error.message}` : String(stdout).trim());
    });
  }, []);
  return jsx(List, { isLoading: said === "waiting", children: jsx(List.Item, { id: "notes", title: "Notes", subtitle: said }) });
}

module.exports = { default: Command };
