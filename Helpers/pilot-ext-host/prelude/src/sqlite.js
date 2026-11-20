// Node's `node:sqlite` for the prelude (T7), written from nodejs.org's API docs: `DatabaseSync` and its statements on
// the host's SQLite bridge (SQLite.swift), which opens every database read-only and loads no extension, so `run` and
// `exec` of a write fail as SQLite answers them. Enough for @raycast/utils' useSQL (`prepare(query).all()`).
import { Buffer } from "./buffer.js";

const native = globalThis.__native;

function answered(result) {
  if (result && typeof result === "object" && !Array.isArray(result) && result.error) {
    throw Object.assign(new Error(result.message), { code: result.error });
  }
  return result;
}

const rowOf = (row) => {
  for (const key of Object.keys(row)) if (row[key] && typeof row[key] === "object" && "$blob" in row[key]) row[key] = Buffer.from(row[key].$blob, "base64");
  return row;
};

class StatementSync {
  #db;
  #sql;
  constructor(db, sql) { this.#db = db; this.#sql = String(sql); }
  all(...params) { return answered(native.sqliteAll(this.#db.id, this.#sql, params.flat())).map(rowOf); }
  get(...params) { return this.all(...params)[0]; }
  iterate(...params) { return this.all(...params)[Symbol.iterator](); }
  run(...params) { this.all(...params); return { changes: 0, lastInsertRowid: 0 }; }
  get sourceSQL() { return this.#sql; }
}

class DatabaseSync {
  #path;
  id = null;
  constructor(path, options = {}) {
    this.#path = String(path);
    if (options.open !== false) this.open();
  }
  get isOpen() { return this.id != null; }
  open() {
    if (this.id != null) throw new Error("database is already open");
    this.id = answered(native.sqliteOpen(this.#path));
  }
  close() {
    if (this.id == null) throw new Error("database is not open");
    native.sqliteClose(this.id);
    this.id = null;
  }
  prepare(sql) {
    if (this.id == null) throw new Error("database is not open");
    return new StatementSync(this, sql);
  }
  exec(sql) { this.prepare(sql).all(); }
}

export const sqlite = { DatabaseSync, StatementSync };
