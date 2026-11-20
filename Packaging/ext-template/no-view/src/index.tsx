// A command made by `pilot ext new --mode no-view`: no window, it does its one thing and says so in a HUD. Replace the
// body with what the command should do.
import { Clipboard, showHUD } from "@raycast/api";

export default async function Command() {
  const stamp = new Date().toISOString().slice(0, 16).replace("T", " ");
  await Clipboard.copy(stamp);
  await showHUD(`Copied ${stamp}`);
}
