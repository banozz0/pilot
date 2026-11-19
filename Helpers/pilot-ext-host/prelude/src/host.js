// The React side of pilot-ext-host (ADR 0017): a react-reconciler host that commits into a plain tree, and the
// serializer that turns each commit into the list or detail answer of Pilot's private wire (ADR 0010's lines). Every
// commit that changes the answer is written, so data that arrives after the first render fills the view in.
// Callbacks (T2): each Action's `onAction` goes out as an `invoke` action whose handler id is its host element's serial
// and the prop's name, so the id stays the same while the element lives and a press always reaches its newest props.
// Typed actions (T3) go out as the open, copy or paste action Pilot already performs, and a Detail's Metadata as its facts.
// The table is rebuilt on every answer; an id it lacks is stale. Each query or invoke Pilot numbers (`seq`) is
// answered by the next line, which carries `ack`: the commit it caused, else the current view again.
import { createContext, createElement } from "react";
import Reconciler from "react-reconciler";
import { ConcurrentRoot, DefaultEventPriority, DiscreteEventPriority, NoEventPriority } from "react-reconciler/constants";
import { effects } from "./raycast.js";

const native = globalThis.__native;

let priority = NoEventPriority, serials = 0;
const noop = () => {};
const hostConfig = {
  supportsMutation: true, supportsPersistence: false, supportsHydration: false, supportsMicrotasks: true,
  isPrimaryRenderer: true, noTimeout: -1, warnsIfNotActing: false,
  rendererPackageName: "pilot-ext-host", rendererVersion: "1",
  NotPendingTransition: null, HostTransitionContext: createContext(null),
  createInstance: (type, props) => ({ type, props, children: [], serial: ++serials }),
  createTextInstance: (text) => ({ text }),
  appendInitialChild: (parent, child) => { parent.children.push(child); },
  appendChild: (parent, child) => { move(parent.children, child); },
  appendChildToContainer: (container, child) => { move(container.children, child); },
  insertBefore: (parent, child, before) => { move(parent.children, child, before); },
  insertInContainerBefore: (container, child, before) => { move(container.children, child, before); },
  removeChild: (parent, child) => { remove(parent.children, child); },
  removeChildFromContainer: (container, child) => { remove(container.children, child); },
  commitUpdate: (instance, _type, _old, props) => { instance.props = props; },
  commitTextUpdate: (instance, _old, text) => { instance.text = text; },
  clearContainer: (container) => { container.children = []; },
  finalizeInitialChildren: () => false,
  shouldSetTextContent: () => false,
  getRootHostContext: () => null,
  getChildHostContext: (context) => context,
  getPublicInstance: (instance) => instance,
  prepareForCommit: () => null,
  resetAfterCommit: (container) => { container.committed(); },
  preparePortalMount: noop, resetTextContent: noop, commitMount: noop, detachDeletedInstance: noop,
  hideInstance: noop, unhideInstance: noop, hideTextInstance: noop, unhideTextInstance: noop,
  scheduleTimeout: (fn, ms) => setTimeout(fn, ms), cancelTimeout: (id) => clearTimeout(id),
  scheduleMicrotask: (fn) => queueMicrotask(fn),
  getCurrentUpdatePriority: () => priority,
  setCurrentUpdatePriority: (p) => { priority = p; },
  resolveUpdatePriority: () => priority || DefaultEventPriority,
  resolveEventType: () => null, resolveEventTimeStamp: () => -1.1, trackSchedulerEvent: noop,
  shouldAttemptEagerTransition: () => false, requestPostPaintCallback: noop,
  getInstanceFromNode: () => null, getInstanceFromScope: () => null, prepareScopeUpdate: noop,
  beforeActiveInstanceBlur: noop, afterActiveInstanceBlur: noop,
  maySuspendCommit: () => false, maySuspendCommitOnUpdate: () => false, maySuspendCommitInSyncRender: () => false,
  preloadInstance: () => true, startSuspendingCommit: noop, suspendInstance: noop, waitForCommitToBeReady: () => null,
  getSuspendedCommitReason: () => null, resetFormInstance: noop, bindToConsole: (fn, args) => fn.bind(console, ...args),
};

function move(list, child, before) {
  remove(list, child);
  const at = before ? list.indexOf(before) : -1;
  if (at < 0) list.push(child); else list.splice(at, 0, child);
}

