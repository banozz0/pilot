// Pilot's clean-room `@raycast/api` (ADR 0017), written from developers.raycast.com only: each view component renders
// a host element named after it, which host.js turns into the list or detail answer Pilot draws. An item's or a
// detail's `actions` prop (an ActionPanel) is mounted as its child, so each Action is a committed host element whose
// `onAction` Pilot presses by its handler id (T2). The typed actions (Action.OpenInBrowser and the rest) come in T3,
// submenus later; until then they render nothing.
import { createElement } from "react";

function host(name) {
  const component = (props) => createElement(name, props);
  component.displayName = name;
  return component;
}

/** A host element whose `actions` prop is mounted under it, after its own children. */
function withActions(name) {
  const component = (props) => createElement(name, props, props.children, props.actions ?? null);
  component.displayName = name;
  return component;
}

export const List = host("List");
List.Item = withActions("List.Item");
List.Section = host("List.Section");
List.EmptyView = host("List.EmptyView");
List.Dropdown = () => null;
List.Dropdown.Item = () => null;
List.Dropdown.Section = () => null;

export const Detail = withActions("Detail");

export const ActionPanel = host("ActionPanel");
ActionPanel.Section = host("ActionPanel.Section");
ActionPanel.Submenu = () => null;
export const Action = host("Action");
for (const name of ["OpenInBrowser", "CopyToClipboard", "Paste", "Push", "Open", "ShowInFinder", "SubmitForm"]) Action[name] = () => null;

/** The run message's preference values by name, as Pilot resolved them. */
export function makeAPI(message) {
  const preferences = Object.freeze({ ...(message.preferences ?? {}) });
  return {
    List, Detail, ActionPanel, Action,
    getPreferenceValues: () => preferences,
    environment: Object.freeze({
      commandName: message.command, extensionName: message.extension, launchType: "userInitiated",
      supportPath: message.paths?.data ?? "", raycastVersion: "", isDevelopment: false, textSize: "medium",
      appearance: "dark", theme: "dark",
    }),
    LaunchType: Object.freeze({ UserInitiated: "userInitiated", Background: "background" }),
  };
}
