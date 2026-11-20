// The web globals a bare JSContext lacks and Raycast extensions use (ADR 0017, T3), written from the WHATWG and MDN
// descriptions: atob and btoa, TextEncoder and TextDecoder (UTF-8), URL and URLSearchParams (parsed by Foundation in
// the host), AbortController, Headers, Response and fetch (URLSession in the host, http and https only, the body as
// text). A response's binary body is not here yet and records its use.
import { lack } from "./gaps.js";

const native = globalThis.__native;
const letters = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";

globalThis.btoa = (text) => {
  const s = String(text);
  let out = "";
  for (let i = 0; i < s.length; i += 3) {
    const [a, b, c] = [s.charCodeAt(i), s.charCodeAt(i + 1), s.charCodeAt(i + 2)];
    if (a > 255 || b > 255 || c > 255) throw new Error("btoa: a character outside Latin-1");
    const n = (a << 16) | ((b || 0) << 8) | (c || 0);
    out += letters[n >> 18] + letters[(n >> 12) & 63] + (i + 1 < s.length ? letters[(n >> 6) & 63] : "=") + (i + 2 < s.length ? letters[n & 63] : "=");
  }
  return out;
};

globalThis.atob = (text) => {
  const s = String(text).replace(/[\s=]+/g, "");
  let out = "", bits = 0, value = 0;
  for (const ch of s) {
    const v = letters.indexOf(ch);
    if (v < 0) throw new Error("atob: not base64");
    value = (value << 6) | v;
    bits += 6;
    if (bits >= 8) { bits -= 8; out += String.fromCharCode((value >> bits) & 255); }
  }
  return out;
};

globalThis.TextEncoder = class TextEncoder {
  get encoding() { return "utf-8"; }
  encode(text = "") { return Uint8Array.from(unescape(encodeURIComponent(String(text))), (c) => c.charCodeAt(0)); }
};

globalThis.TextDecoder = class TextDecoder {
  get encoding() { return "utf-8"; }
  decode(bytes) {
    if (!bytes) return "";
    const view = bytes instanceof Uint8Array ? bytes : new Uint8Array(bytes.buffer ?? bytes);
    let s = "";
    for (let i = 0; i < view.length; i += 8192) s += String.fromCharCode(...view.subarray(i, i + 8192));
    try { return decodeURIComponent(escape(s)); } catch { return s; }
  }
};

// MARK: URL

