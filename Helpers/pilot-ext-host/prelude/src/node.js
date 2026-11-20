// The Node subset Raycast extensions reach for (ADR 0017, T3), written from Node's documentation: `fs` (sync, callback
// and promise forms, text only: a read answers a string), `path` (POSIX), `os`, `crypto`'s hashes, `child_process`
// (spawn, exec, execFile and their sync forms; a `detached` child gets its own session and outlives the host),
// `events`, `util` and `url`. Every module is guarded: a member Node has and this lacks records its use (gaps.js), and
// a module this lacks records `require("<name>")`.
import { guard, lack } from "./gaps.js";
import { hexBytes } from "./web.js";

const native = globalThis.__native;

/** A native answer, or Node's error with its code. */
function check(answer, syscall) {
  if (answer && typeof answer === "object" && typeof answer.error === "string" && !Array.isArray(answer)) {
    throw Object.assign(new Error(answer.message ?? answer.error), { code: answer.error, errno: -1, syscall });
  }
  return answer;
}

const text = (p) => String(p instanceof URL ? fileURLToPath(p) : p);

// MARK: path

function normalizeParts(parts, absolute) {
  const out = [];
  for (const part of parts) {
    if (!part || part === ".") continue;
    if (part === "..") { if (out.length && out[out.length - 1] !== "..") out.pop(); else if (!absolute) out.push(".."); } else out.push(part);
  }
  return out;
}

const path = {
  sep: "/", delimiter: ":",
  isAbsolute: (p) => String(p).startsWith("/"),
  normalize(p) {
    const s = String(p);
    if (!s) return ".";
    const absolute = s.startsWith("/"), trailing = s.endsWith("/");
    const joined = normalizeParts(s.split("/"), absolute).join("/");
    return (absolute ? "/" : "") + (joined || (absolute ? "" : ".")) + (trailing && joined ? "/" : "");
  },
  join: (...parts) => path.normalize(parts.filter((p) => p !== "").map(String).join("/") || "."),
  resolve(...parts) {
    let out = "";
    for (let i = parts.length - 1; i >= 0 && !out.startsWith("/"); i--) if (parts[i]) out = `${parts[i]}/${out}`;
    if (!out.startsWith("/")) out = `${native.cwd()}/${out}`;
    return `/${normalizeParts(out.split("/"), true).join("/")}`;
  },
  dirname(p) {
    const s = String(p).replace(/\/+$/, "");
    if (!s) return String(p).startsWith("/") ? "/" : ".";
    const at = s.lastIndexOf("/");
    return at < 0 ? "." : at === 0 ? "/" : s.slice(0, at);
  },
  basename(p, ext) {
    const s = String(p).replace(/\/+$/, ""), base = s.slice(s.lastIndexOf("/") + 1);
    return ext && base.endsWith(ext) && base !== ext ? base.slice(0, -ext.length) : base;
  },
  extname(p) {
    const base = path.basename(p), at = base.lastIndexOf(".");
    return at <= 0 ? "" : base.slice(at);
  },
  relative(from, to) {
    const a = path.resolve(from).split("/").filter(Boolean), b = path.resolve(to).split("/").filter(Boolean);
    let i = 0;
    while (i < a.length && i < b.length && a[i] === b[i]) i++;
    return [...a.slice(i).map(() => ".."), ...b.slice(i)].join("/");
  },
  parse(p) {
    const s = String(p), root = s.startsWith("/") ? "/" : "", base = path.basename(s), ext = path.extname(s);
    const dir = s.includes("/") ? path.dirname(s) : "";
    return { root, dir, base, ext, name: ext ? base.slice(0, -ext.length) : base };
  },
  format: (o) => {
    const base = o.base ?? `${o.name ?? ""}${o.ext ?? ""}`, dir = o.dir ?? o.root ?? "";
    return dir ? (dir.endsWith("/") ? dir + base : `${dir}/${base}`) : base;
  },
  toNamespacedPath: (p) => p,
};
path.posix = path;

