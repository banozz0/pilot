// AppleScript consent (ADR 0017, T9; Sven's open question 4, 2026-11-19: yes, asked once per extension per app). Every
// child the extension starts is looked at here first. It runs AppleScript when its file is `osascript` (any case,
// wherever it lives) or when its file or any argument names osascript (a shell line, `env osascript`, a login shell).
// Its script is read for the apps it controls: `tell application "Notes"`, `app "Notes"` (AppleScript ignores case),
// `application id "com.apple.Notes"` and JXA's `Application("Notes")`, each resolved through the app's own Info.plist to
// one bundle id (Apps.swift), so a name and its bundle id are one app. Anything Pilot cannot read for certain counts as
// one app of its own, `*`: an app word no literal target accounts for, a target built at run time, a compiled or
// unreadable script, `run script`, raw «codes», JXA's eval or ObjC bridge, or a line that is not plain osascript with a
// `$`, a backtick or no literal target at all. A `*` Allow never applies while the extension has a refusal kept.
// System Events is asked like any other: the child runs under Pilot's own grant, so macOS would not ask again for it.
//
// Each app not answered yet is asked once per extension. In a view, the view gives way to two rows, Don't Allow and
// Allow, pressed as callbacks (T2); each question's handler ids carry its serial and app, so a press meant for one
// question never answers the next. A no-view command has no view: its call is held and the host prints ADR 0010's alert
// action, whose Don't Allow and Allow buttons run the same command again with the answer in its context, kept here on
// that run's start. The call starts only once every app it names is allowed; a refusal fails it with EPERM. A sync call
// cannot wait, so it fails with EAGAIN while Pilot asks. Answers live per extension in ExtensionData/<id>/automation.json,
// beside gaps.json, outside the extension's own support folder.
//
// This is a courtesy, not a sandbox: an extension runs with the user's rights (ADR 0017), so code in the same context can
// call the native bridge itself, run a script that never names osascript (`sh script.sh`, a copied binary), forge the
// answer file or an answer context.
import { store } from "./gaps.js";

const native = globalThis.__native;
let saved = store(""), title = "This extension", view = true, command = "", context;
/** Apps waiting for an answer, in asking order (`{ app, serial, sync }`), and the calls waiting on them. */
const queue = [], waiters = new Set();
let serials = 0, alerted = false, typed = "";
let changed = () => {};

/** Text from a script or a manifest as a question shows it: no control or hidden characters, one line, `most` long. */
function clean(text, most) {
  const plain = String(text).replace(/[\p{C}\p{Zl}\p{Zp}]/gu, " ").replace(/\s+/g, " ").trim();
  return plain.length > most ? `${plain.slice(0, most - 1)}…` : plain;
}

/** This run's extension, command and answers; a run started by an alert's button keeps the answer it carries. */
export function consentFor(message, mode) {
  const data = typeof message.paths?.data === "string" ? message.paths.data.replace(/\/+$/, "") : "";
  saved = store(data.includes("/") ? `${data.slice(0, data.lastIndexOf("/"))}/automation.json` : "");
  view = mode !== "no-view";
  command = String(message.command ?? "");
  try {
    const manifest = JSON.parse(native.fsRead(`${native.cwd()}/package.json`));
    if (typeof manifest.title === "string" && clean(manifest.title, 60)) title = clean(manifest.title, 60);
  } catch { /* the id's own name below */ }
  if (title === "This extension" && message.extension) title = clean(message.extension, 60);
  const given = message.context && typeof message.context === "object" ? message.context : null;
  const answered = given?.pilotConsent;
  if (answered && typeof answered.key === "string" && typeof answered.allowed === "boolean") {
    keep({ key: answered.key, label: clean(answered.app ?? answered.key, 60) }, answered.allowed);
    const { pilotConsent: _, ...rest } = given;
    message.context = Object.keys(rest).length ? rest : undefined;
  }
  context = message.context;
}

/** Called whenever the ask changes, so the view draws it or gives it back. */
export function onConsentChange(fn) { changed = fn; }

/** The view's search as typed: the question's rows carry it, so Pilot's own filter never hides them. */
export function consentSearch(text) { typed = String(text ?? ""); }

// MARK: Reading a script's targets

const unread = { key: "*", label: "an app its script names in a way Pilot cannot read" };

/** One app, by name or bundle id, keyed by its bundle id when it resolves, and named as it shows. */
function app(raw, byID) {
  const text = clean(raw, 200);
  if (!text) return unread;
  const known = native.appIdentity?.(text, byID);
  if (known && typeof known.id === "string") return { key: `id:${known.id.toLowerCase()}`, label: clean(known.name || text, 60) };
  const name = text.replace(/\.app$/i, "");
  return { key: byID ? `id:${name.toLowerCase()}` : name.toLowerCase(), label: clean(name, 60) };
}