const plus = (s) => decodeURIComponent(s.replace(/\+/g, " "));
const encodeForm = (s) => encodeURIComponent(s).replace(/%20/g, "+").replace(/[!'()~]/g, (c) => `%${c.charCodeAt(0).toString(16).toUpperCase()}`);

globalThis.URLSearchParams = class URLSearchParams {
  #pairs = [];
  #changed;
  constructor(init, changed) {
    this.#changed = changed;
    if (typeof init === "string") this.#read(init);
    else if (init && typeof init[Symbol.iterator] === "function") for (const [k, v] of init) this.#pairs.push([String(k), String(v)]);
    else if (init && typeof init === "object") for (const k of Object.keys(init)) this.#pairs.push([k, String(init[k])]);
  }
  #read(text) {
    this.#pairs = String(text).replace(/^\?/, "").split("&").filter(Boolean).map((part) => {
      const at = part.indexOf("=");
      return at < 0 ? [plus(part), ""] : [plus(part.slice(0, at)), plus(part.slice(at + 1))];
    });
  }
  #change() { this.#changed?.(this.toString()); }
  /** The URL's own, read again when its search changes. */
  _reset(text) { this.#read(text); }
  get size() { return this.#pairs.length; }
  append(k, v) { this.#pairs.push([String(k), String(v)]); this.#change(); }
  set(k, v) {
    const at = this.#pairs.findIndex(([n]) => n === String(k));
    if (at < 0) this.#pairs.push([String(k), String(v)]);
    else { this.#pairs[at][1] = String(v); this.#pairs = this.#pairs.filter(([n], i) => i <= at || n !== String(k)); }
    this.#change();
  }
  get(k) { return this.#pairs.find(([n]) => n === String(k))?.[1] ?? null; }
  getAll(k) { return this.#pairs.filter(([n]) => n === String(k)).map(([, v]) => v); }
  has(k) { return this.#pairs.some(([n]) => n === String(k)); }
  delete(k) { this.#pairs = this.#pairs.filter(([n]) => n !== String(k)); this.#change(); }
  sort() { this.#pairs.sort(([a], [b]) => (a < b ? -1 : a > b ? 1 : 0)); this.#change(); }
  forEach(fn, self) { for (const [k, v] of this.#pairs) fn.call(self, v, k, this); }
  keys() { return this.#pairs.map(([k]) => k)[Symbol.iterator](); }
  values() { return this.#pairs.map(([, v]) => v)[Symbol.iterator](); }
  entries() { return this.#pairs.map((p) => [...p])[Symbol.iterator](); }
  [Symbol.iterator]() { return this.entries(); }
  toString() { return this.#pairs.map(([k, v]) => `${encodeForm(k)}=${encodeForm(v)}`).join("&"); }
};

const special = { "http:": "80", "https:": "443", "ws:": "80", "wss:": "443", "ftp:": "21" };

globalThis.URL = class URL {
  #p;
  #params;
  constructor(input, base) {
    const parts = native.parseURL(String(input), base === undefined ? "" : String(base instanceof URL ? base.href : base));
    if (!parts) throw new TypeError(`Invalid URL: ${input}`);
    if (special[parts.protocol] && !parts.pathname) parts.pathname = "/";
    if (special[parts.protocol] === parts.port) parts.port = "";
    this.#p = parts;
    this.#params = new URLSearchParams(parts.search, (text) => { this.#p.search = text ? `?${text}` : ""; });
  }
  static canParse(input, base) { try { new URL(input, base); return true; } catch { return false; } }
  get protocol() { return this.#p.protocol; }
  get username() { return this.#p.username; }
  get password() { return this.#p.pass; }
  get hostname() { return this.#p.hostname; }
  get port() { return this.#p.port; }
  get host() { return this.#p.hostname + (this.#p.port ? `:${this.#p.port}` : ""); }
  get origin() { return special[this.#p.protocol] ? `${this.#p.protocol}//${this.host}` : "null"; }
  get pathname() { return this.#p.pathname; }
  set pathname(v) { const s = String(v); this.#p.pathname = s.startsWith("/") || !this.#p.slashes ? s : `/${s}`; }
  get search() { return this.#p.search.length > 1 ? this.#p.search : ""; }
  set search(v) { const s = String(v).replace(/^\?/, ""); this.#p.search = s ? `?${s}` : ""; this.#params._reset(s); }
  get searchParams() { return this.#params; }
  get hash() { return this.#p.hash.length > 1 ? this.#p.hash : ""; }
  set hash(v) { const s = String(v).replace(/^#/, ""); this.#p.hash = s ? `#${s}` : ""; }
  get href() {
    const p = this.#p, auth = p.username ? `${p.username}${p.pass ? `:${p.pass}` : ""}@` : "";
    return `${p.protocol}${p.slashes ? "//" : ""}${auth}${this.host}${p.pathname}${this.search}${this.hash}`;
  }
  toString() { return this.href; }
  toJSON() { return this.href; }
};

// MARK: Abort

class AbortSignal {
  aborted = false;
  reason = undefined;
  onabort = null;
  #listeners = [];
  addEventListener(type, fn) { if (type === "abort") this.#listeners.push(fn); }
  removeEventListener(type, fn) { this.#listeners = this.#listeners.filter((f) => f !== fn); }
  throwIfAborted() { if (this.aborted) throw this.reason; }
  _abort(reason) {
    if (this.aborted) return;
    this.aborted = true;
    this.reason = reason ?? Object.assign(new Error("This operation was aborted"), { name: "AbortError" });
    const event = { type: "abort", target: this };
    this.onabort?.(event);
    for (const fn of this.#listeners) fn(event);
  }
  static timeout(ms) {
    const signal = new AbortSignal();
    setTimeout(() => signal._abort(Object.assign(new Error("The operation timed out"), { name: "TimeoutError" })), ms);
    return signal;
  }
  static abort(reason) { const signal = new AbortSignal(); signal._abort(reason); return signal; }
}
globalThis.AbortSignal = AbortSignal;
globalThis.AbortController = class AbortController {
  signal = new AbortSignal();
  abort(reason) { this.signal._abort(reason); }
};

// MARK: fetch

globalThis.Headers = class Headers {
  #map = new Map();
  constructor(init) {
    if (init instanceof Headers) init.forEach((v, k) => this.append(k, v));
    else if (Array.isArray(init)) for (const [k, v] of init) this.append(k, v);
    else if (init && typeof init === "object") for (const k of Object.keys(init)) this.append(k, init[k]);
  }
  append(k, v) { const key = String(k).toLowerCase(), old = this.#map.get(key); this.#map.set(key, old == null ? String(v) : `${old}, ${v}`); }
  set(k, v) { this.#map.set(String(k).toLowerCase(), String(v)); }
  get(k) { return this.#map.get(String(k).toLowerCase()) ?? null; }
  // Each Set-Cookie on its own (fetch's spec), split from the joined value at a comma before the next `name=`, so an
  // `Expires=Sat, 21 Nov …` date stays whole (Stock Tracker reads Yahoo's cookie this way, T27).
  getSetCookie() { return this.#map.get("set-cookie")?.split(/,\s*(?=[^;,=\s]+=)/) ?? []; }
  has(k) { return this.#map.has(String(k).toLowerCase()); }
  delete(k) { this.#map.delete(String(k).toLowerCase()); }
  forEach(fn, self) { for (const [k, v] of this.#map) fn.call(self, v, k, this); }
  keys() { return this.#map.keys(); }
  values() { return this.#map.values(); }
  entries() { return this.#map.entries(); }
  [Symbol.iterator]() { return this.#map.entries(); }
};

globalThis.Response = class Response {
  #body;
  #used = false;
  constructor(body = "", init = {}) {
    this.#body = body == null ? "" : String(body);
    this.status = init.status ?? 200;
    this.statusText = init.statusText ?? "";
    this.headers = new Headers(init.headers);
    this.url = init.url ?? "";
    this.ok = this.status >= 200 && this.status < 300;
    this.redirected = false;
    this.type = "basic";
  }
  get bodyUsed() { return this.#used; }
  async text() { this.#used = true; return this.#body; }
  async json() { this.#used = true; return JSON.parse(this.#body); }
  async arrayBuffer() { lack("Response.arrayBuffer"); }
  async blob() { lack("Response.blob"); }
  get body() { return lack("Response.body"); }
  clone() { return new Response(this.#body, { status: this.status, statusText: this.statusText, headers: this.headers, url: this.url }); }
};

const fetches = new Map();
let lastFetch = 0;

globalThis.fetch = (input, init = {}) => new Promise((resolve, reject) => {
  const url = input instanceof URL ? input.href : typeof input === "string" ? input : String(input?.url ?? input);
  const method = String(init.method ?? input?.method ?? "GET");
  const headers = [...new Headers(init.headers ?? input?.headers)];
  let body = init.body;
  if (body instanceof URLSearchParams) {
    body = body.toString();
    if (!headers.some(([k]) => k === "content-type")) headers.push(["content-type", "application/x-www-form-urlencoded;charset=UTF-8"]);
  } else if (body != null && typeof body !== "string") {
    try { lack(`fetch with a ${body?.constructor?.name ?? typeof body} body`); } catch (error) { return reject(error); }
  }
  const signal = init.signal;
  if (signal?.aborted) return reject(signal.reason);
  const id = ++lastFetch;
  fetches.set(id, { resolve, reject });
  signal?.addEventListener("abort", () => { if (fetches.delete(id)) reject(signal.reason); });
  native.fetch(id, { url, method, headers, body: body ?? undefined });
});

globalThis.__pilotFetched = (id, answer) => {
  const waiting = fetches.get(id);
  if (!waiting) return;
  fetches.delete(id);
  if (answer.error) return waiting.reject(new TypeError(`fetch failed: ${answer.error}`));
  waiting.resolve(new Response(answer.body, { status: answer.status, statusText: answer.statusText, headers: answer.headers, url: answer.url }));
};

// MARK: Web Crypto, the two calls extensions use

export const hexBytes = (hex) => Uint8Array.from(hex.match(/../g) ?? [], (h) => parseInt(h, 16));
globalThis.crypto = {
  getRandomValues(array) {
    const bytes = hexBytes(native.random(array.byteLength));
    new Uint8Array(array.buffer, array.byteOffset, array.byteLength).set(bytes);
    return array;
  },
  randomUUID() {
    const b = hexBytes(native.random(16));
    b[6] = (b[6] & 0x0f) | 0x40;
    b[8] = (b[8] & 0x3f) | 0x80;
    const h = [...b].map((x) => x.toString(16).padStart(2, "0")).join("");
    return `${h.slice(0, 8)}-${h.slice(8, 12)}-${h.slice(12, 16)}-${h.slice(16, 20)}-${h.slice(20)}`;
  },
  get subtle() { return lack("crypto.subtle"); },
};
