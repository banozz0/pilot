// AppleScript consent (ADR 0017, T9; Sven's open question 4, 2026-11-19: yes, asked once per extension per app). Every
// child the extension starts is looked at here first. Only a call Pilot reads in full is asked about the apps it names,
// each resolved through the app's own Info.plist to one bundle id (Apps.swift), so a name and its bundle id are one app;
// every other call that names osascript is the unread app, `*`, which never stands while a refusal is kept. System
// Events is asked like any other: the child runs under Pilot's own grant, so macOS would not ask again for it.
// Which calls are read, and how, is the one rule under "Reading a call" below.
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
// answer file or a no-view answer's context. Its nonce lives in automation-alert.json, beside the answers.
import { store } from "./gaps.js";

const native = globalThis.__native;
let saved = store(""), title = "This extension", view = true, command = "", context;
/** Apps waiting for an answer, in asking order (`{ app, serial, sync }`), and the calls waiting on them. */
const queue = [], waiters = new Set();
let serials = 0, alerted = false, typed = "";
/** Where a no-view alert's one-time nonce waits: a file of its own beside automation.json, never among the answers. */
let pendingAlert = store("");
let changed = () => {};

/** Text from a script or a manifest as a question shows it: no control or hidden characters, one line, `most` long. */
function clean(text, most) {
  const plain = String(text).replace(/[\p{C}\p{Zl}\p{Zp}]/gu, " ").replace(/\s+/g, " ").trim();
  return plain.length > most ? `${plain.slice(0, most - 1)}…` : plain;
}

/** This run's extension, command and answers; a run started by an alert's button keeps the answer it carries. */
export function consentFor(message, mode) {
  const data = typeof message.paths?.data === "string" ? message.paths.data.replace(/\/+$/, "") : "";
  const folder = data.includes("/") ? data.slice(0, data.lastIndexOf("/")) : "";
  saved = store(folder ? `${folder}/automation.json` : "");
  pendingAlert = store(folder ? `${folder}/automation-alert.json` : "");
  view = mode !== "no-view";
  command = String(message.command ?? "");
  try {
    const manifest = JSON.parse(native.fsRead(`${native.cwd()}/package.json`));
    if (typeof manifest.title === "string" && clean(manifest.title, 60)) title = clean(manifest.title, 60);
  } catch { /* the id's own name below */ }
  if (title === "This extension" && message.extension) title = clean(message.extension, 60);
  const given = message.context && typeof message.context === "object" ? message.context : null;
  const answered = given?.pilotConsent;
  if (answered) {
    const pending = pendingAlert.read();
    if (typeof pending.nonce === "string" && answered.nonce === pending.nonce && answered.key === pending.key && pending.command === command
        && typeof answered.allowed === "boolean") {
      pendingAlert.write({});
      keep({ key: pending.key, label: clean(answered.app ?? pending.key, 60) }, answered.allowed);
    } else console.error("a consent answer without this extension's pending nonce: not kept");
    const { pilotConsent: __, ...others } = given;
    message.context = Object.keys(others).length ? others : undefined;
  }
  context = message.context;
}

/** Called whenever the ask changes, so the view draws it or gives it back. */
export function onConsentChange(fn) { changed = fn; }

/** The view's search as typed: the question's rows carry it, so Pilot's own filter never hides them. */
export function consentSearch(text) { typed = String(text ?? ""); }

// MARK: Reading a call
//
// One rule (review 3): a call gets a named app only when Pilot reads all of it. That is a child whose file really is
// /usr/bin/osascript (resolved as posix_spawnp resolves it, Apps.swift), started with no shell, wrapper or env; whose
// options are -e lines, -l AppleScript or JavaScript from its own argument, -s flags and `-` (stdin), never a script
// file; whose script (the -e lines, or its stdin as runAppleScript hands it over) has no nested script (do shell script,
// run script, raw «codes», JXA's doShellScript, eval and the like); and in which every app word is followed, on its line,
// by a quoted name with no quote, backslash or newline inside and nothing joined after it. Anything else is the unread
// app, `*`, which is refused while any refusal stands. A call reads as controlling nothing only in that exact shape with
// no app word at all. A call read in full is started by the real path it was read at.

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

/** A quoted name a strict target takes: one line, no quote of either kind, no backslash. */
const name = String.raw`([^"'\\\r\n]+)`;

/** The apps a fully read script controls, or the unread app. AppleScript's app words are `app` and `application` in any
 *  case; JXA's is `Application`, whose `currentApplication()` controls nothing. */
