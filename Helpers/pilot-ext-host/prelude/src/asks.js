// What a run asks Pilot (ADR 0017, T11): Raycast's `AI.ask` goes to the AI page's provider, `getSelectedText` to the
// focused app's selection, both read by Pilot only as the extension calls them. Each ask is one `ask` line with an `id`;
// Pilot answers on stdin with an `answer` line carrying the same `id` and its `text` or `error`, and the run is held
// (native.hold) until it comes. Pilot answers on an open view's stdin, and on a one-shot run's when its run message
// says `answers` (main.swift); once the run's input ended, an ask fails at once with a clear error instead of waiting
// for nothing.
// Written from developers.raycast.com (AI and Environment pages, read 2026-11-20).
import { modules } from "./node.js";

const native = globalThis.__native;
const waiting = new Map();
let ids = 0, open = true;

/** Asks Pilot `what` with `fields`; resolves with the answer's text, rejects with its error. `signal` aborts it. */
export function ask(what, fields, api, signal) {
  if (!open) return Promise.reject(new Error(`Pilot answers ${api} only while the command's view is open`));
  if (signal?.aborted) return Promise.reject(signal.reason);
  const id = ++ids;
  return new Promise((resolve, reject) => {
    const settle = () => { waiting.delete(id); native.hold(-1); };
    waiting.set(id, { resolve, reject, settle });
    signal?.addEventListener?.("abort", () => { if (waiting.has(id)) { settle(); reject(signal.reason); } });
    native.hold(1);
    native.write(JSON.stringify({ type: "ask", id, what, ...fields }));
  });
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

/** Raycast's `AI.ask(prompt, options)`: a promise of the whole answer that is also an emitter (node.js's), its `data`
 *  event handed the answer as it lands (Pilot sends it whole, so once). `creativity` and `model` are Raycast's choices:
 *  Pilot asks the provider picked on its AI page, at that page's settings. */
export function askAI(prompt, options = {}) {
  const emitter = new modules.events();
  const promise = ask("ai", { prompt: String(prompt ?? "") }, "AI.ask", options?.signal).then((text) => {
    emitter.emit("data", text);
    return text;
  });
  // The emitter's methods on the promise, those that chain answering the promise, so `await` still finds it.
  for (const name of ["on", "addListener", "prependListener", "once", "off", "removeListener", "removeAllListeners", "setMaxListeners"]) {
    promise[name] = (...args) => { emitter[name](...args); return promise; };
  }
  for (const name of ["emit", "listeners", "listenerCount", "eventNames"]) promise[name] = emitter[name].bind(emitter);
  return promise;
}

/** Raycast's `getSelectedText()`: the focused app's selected text, read by Pilot now; rejects when none is selected. */
export const selectedText = () => ask("selection", {}, "getSelectedText");
