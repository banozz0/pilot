// pilot-ext-prelude.js's entry (ADR 0017): loaded into each fresh JSContext before an extension's bundle. globals.js
// comes first, so React's scheduler finds its timers. The host then calls __pilotStart with the bundle's CommonJS
// factory and the run message, __pilotQuery with each later search and __pilotClose when the view closes.
import "./globals.js";
import * as React from "react";
import * as JSX from "react/jsx-runtime";
import { makeAPI } from "./raycast.js";
import { fail, render } from "./host.js";

let view = null;

function requirer(api) {
  const modules = { react: React, "react/jsx-runtime": JSX, "react/jsx-dev-runtime": JSX, "@raycast/api": api };
  return (name) => {
    const found = modules[String(name).replace(/^node:/, "")];
    if (found) return found;
    throw new Error(`Cannot find module '${name}': Pilot does not have it yet`);
  };
}

globalThis.__pilotStart = (factory, message) => {
  try {
    const module = { exports: {} };
    factory(module, module.exports, requirer(makeAPI(message)));
    const command = module.exports?.default ?? module.exports;
    if (typeof command !== "function") throw new Error("its command exports no function");
    view = render(command, message);
    if (message.query) view.search(message.query);
  } catch (error) {
    fail(error);
  }
};

globalThis.__pilotQuery = (text) => {
  try { view?.search(text); } catch (error) { fail(error); }
};

globalThis.__pilotClose = () => {
  try { view?.close(); } catch (error) { console.error(error); }
  view = null;
};
