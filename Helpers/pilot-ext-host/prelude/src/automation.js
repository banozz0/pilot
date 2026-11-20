// AppleScript consent (ADR 0017, T9; Sven's open question 4, 2026-11-19: yes, asked once per extension per app). Every
// child the extension starts is looked at here first: `osascript` by its file's name wherever it lives, or a shell's
// `-c` line that runs it. Its script (the `-e` lines, a script file, or what it is handed on stdin) is read for the apps
// it controls: `tell application "Notes"`, `app "Notes"`, `application id "com.apple.Notes"` and JXA's
// `Application("Notes")`. A script whose target Pilot cannot read (a variable, a compiled file) counts as one app of its
// own. System Events is asked too: the child runs under Pilot's own grant, so macOS would not ask again for it.
// Each app not answered yet is asked in the open view, one at a time: the view gives way to an Allow and a Don't Allow
// row, pressed as callbacks (T2), and the child starts only after every app it names is allowed. Answers are kept per
// extension per app in ExtensionData/<id>/automation.json, beside gaps.json, outside the extension's own support folder;
// a refusal stays, and that call and later ones fail with a clear error. A sync call or a no-view command cannot wait
// for an answer, so an app not answered yet fails it: a view asks then, and a sync call can be run again after Allow.
// This is a courtesy for honest extensions, not a sandbox: an extension runs with the user's rights, so code in the
// same context can reach the native bridge or run a script by other means.
import { store } from "./gaps.js";

const native = globalThis.__native;
let saved = store(""), title = "This extension", view = true;
/** Apps waiting for an answer, in asking order, and the calls waiting on them. */
const queue = [], waiters = new Set();
let changed = () => {};

/** This run's extension and where its answers live: the folder above its data folder, which Pilot owns. */
export function consentFor(message, mode) {
  const data = typeof message.paths?.data === "string" ? message.paths.data.replace(/\/+$/, "") : "";
  saved = store(data.includes("/") ? `${data.slice(0, data.lastIndexOf("/"))}/automation.json` : "");
  view = mode !== "no-view";
  try {
    const manifest = JSON.parse(native.fsRead(`${native.cwd()}/package.json`));
    if (typeof manifest.title === "string" && manifest.title.trim()) title = manifest.title.trim().slice(0, 80);
  } catch { /* the id's own name below */ }
  if (title === "This extension" && message.extension) title = String(message.extension);
}

/** Called whenever the ask changes, so the view draws it or gives it back. */
export function onConsentChange(fn) { changed = fn; }

// MARK: Reading a script's targets

const base = (file) => String(file).split("/").pop();
const shells = new Set(["sh", "bash", "zsh", "dash", "ksh"]);
const unread = { key: "*", label: "apps its script names in a way Pilot cannot read" };

