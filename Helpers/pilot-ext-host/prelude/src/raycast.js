// Pilot's clean-room `@raycast/api` (ADR 0017), written from developers.raycast.com only: each view component renders
// a host element named after it, which host.js turns into the list or detail answer Pilot draws. An item's or a
// detail's `actions` prop (an ActionPanel) is mounted as its child, so each Action is a committed host element whose
// `onAction` Pilot presses by its handler id (T2); a detail's `metadata` is mounted the same way. T3 adds the common
// typed actions (open, copy, paste, show in Finder), Detail's metadata, toast and HUD, Clipboard, LocalStorage and
// Cache in ADR 0010's folders, `open`, `showInFinder` and the environment. Anything that acts on the Mac goes to Pilot
// as an ADR 0010 line (a no-view command's `hud` and `action`, a view's `toast` and `action`), so Pilot performs it and
// `pilot ext run` answers it unperformed. T8 adds the view stack: `Action.Push` and `useNavigation()`, whose push and
// pop host.js performs on the run's layers. T10 adds the Form and its items, which form.js turns into fields, and
// Action.SubmitForm. T11 adds `AI.ask` and `getSelectedText`, which ask Pilot (asks.js), and `confirmAlert`, which asks
// in the panel (alert.js). T12 adds MenuBarExtra and its parts (menubar.js). Every other Raycast export is a stub that
// records its use (gaps.js).
import { createContext, createElement, useContext } from "react";
import { guard, missing, record, store, stubs } from "./gaps.js";
import { childProcess, path } from "./node.js";
import { askAI, selectedText } from "./asks.js";
import { confirmAlert } from "./alert.js";
import { menuBarComponents } from "./menubar.js";

const native = globalThis.__native;

function host(name) {
  const component = (props) => createElement(name, props);
  component.displayName = name;
  return component;
}

/** A host element whose `metadata` and `actions` props are mounted under it, after its own children. */
function withParts(name) {
  const component = (props) => createElement(name, props, props.children, props.metadata ?? null, props.actions ?? null);
  component.displayName = name;
  return component;
}

/** An API Pilot lacks that answers a Promise in Raycast: its use is recorded and the Promise rejects, so an
 *  extension's own `.catch` handles it, as it would a failure (T7: Obsidian's getDefaultApplication). */
function rejecting(api) {
  const call = missing(api);
  return (...args) => { try { return Promise.resolve(call(...args)); } catch (error) { return Promise.reject(error); } };
}

/** An action Pilot lacks: rendering it records it, and it shows nothing, so the rest of its panel still works. */
function lacking(api) {
  const component = () => { record(api); return null; };
  component.displayName = api;
  return component;
}

/** A Metadata component and its parts, named under `owner`. */
function metadata(owner) {
  const tree = host(`${owner}.Metadata`);
  for (const part of ["Label", "Link", "TagList", "Separator"]) tree[part] = host(`${owner}.Metadata.${part}`);
  tree.TagList.Item = host(`${owner}.Metadata.TagList.Item`);
  return tree;
}

export const List = host("List");
List.Item = withParts("List.Item");
// An item's side detail (`detail` with isShowingDetail) is built but not drawn yet.
List.Item.Detail = host("List.Item.Detail");
List.Item.Detail.Metadata = metadata("List.Item.Detail");
List.Section = host("List.Section");
List.EmptyView = host("List.EmptyView");
List.Dropdown = lacking("List.Dropdown");
List.Dropdown.Item = () => null;
List.Dropdown.Section = () => null;

export const Detail = withParts("Detail");
Detail.Metadata = metadata("Detail");

export const ActionPanel = host("ActionPanel");
ActionPanel.Section = host("ActionPanel.Section");
ActionPanel.Submenu = host("ActionPanel.Submenu");
export const Action = host("Action");
for (const name of ["OpenInBrowser", "CopyToClipboard", "Paste", "Open", "OpenWith", "ShowInFinder"]) Action[name] = host(`Action.${name}`);
// A push is pressed by its handler id as an Action's onAction is; host.js mounts its `target` over the view (T8).
Action.Push = host("Action.Push");
// SubmitForm is pressed by its handler id; form.js hands onSubmit the form's values (T10).
Action.SubmitForm = host("Action.SubmitForm");
for (const name of ["CreateQuicklink", "CreateSnippet", "Trash", "PickDate", "ToggleQuickLook", "OpenInBrowserTab"]) {
  Action[name] = lacking(`Action.${name}`);
}
Action.Style = Object.freeze({ Regular: "regular", Destructive: "destructive" });

