// Node's streams for the prelude (spec raycast-extensions T26), written from nodejs.org's `stream` docs: Stream,
// Readable, Writable, Duplex, Transform and PassThrough with their events (data, readable, end, finish, close, error,
// drain, pipe), flowing and paused modes, pipe() with backpressure, async iteration, Readable.from and fromWeb, and
// pipeline() and finished() in callback and promise forms. Simpler than Node's inside (a chunk queue, no corking, no
// writev batching), the same from outside for the calls extensions make. Every callback Node defers is deferred here
// too (process.nextTick, a microtask), so a stream's events come in Node's order.
import { EventEmitter } from "./events.js";
import { Buffer, StringDecoder } from "./buffer.js";
import { guard } from "./gaps.js";

const tick = (fn, ...args) => queueMicrotask(() => fn(...args));
const hwm = (options, objectMode) => options?.highWaterMark ?? (objectMode ? 16 : 65536);
const sizeOf = (chunk, objectMode) => (objectMode ? 1 : chunk.length);
const errored = (code, message) => Object.assign(new Error(message), { code });

export class Stream extends EventEmitter {
  /** The legacy pipe Node's Stream has: data to `dest`, ended with it unless `end` is false. */
  pipe(dest, options) {
    return Readable.prototype.pipe.call(this, dest, options);
  }
}

// MARK: Readable

export class Readable extends Stream {
  constructor(options = {}) {
    super();
    const objectMode = !!(options.objectMode || options.readableObjectMode);
    this._readableState = {
      objectMode, highWaterMark: hwm(options, objectMode), buffer: [], length: 0, flowing: null, ended: false,
      endEmitted: false, reading: false, sync: false, decoder: null, encoding: null, destroyed: false, closed: false,
      errored: null, scheduled: false, pipes: [], emitClose: options.emitClose !== false, autoDestroy: options.autoDestroy !== false,
    };
    if (options.encoding) this.setEncoding(options.encoding);
    if (typeof options.read === "function") this._read = options.read;
    if (typeof options.destroy === "function") this._destroy = options.destroy;
    if (typeof options.construct === "function") this._construct = options.construct;
    if (options.signal) options.signal.addEventListener?.("abort", () => this.destroy(errored("ABORT_ERR", "The operation was aborted")));
    if (typeof this._construct === "function") {
      const state = this._readableState;
      state.constructing = true;
      tick(() => this._construct((error) => { state.constructing = false; if (error) this.destroy(error); else this._schedule(); }));
    }
  }

  get readable() { const s = this._readableState; return !s.destroyed && !s.endEmitted && !s.errored; }
  get readableEnded() { return this._readableState.endEmitted; }
  get readableFlowing() { return this._readableState.flowing; }
  get readableLength() { return this._readableState.length; }
  get readableHighWaterMark() { return this._readableState.highWaterMark; }
  get readableObjectMode() { return this._readableState.objectMode; }
  get readableEncoding() { return this._readableState.encoding; }
  get readableAborted() { const s = this._readableState; return s.destroyed && !s.endEmitted; }
  get destroyed() { return this._readableState.destroyed; }
  set destroyed(value) { this._readableState.destroyed = !!value; }
  get closed() { return this._readableState.closed; }
  get errored() { return this._readableState.errored; }

  _read() { this.destroy(errored("ERR_METHOD_NOT_IMPLEMENTED", "The _read() method is not implemented")); }

  setEncoding(encoding) {
    const state = this._readableState;
    state.decoder = new StringDecoder(encoding);
    state.encoding = state.decoder.encoding ?? encoding;
    state.buffer = state.buffer.map((chunk) => (typeof chunk === "string" ? chunk : state.decoder.write(chunk)));
    return this;
  }

  /** Adds a chunk (null ends the stream); answers whether more is wanted now. */
  push(chunk, encoding) { return this._add(chunk, encoding, false); }
  unshift(chunk, encoding) { return this._add(chunk, encoding, true); }

