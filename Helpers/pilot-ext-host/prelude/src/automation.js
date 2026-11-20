// AppleScript consent (ADR 0017, T9; Sven, 2026-11-20, Q274: one question per extension). The first time an extension
// starts a child that is osascript (its file named osascript in any case, or any argument naming it, a shell's -c line
// included), the call is held and Pilot asks once whether the extension may run AppleScript to control other apps. The
// answer is kept per extension in ExtensionData/<id>/automation.json, beside gaps.json, outside the extension's own
// support folder: Allow lets every later call of every command run with no ask, Don't Allow fails each with EPERM.
//
// In a view, the view gives way to two rows, Don't Allow and Allow, pressed as callbacks (T2), their handler ids
// carrying the question's serial so a stale press answers nothing. A no-view command has no view: its call is held and
// the host prints ADR 0010's alert action, whose buttons run the same command again with the answer in its context,
// kept on that run's start only with the one-time nonce the alert went out with (automation-alert.json) and the same
// command. A sync call cannot wait, so it fails with EAGAIN while Pilot asks.
//
// This is a courtesy for honest extensions, not a sandbox: an extension runs with the user's rights (ADR 0017), so it
// can reach AppleScript without naming osascript (a copy under another name, a script file a shell runs), call the
// native bridge itself, or write its own answer file. macOS's own Automation prompt still names each app it controls.
import { store } from "./gaps.js";

const native = globalThis.__native;
const key = "osascript";
let saved = store(""), pendingAlert = store(""), title = "This extension", view = true, command = "", context;
/** The calls waiting on the answer; the open question's serial, 0 while none is open. */
const waiters = new Set();
let serial = 0, serials = 0, alerted = false, changed = () => {};

/** Text from a manifest as a question shows it: no control or hidden characters, one line, `most` long. */
function clean(text, most) {
  const plain = String(text).replace(/[\p{C}\p{Zl}\p{Zp}]/gu, " ").replace(/\s+/g, " ").trim();
  return plain.length > most ? `${plain.slice(0, most - 1)}…` : plain;
}

/** This run's extension, command and answer; a run started by an alert's button keeps the answer it carries. */
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
    if (typeof pending.nonce === "string" && answered.nonce === pending.nonce && pending.command === command && typeof answered.allowed === "boolean") {
      pendingAlert.write({});
      keep(answered.allowed);
    } else console.error("a consent answer without this extension's pending nonce: not kept");
    const { pilotConsent: __, ...others } = given;
    message.context = Object.keys(others).length ? others : undefined;
  }
  context = message.context;
}

/** Called whenever the question comes or goes, so the view draws it or gives it back. */
export function onConsentChange(fn) { changed = fn; }

/** Whether a child about to start is osascript: its file, or any argument (a shell's -c line), names it in any case. */
export const runsAppleScript = (file, args) => [file, ...args].some((t) => /osascript/i.test(String(t)));

const allowed = () => saved.read()[key]?.allowed;

const refused = () => Object.assign(new Error(`${title} may not run AppleScript: Don't Allow was chosen in Pilot, so its osascript did not run`), { code: "EPERM" });

/** Starts an osascript call: `go(null)` once allowed, else `go(error)`, always on a later turn, so a throw in its
 *  listener never stops another call. Returns a cancel for a call that ends first (a kill); its question stays, so the
 *  answer is still kept for the next run. */
export function consent(go) {
  const settle = (error) => queueMicrotask(() => go(error));
  const now = allowed();
  if (now === false) { settle(refused()); return () => {}; }
  if (now === true) { settle(null); return () => {}; }
  const waiter = { go: settle };
  waiters.add(waiter);
  ask();
  return () => { waiters.delete(waiter); };
}

/** A call that cannot wait (spawnSync, execSync): null when allowed, else the error it fails with; not answered yet,
 *  Pilot asks meanwhile, so the call can be run again after Allow. */
export function consentNow() {
  const now = allowed();
  if (now === false) return refused();
  if (now === true) return null;
  ask();
  return Object.assign(new Error(`${title} has no yes yet to run AppleScript: Pilot is asking now; run it again after Allow`), { code: "EAGAIN" });
}

function ask() {
  if (serial) return;
  serial = ++serials;
  if (view) changed();
  else alert();
}

/** A no-view run's ask: one alert per run, whose buttons run this command again with the answer and a one-time nonce,
 *  so a context that does not carry it (a launchCommand's, a forged one) is not an answer. */
function alert() {
  if (alerted) return;
  alerted = true;
  const nonce = native.random(16);
  pendingAlert.write({ nonce, command });
  const button = (label, yes) => ({ type: "run", title: label, command, context: { ...(context ?? {}), pilotConsent: { allowed: yes, nonce } } });
  native.write(JSON.stringify({ type: "action", action: {
    type: "alert", text: `${title} wants to run AppleScript to control other apps.`, note: "macOS will then ask for each app too.",
    actions: [button("Don't Allow", false), button("Allow", true)],
  } }));
}

/** Whether this run sent a no-view consent alert: its failure is then the held call's, logged, never an error line,
 *  which would stand in for the alert (ExtensionRun keeps the first error line and drops the actions). */
export const consentAlerted = () => alerted;

/** The question being asked in the view, or null. */
export function question() {
  return serial ? { serial, text: `${title} wants to run AppleScript to control other apps.` } : null;
}

function keep(yes) {
  saved.write({ ...saved.read(), [key]: { allowed: yes, at: new Date().toISOString() } });
}

/** The answer to question `n`: only the open one takes it. Kept first, then every waiting call goes on or fails, and
 *  the view redraws. */
export function answer(n, yes) {
  if (!serial || n !== serial) return console.error(`consent answer for question ${n} is stale: answering the view unchanged`);
  keep(yes);
  serial = 0;
  for (const waiter of [...waiters]) { waiters.delete(waiter); waiter.go(yes ? null : refused()); }
  changed();
}

/** The view closed with the question open: its calls fail and nothing is kept. */
export function consentClosed() {
  serial = 0;
  for (const waiter of [...waiters]) {
    waiters.delete(waiter);
    waiter.go(Object.assign(new Error(`${title} closed before Pilot's question to run AppleScript was answered, so its osascript did not run`), { code: "ECANCELED" }));
  }
}
