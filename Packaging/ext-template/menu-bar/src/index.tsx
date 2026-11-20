// A menu-bar item made by `pilot ext new --mode menu-bar`: its title and icon sit in the menu bar, read again every
// `interval` (package.json), and its items show when it is clicked. Replace `reading` with what it should show.
import { Clipboard, Icon, MenuBarExtra } from "@raycast/api";

function reading(): string {
  const now = new Date();
  return `${now.getHours()}:${String(now.getMinutes()).padStart(2, "0")}`;
}

export default function Command() {
  const time = reading();
  return (
    <MenuBarExtra icon={Icon.Clock} title={time} tooltip="The time when it last read">
      <MenuBarExtra.Item title={`Read at ${time}`} />
      <MenuBarExtra.Item title="Copy It" onAction={() => Clipboard.copy(time)} />
    </MenuBarExtra>
  );
}