// MARK: fs

class Stats {
  constructor(s) {
    Object.assign(this, { size: s.size, mode: s.mode, mtimeMs: s.mtimeMs, birthtimeMs: s.birthtimeMs, ctimeMs: s.mtimeMs, atimeMs: s.mtimeMs });
    this.mtime = new Date(s.mtimeMs); this.ctime = this.mtime; this.atime = this.mtime; this.birthtime = new Date(s.birthtimeMs);
    this._kind = s;
  }
  isFile() { return this._kind.isFile; }
  isDirectory() { return this._kind.isDirectory; }
  isSymbolicLink() { return this._kind.isSymbolicLink; }
}

const encodingOf = (options) => (typeof options === "string" ? options : options?.encoding);

const sync = {
  existsSync: (p) => !native.fsStat(text(p), true).error,
  readFileSync(p, options) {
    const encoding = encodingOf(options);
    if (encoding && !/^utf-?8$/i.test(encoding)) lack(`fs.readFileSync as ${encoding}`);
    return check(native.fsRead(text(p)), "open");
  },
  writeFileSync: (p, data) => { check(native.fsWrite(text(p), String(data), false), "open"); },
  appendFileSync: (p, data) => { check(native.fsWrite(text(p), String(data), true), "open"); },
  statSync(p, options) {
    const s = native.fsStat(text(p), true);
    if (s?.error && options?.throwIfNoEntry === false) return undefined;
    return new Stats(check(s, "stat"));
  },
  lstatSync: (p) => new Stats(check(native.fsStat(text(p), false), "lstat")),
  readdirSync(p, options) {
    const names = check(native.fsList(text(p)), "scandir");
    if (!options?.withFileTypes) return names;
    return names.map((name) => {
      const s = check(native.fsStat(`${text(p)}/${name}`, false), "lstat");
      return { name, parentPath: text(p), path: text(p), isFile: () => s.isFile, isDirectory: () => s.isDirectory, isSymbolicLink: () => s.isSymbolicLink };
    });
  },
  mkdirSync: (p, options) => { check(native.fsMakeFolder(text(p), options === true || options?.recursive === true), "mkdir"); },
  unlinkSync: (p) => { check(native.fsRemove(text(p), false), "unlink"); },
  rmdirSync: (p, options) => { check(options?.recursive ? native.fsRemoveAll(text(p)) : native.fsRemove(text(p), true), "rmdir"); },
  rmSync(p, options) {
    const s = native.fsStat(text(p), false);
    if (s?.error) { if (options?.force) return; check(s, "rm"); }
    if (s.isDirectory && !options?.recursive) throw Object.assign(new Error(`EISDIR: is a directory, rm '${text(p)}'`), { code: "ERR_FS_EISDIR" });
    check(s.isDirectory ? native.fsRemoveAll(text(p)) : native.fsRemove(text(p), false), "rm");
  },
  renameSync: (a, b) => { check(native.fsMove(text(a), text(b)), "rename"); },
  copyFileSync: (a, b) => { check(native.fsCopy(text(a), text(b)), "copyfile"); },
  realpathSync: (p) => check(native.fsReal(text(p)), "realpath"),
  accessSync: (p) => { check(native.fsStat(text(p), true), "access"); },
};
sync.realpathSync.native = sync.realpathSync;

// Each sync call as a promise, and as Node's callback form (the callback last, its error first).
const promises = {};
const callbacks = {};
for (const [name, fn] of Object.entries(sync)) {
  if (name === "existsSync") continue;
  const plain = name.replace(/Sync$/, "");
  promises[plain] = (...args) => new Promise((resolve, reject) => { try { resolve(fn(...args)); } catch (error) { reject(error); } });
  callbacks[plain] = (...args) => {
    const done = typeof args[args.length - 1] === "function" ? args.pop() : () => {};
    let result, failure = null;
    try { result = fn(...args); } catch (error) { failure = error; }
    queueMicrotask(() => done(failure, result));
  };
}
const constants = { F_OK: 0, R_OK: 4, W_OK: 2, X_OK: 1 };
const fsPromises = guard("fs.promises", { ...promises, constants });
const fs = guard("fs", {
  ...sync, ...callbacks, promises: fsPromises, constants,
  exists: (p, done) => queueMicrotask(() => done(sync.existsSync(p))),
});

