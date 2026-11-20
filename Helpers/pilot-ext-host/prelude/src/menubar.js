// Raycast's MenuBarExtra (T12), written from developers.raycast.com's Menu Bar Commands page (read 2026-11-20): a
// `menu-bar` command's view, which Pilot draws as a top-bar item. Its answer depends on who asks:
// - A bar render (`"surface": "bar"`, one host run per tick) answers a `bar` line: the extra's title as the item's text,
//   its icon as the bar line's `symbol` or `image` (an emoji goes before the text), and its menu as a display-only list
//   block for the popover to show until its own answer comes. That host exits soon after, so the line carries no
//   handlers. The run ends once the extra committed with `isLoading` not true and every picture landed (main.swift's
//   barReady), as Raycast unloads a menu-bar command then; at 9.5 s at the latest (Pilot gives a bar render 10 s).
// - An open popover (no surface: Pilot keeps the host while it shows, ExtensionSession) answers a `list` of the menu's
//   rows: each Item a row whose action is `<serial>.onAction`, its `alternate` (the ⌥ item) a second action, a
//   Section's or Submenu's title the rows' section, a Separator nothing. An Item without onAction is a row with no
//   action, as Raycast draws it disabled. A press calls onAction with `{ type: "left-click" }`.
// - A one-shot popover ask (`"surface": "popover"`, ADR 0010's old route) answers the menu as display-only blocks.
// A command that renders no MenuBarExtra (Raycast: returning null removes the item) answers an empty bar line.
import { createElement } from "react";

/** The extra's components; an Item's `alternate` is mounted under it, so its onAction is a committed element too. */
export function menuBarComponents(host) {
  const MenuBarExtra = host("MenuBarExtra");
  const item = (props) => createElement("MenuBarExtra.Item", props, props.alternate ?? null);
  item.displayName = "MenuBarExtra.Item";
  MenuBarExtra.Item = item;
  MenuBarExtra.Section = host("MenuBarExtra.Section");
  MenuBarExtra.Submenu = host("MenuBarExtra.Submenu");
  MenuBarExtra.Separator = host("MenuBarExtra.Separator");
  return MenuBarExtra;
}

/** The menu's rows under `nodes`, each with its actions entered in `handlers` when `pressable`. */
function rows(nodes, section, words, picture, handlers, pressable, out) {
  for (const node of nodes) {
    const p = node.props ?? {};
    if (node.type === "MenuBarExtra.Item") {
      const row = { title: words(p.title) ?? "", actions: [] };
      const subtitle = words(p.subtitle);
      if (subtitle) row.subtitle = subtitle;
      Object.assign(row, picture(p.icon));
      if (section) row.section = section;
      if (pressable) {
        for (const one of [node, ...node.children.filter((c) => c.type === "MenuBarExtra.Item")]) {
          if (typeof one.props.onAction !== "function") continue;
          const handler = `${one.serial}.onAction`;
          handlers.set(handler, one);
          row.actions.push({ type: "invoke", handler, title: words(one.props.title) || row.title || undefined });
        }
      }
      out.push(row);
    } else if (node.type === "MenuBarExtra.Section" || node.type === "MenuBarExtra.Submenu") {
      rows(node.children, words(p.title) ?? section, words, picture, handlers, pressable, out);
    } else if (node.type !== "MenuBarExtra.Separator" && node.children) {
      rows(node.children, section, words, picture, handlers, pressable, out);
    }
  }
  return out;
}

/** The answer `root` (a MenuBarExtra, or null when the command rendered none) gives the run's `surface`. */
export function menuBarAnswer(root, surface, handlers, words, picture) {
  if (surface === "bar") {
    if (!root) return { type: "bar", text: "" };
    const p = root.props, face = picture(p.icon), title = words(p.title) ?? "";
    const line = { type: "bar", text: face.icon ? [face.icon, title].filter(Boolean).join(" ") : title };
    if (face.symbol) line.symbol = face.symbol;
    if (face.image) line.image = face.image;
    const menu = rows(root.children, undefined, words, picture, handlers, false, []);
    if (menu.length) line.blocks = [{ type: "list", items: menu }];
    return line;
  }
  if (!root) return null;
  if (surface === "popover") return { type: "blocks", blocks: [{ type: "list", items: rows(root.children, undefined, words, picture, handlers, false, []) }] };
  const list = { type: "list", items: rows(root.children, undefined, words, picture, handlers, true, []) };
  if (root.props.isLoading === true) list.isLoading = true;
  return list;
}

/** A bar render is done once the extra committed not loading (or the command rendered none) and no picture waits. */
export const menuBarReady = (root, picturesWaiting) => (!root || root.props.isLoading !== true) && !picturesWaiting;

/** A popover press of an Item: its onAction with Raycast's left-click event; nil for any other element. */
export function menuBarPress(word, node) {
  if (node?.type !== "MenuBarExtra.Item" || !word.endsWith(".onAction")) return undefined;
  const onAction = node.props.onAction;
  return typeof onAction === "function" ? () => onAction({ type: "left-click" }) : undefined;
}