/** The apps `script` controls, each `{ key, label }`; a non-literal target is `unread`. */
export function targets(script) {
  const found = new Map();
  const add = (key, label) => { if (!found.has(key)) found.set(key, { key, label }); };
  const literal = /\b(?:application|app)\s+id\s+"([^"]+)"|\b(?:application|app)\s+"([^"]+)"|\bApplication\(\s*(["'])(.*?)\3\s*\)/g;
  for (const m of script.matchAll(literal)) {
    if (m[1] != null) add(`id:${m[1].toLowerCase()}`, m[1]);
    else {
      const name = (m[2] ?? m[4]).replace(/\.app$/i, "").trim();
      if (name) add(name.toLowerCase(), name);
    }
  }
  // `tell application someName`, `Application(someName)`: the app is chosen at run time.
  if (/\btell\s+(?:application|app)\s+(?!id\s+"|")\S/.test(script) || /\bApplication\(\s*[^"'\s)]/.test(script)) add(unread.key, unread.label);
  return [...found.values()];
}

/** What a child about to start needs: null when it runs no AppleScript; else its `apps`, or `stdin: true` when its script
 *  comes on its stdin. */
export function scan(file, args, options = {}) {
  const name = base(file);
  if (shells.has(name)) {
    const at = args.indexOf("-c");
    const line = at >= 0 ? String(args[at + 1] ?? "") : "";
    if (!/(^|[\s/;&|(`'"])osascript\b/.test(line)) return null;
    const apps = targets(line);
    // No -e and no target in the line: the script comes from a file or a pipe the line names, which Pilot does not follow.
    return { apps: apps.length || /\s-e\s/.test(line) ? apps : [unread] };
  }
  if (name !== "osascript") return null;
  const lines = [];
  let scriptFile = null;
  for (let i = 0; i < args.length; i++) {
    const a = String(args[i]);
    if (a === "-e") lines.push(String(args[++i] ?? ""));
    else if (a === "-l" || a === "-s") i++;
    else if (a.startsWith("-") && a !== "-") continue;
    else { scriptFile = a; break; }
  }
  if (lines.length) return { apps: targets(lines.join("\n")) };
  if (scriptFile === null || scriptFile === "-") return { stdin: true };
  const at = scriptFile.startsWith("/") ? scriptFile : `${options.cwd || native.cwd()}/${scriptFile}`;
  const text = native.fsRead(at);
  // A compiled script ("FasdUAS") or one that does not read: its targets are unknown.
  if (typeof text !== "string" || text.startsWith("FasdUAS") || text.includes("\u0000")) return { apps: [unread] };
  return { apps: targets(text) };
}

// MARK: Answers

/** The first of `apps` refused, the ones not answered yet, all allowed. */
function standing(apps) {
  const answers = saved.read();
  const refused = apps.find((a) => answers[a.key]?.allowed === false);
  return { refused, open: apps.filter((a) => typeof answers[a.key]?.allowed !== "boolean") };
}

const refusedError = (app) => Object.assign(new Error(`${title} may not control ${app.label}: Don't Allow was chosen in Pilot, so its AppleScript did not run`), { code: "EPERM" });

/** Starts a call that controls `apps`: `go(null)` once every one is allowed, at once when all already are, else
 *  `go(error)`. Returns a cancel for a call that ends first (a kill). */
export function consent(apps, go) {
  const now = standing(apps);
  if (now.refused) { queueMicrotask(() => go(refusedError(now.refused))); return () => {}; }
  if (!now.open.length) { queueMicrotask(() => go(null)); return () => {}; }
  if (!view) {
    const error = Object.assign(new Error(`${title} needs a yes to control ${now.open[0].label}, which Pilot asks only while one of its views is open, so its AppleScript did not run`), { code: "EPERM" });
    queueMicrotask(() => go(error));
    return () => {};
  }
  const waiter = { apps, go };
  waiters.add(waiter);
  ask(now.open);
  return () => { waiters.delete(waiter); };
}

/** A call that cannot wait (spawnSync, execSync): null when every app is allowed, else the error it fails with; an app
 *  not answered yet is asked in the view meanwhile, so the call can be run again after Allow. */
export function consentNow(apps) {
  const now = standing(apps);
  if (now.refused) return refusedError(now.refused);
  if (!now.open.length) return null;
  if (!view) return Object.assign(new Error(`${title} needs a yes to control ${now.open[0].label}, which Pilot asks only while one of its views is open, so its AppleScript did not run`), { code: "EPERM" });
  ask(now.open);
  return Object.assign(new Error(`${title} has no yes yet to control ${now.open[0].label}: Pilot is asking now; run it again after Allow`), { code: "EAGAIN" });
}

function ask(apps) {
  const before = queue.length;
  for (const app of apps) if (!queue.some((q) => q.key === app.key)) queue.push(app);
  if (queue.length !== before) changed();
}

/** The app being asked about, and its question, or null. */
export function asking() {
  const app = queue[0];
  return app ? { app, question: `${title} wants to control ${app.label}. macOS will then ask too.` } : null;
}

/** The answer to the app being asked about: kept, then every waiting call that it settles goes on or fails. */
export function answer(allowed) {
  const app = queue.shift();
  if (!app) return;
  const answers = saved.read();
  saved.write({ ...answers, [app.key]: { app: app.label, allowed, at: new Date().toISOString() } });
  for (const waiter of [...waiters]) {
    const now = standing(waiter.apps);
    if (now.refused) { waiters.delete(waiter); waiter.go(refusedError(now.refused)); } else if (!now.open.length) { waiters.delete(waiter); waiter.go(null); }
  }
  changed();
}

/** The view closed with apps still asked: their calls fail and nothing is kept. */
export function consentClosed() {
  const left = queue.splice(0);
  for (const waiter of [...waiters]) {
    waiters.delete(waiter);
    const app = left.find((q) => waiter.apps.some((a) => a.key === q.key)) ?? waiter.apps[0];
    waiter.go(Object.assign(new Error(`${title} closed before Pilot's question to control ${app.label} was answered, so its AppleScript did not run`), { code: "ECANCELED" }));
  }
}