  _add(chunk, encoding, front) {
    const state = this._readableState;
    state.reading = false;
    if (state.destroyed) return false;
    if (chunk === null) {
      if (!state.ended) {
        state.ended = true;
        const rest = state.decoder?.end();
        if (rest) { state.buffer.push(rest); state.length += sizeOf(rest, state.objectMode); }
      }
      this._schedule();
      return false;
    }
    if (!state.objectMode) {
      if (typeof chunk === "string") {
        if (!state.decoder) chunk = Buffer.from(chunk, encoding);
      } else if (chunk instanceof Uint8Array) {
        if (!(chunk instanceof Buffer)) chunk = Buffer.from(chunk.buffer, chunk.byteOffset, chunk.byteLength);
      } else if (chunk !== undefined) {
        this.destroy(new TypeError('The "chunk" argument must be of type string or an instance of Buffer or Uint8Array'));
        return false;
      }
      if (chunk === undefined) return state.length < state.highWaterMark;
      if (state.decoder && typeof chunk !== "string") chunk = state.decoder.write(chunk);
      if (chunk.length === 0) return state.length < state.highWaterMark;
    }
    if (state.ended && !front) {
      this.destroy(errored("ERR_STREAM_PUSH_AFTER_EOF", "stream.push() after EOF"));
      return false;
    }
    if (front) state.buffer.unshift(chunk); else state.buffer.push(chunk);
    state.length += sizeOf(chunk, state.objectMode);
    if (state.flowing === false || state.flowing === null) this._readableNow = true;
    this._schedule();
    return state.length < state.highWaterMark;
  }

  /** Takes up to `n` bytes (all buffered when omitted; one chunk in object mode), or null when there are not enough. */
  read(n) {
    const state = this._readableState;
    if (n === 0) { this._more(); return null; }
    let out = null;
    if (state.length > 0 && (n === undefined || state.objectMode || n <= state.length || state.ended)) {
      if (state.objectMode) out = state.buffer.shift();
      else if (n === undefined || n >= state.length) out = concat(state.buffer.splice(0), state.decoder != null);
      else out = take(state, n);
      state.length -= sizeOf(out, state.objectMode);
    }
    if (out !== null && state.flowing !== true) this.emit("data", out);
    this._more();
    if (state.length === 0 && state.ended) this._schedule();
    return out;
  }

  /** Asks the source for more while under the high water mark. */
  _more() {
    const state = this._readableState;
    if (state.ended || state.reading || state.destroyed || state.constructing || state.length >= state.highWaterMark) return;
    state.reading = true;
    state.sync = true;
    try { this._read(state.highWaterMark); } catch (error) { this.destroy(error); }
    state.sync = false;
  }

  /** One pass of the stream's work on a later microtask: flowing data out, `readable`, `end`. */
  _schedule() {
    const state = this._readableState;
    if (state.scheduled) return;
    state.scheduled = true;
    tick(() => { state.scheduled = false; this._work(); });
  }

  _work() {
    const state = this._readableState;
    if (state.destroyed) return;
    if (state.flowing === true) {
      while (state.flowing === true && state.length > 0) {
        const chunk = state.objectMode ? state.buffer.shift() : concat(state.buffer.splice(0, 1), state.decoder != null);
        state.length -= sizeOf(chunk, state.objectMode);
        this.emit("data", chunk);
      }
    } else if (this._readableNow && this.listenerCount("readable") > 0) {
      this._readableNow = false;
      this.emit("readable");
    }
    if (state.ended && state.length === 0) return this._end();
    if (state.flowing === true || this.listenerCount("readable") > 0) this._more();
  }

  _end() {
    const state = this._readableState;
    if (state.endEmitted) return;
    if (this.listenerCount("readable") > 0 && this._readableNow) { this._readableNow = false; this.emit("readable"); }
    state.endEmitted = true;
    this.emit("end");
    const writable = this._writableState;
    if (state.autoDestroy) whenDone(this);
  }

  on(name, fn) {
    super.on(name, fn);
    const state = this._readableState;
    if (name === "data" && state.flowing !== false) this.resume();
    if (name === "readable") { state.flowing = false; this._readableNow = true; this._schedule(); }
    return this;
  }
  addListener(name, fn) { return this.on(name, fn); }

  resume() {
    const state = this._readableState;
    if (state.flowing !== true) {
      state.flowing = true;
      tick(() => this.emit("resume"));
    }
    this._schedule();
    return this;
  }

  pause() {
    const state = this._readableState;
    if (state.flowing !== false) { state.flowing = false; this.emit("pause"); }
    return this;
  }

  isPaused() { return this._readableState.flowing === false; }