/** Character spans `pattern` matches in `text`. */
const spans = (text, pattern) => [...text.matchAll(pattern)].map((m) => [m.index, m.index + m[0].length]);
const inside = (at, list) => list.some(([a, b]) => at >= a && at < b);

/** The apps `script` controls: AppleScript, or JXA when `js`; `shell` when it is a command line around osascript. */
export function targets(script, { js = false, shell = false } = {}) {
  const found = new Map();
  const add = (a) => { if (!found.has(a.key)) found.set(a.key, a); };
  // A target is literal only when nothing is joined to it: `application "Mu" & "sic"` is built at run time.
  const q = String.raw`\\?"([^"\\]*)\\?"`;
  const literal = [
    [new RegExp(String.raw`\b(?:application|app)\s+id\s+${q}(?!\s*&)`, "gi"), (m) => app(m[1], true)],
    [new RegExp(String.raw`\b(?:application|app)\s+${q}(?!\s*&)`, "gi"), (m) => app(m[1], false)],
    [/\bApplication\s*\(\s*\\?(["'])((?:(?!\1)[^\\])*)\\?\1\s*\)/gi, (m) => app(m[2], /^[a-z0-9-]+(\.[a-z0-9-]+){2,}$/i.test(m[2]))],
  ];
  const used = [];
  for (const [pattern, made] of literal) {
    for (const m of script.matchAll(pattern)) {
      if (inside(m.index, used)) continue;
      used.push([m.index, m.index + m[0].length]);
      add(made(m));
    }
  }
  // Every app word a literal target did not account for is a target Pilot cannot read: outside strings (a shell line's
  // quotes hold the script itself, so there nothing counts as a string), never `current application` or JXA's own.
  const strings = shell ? [] : spans(script, js ? /"(?:[^"\\]|\\.)*"|'(?:[^'\\]|\\.)*'/g : /"(?:[^"\\]|\\.)*"/g);
  const words = js ? /\bApplication\b/g : /\b(?:application|app)\b/gi;
  for (const m of script.matchAll(words)) {
    if (inside(m.index, used) || inside(m.index, strings)) continue;
    if (!js && /current\s+$/i.test(script.slice(Math.max(0, m.index - 12), m.index))) continue;
    if (/^\s*\.\s*currentApplication\b/.test(script.slice(m.index + m[0].length))) continue;
    add(unread);
  }
  const opaque = js ? /\beval\b|\bFunction\s*\(|\bObjC\b|\$\s*[.(]/ : /«|\b(?:run|load)\s+script\b|\bosascript\b/i;
  if (opaque.test(shell ? script.replace(/\bosascript\b/gi, "") : script)) add(unread);
  if (shell && (/[$`]/.test(script) || !found.size)) add(unread);
  return [...found.values()];
}

/** What a child about to start needs: null when it runs no AppleScript; else its `apps`, or `stdin` (with `js`) when its
 *  script comes on its stdin. */
export function scan(file, args, options = {}) {
  const name = String(file).split("/").pop().toLowerCase();
  if (name !== "osascript") {
    const line = [String(file), ...args.map(String)].join(" ");
    if (!/\bosascript\b/i.test(line)) return null;
    return { apps: targets(args.map(String).join(" "), { shell: true }) };
  }
  const lines = [];
  let scriptFile = null, js = false;
  for (let i = 0; i < args.length; i++) {
    const a = String(args[i]);
    if (a === "-e") lines.push(String(args[++i] ?? ""));
    else if (a === "-l") js = /^javascript$/i.test(String(args[++i] ?? ""));
    else if (a === "-s") i++;
    else if (a.startsWith("-") && a !== "-") continue;
    else { scriptFile = a; break; }
  }
  if (lines.length) return { apps: targets(lines.join("\n"), { js }) };
  if (scriptFile === null || scriptFile === "-") return { stdin: true, js };
  const at = scriptFile.startsWith("/") ? scriptFile : `${options.cwd || native.cwd()}/${scriptFile}`;
  const text = native.fsRead(at);
  // A compiled script ("FasdUAS") or one that does not read: its targets are unknown.
  if (typeof text !== "string" || text.startsWith("FasdUAS") || text.includes("\u0000")) return { apps: [unread] };
  return { apps: targets(text, { js: js || /\.js$/i.test(scriptFile) }) };
}

/** A script handed on stdin, read once it ends. */
export const stdinApps = (script, js) => targets(String(script), { js });

// MARK: Answers

/** The first of `apps` refused, and the ones not answered yet. A `*` Allow stands only while nothing is refused. */
function standing(apps) {
  const answers = saved.read();
  let refused = apps.find((a) => answers[a.key]?.allowed === false);
  if (!refused && apps.some((a) => a.key === unread.key)) {
    const kept = Object.entries(answers).find(([, v]) => v?.allowed === false);
    if (kept) refused = { key: kept[0], label: clean(kept[1].app ?? kept[0], 60), widened: true };
  }
  return { refused, open: apps.filter((a) => typeof answers[a.key]?.allowed !== "boolean") };
}

function refusedError(a) {
  const why = a.widened ? `${title} may not control ${a.label}, and Pilot cannot read which app this script controls, so its AppleScript did not run`
    : `${title} may not control ${a.label}: Don't Allow was chosen in Pilot, so its AppleScript did not run`;
  return Object.assign(new Error(why), { code: "EPERM" });
}

const asking = (a) => Object.assign(new Error(`${title} has no yes yet to control ${a.label}: Pilot is asking now; run it again after Allow`), { code: "EAGAIN" });

/** Starts a call that controls `apps`: `go(null)` once every one is allowed, else `go(error)`, always on a later turn,
 *  so a throw in its listener never stops another call. Returns a cancel for a call that ends first (a kill). */
export function consent(apps, go) {
  const settle = (error) => queueMicrotask(() => go(error));
  const now = standing(apps);
  if (now.refused) { settle(refusedError(now.refused)); return () => {}; }
  if (!now.open.length) { settle(null); return () => {}; }
  const waiter = { apps, go: settle };
  waiters.add(waiter);
  ask(now.open, false);
  return () => { waiters.delete(waiter); prune(); };
}

/** A call that cannot wait (spawnSync, execSync): null when every app is allowed, else the error it fails with; an app
 *  not answered yet is asked meanwhile, so the call can be run again after Allow. */
export function consentNow(apps) {
  const now = standing(apps);
  if (now.refused) return refusedError(now.refused);
  if (!now.open.length) return null;
  ask(now.open, true);
  return asking(now.open[0]);
}

function ask(apps, sync) {
  const before = queue[0];
  for (const a of apps) {
    const entry = queue.find((q) => q.app.key === a.key);
    if (entry) entry.sync ||= sync;
    else queue.push({ app: a, serial: ++serials, sync });
  }
  if (!view) return alert();
  if (queue[0] !== before) changed();
}

/** A no-view run's ask: one alert per run, for the first app, whose buttons run this command again with the answer. */
function alert() {
  if (alerted || !queue.length) return;
  alerted = true;
  const { app: a } = queue[0];
  const button = (label, allowed) => ({ type: "run", title: label, command, context: { ...(context ?? {}), pilotConsent: { key: a.key, app: a.label, allowed } } });
  native.write(JSON.stringify({ type: "action", action: {
    type: "alert", text: `${title} wants to control ${a.label}.`, note: "macOS will then ask too.",
    actions: [button("Don't Allow", false), button("Allow", true)],
  } }));
}

/** The question being asked in the view, or null. */
export function question() {
  const head = queue[0];
  if (!head) return null;
  return { serial: head.serial, slug: head.app.key.replace(/[^a-z0-9]+/gi, "-").slice(0, 40), typed,
    text: `${title} wants to control ${head.app.label}. macOS will then ask too.` };
}

/** Keeps the answer for `a`. */
function keep(a, allowed) {
  const answers = saved.read();
  saved.write({ ...answers, [a.key]: { app: a.label, allowed, at: new Date().toISOString() } });
}

/** The answer to question `serial`: only the one being asked takes it, anything else is stale. Kept first, then each
 *  waiting call it settles goes on or fails, apps no call still needs leave the queue, and the view redraws. */
export function answer(serial, allowed) {
  const head = queue[0];
  if (!head || head.serial !== serial) return console.error(`consent answer for question ${serial} is stale: answering the view unchanged`);
  keep(head.app, allowed);
  queue.shift();
  for (const waiter of [...waiters]) {
    const now = standing(waiter.apps);
    if (now.refused) { waiters.delete(waiter); waiter.go(refusedError(now.refused)); } else if (!now.open.length) { waiters.delete(waiter); waiter.go(null); }
  }
  prune();
  changed();
}

/** Drops asked apps that no waiting call and no sync call still needs. */
function prune() {
  for (let i = queue.length - 1; i >= 0; i--) {
    const q = queue[i];
    if (!q.sync && ![...waiters].some((w) => w.apps.some((a) => a.key === q.app.key))) queue.splice(i, 1);
  }
}

/** The view closed with apps still asked: their calls fail and nothing is kept. */
export function consentClosed() {
  const left = queue.splice(0);
  for (const waiter of [...waiters]) {
    waiters.delete(waiter);
    const a = left.find((q) => waiter.apps.some((w) => w.key === q.app.key))?.app ?? waiter.apps[0];
    waiter.go(Object.assign(new Error(`${title} closed before Pilot's question to control ${a.label} was answered, so its AppleScript did not run`), { code: "ECANCELED" }));
  }
}
