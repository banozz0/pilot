// Raycast's `confirmAlert` (ADR 0017, T11), written from developers.raycast.com's Alert page (read 2026-11-20): it asks
// in the open view's panel. While an alert is up it takes the view's place as two rows under the alert's title, its
// message their subtitle: the primary action, then the dismiss action. Each is a callback Pilot presses as any row's
// (T2), `alert.<n>.confirm` or `alert.<n>.dismiss`, the alert's number in it so a press meant for an earlier alert is
// stale; Escape (`navigation.pop`) dismisses it. The promise resolves true for the primary action and false for the
// dismiss, after that action's own `onAction`, and the view under it comes back as it was. An alert asked while one is
// up waits its turn. A no-view command has no panel to ask in, so its confirmAlert fails with a clear error, and what
// it guards never runs. The rows carry the search as keywords, so Pilot's filter of the view keeps them.
import { record } from "./gaps.js";

const queue = [];
let serials = 0, redraw = () => {};

/** How the run draws its view again once an alert comes or goes (host.js). */
export function setRedraw(fn) { redraw = fn; }

const text = (value) => (typeof value === "string" || typeof value === "number" ? String(value) : "");

/** Raycast's `confirmAlert(options)`; `noView` when the command has no view to ask in. */
export function confirmAlert(options, noView) {
  const o = options && typeof options === "object" ? options : {};
  if (noView) {
    record("confirmAlert in a no-view command");
    return Promise.reject(new Error("confirmAlert needs a view: Pilot asks it in the open panel, and a no-view command has none"));
  }
  if (o.rememberUserChoice) record("confirmAlert rememberUserChoice");
  return new Promise((resolve) => {
    queue.push({ n: ++serials, options: o, resolve });
    if (queue.length === 1) redraw();
  });
}

/** The alert up now as the list Pilot draws, its two handlers entered in `handlers`; null while none is up. */
export function alertAnswer(handlers, query) {
  const alert = queue[0];
  if (!alert) return null;
  const o = alert.options, section = text(o.title) || "Are you sure?", subtitle = text(o.message);
  const row = (choice, action, fallback) => {
    const handler = `alert.${alert.n}.${choice}`, title = text(action?.title) || fallback;
    handlers.set(handler, { type: "Alert" });
    const item = { title, section, actions: [{ type: "invoke", handler, title }] };
    if (subtitle) item.subtitle = subtitle;
    if (action?.style === "destructive") item.actions[0].destructive = true;
    if (query) item.keywords = query;
    return item;
  };
  return { type: "list", items: [row("confirm", o.primaryAction, "Confirm"), row("dismiss", o.dismissAction, "Cancel")] };
}

/** The callback a press `word` names while an alert is up: its choice, Escape the dismiss, a stale alert id nothing;
 *  undefined while no alert is up, so the view's own handlers answer. */
export function alertPress(word) {
  const alert = queue[0];
  if (!alert) return undefined;
  if (/^navigation\.pop(?:\.\d+)?$/.test(word)) return () => choose(alert, false);
  const named = /^alert\.(\d+)\.(confirm|dismiss)$/.exec(word);
  if (named && Number(named[1]) === alert.n) return () => choose(alert, named[2] === "confirm");
  return null;
}

/** Takes the alert down, runs the chosen action's onAction, then answers the promise and shows what comes next. */
function choose(alert, confirmed) {
  queue.shift();
  const action = confirmed ? alert.options.primaryAction : alert.options.dismissAction;
  try {
    if (typeof action?.onAction === "function") action.onAction();
  } finally {
    alert.resolve(confirmed);
    redraw();
  }
}
