"use strict";
// A fixture command: Start sleeps for 37 s in a detached child (its own session, stdio ignored, unref'd) and for 38 s
// in an attached one, writing both pids to its support folder; the detached one outlives the view's close, the
// attached one is stopped with the host.
const { useState } = require("react");
const { jsx } = require("react/jsx-runtime");
const { Action, ActionPanel, List, environment } = require("@raycast/api");
const fs = require("fs");
const path = require("path");
const { spawn } = require("child_process");

function Command() {
  const [pids, setPids] = useState(null);
  const start = () => {
    const detached = spawn("/bin/sleep", ["37"], { detached: true, stdio: "ignore" });
    detached.unref();
    const attached = spawn("/bin/sleep", ["38"]);
    fs.mkdirSync(environment.supportPath, { recursive: true });
    fs.writeFileSync(path.join(environment.supportPath, "pids.json"), JSON.stringify({ detached: detached.pid, attached: attached.pid }));
    setPids(`detached ${detached.pid}, attached ${attached.pid}`);
  };
  return jsx(List, {
    children: jsx(List.Item, {
      id: "start", title: "Start", subtitle: pids ?? "not started",
      actions: jsx(ActionPanel, { children: jsx(Action, { title: "Start sleeps", onAction: start }) }),
    }, "start"),
  });
}

module.exports = { default: Command };