  pipe(dest, options = {}) {
    const state = this._readableState ?? { pipes: [] };
    state.pipes?.push(dest);
    const ondata = (chunk) => { if (dest.write(chunk) === false) { this.pause(); dest.once("drain", () => this.resume()); } };
    this.on("data", ondata);
    if (options.end !== false) this.once("end", () => dest.end());
    const unpiped = () => this.off("data", ondata);
    dest.once("close", unpiped);
    dest.emit("pipe", this);
    if (typeof this.resume === "function") this.resume();
    return dest;
  }

  unpipe(dest) {
    const state = this._readableState;
    for (const d of dest ? [dest] : state.pipes.splice(0)) {
      state.pipes = state.pipes.filter((p) => p !== d);
      d.emit("unpipe", this);
    }
    this.removeAllListeners("data");
    this.pause();
    return this;
  }

  wrap(stream) {
    stream.on("data", (chunk) => { if (!this.push(chunk)) stream.pause?.(); });
    stream.on("end", () => this.push(null));
    stream.on("error", (error) => this.destroy(error));
    this._read = () => stream.resume?.();
    return this;
  }

  destroy(error, cb) {
    return destroy(this, error, cb);
  }

  _destroy(error, cb) { cb(error); }

  async *[Symbol.asyncIterator]() {
    const state = this._readableState;
    let wake = null, failure = null, done = false;
    const notify = () => { const w = wake; wake = null; w?.(); };
    this.on("readable", notify);
    this.once("end", () => { done = true; notify(); });
    this.once("error", (error) => { failure = error; notify(); });
    this.once("close", () => { done = true; notify(); });
    try {
      while (true) {
        if (failure) throw failure;
        const chunk = state.length > 0 ? (state.objectMode ? this.read() : this.read()) : null;
        if (chunk !== null) { yield chunk; continue; }
        if (done || state.endEmitted || state.destroyed) { if (failure ?? state.errored) throw failure ?? state.errored; return; }
        await new Promise((resolve) => { wake = resolve; });
      }
    } finally {
      if (!state.endEmitted && !state.destroyed) this.destroy();
    }
  }

  /** A Readable of an iterable's or async iterable's items (object mode unless options say otherwise). */
  static from(iterable, options = {}) {
    if (iterable instanceof Readable) return iterable;
    if (typeof iterable === "string" || iterable instanceof Uint8Array) {
      return new Readable({ objectMode: true, ...options, read() { this.push(iterable); this.push(null); } });
    }
    const iterator = iterable?.[Symbol.asyncIterator]?.() ?? iterable?.[Symbol.iterator]?.();
    if (!iterator) throw Object.assign(new TypeError('The "iterable" argument must be an instance of Iterable'), { code: "ERR_INVALID_ARG_TYPE" });
    let busy = false;
    return new Readable({
      objectMode: true, ...options,
      read() {
        if (busy) return;
        busy = true;
        Promise.resolve(iterator.next()).then(({ value, done }) => {
          busy = false;
          if (done) return this.push(null);
          return Promise.resolve(value).then((v) => this.push(v));
        }, (error) => { busy = false; this.destroy(error); });
      },
      destroy(error, cb) {
        Promise.resolve(iterator.return?.()).then(() => cb(error), (e) => cb(error ?? e));
      },
    });
  }

  /** A Readable of a web ReadableStream's chunks, each a Buffer. */
  static fromWeb(web, options = {}) {
    const reader = web.getReader();
    return new Readable({
      ...options,
      read() {
        reader.read().then(({ value, done }) => {
          if (done) return this.push(null);
          this.push(value instanceof Uint8Array || typeof value === "string" ? value : Buffer.from(value));
        }, (error) => this.destroy(error));
      },
      destroy(error, cb) { reader.cancel(error).then(() => cb(error), () => cb(error)); },
    });
  }

  static toWeb(readable) {
    const iterator = readable[Symbol.asyncIterator]();
    return new globalThis.ReadableStream({
      async pull(controller) { const { value, done } = await iterator.next(); if (done) controller.close(); else controller.enqueue(value); },
      cancel() { readable.destroy(); },
    });
  }

  static isDisturbed(stream) { return !!stream?._readableState && (stream._readableState.flowing !== null || stream._readableState.endEmitted); }
}