function remove(list, child) {
  const at = list.indexOf(child);
  if (at >= 0) list.splice(at, 1);
}

const reconciler = Reconciler(hostConfig);

// MARK: The answer

/** A Raycast text prop: a string, or an object with a `value` (title, subtitle, accessory text). */
function words(value) {
  if (typeof value === "string") return value;
  if (typeof value === "number") return String(value);
  if (value && typeof value === "object" && (typeof value.value === "string" || typeof value.value === "number")) return String(value.value);
  return undefined;
}

/** An item's first accessory with text, as the word at its right. */
function accessory(accessories) {
  if (!Array.isArray(accessories)) return undefined;
  for (const a of accessories) {
    const text = words(a?.text) ?? words(a?.tag) ?? (a?.date instanceof Date ? a.date.toLocaleDateString() : undefined);
    if (text) return text;
  }
  return undefined;
}

/** A typed action (T3) as the ADR 0010 action Pilot performs itself (raycast.js's effects), with Raycast's title. */
const typed = {
  "Action.OpenInBrowser": (p) => [effects.open(p.url), "Open in Browser"],
  "Action.Open": (p) => [effects.open(p.target), undefined],
  "Action.OpenWith": (p) => [effects.open(p.path), "Open With"],
  "Action.ShowInFinder": (p) => [effects.reveal(p.path), "Show in Finder"],
  "Action.CopyToClipboard": (p) => [effects.copy(p.content), "Copy to Clipboard"],
  "Action.Paste": (p) => [effects.paste(p.content), "Paste"],
};

/** The Actions under `nodes` (an ActionPanel, its sections and submenus, flattened), in order: each pressable one as an
 *  invoke action, its handler entered in `handlers`, each typed one as the action it stands for. */
function actions(nodes, handlers, out = []) {
  for (const node of nodes) {
    if (node.type === "Action") {
      if (typeof node.props.onAction !== "function") continue;
      const handler = `${node.serial}.onAction`;
      handlers.set(handler, node);
      out.push({ type: "invoke", handler, title: words(node.props.title) || undefined });
    } else if (typed[node.type]) {
      const [action, title] = typed[node.type](node.props);
      if (action) out.push({ ...action, title: words(node.props.title) ?? title });
    } else if (node.type === "ActionPanel" || node.type === "ActionPanel.Section" || node.type === "ActionPanel.Submenu") actions(node.children, handlers, out);
  }
  return out;
}

/** A Detail's Metadata as Pilot's facts: a label's or link's text, a tag list's tags joined; separators drop. */
function facts(nodes) {
  const out = [];
  for (const node of nodes) {
    if (!node.type?.endsWith(".Metadata")) continue;
    for (const part of node.children) {
      const p = part.props ?? {}, label = words(p.title) ?? "";
      if (part.type.endsWith(".Label") || part.type.endsWith(".Link")) {
        const text = words(p.text);
        if (text) out.push({ label, text });
      } else if (part.type.endsWith(".TagList")) {
        const tags = part.children.map((t) => words(t.props?.text)).filter(Boolean);
        if (tags.length) out.push({ label, text: tags.join(", ") });
      }
    }
  }
  return out;
}

function item(node, section, handlers) {
  const p = node.props;
  const row = { title: words(p.title) ?? "", actions: actions(node.children, handlers) };
  if (p.id != null) row.id = String(p.id);
  const subtitle = words(p.subtitle);
  if (subtitle) row.subtitle = subtitle;
  if (Array.isArray(p.keywords) && p.keywords.length) row.keywords = p.keywords.filter((k) => typeof k === "string").join(" ");
  if (typeof p.icon === "string") row.icon = p.icon;
  const word = accessory(p.accessories);
  if (word) row.accessory = word;
  if (section) row.section = section;
  return row;
}

function rows(nodes, section, handlers, out) {
  for (const node of nodes) {
    if (node.type === "List.Item") out.push(item(node, section, handlers));
    else if (node.type === "List.Section") rows(node.children, words(node.props.title) ?? section, handlers, out);
    else if (node.children) rows(node.children, section, handlers, out);
  }
  return out;
}

/** The first List or Detail in the tree, depth first. */
function view(nodes) {
  for (const node of nodes) {
    if (node.type === "List" || node.type === "Detail") return node;
    const inner = node.children && view(node.children);
    if (inner) return inner;
  }
  return null;
}

