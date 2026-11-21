// A page made by `pilot ext new --mode detail`: one Markdown text, built when the command opens. Replace `page` with
// what the command should show.
import { Action, ActionPanel, Detail } from "@raycast/api";
import os from "node:os";

function page(): string {
  const now = new Date().toLocaleString();
  return ["# Example", "", `This Mac is **${os.hostname()}**, and it is ${now}.`].join("\n");
}

export default function Command() {
  const markdown = page();
  return (
    <Detail
      markdown={markdown}
      actions={
        <ActionPanel>
          <Action.CopyToClipboard title="Copy Page" content={markdown} />
        </ActionPanel>
      }
    />
  );
}