// MARK: os

const env = () => globalThis.process.env;
const os = guard("os", {
  EOL: "\n", homedir: () => env().HOME ?? "", tmpdir: () => String(env().TMPDIR ?? "/tmp").replace(/\/+$/, "") || "/tmp",
  platform: () => "darwin", type: () => "Darwin", arch: () => "arm64", hostname: () => native.hostname(), release: () => native.osRelease(),
  userInfo: () => ({ username: env().USER ?? "", homedir: env().HOME ?? "", shell: env().SHELL ?? "/bin/zsh", uid: -1, gid: -1 }),
  endianness: () => "LE", availableParallelism: () => 4,
});

// MARK: crypto

const hex64 = (hex) => btoa(String.fromCharCode(...hexBytes(hex)));
function encoded(hex, encoding) {
  if (encoding === "hex") return hex;
  if (encoding === "base64") return hex64(hex);
  if (encoding === "base64url") return hex64(hex).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
  return lack(`crypto digest as ${encoding ?? "a Buffer"}`);
}
const crypto = guard("crypto", {
  createHash(algorithm) {
    let data = "";
    const hash = guard("crypto.Hash", {
      update(more) {
        if (typeof more !== "string") lack("crypto.Hash.update with bytes");
        data += more;
        return hash;
      },
      digest: (encoding) => encoded(check(native.hash(String(algorithm), data), "digest"), encoding),
    });
    return hash;
  },
  randomUUID: () => globalThis.crypto.randomUUID(),
  randomBytes: (n) => { const hex = native.random(n); return { length: n, toString: (encoding = "hex") => encoded(hex, encoding) }; },
  getHashes: () => ["md5", "sha1", "sha256", "sha384", "sha512"],
  webcrypto: globalThis.crypto,
});

// MARK: events

