// Node's `assert` (raycast-extensions T25), written from Node's documentation (nodejs.org/api/assert.html, read
// 2026-11-20): the call itself and `ok`, `equal`, `notEqual`, `strictEqual`, `notStrictEqual`, `deepEqual`,
// `deepStrictEqual`, `notDeepEqual`, `notDeepStrictEqual`, `throws`, `doesNotThrow`, `rejects`, `doesNotReject`, `match`,
// `doesNotMatch`, `ifError`, `fail` and `AssertionError`; `assert.strict` and `assert/strict` are the strict forms, where
// `equal` is `strictEqual` and `deepEqual` is `deepStrictEqual`. Speedtest requires it at load (T15).
import { guard } from "./gaps.js";

export class AssertionError extends Error {
  constructor(options = {}) {
    const { message, actual, expected, operator } = options;
    super(message ?? `${show(actual)} ${operator ?? "=="} ${show(expected)}`);
    this.name = "AssertionError";
    this.code = "ERR_ASSERTION";
    this.actual = actual;
    this.expected = expected;
    this.operator = operator;
    this.generatedMessage = message == null;
  }
}

function show(value) {
  if (typeof value === "string") return JSON.stringify(value);
  if (typeof value === "function") return `[Function${value.name ? `: ${value.name}` : ""}]`;
  try { return typeof value === "object" && value !== null ? JSON.stringify(value) : String(value); } catch { return String(value); }
}

/** Throws `message` itself when it is an Error, as Node does, else an AssertionError. */
function failed(message, actual, expected, operator, fallback) {
  if (message instanceof Error) throw message;
  throw new AssertionError({ message: message ?? fallback, actual, expected, operator });
}

const tag = (v) => Object.prototype.toString.call(v);

/** Node's deep equality: `strict` compares primitives with Object.is and prototypes too; loose with ==. */
function deep(a, b, strict, seen = new Map()) {
  if (strict ? Object.is(a, b) : a == b || (a !== a && b !== b)) return true;
  if (typeof a !== "object" || typeof b !== "object" || a === null || b === null) return false;
  if (strict && Object.getPrototypeOf(a) !== Object.getPrototypeOf(b)) return false;
  if (tag(a) !== tag(b)) return false;
  if (seen.get(a) === b) return true;
  seen.set(a, b);
  if (a instanceof Date) return a.getTime() === b.getTime();
  if (a instanceof RegExp) return a.source === b.source && a.flags === b.flags;
  if (a instanceof Error && (a.message !== b.message || a.name !== b.name)) return false;
  if (ArrayBuffer.isView(a)) {
    if (a.byteLength !== b.byteLength) return false;
    const x = new Uint8Array(a.buffer, a.byteOffset, a.byteLength), y = new Uint8Array(b.buffer, b.byteOffset, b.byteLength);
    return x.every((v, i) => v === y[i]);
  }
  if (a instanceof Set) {
    if (a.size !== b.size) return false;
    for (const v of a) if (!b.has(v) && ![...b].some((w) => deep(v, w, strict, seen))) return false;
    return true;
  }
  if (a instanceof Map) {
    if (a.size !== b.size) return false;
    for (const [k, v] of a) if (!b.has(k) || !deep(v, b.get(k), strict, seen)) return false;
    return true;
  }
  const keys = Object.keys(a), other = Object.keys(b);
  if (keys.length !== other.length) return false;
  return keys.every((k) => Object.prototype.hasOwnProperty.call(b, k) && deep(a[k], b[k], strict, seen));
}

/** Whether `error` is what `expected` asks for: a class, a RegExp on its text, a validator, or an object of its fields. */
function matches(error, expected) {
  if (expected === undefined) return true;
  if (expected instanceof RegExp) return expected.test(String(error));
  if (typeof expected === "function") {
    if (expected.prototype !== undefined && error instanceof expected) return true;
    if (Error.isPrototypeOf(expected) || expected === Error) return false;
    return expected.call({}, error) === true;
  }
  if (typeof expected === "object" && expected !== null) {
    return Object.keys(expected).every((k) => expected[k] instanceof RegExp && typeof error?.[k] === "string"
      ? expected[k].test(error[k]) : deep(error?.[k], expected[k], true));
  }
  return false;
}

/** `throws(fn, [expected], [message])`'s optional middle: a string there is the message. */
const split = (expected, message) => (typeof expected === "string" ? [undefined, expected] : [expected, message]);

