// What a run asks Pilot (ADR 0017, T11): Raycast's `AI.ask` goes to the AI page's provider, `getSelectedText` to the
// focused app's selection, both read by Pilot only as the extension calls them. Each ask is one `ask` line with an `id`;
// Pilot answers on stdin with an `answer` line carrying the same `id` and its `text` or `error`, and the run is held
// (native.hold) until it comes. Only an open view's host has a stdin Pilot answers on: once the run's input ended (a
// one-shot run, or a closed view), an ask fails at once with a clear error instead of waiting for nothing.
// Written from developers.raycast.com (AI and Environment pages, read 2026-11-20).
const native = globalThis.__native;
const waiting = new Map();
let ids = 0, open = true;

/** Asks Pilot `what` with `fields`; resolves with the answer's text, rejects with its error. `signal` aborts it. */
export function ask(what, fields, api, signal) {
  if (!open) return Promise.reject(new Error(`Pilot answers ${api} only while the command's view is open`));
  if (signal?.aborted) return Promise.reject(aborted());
  const id = ++ids;
  return new Promise((resolve, reject) => {
    const settle = () => { waiting.delete(id); native.hold(-1); };
    waiting.set(id, { resolve, reject, settle });
    signal?.addEventListener?.("abort", () => { if (waiting.has(id)) { settle(); reject(aborted()); } });
    native.hold(1);
    native.write(JSON.stringify({ type: "ask", id, what, ...fields }));
  });
}

function aborted() {
  const error = new Error("The operation was aborted");
  error.name = "AbortError";
  return error;
}

globalThis.__pilotAnswer = (message) => {
  const asked = waiting.get(message?.id);
  if (!asked) return;
  asked.settle();
  if (message.error != null) asked.reject(new Error(String(message.error)));
  else asked.resolve(String(message.text ?? ""));
};

globalThis.__pilotInputEnded = () => {
  open = false;
  for (const asked of [...waiting.values()]) {
    asked.settle();
    asked.reject(new Error("Pilot closed the run before it answered"));
  }
};

/** Raycast's `AI.ask(prompt, options)`: a promise of the whole answer that is also an emitter, its `data` event
 *  handed the answer as it lands (Pilot sends it whole, so once). `creativity` and `model` are Raycast's choices: Pilot
 *  asks the provider picked on its AI page, at that page's settings. */
export function askAI(prompt, options = {}) {
  const listeners = new Map();
  const promise = ask("ai", { prompt: String(prompt ?? "") }, "AI.ask", options?.signal).then((text) => {
    for (const fn of listeners.get("data") ?? []) fn(text);
    return text;
  });
  const on = (name, fn) => {
    if (typeof fn === "function") listeners.set(name, [...(listeners.get(name) ?? []), fn]);
    return promise;
  };
  return Object.assign(promise, {
    on, addListener: on, once: on,
    off(name, fn) { listeners.set(name, (listeners.get(name) ?? []).filter((f) => f !== fn)); return promise; },
  });
}

/** Raycast's `getSelectedText()`: the focused app's selected text, read by Pilot now; rejects when none is selected. */
export const selectedText = () => ask("selection", {}, "getSelectedText");
