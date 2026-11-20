// Node's zlib for the prelude (spec raycast-extensions T26), written from nodejs.org's `zlib` docs: Deflate, Inflate,
// Gzip, Gunzip, DeflateRaw, InflateRaw and Unzip, as Transform streams, their create* factories, the sync, callback and
// promisified one-shot forms, crc32 and the constants. The compression is macOS's own libz in the host (Bytes.swift),
// the library Node's zlib binds, so its output and its errors are Node's. Each class also has the inside node-tar's
// minizlib reaches for: `_handle` (a `close` it swaps out) and a synchronous `_processChunk(chunk, flushFlag)` that
// answers `Buffer.concat` of the output, so minizlib's no-op concat gets the pieces. Brotli and zstd are not here: they
// record their use.
import { missing } from "./gaps.js";
import { Buffer } from "./buffer.js";
import { Transform } from "./stream.js";

const native = globalThis.__native;

export const constants = Object.freeze({
  Z_NO_FLUSH: 0, Z_PARTIAL_FLUSH: 1, Z_SYNC_FLUSH: 2, Z_FULL_FLUSH: 3, Z_FINISH: 4, Z_BLOCK: 5, Z_TREES: 6,
  Z_OK: 0, Z_STREAM_END: 1, Z_NEED_DICT: 2, Z_ERRNO: -1, Z_STREAM_ERROR: -2, Z_DATA_ERROR: -3, Z_MEM_ERROR: -4, Z_BUF_ERROR: -5,
  Z_VERSION_ERROR: -6, Z_NO_COMPRESSION: 0, Z_BEST_SPEED: 1, Z_BEST_COMPRESSION: 9, Z_DEFAULT_COMPRESSION: -1, Z_FILTERED: 1,
  Z_HUFFMAN_ONLY: 2, Z_RLE: 3, Z_FIXED: 4, Z_DEFAULT_STRATEGY: 0, ZLIB_VERNUM: 4865, DEFLATE: 1, INFLATE: 2, GZIP: 3, GUNZIP: 4,
  DEFLATERAW: 5, INFLATERAW: 6, UNZIP: 7, BROTLI_DECODE: 8, BROTLI_ENCODE: 9, Z_MIN_WINDOWBITS: 8, Z_MAX_WINDOWBITS: 15,
  Z_DEFAULT_WINDOWBITS: 15, Z_MIN_CHUNK: 64, Z_MAX_CHUNK: Infinity, Z_DEFAULT_CHUNK: 16384, Z_MIN_MEMLEVEL: 1, Z_MAX_MEMLEVEL: 9,
  Z_DEFAULT_MEMLEVEL: 8, Z_MIN_LEVEL: -1, Z_MAX_LEVEL: 9, Z_DEFAULT_LEVEL: -1,
  BROTLI_OPERATION_PROCESS: 0, BROTLI_OPERATION_FLUSH: 1, BROTLI_OPERATION_FINISH: 2, BROTLI_OPERATION_EMIT_METADATA: 3,
});

// MARK: Checksums

/** zlib.crc32(data, value): libz's CRC-32. */
export function crc32(data, value = 0) {
  return native.crc32(typeof data === "string" ? Buffer.from(data) : data, value);
}

const zlibError = (answer) => Object.assign(new Error(answer.message), { code: answer.error, errno: answer.errno });

// MARK: The engine

/** One Node zlib stream in the host: libz in Node's `mode` number, opened at the first chunk. */
class Engine {
  constructor(mode, options) {
    this.mode = mode;
    this.options = { level: options.level, windowBits: options.windowBits, memLevel: options.memLevel, strategy: options.strategy };
    this.id = null;
  }

  push(chunk, flush) {
    if (this.id === null) {
      const id = native.zlibOpen(constants[this.mode.toUpperCase()], this.options);
      if (typeof id !== "number") throw zlibError(id);
      this.id = id;
    }
    const answer = native.zlibPush(this.id, chunk, flush);
    if (answer?.error) throw zlibError(answer);
    return answer.out;
  }

  reset() { if (this.id !== null) native.zlibReset(this.id); }
  close() { if (this.id !== null) native.zlibClose(this.id); this.id = null; }
}

// MARK: Node's classes

