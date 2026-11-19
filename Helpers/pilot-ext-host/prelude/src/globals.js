// The globals a bare JSContext lacks and React's scheduler needs before it loads (ADR 0017): console on stderr, timers
// on the host's native timers, queueMicrotask, performance.now and a small `process`. Stdout carries only Pilot's
// protocol lines, so nothing here prints there.
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

const started = Date.now();
globalThis.performance = { now: () => Date.now() - started };
globalThis.global = globalThis;
globalThis.process = { env: { NODE_ENV: "production" }, platform: "darwin", argv: [], nextTick: (fn, ...a) => queueMicrotask(() => fn(...a)) };