/** Buffers joined, or text joined when the stream decodes. */
function concat(chunks, text) {
  if (chunks.length === 1) return chunks[0];
  return text ? chunks.join("") : Buffer.concat(chunks);
}

/** The first `n` bytes (or characters) off the buffer. */
function take(state, n) {
  const parts = [];
  let left = n;
  while (left > 0) {
    const head = state.buffer[0];
    if (head.length <= left) { parts.push(state.buffer.shift()); left -= head.length; } else {
      parts.push(head.slice(0, left));
      state.buffer[0] = head.slice(left);
      left = 0;
    }
  }
  return concat(parts, state.decoder != null);
}

// MARK: Writable

const writableMethods = {};

export class Writable extends Stream {
  constructor(options = {}) {
    super();
    initWritable(this, options);
  }

  static [Symbol.hasInstance](object) {
    return Function.prototype[Symbol.hasInstance].call(this, object) || (this === Writable && !!object?._writableState);
  }
}

function initWritable(stream, options) {
  const objectMode = !!(options.objectMode || options.writableObjectMode);
  stream._writableState = {
    objectMode, highWaterMark: hwm(options, objectMode), queue: [], length: 0, writing: false, ending: false, ended: false,
    finished: false, finalCalled: false, needDrain: false, destroyed: false, closed: false, errored: null, corked: 0,
    decodeStrings: options.decodeStrings !== false, defaultEncoding: options.defaultEncoding ?? "utf8",
    emitClose: options.emitClose !== false, autoDestroy: options.autoDestroy !== false, writable: true,
  };
  if (typeof options.write === "function") stream._write = options.write;
  if (typeof options.writev === "function") stream._writev = options.writev;
  if (typeof options.final === "function") stream._final = options.final;
  if (typeof options.destroy === "function") stream._destroy = options.destroy;
  if (typeof options.construct === "function" && !stream._readableState) stream._construct = options.construct;
  if (options.signal) options.signal.addEventListener?.("abort", () => stream.destroy(errored("ABORT_ERR", "The operation was aborted")));
  if (typeof stream._construct === "function" && !stream._readableState) {
    const state = stream._writableState;
    state.constructing = true;
    tick(() => stream._construct((error) => { state.constructing = false; if (error) stream.destroy(error); else drainQueue(stream); }));
  }
}

Object.assign(writableMethods, {
  write(chunk, encoding, cb) {
    if (typeof encoding === "function") { cb = encoding; encoding = null; }
    const state = this._writableState;
    encoding = encoding ?? state.defaultEncoding;
    if (chunk === null) throw errored("ERR_STREAM_NULL_VALUES", "May not write null values to stream");
    if (!state.objectMode) {
      if (typeof chunk === "string") { if (state.decodeStrings) { chunk = Buffer.from(chunk, encoding); encoding = "buffer"; } }
      else if (chunk instanceof Uint8Array) { if (!(chunk instanceof Buffer)) chunk = Buffer.from(chunk.buffer, chunk.byteOffset, chunk.byteLength); encoding = "buffer"; }
      else throw Object.assign(new TypeError('The "chunk" argument must be of type string or an instance of Buffer or Uint8Array'), { code: "ERR_INVALID_ARG_TYPE" });
    }
    if (state.ending || state.destroyed) {
      const error = state.destroyed ? errored("ERR_STREAM_DESTROYED", "Cannot call write after a stream was destroyed") : errored("ERR_STREAM_WRITE_AFTER_END", "write after end");
      tick(() => { cb?.(error); });
      if (!state.destroyed) tick(() => this.emit("error", error));
      return false;
    }
    state.length += sizeOf(chunk, state.objectMode);
    const ok = state.length < state.highWaterMark;
    if (!ok) state.needDrain = true;
    state.queue.push({ chunk, encoding, cb });
    if (!state.writing && !state.corked && !state.constructing) drainQueue(this);
    return ok;
  },

  end(chunk, encoding, cb) {
    if (typeof chunk === "function") { cb = chunk; chunk = null; encoding = null; } else if (typeof encoding === "function") { cb = encoding; encoding = null; }
    const state = this._writableState;
    if (chunk != null) this.write(chunk, encoding);
    if (cb) {
      if (state.finished) tick(cb); else this.once("finish", () => cb()), this.once("error", (error) => cb(error));
    }
    if (!state.ending) {
      state.ending = true;
      state.corked = 0;
      maybeFinish(this);
    }
    return this;
  },

  cork() { this._writableState.corked++; },
  uncork() { const s = this._writableState; if (s.corked) { s.corked--; if (!s.corked && !s.writing) drainQueue(this); } },
  setDefaultEncoding(encoding) { this._writableState.defaultEncoding = encoding; return this; },
  _write(chunk, encoding, cb) {
    if (this._writev) return this._writev([{ chunk, encoding }], cb);
    cb(errored("ERR_METHOD_NOT_IMPLEMENTED", "The _write() method is not implemented"));
  },
  destroy(error, cb) { return destroy(this, error, cb); },
  _destroy(error, cb) { cb(error); },
});

