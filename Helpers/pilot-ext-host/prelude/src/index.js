// pilot-ext-prelude.js's entry (ADR 0017): loaded into each fresh JSContext before an extension's bundle. globals.js
// comes first, so React's scheduler finds its timers. The host then calls __pilotStart with the bundle's CommonJS
// factory and the run message, __pilotQuery with each later search, __pilotInvoke with each press (T2; a form's carries its value, T10), both numbered
// by Pilot so their answer carries the number back, and __pilotClose when the view closes. The command's mode comes from
// the manifest in the host's folder, the extension's own (T3): a view renders, a no-view command is called and the run
// ends once its promise settles, its HUD and actions printed as ADR 0010's lines. Its `arguments` (T11) are the
// manifest's, each a string: the run message's own when it carries them, else empty, the first filled with the run's
// `input`, the words typed after the command's keyword at Hyper+Space's root (or `pilot ext run --input`).
import "./globals.js";
import * as React from "react";
import * as JSX from "react/jsx-runtime";
import { makeAPI } from "./raycast.js";
import { fail, render } from "./host.js";
import { modules as node } from "./node.js";
import { gapsAt, record } from "./gaps.js";

const native = globalThis.__native;
let view = null;

function requirer(api) {
  const modules = { ...node, react: React, "react/jsx-runtime": JSX, "react/jsx-dev-runtime": JSX, "@raycast/api": api };
  return (name) => {
    const plain = String(name).replace(/^node:/, "");
    const found = modules[plain];
    if (found) return found;
    record(`require("${plain}")`);
    throw new Error(`Cannot find module '${name}': Pilot does not have it yet`);
  };
}

/** The manifest's entry for `command` in the extension's folder; empty when it has none. */
function manifestOf(command) {
  const raw = native.fsRead(`${native.cwd()}/package.json`);
  try { return JSON.parse(raw).commands.find((c) => c?.name === command) ?? {}; } catch { return {}; }
}

/** The command's `arguments` prop (developers.raycast.com, Arguments, read 2026-11-20): each manifest argument by its
 *  name, a string, at most Raycast's three; the run's `input` fills the first unless the message carries arguments. */
function argumentsOf(entry, message) {
  const given = message.arguments && typeof message.arguments === "object" ? message.arguments : {};
  const names = (Array.isArray(entry.arguments) ? entry.arguments : []).map((a) => a?.name).filter((n) => typeof n === "string" && n).slice(0, 3);
  const out = {};
  for (const name of names) out[name] = typeof given[name] === "string" ? given[name] : "";
  if (names.length && !message.arguments && typeof message.input === "string") out[names[0]] = message.input;
  return out;
}

globalThis.__pilotStart = (factory, message) => {
  try {
    gapsAt(message.paths, message.command);
    const entry = manifestOf(message.command), mode = entry.mode ?? "view";
    message.arguments = argumentsOf(entry, message);
    if (mode === "no-view") native.noView();
    const module = { exports: {} };
    factory(module, module.exports, requirer(makeAPI(message, mode)));
    const command = module.exports?.default ?? module.exports;
    if (typeof command !== "function") throw new Error("its command exports no function");
    const props = { arguments: message.arguments ?? {}, launchType: "userInitiated", launchContext: message.context };
    if (mode === "no-view") {
      Promise.resolve().then(() => command(props)).then(undefined, (error) => fail(error));
      return;
    }
    view = render(command, message);
    if (message.query) view.search(message.query);
  } catch (error) {
    fail(error);
  }
};

// Each catches its own work's throw (render's request), answering its seq.
globalThis.__pilotQuery = (text, seq) => { view ? view.search(text, seq) : fail(new Error("no view is open"), seq); };
globalThis.__pilotInvoke = (handler, seq, value) => { view ? view.invoke(handler, seq, value) : fail(new Error("no view is open"), seq); };

globalThis.__pilotClose = () => {
  try { view?.close(); } catch (error) { console.error(error); }
  view = null;
};
