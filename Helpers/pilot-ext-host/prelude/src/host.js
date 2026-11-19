// The React side of pilot-ext-host (ADR 0017): a react-reconciler host that commits into a plain tree, and the
// serializer that turns each commit into the list or detail answer of Pilot's private wire (ADR 0010's lines). Every
// commit that changes the answer is written, so data that arrives after the first render fills the view in.
import { createContext, createElement } from "react";
import Reconciler from "react-reconciler";
import { ConcurrentRoot, DefaultEventPriority, NoEventPriority } from "react-reconciler/constants";

const native = globalThis.__native;

let priority = NoEventPriority;
const noop = () => {};
const hostConfig = {
  supportsMutation: true, supportsPersistence: false, supportsHydration: false, supportsMicrotasks: true,
  isPrimaryRenderer: true, noTimeout: -1, warnsIfNotActing: false,
  rendererPackageName: "pilot-ext-host", rendererVersion: "1",
  NotPendingTransition: null, HostTransitionContext: createContext(null),
  createInstance: (type, props) => ({ type, props, children: [] }),
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

function item(node, section) {
  const p = node.props;
  const row = { title: words(p.title) ?? "", actions: [] };
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

function rows(nodes, section, out) {
  for (const node of nodes) {
    if (node.type === "List.Item") out.push(item(node, section));
    else if (node.type === "List.Section") rows(node.children, words(node.props.title) ?? section, out);
    else if (node.children) rows(node.children, section, out);
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

function answer(container) {
  const root = view(container.children);
  if (!root) return null;
  if (root.type === "Detail") return { type: "detail", markdown: typeof root.props.markdown === "string" ? root.props.markdown : "", actions: [] };
  return { type: "list", items: rows(root.children, undefined, []) };
}

// MARK: The run

/** Writes one wire line; a line Pilot can't read is never sent. */
function send(message) {
  native.write(JSON.stringify(message));
}

export function fail(error) {
  const text = error instanceof Error ? error.message : String(error);
  console.error(error instanceof Error && error.stack ? `${text}\n${error.stack}` : text);
  send({ type: "error", text: text.slice(0, 300) });
}

/** Renders the command `component` for the run `message`, writing each changed answer. */
export function render(component, message) {
  let last = null, queued = false;
  const container = {
    children: [],
    committed() {
      if (queued) return;
      queued = true;
      queueMicrotask(() => {
        queued = false;
        const now = answer(container);
        if (!now) return;
        const line = JSON.stringify(now);
        if (line !== last) { last = line; native.write(line); }
      });
    },
  };
  // Only an error no boundary caught is the run's error line; one a boundary caught, or React recovered from, leaves the
  // boundary's fallback on screen and goes to stderr alone.
  const logged = (error) => console.error(error instanceof Error && error.stack ? `${error.message}\n${error.stack}` : String(error));
  const root = reconciler.createContainer(container, ConcurrentRoot, null, false, null, "", fail, logged, logged, noop);
  const props = { arguments: message.arguments ?? {}, launchType: "userInitiated", launchContext: message.context };
  reconciler.updateContainer(createElement(component, props), root, null, null);
  return {
    /** A later search: the List's own onSearchTextChange, when it takes one. */
    search(text) {
      const list = view(container.children);
      const handler = list?.props?.onSearchTextChange;
      if (typeof handler === "function") handler(text);
    },
    close() { reconciler.updateContainer(null, root, null, null); },
  };
}