function make(strict) {
  function ok(...a) {
    if (a.length === 0) failed(undefined, undefined, true, "==", "No value argument passed to `assert.ok()`");
    if (!a[0]) failed(a[1], a[0], true, "==", `The expression evaluated to a falsy value: ${show(a[0])}`);
  }
  const assert = function (...a) { ok(...a); };
  const strictEqual = (a, b, m) => { if (!Object.is(a, b)) failed(m, a, b, "strictEqual", `Expected values to be strictly equal: ${show(a)} !== ${show(b)}`); };
  const notStrictEqual = (a, b, m) => { if (Object.is(a, b)) failed(m, a, b, "notStrictEqual", `Expected "actual" to be strictly unequal to: ${show(b)}`); };
  const deepStrictEqual = (a, b, m) => { if (!deep(a, b, true)) failed(m, a, b, "deepStrictEqual", `Expected values to be strictly deep-equal: ${show(a)} vs ${show(b)}`); };
  const notDeepStrictEqual = (a, b, m) => { if (deep(a, b, true)) failed(m, a, b, "notDeepStrictEqual", `Expected "actual" not to be strictly deep-equal to: ${show(b)}`); };
  const looseEqual = (a, b, m) => { if (!(a == b || (a !== a && b !== b))) failed(m, a, b, "==", `${show(a)} == ${show(b)}`); };
  const looseNotEqual = (a, b, m) => { if (a == b || (a !== a && b !== b)) failed(m, a, b, "!=", `${show(a)} != ${show(b)}`); };
  const deepEqual = (a, b, m) => { if (!deep(a, b, false)) failed(m, a, b, "deepEqual", `Expected values to be loosely deep-equal: ${show(a)} vs ${show(b)}`); };
  const notDeepEqual = (a, b, m) => { if (deep(a, b, false)) failed(m, a, b, "notDeepEqual", `Expected "actual" not to be loosely deep-equal to: ${show(b)}`); };

  function throws(fn, expected, message) {
    [expected, message] = split(expected, message);
    if (typeof fn !== "function") throw new TypeError('The "fn" argument must be of type function');
    try { fn(); } catch (error) {
      if (!matches(error, expected)) failed(message, error, expected, "throws", `The error is not the one expected: ${show(String(error))}`);
      return;
    }
    failed(message, undefined, expected, "throws", "Missing expected exception.");
  }
  function doesNotThrow(fn, expected, message) {
    [expected, message] = split(expected, message);
    try { fn(); } catch (error) {
      if (expected !== undefined && !matches(error, expected)) throw error;
      failed(message, error, expected, "doesNotThrow", `Got unwanted exception: ${show(String(error))}`);
    }
  }
  async function rejects(promise, expected, message) {
    [expected, message] = split(expected, message);
    const waited = typeof promise === "function" ? promise() : promise;
    if (!waited || typeof waited.then !== "function") throw new TypeError('The "promiseFn" argument must be a promise or return one');
    try { await waited; } catch (error) {
      if (!matches(error, expected)) failed(message, error, expected, "rejects", `The error is not the one expected: ${show(String(error))}`);
      return;
    }
    failed(message, undefined, expected, "rejects", "Missing expected rejection.");
  }
  async function doesNotReject(promise, expected, message) {
    [expected, message] = split(expected, message);
    try { await (typeof promise === "function" ? promise() : promise); } catch (error) {
      if (expected !== undefined && !matches(error, expected)) throw error;
      failed(message, error, expected, "doesNotReject", `Got unwanted rejection: ${show(String(error))}`);
    }
  }
  const match = (s, re, m) => { if (typeof s !== "string" || !re.test(s)) failed(m, s, re, "match", `The input did not match the regular expression ${re}: ${show(s)}`); };
  const doesNotMatch = (s, re, m) => { if (typeof s !== "string" || re.test(s)) failed(m, s, re, "doesNotMatch", `The input was expected to not match the regular expression ${re}: ${show(s)}`); };
  const ifError = (value) => { if (value !== null && value !== undefined) { if (value instanceof Error) throw value; failed(undefined, value, null, "ifError", `ifError got unwanted exception: ${show(value)}`); } };
  const fail = (message = "Failed") => { if (message instanceof Error) throw message; throw new AssertionError({ message, operator: "fail" }); };

  Object.assign(assert, {
    ok, fail, AssertionError, strictEqual, notStrictEqual, deepStrictEqual, notDeepStrictEqual, throws, doesNotThrow, rejects,
    doesNotReject, match, doesNotMatch, ifError,
    equal: strict ? strictEqual : looseEqual, notEqual: strict ? notStrictEqual : looseNotEqual,
    deepEqual: strict ? deepStrictEqual : deepEqual, notDeepEqual: strict ? notDeepStrictEqual : notDeepEqual,
  });
  return assert;
}

const strict = make(true), loose = make(false);
loose.strict = strict;
strict.strict = strict;

/** The modules this file adds to `require`: a member Node has and this lacks records its use, as every module's does. */
export const modules = { assert: guard("assert", loose), "assert/strict": guard("assert", strict) };