class Zlib extends Transform {
  constructor(options = {}, mode) {
    super({ ...options, objectMode: false });
    this._opts = options;
    this._finishFlushFlag = options.finishFlush ?? constants.Z_FINISH;
    this._defaultFlushFlag = options.flush ?? constants.Z_NO_FLUSH;
    this._engine = new Engine(mode, options);
    this.bytesWritten = 0;
    // What minizlib reaches for: a handle whose close it swaps out while it calls _processChunk.
    this._handle = { close: () => this._engine.close() };
  }

  /** The output of one chunk, now: Buffer.concat of its pieces (minizlib makes concat give the pieces back). */
  _processChunk(chunk, flushFlag) {
    const bytes = typeof chunk === "string" ? Buffer.from(chunk) : chunk;
    this.bytesWritten += bytes.length;
    const out = this._engine.push(bytes, flushFlag);
    const pieces = out.length ? [Buffer.from(out.buffer, out.byteOffset, out.byteLength)] : [];
    return Buffer.concat(pieces, out.length);
  }

  _transform(chunk, encoding, cb) {
    let out;
    try { out = this._processChunk(chunk, this._defaultFlushFlag); } catch (error) { return cb(error); }
    cb(null, out.length ? out : null);
  }

  _flush(cb) {
    let out;
    try { out = this._processChunk(Buffer.alloc(0), this._finishFlushFlag); } catch (error) { return cb(error); }
    cb(null, out.length ? out : null);
  }

  /** Pushes out what is held, by Z_FULL_FLUSH unless another flag is given. */
  flush(kind, cb) {
    if (typeof kind === "function") { cb = kind; kind = constants.Z_FULL_FLUSH; }
    try { const out = this._processChunk(Buffer.alloc(0), kind ?? constants.Z_FULL_FLUSH); if (out.length) this.push(out); } catch (error) { this.destroy(error); }
    if (cb) queueMicrotask(cb);
  }
  params(level, strategy, cb) { if (cb) queueMicrotask(cb); }
  reset() { this._engine.reset(); }
  close(cb) { this._engine.close(); if (cb) queueMicrotask(cb); this.destroy(); }
  _destroy(error, cb) { this._engine.close(); cb(error); }
}

const modes = ["Deflate", "Inflate", "Gzip", "Gunzip", "DeflateRaw", "InflateRaw", "Unzip"];
const classes = Object.fromEntries(modes.map((mode) => [mode, { [mode]: class extends Zlib { constructor(options) { super(options, mode); } } }[mode]]));

/** The one-shot forms: `<name>Sync(buffer)`, `<name>(buffer, [options], cb)`. */
function oneShot(mode, input, options) {
  const bytes = typeof input === "string" ? Buffer.from(input) : input instanceof ArrayBuffer ? Buffer.from(input) : input;
  return new classes[mode](options)._processChunk(bytes, constants.Z_FINISH);
}

const zlib = { constants, crc32, Zlib, ...classes, codes: { Z_OK: 0, Z_STREAM_END: 1, Z_NEED_DICT: 2, Z_ERRNO: -1, Z_STREAM_ERROR: -2, Z_DATA_ERROR: -3, Z_MEM_ERROR: -4, Z_BUF_ERROR: -5, Z_VERSION_ERROR: -6 } };
for (const mode of modes) {
  const name = mode[0].toLowerCase() + mode.slice(1);
  zlib[`create${mode}`] = (options) => new classes[mode](options);
  zlib[`${name}Sync`] = (input, options) => Buffer.from(oneShot(mode, input, options));
  zlib[name] = (input, options, cb) => {
    if (typeof options === "function") { cb = options; options = {}; }
    let out, failure = null;
    try { out = Buffer.from(oneShot(mode, input, options)); } catch (error) { failure = error; }
    queueMicrotask(() => cb(failure, out));
  };
}
for (const name of ["BrotliCompress", "BrotliDecompress", "ZstdCompress", "ZstdDecompress"]) {
  zlib[name] = missing(`zlib.${name}`);
  zlib[`create${name}`] = missing(`zlib.create${name}`);
  const plain = name[0].toLowerCase() + name.slice(1);
  zlib[plain] = missing(`zlib.${plain}`);
  zlib[`${plain}Sync`] = missing(`zlib.${plain}Sync`);
}

export const modules = { zlib };