export const Form = withParts("Form");
for (const name of ["TextField", "PasswordField", "TextArea", "Checkbox", "DatePicker", "Dropdown", "FilePicker", "Separator", "Description"]) {
  Form[name] = host(`Form.${name}`);
}
Form.Dropdown.Item = host("Form.Dropdown.Item");
Form.Dropdown.Section = host("Form.Dropdown.Section");
Form.DatePicker.Type = Object.freeze({ Date: "date", DateTime: "dateTime" });
/** Whether `date` is a whole day, as a Date-only pick gives it: local midnight. */
Form.DatePicker.isFullDay = (date) => date instanceof Date && date.getHours() === 0 && date.getMinutes() === 0 && date.getSeconds() === 0 && date.getMilliseconds() === 0;
Form.TagPicker = lacking("Form.TagPicker");
Form.TagPicker.Item = () => null;
Form.LinkAccessory = lacking("Form.LinkAccessory");

/** The run's view stack (host.js provides it to every layer): `push(view, onPop)` mounts a view over the current one,
 *  `pop()` goes back to the one under it, its state kept. */
export const Navigation = createContext(null);

export const MenuBarExtra = menuBarComponents(host);
const useNavigation = () => useContext(Navigation);

/** Raycast's named constants (Icon, Color): each name answers itself, so `Icon.Checkmark` is "Checkmark" (host.js maps an Icon name to its SF Symbol, T5). */
const names = () => new Proxy({}, { get: (_, key) => (typeof key === "string" ? key : undefined) });
const shortcut = () => new Proxy({}, { get: (_, key) => (typeof key === "string" ? Object.freeze({ modifiers: [], key: "" }) : undefined) });

/** What a run sends Pilot beside its view: one line, built by the caller. */
const send = (line) => native.write(JSON.stringify(line));

/** The text a Raycast clipboard content carries: a string or number, or `{ text }`; a file or HTML is not here yet. */
function clipText(content) {
  if (typeof content === "string" || typeof content === "number") return String(content);
  if (content && typeof content.text === "string") return content.text;
  if (content && (content.file || content.html)) record(`Clipboard ${content.file ? "file" : "html"} content`);
  return undefined;
}

/** Each effect as the ADR 0010 action Pilot performs, for the typed actions (host.js) and the calls below alike; nil
 *  when it has nothing to act on. Raycast's show in Finder reveals its file; Pilot's open action opens its folder. */
export const effects = {
  open: (target) => (target ? { type: "open", url: String(target) } : undefined),
  reveal: (file) => (file ? { type: "open", url: path.dirname(String(file)) } : undefined),
  copy: (content) => { const text = clipText(content); return text === undefined ? undefined : { type: "copy", text }; },
  paste: (content) => { const text = clipText(content); return text === undefined ? undefined : { type: "paste", text }; },
};