const writableGetters = {
  writable() { const s = this._writableState; return s.writable !== false && !s.destroyed && !s.ending && !s.errored; },
  writableEnded() { return this._writableState.ending; },
  writableFinished() { return this._writableState.finished; },
  writableLength() { return this._writableState.length; },
  writableHighWaterMark() { return this._writableState.highWaterMark; },
  writableObjectMode() { return this._writableState.objectMode; },
  writableNeedDrain() { return this._writableState.needDrain; },
  writableCorked() { return this._writableState.corked; },
};

for (const [name, fn] of Object.entries(writableMethods)) Writable.prototype[name] = fn;
for (const [name, get] of Object.entries(writableGetters)) Object.defineProperty(Writable.prototype, name, { get, configurable: true });
for (const name of ["destroyed", "closed", "errored"]) {
  Object.defineProperty(Writable.prototype, name, {
    get() { return this._writableState[name === "errored" ? "errored" : name]; },
    set(value) { this._writableState[name] = value; },
    configurable: true,
  });
}

/** Writes the queue's head, then the rest as each write calls back. */
function drainQueue(stream) {
  const state = stream._writableState;
  if (state.writing || state.destroyed || state.errored) return;
  const next = state.queue.shift();
  if (!next) return maybeFinish(stream);
  state.writing = true;
  let sync = true;
  const done = (error) => {
    if (!state.writing) return;
    state.writing = false;
    state.length -= sizeOf(next.chunk, state.objectMode);
    const after = () => {
      if (error) {
        next.cb?.(error);
        for (const queued of state.queue.splice(0)) queued.cb?.(error);
        destroy(stream, error);
        return;
      }
      next.cb?.(null);
      if (state.needDrain && state.length === 0 && !state.ending) { state.needDrain = false; stream.emit("drain"); }
      if (state.queue.length) drainQueue(stream); else maybeFinish(stream);
    };
    if (sync) tick(after); else after();
  };
  try { stream._write(next.chunk, next.encoding, done); } catch (error) { done(error); }
  sync = false;
}

function maybeFinish(stream) {
  const state = stream._writableState;
  if (!state.ending || state.writing || state.queue.length || state.finished || state.destroyed || state.errored) return;
  const finish = () => {
    state.finished = true;
    state.ended = true;
    stream.emit("finish");
    if (state.autoDestroy) whenDone(stream);
  };
  if (typeof stream._final === "function" && !state.finalCalled) {
    state.finalCalled = true;
    state.writing = true;
    tick(() => {
      try {
        stream._final((error) => { state.writing = false; if (error) destroy(stream, error); else tick(finish); });
      } catch (error) { state.writing = false; destroy(stream, error); }
    });
  } else if (!state.finalCalled) {
    state.finalCalled = true;
    tick(finish);
  }
}

// MARK: Destroy

/** autoDestroy: destroyed once each side it has is done (a Duplex's end and finish come in either order). */
function whenDone(stream) {
  const readable = stream._readableState, writable = stream._writableState;
  const done = (!readable || readable.endEmitted) && (!writable || writable.finished || writable.writable === false);
  if (done) tick(() => stream.destroy());
}