class EventEmitter {
  #events = new Map();
  on(name, fn) { (this.#events.get(name) ?? this.#events.set(name, []).get(name)).push(fn); return this; }
  addListener(name, fn) { return this.on(name, fn); }
  prependListener(name, fn) { (this.#events.get(name) ?? this.#events.set(name, []).get(name)).unshift(fn); return this; }
  once(name, fn) { const once = (...a) => { this.off(name, once); fn.apply(this, a); }; once.listener = fn; return this.on(name, once); }
  off(name, fn) { const list = this.#events.get(name); if (list) this.#events.set(name, list.filter((f) => f !== fn && f.listener !== fn)); return this; }
  removeListener(name, fn) { return this.off(name, fn); }
  removeAllListeners(name) { if (name === undefined) this.#events.clear(); else this.#events.delete(name); return this; }
  emit(name, ...args) {
    const list = this.#events.get(name);
    if (!list?.length) { if (name === "error") throw args[0]; return false; }
    for (const fn of [...list]) fn.apply(this, args);
    return true;
  }
  listeners(name) { return [...(this.#events.get(name) ?? [])]; }
  listenerCount(name) { return this.#events.get(name)?.length ?? 0; }
  eventNames() { return [...this.#events.keys()]; }
  setMaxListeners() { return this; }
  getMaxListeners() { return 10; }
}
EventEmitter.EventEmitter = EventEmitter;
EventEmitter.once = (emitter, name) => new Promise((resolve) => emitter.once(name, (...a) => resolve(a)));

// MARK: child_process

const running = new Map();
let lastChild = 0;

/** A stream of a child's output: `data` events, as text once an encoding is set (and as text anyway: no Buffer yet). */
class Readable extends EventEmitter {
  setEncoding() { return this; }
  pipe() { return lack("child stream pipe"); }
}

class ChildProcess extends EventEmitter {
  constructor(id, pid, piped) {
    super();
    this._id = id;
    this.pid = pid;
    this.exitCode = null;
    this.signalCode = null;
    this.killed = false;
    this.stdout = piped ? new Readable() : null;
    this.stderr = piped ? new Readable() : null;
    this.stdin = piped ? { write: (t) => { native.childWrite(id, String(t)); return true; }, end: (t) => { if (t != null) native.childWrite(id, String(t)); native.childEnd(id); } } : null;
  }
  kill(signal = "SIGTERM") {
    const numbers = { SIGTERM: 15, SIGKILL: 9, SIGINT: 2, SIGHUP: 1 };
    const sent = native.childKill(this._id, typeof signal === "number" ? signal : numbers[signal] ?? 15);
    if (sent) this.killed = true;
    return sent;
  }
  unref() { native.unref(this._id); return this; }
  ref() { return this; }
}

globalThis.__pilotChild = (id, event, a, b) => {
  const child = running.get(id);
  if (!child) return;
  if (event === "stdout" || event === "stderr") child[event]?.emit("data", a);
  else if (event === "exit") { child.exitCode = a; child.signalCode = b; child.emit("exit", a, b); } else if (event === "close") {
    running.delete(id);
    child.emit("close", child.exitCode, child.signalCode);
  }
};

function spawnOptions(options = {}) {
  const stdio = Array.isArray(options.stdio) ? (options.stdio.every((s) => s === "ignore") ? "ignore" : "pipe") : options.stdio === "ignore" ? "ignore" : "pipe";
  return { cwd: options.cwd ? text(options.cwd) : undefined, env: options.env, detached: options.detached === true, stdio };
}

/** `[file, args]` for a command line run by a shell, as `shell: true` and exec do. */
const shell = (command, options) => [typeof options?.shell === "string" ? options.shell : "/bin/sh", ["-c", command]];

function spawn(file, args = [], options = {}) {
  if (!Array.isArray(args)) { options = args ?? {}; args = []; }
  if (options.shell) [file, args] = shell([file, ...args].join(" "), options);
  const id = ++lastChild, made = spawnOptions(options);
  const pid = native.spawn(id, String(file), args.map(String), made);
  const child = new ChildProcess(id, typeof pid === "number" ? pid : undefined, made.stdio === "pipe");
  if (typeof pid !== "number") {
    queueMicrotask(() => child.emit("error", Object.assign(new Error(`spawn ${file} ${pid?.error ?? "failed"}`), { code: pid?.error, syscall: `spawn ${file}`, path: file })));
    return child;
  }
  running.set(id, child);
  return child;
}

/** Runs `file` to its end, collecting its output for `done(error, stdout, stderr)`; a non-zero exit is the error. */
function collect(file, args, options, done) {
  const child = spawn(file, args, { ...options, stdio: "pipe" });
  let stdout = "", stderr = "";
  child.stdout?.on("data", (d) => { stdout += d; });
  child.stderr?.on("data", (d) => { stderr += d; });
  child.on("error", (error) => done?.(error, stdout, stderr));
  child.on("close", (code, signal) => {
    if (code === 0) return done?.(null, stdout, stderr);
    const error = Object.assign(new Error(`Command failed: ${[file, ...args].join(" ")}\n${stderr}`), { code, signal, killed: child.killed, stdout, stderr });
    done?.(error, stdout, stderr);
  });
  return child;
}

function exec(command, options, done) {
  if (typeof options === "function") { done = options; options = {}; }
  const [file, args] = shell(command, options);
  return collect(file, args, options, done);
}

function execFile(file, args, options, done) {
  if (typeof args === "function") { done = args; args = []; options = {}; } else if (typeof options === "function") { done = options; options = {}; }
  if (!Array.isArray(args)) { options = args ?? {}; args = []; }
  return collect(file, args, options ?? {}, done);
}

// util.promisify of exec and execFile answers { stdout, stderr }, as Node's own does.
const custom = Symbol.for("nodejs.util.promisify.custom");
for (const fn of [exec, execFile]) {
  fn[custom] = (...args) => new Promise((resolve, reject) => {
    fn(...args, (error, stdout, stderr) => (error ? reject(Object.assign(error, { stdout, stderr })) : resolve({ stdout, stderr })));
  });
}

function spawnSync(file, args = [], options = {}) {
  if (!Array.isArray(args)) { options = args ?? {}; args = []; }
  if (options.shell) [file, args] = shell([file, ...args].join(" "), options);
  const made = spawnOptions(options);
  const r = native.spawnSync(String(file), args.map(String), made, options.input == null ? "" : String(options.input));
  if (r.error) return { pid: 0, status: null, signal: null, stdout: "", stderr: "", output: [null, "", ""], error: Object.assign(new Error(r.message), { code: r.error }) };
  return { pid: r.pid, status: r.status, signal: r.signal, stdout: r.stdout, stderr: r.stderr, output: [null, r.stdout, r.stderr] };
}

function execFileSync(file, args = [], options = {}) {
  const r = spawnSync(file, args, options);
  if (r.error) throw r.error;
  if (r.status !== 0) throw Object.assign(new Error(`Command failed: ${[file, ...(Array.isArray(args) ? args : [])].join(" ")}\n${r.stderr}`), r);
  return r.stdout;
}

function execSync(command, options = {}) {
  const [file, args] = shell(command, options);
  return execFileSync(file, args, options);
}

const childProcess = guard("child_process", { spawn, exec, execFile, spawnSync, execSync, execFileSync, ChildProcess });

// MARK: util and url

function promisify(fn) {
  if (typeof fn[custom] === "function") return fn[custom];
  return (...args) => new Promise((resolve, reject) => fn(...args, (error, value) => (error ? reject(error) : resolve(value))));
}
promisify.custom = custom;

function format(first, ...rest) {
  if (typeof first !== "string") return [first, ...rest].map(inspect).join(" ");
  let i = 0;
  const out = first.replace(/%[sdifjoO%]/g, (m) => {
    if (m === "%%") return "%";
    if (i >= rest.length) return m;
    const v = rest[i++];
    return m === "%s" ? String(v) : m === "%d" || m === "%i" ? String(parseInt(v, 10)) : m === "%f" ? String(parseFloat(v)) : inspect(v);
  });
  return [out, ...rest.slice(i).map(inspect)].join(" ");
}

function inspect(v) {
  if (typeof v === "string") return v;
  try { return JSON.stringify(v) ?? String(v); } catch { return String(v); }
}

const util = guard("util", {
  promisify, format, inspect, deprecate: (fn) => fn, inherits: (a, b) => { Object.setPrototypeOf(a.prototype, b.prototype); Object.setPrototypeOf(a, b); },
  TextEncoder: globalThis.TextEncoder, TextDecoder: globalThis.TextDecoder, isDeepStrictEqual: (a, b) => JSON.stringify(a) === JSON.stringify(b),
  types: { isPromise: (p) => p instanceof Promise, isDate: (d) => d instanceof Date, isRegExp: (r) => r instanceof RegExp },
});

function fileURLToPath(u) {
  const url = u instanceof URL ? u : new URL(String(u));
  if (url.protocol !== "file:") throw new TypeError("The URL must be of scheme file");
  return decodeURIComponent(url.pathname);
}

const url = guard("url", {
  URL: globalThis.URL, URLSearchParams: globalThis.URLSearchParams, fileURLToPath,
  pathToFileURL: (p) => new URL(`file://${encodeURI(path.resolve(String(p)))}`),
});

/** The modules `require` finds, by name, `node:` or not. */
export { path, childProcess };
export const modules = {
  fs, "fs/promises": fsPromises, path, "path/posix": path, os, crypto, child_process: childProcess,
  events: EventEmitter, util, url,
};
