// Pilot's clean-room `@raycast/api` (ADR 0017), written from developers.raycast.com only: each view component renders
// a host element named after it, which host.js turns into the list or detail answer Pilot draws. T1 holds List and
// Detail; ActionPanel and Action render nothing yet (callbacks are T2, actions T3), and the rest of the API comes later.
import { createElement } from "react";

function host(name) {
  const component = (props) => createElement(name, props);
  component.displayName = name;
  return component;
}

export const List = host("List");
List.Item = host("List.Item");
List.Section = host("List.Section");
List.EmptyView = host("List.EmptyView");
List.Dropdown = () => null;
List.Dropdown.Item = () => null;
List.Dropdown.Section = () => null;

export const Detail = host("Detail");

export const ActionPanel = () => null;
ActionPanel.Section = () => null;
ActionPanel.Submenu = () => null;
export const Action = () => null;
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
