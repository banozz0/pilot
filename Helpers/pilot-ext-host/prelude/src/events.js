// Node's `events` for the prelude (ADR 0017, T3; its own file since T26, so stream.js can extend it), written from
// Node's documentation: on, once, off, emit and the listener reads; listeners are never capped.
export class EventEmitter {
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
// events.setMaxListeners(n, ...targets): listeners are never capped here, so it does nothing (T15: execa calls it).
EventEmitter.setMaxListeners = () => {};
EventEmitter.once = (emitter, name) => new Promise((resolve) => emitter.once(name, (...a) => resolve(a)));
