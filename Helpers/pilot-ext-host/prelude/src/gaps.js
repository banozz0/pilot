// The gap recorder (ADR 0017, T3): `pilot ext gaps` is the published list of what Pilot lacks, so every API an extension
// uses that the shim does not have is written down as it is used. A stub lists its members as own keys (so a bundle's
// `__toESM` copy and destructuring find them) and records only when it is called or rendered, then throws a clear
// error; a name the shim never heard of reads as such a stub too. Each one is written at once, never at exit, since
// Pilot may kill the host: into ExtensionData/<id>/gaps.json, beside the extension's preferences, which Pilot owns.
const native = globalThis.__native;
let file = null, command = "";
const seen = new Set();

/** Where this run's gaps go: the folder above its data folder. */
export function gapsAt(paths, name) {
  const data = typeof paths?.data === "string" ? paths.data.replace(/\/+$/, "") : "";
  file = data.includes("/") ? `${data.slice(0, data.lastIndexOf("/"))}/gaps.json` : null;
  command = String(name ?? "");
}

/** A JSON object file, made with its folder on the first write: read again only when its size or time changed, so
 *  two runs see each other's writes; written whole, atomically, after each change. */
export function store(path) {
  let known = null, mark = "";
  const read = () => {
    const s = path ? native.fsStat(path, true) : { error: "ENOENT" };
    const now = s.error ? "" : `${s.size}:${s.mtimeMs}`;
    if (known && now === mark) return known;
    let o = {};
    if (now) { try { o = JSON.parse(native.fsRead(path)); } catch { o = {}; } }
    known = o && typeof o === "object" && !Array.isArray(o) ? o : {};
    mark = now;
    return known;
  };
  const write = (o) => {
    if (!path) return;
    native.fsMakeFolder(path.slice(0, path.lastIndexOf("/")), true);
    const wrote = native.fsWrite(path, JSON.stringify(o), false);
    if (wrote !== true) throw new Error(`could not save ${path}: ${wrote?.message ?? wrote}`);
    known = null;
  };
  return { read, write };
}

/** Writes `api` down once per run: its count of runs, first and last time, and the commands that touched it. */
export function record(api) {
  if (seen.has(api)) return;
  seen.add(api);
  console.error(`[gap] ${api}`);
  if (!file) return;
  const gapsFile = store(file), all = gapsFile.read();
  const gaps = all.gaps && typeof all.gaps === "object" ? all.gaps : (all.gaps = {});
  const now = new Date().toISOString();
  const entry = gaps[api] ?? (gaps[api] = { count: 0, first: now, commands: [] });
  entry.count = (Number(entry.count) || 0) + 1;
  entry.last = now;
  if (!Array.isArray(entry.commands)) entry.commands = [];
  if (!entry.commands.includes(command)) entry.commands.push(command);
  try { gapsFile.write(all); } catch (error) { console.error(`[gap] not saved: ${error.message}`); }
}

/** The error a missing API throws. */
export class Missing extends Error {
  constructor(api) { super(`${api} is not in Pilot yet`); this.name = "PilotGap"; this.api = api; }
}

/** A function (or component) Pilot lacks: calling it records it and throws. */
export function missing(api) {
  const stub = function () { record(api); throw new Missing(api); };
  Object.defineProperty(stub, "name", { value: api.split(".").pop() });
  return stub;
}

/** Records `api` and throws its Missing error: a missing API used where it is reached. */
export const lack = (api) => missing(api)();

/** An object whose members `names` are stubs under `api`, beside the real ones in `own`. */
export function stubs(api, names, own = {}) {
  for (const name of names) if (!(name in own)) own[name] = missing(`${api}.${name}`);
  return guard(api, own);
}

// Names a loader, a bundler's interop or a feature check asks of any object: never a gap.
const quiet = new Set(["__esModule", "default", "then", "toJSON", "$$typeof", "constructor", "prototype", "displayName", "name",
  "length", "inspect", "nodeType", "tagName", "asymmetricMatch", "@@__IMMUTABLE_ITERABLE__@@", "@@__IMMUTABLE_RECORD__@@", "toString", "valueOf"]);

/** `target`, where any other name read is a stub that records `api.<name>` (`<name>` for Raycast's own) when called. */
export function guard(api, target) {
  return new Proxy(target, {
    get(object, key, receiver) {
      if (typeof key === "symbol" || key in object || quiet.has(key)) return Reflect.get(object, key, receiver);
      return missing(api ? `${api}.${key}` : key);
    },
  });
}