function destroy(stream, error, cb) {
  const readable = stream._readableState, writable = stream._writableState;
  const states = [readable, writable].filter(Boolean);
  if (states.some((s) => s.destroyed)) {
    if (typeof cb === "function") tick(cb, error);
    return stream;
  }
  for (const s of states) { s.destroyed = true; if (error && !s.errored) s.errored = error; }
  const closed = (failure) => {
    for (const s of states) s.closed = true;
    const emitClose = states.every((s) => s.emitClose !== false);
    tick(() => {
      if (failure) stream.emit("error", failure);
      if (emitClose) stream.emit("close");
    });
    if (typeof cb === "function") tick(cb, failure);
  };
  try { stream._destroy(error ?? null, (failure) => closed(failure ?? error)); } catch (failure) { closed(failure); }
  return stream;
}

// MARK: Duplex, Transform, PassThrough

export class Duplex extends Readable {
  constructor(options = {}) {
    super(options);
    initWritable(this, options);
    if (options.allowHalfOpen === false) this.once("end", () => this.end());
    if (options.readable === false) this._readableState.ended = this._readableState.endEmitted = true;
    if (options.writable === false) this._writableState.writable = false, this._writableState.ending = this._writableState.finished = true;
  }

  static from(source) {
    if (source instanceof Duplex) return source;
    if (source?.readable && source?.writable) return Duplex.fromPair(source.readable, source.writable);
    const readable = Readable.from(source);
    return Duplex.fromPair(readable, null);
  }

  static fromPair(readable, writable) {
    const duplex = new Duplex({
      objectMode: true,
      read() { readable?.resume?.(); },
      write(chunk, encoding, cb) { if (writable) writable.write(chunk, encoding, cb); else cb(); },
      final(cb) { if (writable) writable.end(cb); else cb(); },
    });
    readable?.on("data", (chunk) => { if (!duplex.push(chunk)) readable.pause(); });
    readable?.on("end", () => duplex.push(null));
    readable?.on("error", (error) => duplex.destroy(error));
    return duplex;
  }
}

for (const [name, fn] of Object.entries(writableMethods)) if (name !== "destroy" && name !== "_destroy") Duplex.prototype[name] = fn;
for (const [name, get] of Object.entries(writableGetters)) Object.defineProperty(Duplex.prototype, name, { get, configurable: true });

export class Transform extends Duplex {
  constructor(options = {}) {
    super(options);
    if (typeof options.transform === "function") this._transform = options.transform;
    if (typeof options.flush === "function") this._flush = options.flush;
  }

  _write(chunk, encoding, cb) {
    let called = false;
    try {
      this._transform(chunk, encoding, (error, data) => {
        if (called) return;
        called = true;
        if (error) return cb(error);
        if (data != null) this.push(data);
        // Backpressure: the next chunk waits while the readable side is full and nobody reads.
        const state = this._readableState;
        if (state.length < state.highWaterMark || state.flowing) cb(); else this._waiting = cb;
      });
    } catch (error) { if (!called) { called = true; cb(error); } }
  }

  _read() {
    const waiting = this._waiting;
    this._waiting = null;
    this._readableState.reading = false;
    waiting?.();
  }

  _final(cb) {
    const done = (error, data) => {
      if (error) return cb(error);
      if (data != null) this.push(data);
      this.push(null);
      cb();
    };
    if (typeof this._flush === "function") {
      try { this._flush(done); } catch (error) { cb(error); }
    } else done();
  }

  _transform() { throw errored("ERR_METHOD_NOT_IMPLEMENTED", "The _transform() method is not implemented"); }
}

export class PassThrough extends Transform {
  _transform(chunk, encoding, cb) { cb(null, chunk); }
}

// MARK: finished, pipeline

/** Calls back once `stream` has ended, finished or failed (or was destroyed early: ERR_STREAM_PREMATURE_CLOSE). */
export function finished(stream, options, cb) {
  if (typeof options === "function") { cb = options; options = {}; }
  const readable = options.readable ?? !!stream._readableState, writable = options.writable ?? !!stream._writableState;
  let done = false, ended = !readable || stream._readableState?.endEmitted, finishedWriting = !writable || stream._writableState?.finished;
  const call = (error) => { if (done) return; done = true; cleanup(); cb.call(stream, error); };
  const onend = () => { ended = true; if (finishedWriting) call(); };
  const onfinish = () => { finishedWriting = true; if (ended) call(); };
  const onerror = (error) => call(error);
  const onclose = () => {
    if (ended && finishedWriting) return call();
    const failure = stream._readableState?.errored ?? stream._writableState?.errored;
    call(failure ?? errored("ERR_STREAM_PREMATURE_CLOSE", "Premature close"));
  };
  stream.on("end", onend);
  stream.on("finish", onfinish);
  if (options.error !== false) stream.on("error", onerror);
  stream.on("close", onclose);
  const cleanup = () => { stream.off("end", onend); stream.off("finish", onfinish); stream.off("error", onerror); stream.off("close", onclose); };
  if ((ended && finishedWriting) || stream._readableState?.closed || stream._writableState?.closed) tick(() => (ended && finishedWriting ? call() : onclose()));
  return cleanup;
}