export function strict(script, js) {
  const found = new Map();
  const add = (a) => { if (!found.has(a.key)) found.set(a.key, a); };
  if (js) {
    if (/osascript|\$|`|\[(?!\s*\d+\s*\])|\b(?:doShellScript|eval|Function|constructor|ObjC|Library|require|Reflect|Proxy|globalThis|this|import)\b/.test(script)) return [unread];
    for (const m of script.matchAll(/\bApplication\b/g)) {
      const rest = script.slice(m.index + m[0].length);
      if (/^\.currentApplication\(\)/.test(rest)) continue;
      const t = rest.match(new RegExp(String.raw`^\(\s*(?:"${name}"|'${name}')\s*\)`));
      if (!t) return [unread];
      const n = t[1] ?? t[2];
      add(app(n, /^[a-z0-9-]+(\.[a-z0-9-]+){2,}$/i.test(n)));
    }
  } else {
    if (/osascript|«|»|\b(?:run|load|store)[ \t]+script\b|\bdo[ \t]+shell[ \t]+script\b/i.test(script)) return [unread];
    for (const m of script.matchAll(/\b(?:application|app)\b/gi)) {
      const t = script.slice(m.index + m[0].length).match(new RegExp(String.raw`^[ \t]+(id[ \t]+)?"${name}"(?![ \t]*&)`, "i"));
      if (!t) return [unread];
      add(app(t[2], Boolean(t[1])));
    }
  }
  return [...found.values()];
}

/** osascript's own arguments read: its script lines and language, or `stdin`; null for any other shape (a script file,
 *  -i, an option it does not know, a language other than AppleScript or JavaScript). */
function argv(args) {
  const lines = [];
  let js = false;
  for (let i = 0; i < args.length; i++) {
    const t = args[i];
    if (t === "-e") { if (i + 1 >= args.length) return null; lines.push(args[++i]); continue; }
    if (t === "-l") { const lang = args[++i]; if (!/^(applescript|javascript)$/i.test(lang ?? "")) return null; js = /^javascript$/i.test(lang); continue; }
    if (t === "-s") { if (!/^[hseo]+$/.test(args[++i] ?? "")) return null; continue; }
    if (/^-s[hseo]+$/.test(t)) continue;
    // `-`: the script comes on stdin, and the rest are its arguments; after -e lines, anything else is an argument too.
    if (t === "-" || lines.length) break;
    return null;
  }
  return lines.length ? { script: lines.join("\n"), js } : { stdin: true, js };
}

/** What a child about to start needs: null when it runs no AppleScript; else its `apps`, or `stdin` (with `js`) when its
 *  script comes on its stdin; `exec`, the real path to start, for a call read in full. */
export function scan(file, args, options = {}) {
  const list = args.map(String);
  const real = native.realExecutable(String(file), String(options.cwd ?? ""));
  const at = typeof real === "string" ? real : "";
  if (!native.trustedOsascripts().includes(at)) {
    // A wrapper, a shell line, a copy under another name, xargs: anything that names osascript is the unread app.
    return [String(file), at, ...list].some((t) => /osascript/i.test(t)) ? { apps: [unread] } : null;
  }
  const read = argv(list);
  if (!read) return { apps: [unread], exec: at };
  if (read.stdin) return { stdin: true, js: read.js, exec: at };
  return { apps: strict(read.script, read.js), exec: at };
}

/** A script handed on stdin, read once it ends, under the same rule. */
export const stdinApps = (script, js) => strict(String(script), js);

// MARK: Answers

/** The first of `apps` refused, the ones not answered yet, and whether the call must wait anyway. A `*` Allow stands
 *  only while nothing is refused and no other question is open, since that question may yet be refused: until it is
 *  answered, such a call waits. */
function standing(apps) {
  const answers = saved.read();
  let refused = apps.find((a) => answers[a.key]?.allowed === false);
  const wide = apps.some((a) => a.key === unread.key);
  if (!refused && wide) {
    const kept = Object.entries(answers).find(([, v]) => v?.allowed === false);
    if (kept) refused = { key: kept[0], label: clean(kept[1].app ?? kept[0], 60), widened: true };
  }
  const open = apps.filter((a) => typeof answers[a.key]?.allowed !== "boolean");
  return { refused, open, wait: wide && queue.some((q) => q.app.key !== unread.key) };
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
  if (!now.open.length && !now.wait) { settle(null); return () => {}; }
  const waiter = { apps, go: settle };
  waiters.add(waiter);
  if (now.open.length) ask(now.open, false);
  // A call killed while asked (runAppleScript's own timeout kills it after 10 s) keeps its question on screen, so its
  // answer is still kept for the next run; every other call is looked at again and the view redrawn.
  return () => {
    waiters.delete(waiter);
    for (const q of queue) if (waiter.apps.some((a) => a.key === q.app.key)) q.sync = true;
    settleAll();
    changed();
  };
}

/** A call that cannot wait (spawnSync, execSync): null when every app is allowed, else the error it fails with; an app
 *  not answered yet is asked meanwhile, so the call can be run again after Allow. */
export function consentNow(apps) {
  const now = standing(apps);
  if (now.refused) return refusedError(now.refused);
  if (!now.open.length && !now.wait) return null;
  if (now.open.length) ask(now.open, true);
  return asking(now.open[0] ?? queue[0].app);
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
  // The answer comes back in a new run's context, so it is bound to a one-time nonce kept here as the alert goes out:
  // a context that does not carry it (a launchCommand's, a forged one) is not an answer.
  const nonce = native.random(16);
  pendingAlert.write({ key: a.key, nonce, command });
  const button = (label, allowed) => ({ type: "run", title: label, command, context: { ...(context ?? {}), pilotConsent: { key: a.key, app: a.label, allowed, nonce } } });
  native.write(JSON.stringify({ type: "action", action: {
    type: "alert", text: `${title} wants to control ${a.label}.`, note: "macOS will then ask too.",
    actions: [button("Don't Allow", false), button("Allow", true)],
  } }));
}

/** Whether this run sent a no-view consent alert: its failure is then the held call's, logged, never an error line,
 *  which would stand in for the alert (ExtensionRun keeps the first error line and drops the actions). */
export const consentAlerted = () => alerted;

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
  settleAll();
  changed();
}

/** Each waiting call its answers now settle goes on or fails; apps no call still needs leave the queue, which may end
 *  the last open question a `*` call waits on, so they are looked at once more. */
function settleAll() {
  const pass = () => {
    for (const waiter of [...waiters]) {
      const now = standing(waiter.apps);
      if (now.refused) { waiters.delete(waiter); waiter.go(refusedError(now.refused)); } else if (!now.open.length && !now.wait) { waiters.delete(waiter); waiter.go(null); }
    }
  };
  pass();
  prune();
  pass();
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