/** The answer the tree shows, its handlers entered in `handlers`; a List still loading says so, so Pilot draws its
 *  loading row. */
function answer(container, handlers) {
  const root = view(container.children);
  if (!root) return null;
  if (root.type === "Detail") {
    const detail = { type: "detail", markdown: typeof root.props.markdown === "string" ? root.props.markdown : "", actions: actions(root.children, handlers) };
    const metadata = facts(root.children);
    if (metadata.length) detail.metadata = metadata;
    return detail;
  }
  const list = { type: "list", items: rows(root.children, undefined, handlers, []) };
  if (root.props.isLoading === true) list.isLoading = true;
  return list;
}

// MARK: The run

/** Writes one wire line; a line Pilot can't read is never sent. */
function send(message) {
  native.write(JSON.stringify(message));
}

/** The error line, answering request `ack` when one waits. */
export function fail(error, ack) {
  const text = error instanceof Error ? error.message : String(error);
  console.error(error instanceof Error && error.stack ? `${text}\n${error.stack}` : text);
  send({ type: "error", text: text.slice(0, 300), ack: typeof ack === "number" ? ack : undefined });
}

/** Renders the command `component` for the run `message`, writing each changed answer. */
export function render(component, message) {
  let last = null, queued = false, handlers = new Map(), ack = null;
  /** Writes the answer when it changed, or, when a request waits, with its `ack` even unchanged. */
  function flush() {
    const table = new Map();
    const now = answer(container, table) ?? (ack != null ? { type: "list", items: [] } : null);
    handlers = table;
    if (!now) return;
    const line = JSON.stringify(now);
    if (ack == null && line === last) return;
    last = line;
    // `now` is an object, so the ack goes in before its closing brace, the line stringified once.
    native.write(ack == null ? line : `${line.slice(0, -1)},"ack":${ack}}`);
    ack = null;
  }
  const container = {
    children: [],
    committed() {
      if (queued) return;
      queued = true;
      queueMicrotask(() => { queued = false; flush(); });
    },
  };
  // Only an error no boundary caught is the run's error line; one a boundary caught, or React recovered from, leaves the
  // boundary's fallback on screen and goes to stderr alone.
  const logged = (error) => console.error(error instanceof Error && error.stack ? `${error.message}\n${error.stack}` : String(error));
  const root = reconciler.createContainer(container, ConcurrentRoot, null, false, null, "", fail, logged, logged, noop);
  const props = { arguments: message.arguments ?? {}, launchType: "userInitiated", launchContext: message.context };
  reconciler.updateContainer(createElement(component, props), root, null, null);

  /** Request `seq`: `work` runs, its commit (flushed in this call's microtasks) carries the ack; when nothing committed,
   *  the current view goes again on the next turn. A throw is the error line, which answers it. */
  function request(seq, work) {
    ack = typeof seq === "number" ? seq : null;
    try {
      work();
    } catch (error) {
      const waiting = ack;
      ack = null;
      fail(error, waiting);
      return;
    }
    // Still waiting once this turn's commits flushed: nothing committed, so the current view answers.
    const mine = ack;
    if (mine != null) setTimeout(() => { if (ack === mine) flush(); }, 0);
  }

  return {
    /** A later search: the List's own onSearchTextChange, when it takes one. */
    search(text, seq) {
      request(seq, () => {
        const list = view(container.children);
        const handler = list?.props?.onSearchTextChange;
        if (typeof handler === "function") handler(text);
      });
    },
    /** A press: the callback `id` names in the newest answer, called with the element's props as they are now, at a
     *  discrete event's priority so its update renders at once, as a click's does. A stale id answers the current view. */
    invoke(id, seq) {
      request(seq, () => {
        const node = handlers.get(id);
        const callback = node?.props?.[String(id).split(".").pop()];
        if (typeof callback !== "function") return console.error(`no handler ${id} in the current view: answering it unchanged`);
        const before = priority;
        priority = DiscreteEventPriority;
        try {
          const result = callback();
          if (result && typeof result.then === "function") result.then(undefined, (error) => fail(error));
        } finally {
          priority = before;
        }
      });
    },
    close() { reconciler.updateContainer(null, root, null, null); },
  };
}