/** The API for the run `message` of a command run in `mode` (view or no-view), its extension's folder the host's cwd. */
export function makeAPI(message, mode) {
  const preferences = Object.freeze({ ...(message.preferences ?? {}) });
  const data = message.paths?.data ?? "", cache = message.paths?.cache ?? "";
  const noView = mode === "no-view";
  /** An effect Pilot performs: an ADR 0010 action line, or a refusal when it has nothing Pilot can act on. */
  const act = (action, what) => {
    if (!action) return Promise.reject(new Error(`Pilot ${what} text only yet`));
    send({ type: "action", action });
    return Promise.resolve();
  };
  const hud = (text) => { send({ type: "hud", text: String(text ?? "") }); return Promise.resolve(); };

  // MARK: Toast and HUD

  const Style = Object.freeze({ Success: "success", Failure: "failure", Animated: "animated" });
  class Toast {
    static Style = Style;
    #shown = false;
    constructor(options) { Object.assign(this, { style: Style.Success, title: "", message: undefined }, options); }
    /** A no-view run has no window, so its toast is its HUD line, as Raycast shows one once its window is gone. */
    show() {
      this.#shown = true;
      const text = [this.title, this.message].filter(Boolean).join(": ");
      if (noView) hud(text); else send({ type: "toast", style: this.style, title: String(this.title ?? ""), message: this.message == null ? undefined : String(this.message) });
      return Promise.resolve();
    }
    hide() { if (this.#shown && !noView) send({ type: "toast", hide: true }); this.#shown = false; return Promise.resolve(); }
  }
  async function showToast(options, title, toastMessage) {
    const toast = new Toast(typeof options === "string" ? { style: options, title, message: toastMessage } : options);
    await toast.show();
    return toast;
  }

  // MARK: Clipboard, open and Finder

  const Clipboard = stubs("Clipboard", ["clear", "readHTML"], {
    copy: (content) => act(effects.copy(content), "copies"),
    paste: (content) => act(effects.paste(content), "pastes"),
    readText: () => new Promise((resolve) => { childProcess.execFile("/usr/bin/pbpaste", [], (error, stdout) => resolve(error ? undefined : stdout)); }),
    async read() { const text = await Clipboard.readText(); return { text }; },
  });
  function open(target, application) {
    if (application) record("open with an application");
    return act(effects.open(target), "opens");
  }
  const showInFinder = (file) => act(effects.reveal(file), "reveals");

  // MARK: LocalStorage and Cache, in ADR 0010's data and cache folders

  const local = store(data ? `${data}/.raycast-local-storage.json` : "");
  const LocalStorage = {
    getItem: async (key) => local.read()[String(key)],
    setItem: async (key, value) => { const o = local.read(); o[String(key)] = value; local.write(o); },
    removeItem: async (key) => { const o = local.read(); delete o[String(key)]; local.write(o); },
    allItems: async () => local.read(),
    clear: async () => { local.write({}); },
  };

  class Cache {
    #store;
    #subscribers = new Set();
    constructor(options = {}) {
      const name = String(options.namespace ?? "default").replace(/[^A-Za-z0-9._-]/g, "_");
      this.#store = store(cache ? `${cache}/raycast-cache-${name}.json` : "");
      // Bound, as Raycast's are: @raycast/utils hands `cache.subscribe` to useSyncExternalStore on its own (T7).
      for (const m of ["get", "has", "set", "remove", "clear", "subscribe"]) this[m] = this[m].bind(this);
    }
    get isEmpty() { return Object.keys(this.#store.read()).length === 0; }
    get(key) { const v = this.#store.read()[String(key)]; return typeof v === "string" ? v : undefined; }
    has(key) { return this.get(key) !== undefined; }
    set(key, value) { const o = this.#store.read(); o[String(key)] = String(value); this.#store.write(o); this.#tell(String(key), String(value)); }
    remove(key) { const o = this.#store.read(), had = String(key) in o; delete o[String(key)]; this.#store.write(o); this.#tell(String(key), undefined); return had; }
    clear(options = {}) { this.#store.write({}); if (options.notifySubscribers !== false) this.#tell(undefined, undefined); }
    subscribe(fn) { this.#subscribers.add(fn); return () => this.#subscribers.delete(fn); }
    #tell(key, value) { for (const fn of this.#subscribers) fn(key, value); }
  }

  // MARK: AI, through the provider on Pilot's AI page (T11)

  const AI = stubs("AI", [], {
    ask: askAI, Model: names(),
    Creativity: Object.freeze({ None: "none", Low: "low", Medium: "medium", High: "high", Maximum: "maximum" }),
  });

  // MARK: The environment

  const environment = Object.freeze({
    commandName: message.command, commandMode: mode, extensionName: message.extension, launchType: message.launchType ?? "userInitiated",
    supportPath: data, assetsPath: `${native.cwd()}/assets`, raycastVersion: "", isDevelopment: false, textSize: "medium",
    appearance: "dark", theme: "dark", ownerOrAuthorName: "",
    /** Pilot has AI (T11), through its AI page's provider, and answers false for the APIs it lacks (browser and window
     *  management): Raycast's docs say to ask before using one. */
    canAccess: (api) => api === AI,
  });

  const api = {
    List, Detail, ActionPanel, Action, Toast, showToast, showHUD: hud, Clipboard, open, showInFinder, LocalStorage, Cache, environment,
    getPreferenceValues: () => preferences, useNavigation,
    closeMainWindow: () => Promise.resolve(), popToRoot: () => Promise.resolve(), clearSearchBar: () => Promise.resolve(),
    Icon: names(), Color: names(), Image: Object.freeze({ Mask: Object.freeze({ Circle: "circle", RoundedRectangle: "roundedRectangle" }) }),
    Keyboard: Object.freeze({ Shortcut: Object.freeze({ Common: shortcut() }) }),
    LaunchType: Object.freeze({ UserInitiated: "userInitiated", Background: "background" }),
    PopToRootType: Object.freeze({ Default: "default", Immediate: "immediate", Suspended: "suspended" }),
    Alert: stubs("Alert", [], { ActionStyle: Object.freeze({ Default: "default", Cancel: "cancel", Destructive: "destructive" }) }),
    // Views and namespaces that come in later tasks, or not at all: each records its use.
    // A view Pilot lacks records and throws on render, so the run shows why it has nothing to draw.
    Form,
    Grid: Object.assign(missing("Grid"), { Inset: names(), Fit: names(), ItemSize: names() }), MenuBarExtra,
    AI, getSelectedText: selectedText, confirmAlert: (options) => confirmAlert(options, noView),
    OAuth: stubs("OAuth", ["PKCEClient"], { RedirectMethod: Object.freeze({ Web: "web", App: "app", AppURI: "appURI" }) }),
    BrowserExtension: stubs("BrowserExtension", ["getContent", "getTabs"]),
    WindowManagement: stubs("WindowManagement", ["getActiveWindow", "getWindowsOnActiveDesktop", "getDesktops", "setWindowBounds"]),
  };
  for (const name of ["trash", "getApplications", "getDefaultApplication", "getFrontmostApplication", "getSelectedFinderItems",
    "launchCommand", "updateCommandMetadata", "openExtensionPreferences", "openCommandPreferences"]) {
    api[name] = rejecting(name);
  }
  api.captureException = missing("captureException");
  return guard("", api);
}