/** Each stream piped into the next; a function in the middle is a transform of the iterable before it (an async
 *  generator), at the end a consumer of it. Calls back with the first error (every stream then destroyed) or none. */
export function pipeline(...streams) {
  // Node's callback form always ends with its callback; a consumer function comes before it.
  const cb = typeof streams[streams.length - 1] === "function" ? streams.pop() : () => {};
  if (streams.length === 1 && Array.isArray(streams[0])) streams = streams[0];
  let failure = null, settled = false;
  const made = [];
  const finish = (error, value) => {
    if (settled) return;
    if (error) {
      failure = failure ?? error;
      for (const s of made) if (typeof s.destroy === "function" && !s.destroyed) s.destroy(error);
    }
    settled = true;
    tick(() => cb(failure, value));
  };
  let previous = null;
  streams.forEach((entry, index) => {
    const last = index === streams.length - 1;
    let stream = entry;
    if (typeof entry === "function") {
      const output = entry(previous ?? undefined, { signal: undefined });
      if (last && !isStreamLike(output)) {
        Promise.resolve(output).then((value) => finish(null, value), finish);
        previous = null;
        return;
      }
      stream = isStreamLike(output) ? output : Readable.from(output);
    } else if (!isStreamLike(entry)) {
      stream = Readable.from(entry);
    }
    made.push(stream);
    if (previous) previous.pipe(stream);
    finished(stream, { readable: last ? false : undefined }, (error) => {
      if (error) return finish(error);
      if (last) finish(null);
    });
    previous = stream;
  });
  return previous;
}

const isStreamLike = (s) => !!s && typeof s === "object" && (typeof s.pipe === "function" || typeof s.write === "function") && typeof s.on === "function";

const promises = {
  pipeline: (...streams) => new Promise((resolve, reject) => {
    const options = streams.length > 1 && streams[streams.length - 1] && typeof streams[streams.length - 1] === "object" && !isStreamLike(streams[streams.length - 1])
      && !streams[streams.length - 1][Symbol.asyncIterator] && !streams[streams.length - 1][Symbol.iterator] ? streams.pop() : {};
    options.signal?.addEventListener?.("abort", () => reject(errored("ABORT_ERR", "The operation was aborted")));
    pipeline(...streams, (error, value) => (error ? reject(error) : resolve(value)));
  }),
  finished: (stream, options = {}) => new Promise((resolve, reject) => finished(stream, options, (error) => (error ? reject(error) : resolve()))),
};

Stream.Stream = Stream;
Stream.Readable = Readable;
Stream.Writable = Writable;
Stream.Duplex = Duplex;
Stream.Transform = Transform;
Stream.PassThrough = PassThrough;
Stream.pipeline = pipeline;
Stream.finished = finished;
Stream.promises = promises;
Stream.addAbortSignal = (signal, stream) => { signal?.addEventListener?.("abort", () => stream.destroy(errored("ABORT_ERR", "The operation was aborted"))); return stream; };
Stream.isReadable = (s) => !!s?.readable;
Stream.isErrored = (s) => !!(s?._readableState?.errored ?? s?._writableState?.errored);
Stream.isDisturbed = Readable.isDisturbed;
// Node 22's 65536 bytes, 16 objects (T15: execa reads it at load).
Stream.getDefaultHighWaterMark = (objectMode) => (objectMode ? 16 : 65536);
Stream.setDefaultHighWaterMark = () => {};

/** The modules this file adds to `require`. */
// stream/web: the web stream classes the prelude has (web.js's ReadableStream); the rest record their use.
const web = guard("stream/web", { ReadableStream: globalThis.ReadableStream });

export const modules = { stream: Stream, "stream/promises": promises, "stream/web": web };
