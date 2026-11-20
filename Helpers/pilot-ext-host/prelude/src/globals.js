// The globals a bare JSContext lacks and React's scheduler needs before it loads (ADR 0017): console on stderr, timers
// on the host's native timers, queueMicrotask, performance.now and a small `process`; and the web globals extensions
// use (T3, web.js): base64, text codecs, URL, AbortController and fetch. Stdout carries only Pilot's protocol lines, so
// nothing here prints there.
import { missing, stubs } from "./gaps.js";
import "./web.js";
import { Buffer } from "./buffer.js";
const native = globalThis.__native;

function text(args) {
  return args.map((a) => {
    if (typeof a === "string") return a;
    if (a instanceof Error) return a.stack ? `${a.message}\n${a.stack}` : String(a.message);
    try { return JSON.stringify(a); } catch { return String(a); }
  }).join(" ");
}

globalThis.console = {
  log: (...a) => native.log("log", text(a)),
  info: (...a) => native.log("info", text(a)),
  debug: (...a) => native.log("debug", text(a)),
  warn: (...a) => native.log("warn", text(a)),
  error: (...a) => native.log("error", text(a)),
};

// Every JS timer is one native timer; the host counts them to know when a run has nothing left to do.
const callbacks = new Map();
let lastID = 0;

function arm(fn, ms, args, repeat) {
  const id = ++lastID;
  const delay = Math.max(0, Number(ms) || 0);
  callbacks.set(id, { fn, args, repeat, delay });
  native.setTimer(id, delay);
  return id;
}

globalThis.__pilotFire = (id) => {
  const timer = callbacks.get(id);
  if (!timer) return;
  if (timer.repeat) native.setTimer(id, timer.delay); else callbacks.delete(id);
  if (typeof timer.fn === "function") timer.fn(...timer.args);
};

function disarm(id) {
  if (callbacks.delete(id)) native.clearTimer(id);
}

globalThis.setTimeout = (fn, ms, ...args) => arm(fn, ms, args, false);
globalThis.setInterval = (fn, ms, ...args) => arm(fn, ms, args, true);
globalThis.clearTimeout = disarm;
globalThis.clearInterval = disarm;
globalThis.queueMicrotask = (fn) => { Promise.resolve().then(fn); };
// Node's setImmediate as the next timer turn (T7: fast-glob, Obsidian's notes).
globalThis.setImmediate = (fn, ...args) => arm(fn, 0, args, false);
globalThis.clearImmediate = disarm;

const started = Date.now();
globalThis.performance = { now: () => Date.now() - started };
globalThis.global = globalThis;
// The child's own environment, which Pilot keeps small (HOME, USER, TMPDIR, PATH, LANG and the extension's id).
const env = { ...native.env(), NODE_ENV: "production" };
// No Node ships with Pilot, so execPath is empty (execa reads it as its default nodePath, used only for node scripts) and
// execArgv holds no flags.
// Node's hrtime from performance.now(), so to the millisecond here: [seconds, nanoseconds] since an arbitrary start, less
// `previous` when given, and hrtime.bigint() as nanoseconds (T15: execa times each child with it).
function hrtime(previous) {
  const ns = Math.round(performance.now() * 1e6), [s, n] = [Math.floor(ns / 1e9), ns % 1e9];
  if (!Array.isArray(previous)) return [s, n];
  const d = (s - previous[0]) * 1e9 + (n - previous[1]);
  return [Math.floor(d / 1e9), d % 1e9];
}
hrtime.bigint = () => BigInt(Math.round(performance.now() * 1e6));
globalThis.process = stubs("process", ["exit", "on", "once", "kill", "chdir", "memoryUsage", "uptime", "stdout", "stderr", "stdin"], {
  env, hrtime, platform: "darwin", arch: "arm64", argv: [], execArgv: [], execPath: "", pid: 0, version: "v22.14.0", versions: { node: "22.14.0" }, release: { name: "node" },
  cwd: () => native.cwd(), nextTick: (fn, ...a) => queueMicrotask(() => fn(...a)), emitWarning: (w) => console.warn(String(w)),
});
// Node's Buffer (buffer.js, T7); the browser's Blob and friends are not here yet: each is a stub that records its use.
globalThis.Buffer = Buffer;
for (const name of ["Blob", "FormData", "WebSocket", "XMLHttpRequest", "EventSource", "structuredClone"]) {
  globalThis[name] = missing(`global.${name}`);
}
