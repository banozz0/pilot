// Node's Buffer, `string_decoder`, the `process` module and a `stream` that only loads, for the prelude (ADR 0017, T7), written from nodejs.org's
// API docs: a Buffer is a Uint8Array with Node's encodings (utf8, base64 and base64url, hex, latin1, ascii, utf16le) and
// its common statics and methods, enough for the top 20's `node:buffer` and `node:process` imports. Child output
// still arrives as text (node.js), so most extensions only build and print Buffers. Anything else of Node's buffer
// (the read and write number methods, `transcode`, `Blob`) is not here.
import { stubs } from "./gaps.js";
import { hexBytes } from "./web.js";

const encoder = new TextEncoder(), decoder = new TextDecoder();

function encodingOf(name = "utf8") {
  const e = String(name).toLowerCase().replace("-", "");
  if (e === "utf8") return "utf8";
  if (["ucs2", "utf16le"].includes(e)) return "utf16le";
  if (e === "binary") return "latin1";
  if (["base64", "base64url", "hex", "latin1", "ascii"].includes(e)) return e;
  throw new TypeError(`Unknown encoding: ${name}`);
}

function bytesOf(text, encoding) {
  const s = String(text);
  switch (encodingOf(encoding)) {
    case "utf8": return encoder.encode(s);
    case "base64":
    case "base64url": {
      const plain = s.replace(/-/g, "+").replace(/_/g, "/").replace(/[^A-Za-z0-9+/]/g, "");
      return Uint8Array.from(atob(plain + "===".slice((plain.length + 3) % 4)), (c) => c.charCodeAt(0));
    }
    case "hex": return hexBytes(s.match(/[0-9a-fA-F]{2}/g)?.join("") ?? "");
    case "utf16le": {
      const out = new Uint8Array(s.length * 2);
      for (let i = 0; i < s.length; i++) { const c = s.charCodeAt(i); out[2 * i] = c & 255; out[2 * i + 1] = c >> 8; }
      return out;
    }
    default: return Uint8Array.from(s, (c) => c.charCodeAt(0) & 255);
  }
}

function textOf(bytes, encoding) {
  const latin = () => { let s = ""; for (let i = 0; i < bytes.length; i += 8192) s += String.fromCharCode(...bytes.subarray(i, i + 8192)); return s; };
  switch (encodingOf(encoding)) {
    case "utf8": return decoder.decode(bytes);
    case "base64": return btoa(latin());
    case "base64url": return btoa(latin()).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
    case "hex": return Array.from(bytes, (b) => b.toString(16).padStart(2, "0")).join("");
    case "ascii": return latin().replace(/[\x80-\xff]/g, (c) => String.fromCharCode(c.charCodeAt(0) & 127));
    case "utf16le": {
      let s = "";
      for (let i = 0; i + 1 < bytes.length; i += 2) s += String.fromCharCode(bytes[i] | (bytes[i + 1] << 8));
      return s;
    }
    default: return latin();
  }
}

export class Buffer extends Uint8Array {
  static from(value, encodingOrOffset, length) {
    if (typeof value === "string") return Buffer.#wrap(bytesOf(value, encodingOrOffset));
    if (value instanceof ArrayBuffer) {
      const at = encodingOrOffset ?? 0;
      return new Buffer(value, at, length ?? value.byteLength - at);
    }
    if (ArrayBuffer.isView(value)) return Buffer.#wrap(new Uint8Array(value.buffer, value.byteOffset, value.byteLength).slice());
    if (Array.isArray(value)) return Buffer.#wrap(Uint8Array.from(value));
    if (value && value.type === "Buffer" && Array.isArray(value.data)) return Buffer.#wrap(Uint8Array.from(value.data));
    throw new TypeError("The first argument must be a string, Buffer, ArrayBuffer, Array or array-like object");
  }
  static #wrap(bytes) { return new Buffer(bytes.buffer, bytes.byteOffset, bytes.byteLength); }
  static alloc(size, fill, encoding) {
    const b = new Buffer(size);
    if (fill !== undefined) typeof fill === "string" ? b.set(fillOf(bytesOf(fill, encoding), size)) : b.fill(fill);
    return b;
  }
  static allocUnsafe(size) { return new Buffer(size); }
  static allocUnsafeSlow(size) { return new Buffer(size); }
  static isBuffer(value) { return value instanceof Buffer; }
  static isEncoding(name) { try { encodingOf(name); return true; } catch { return false; } }
  static byteLength(value, encoding) { return typeof value === "string" ? bytesOf(value, encoding).length : value.byteLength; }
  static concat(list, total) {
    const size = total ?? list.reduce((n, b) => n + b.length, 0);
    const out = Buffer.alloc(size);
    let at = 0;
    for (const b of list) { if (at >= size) break; out.set(b.subarray(0, size - at), at); at += b.length; }
    return out;
  }
  static compare(a, b) {
    for (let i = 0; i < Math.min(a.length, b.length); i++) if (a[i] !== b[i]) return a[i] < b[i] ? -1 : 1;
    return a.length === b.length ? 0 : a.length < b.length ? -1 : 1;
  }
  toString(encoding = "utf8", start = 0, end = this.length) { return textOf(this.subarray(start, end), encoding); }
  toJSON() { return { type: "Buffer", data: Array.from(this) }; }
  equals(other) { return Buffer.compare(this, other) === 0; }
  compare(other) { return Buffer.compare(this, other); }
  /** Node's slice shares memory, as subarray does. */
  slice(start, end) { return this.subarray(start, end); }
  write(text, offset = 0, length, encoding = "utf8") {
    if (typeof offset === "string") [encoding, offset] = [offset, 0];
    if (typeof length === "string") [encoding, length] = [length, undefined];
    const bytes = bytesOf(text, encoding).subarray(0, Math.min(length ?? Infinity, this.length - offset));
    this.set(bytes, offset);
    return bytes.length;
  }
  copy(target, targetStart = 0, start = 0, end = this.length) {
    const part = this.subarray(start, Math.min(end, start + target.length - targetStart));
    target.set(part, targetStart);
    return part.length;
  }
  includes(value, from) { return this.indexOf(value, from) !== -1; }
  indexOf(value, from = 0) {
    if (typeof value === "number") return super.indexOf(value, from);
    const needle = typeof value === "string" ? bytesOf(value) : value;
    for (let i = from; i + needle.length <= this.length; i++) if (needle.every((b, j) => this[i + j] === b)) return i;
    return -1;
  }
}

function fillOf(pattern, size) {
  const out = new Uint8Array(size);
  if (pattern.length) for (let i = 0; i < size; i++) out[i] = pattern[i % pattern.length];
  return out;
}

/** `string_decoder`: text from Buffers that may end mid-character, the rest kept for the next write. */
class StringDecoder {
  #encoding;
  #rest = new Uint8Array(0);
  constructor(encoding = "utf8") { this.#encoding = encodingOf(encoding); }
  write(chunk) {
    if (typeof chunk === "string") return chunk;
    const bytes = new Uint8Array(this.#rest.length + chunk.length);
    bytes.set(this.#rest);
    bytes.set(chunk, this.#rest.length);
    const cut = this.#encoding === "utf8" ? whole(bytes) : this.#encoding === "utf16le" ? bytes.length - (bytes.length % 2) : bytes.length;
    this.#rest = bytes.slice(cut);
    return textOf(bytes.subarray(0, cut), this.#encoding);
  }
  end(chunk) {
    const text = chunk ? this.write(chunk) : "";
    const rest = this.#rest;
    this.#rest = new Uint8Array(0);
    return text + (rest.length ? textOf(rest, this.#encoding) : "");
  }
}

/** How many of `bytes` end on a whole UTF-8 character. */
function whole(bytes) {
  for (let back = 1; back <= Math.min(3, bytes.length); back++) {
    const b = bytes[bytes.length - back];
    if ((b & 0xc0) === 0x80) continue;
    const needs = b >= 0xf0 ? 4 : b >= 0xe0 ? 3 : b >= 0xc0 ? 2 : 1;
    return needs > back ? bytes.length - back : bytes.length;
  }
  return bytes.length;
}

/** The modules this file adds to `require`, by name, `node:` or not. */
export const modules = {
  buffer: { Buffer, constants: { MAX_LENGTH: 2 ** 32 - 1 }, kMaxLength: 2 ** 32 - 1 },
  string_decoder: { StringDecoder },
  get process() { return globalThis.process; },
  // Only loaded, not yet Node's streams: @raycast/utils' exec helpers import it whole; each member records its use and throws.
  // getDefaultHighWaterMark is real: execa reads it at load (Node 22's 65536 bytes, 16 objects; T15).
  stream: stubs("stream", ["Readable", "Writable", "Duplex", "Transform", "PassThrough", "Stream", "pipeline", "finished"],
    { getDefaultHighWaterMark: (objectMode) => (objectMode ? 16 : 65536) }),
  // The same for its promise forms (Speedtest, Video Downloader import them at load; T15).
  "stream/promises": stubs("stream/promises", ["pipeline", "finished"]),
  // Only loaded: execa checks an IPC message with v8.serialize, which no extension's own call reaches here.
  v8: stubs("v8", ["serialize", "deserialize"]),
  // Only loaded: axios's Node adapter and follow-redirects require them at load; a request through them records and throws
  // (fetch is the host's HTTP; T15: Google Translate's speech package loads axios).
  http: stubs("http", ["request", "get", "Agent", "createServer"]),
  https: stubs("https", ["request", "get", "Agent"]),
  zlib: stubs("zlib", ["createGunzip", "createInflate", "createBrotliDecompress", "gunzipSync", "inflateSync"], { constants: {} }),
};
