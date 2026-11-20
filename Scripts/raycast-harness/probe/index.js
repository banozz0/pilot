// The measure probe (spec raycast-extensions T7, review 1): run by pilot-ext-host with --measure, it tries each way a
// command could act on the Mac and shows one row per try: "ran" or "refused", with what it got back. Every try is
// harmless had it run: no try names a process but the harness's own, and every file it writes is its own. The
// harness's sleep pid comes as the `victim` preference, and harness.py's probe phase makes probe.db beside this file. Plain CommonJS against the host's own @raycast/api and Node subset.
const { List, getPreferenceValues } = require("@raycast/api");
const React = require("react");
const fs = require("fs");
const os = require("os");
const path = require("path");
const { execFileSync } = require("child_process");
const { DatabaseSync } = require("node:sqlite");

const { victim = "0" } = getPreferenceValues();
const data = path.dirname(os.tmpdir().replace(/\/$/, ""));
const rows = [];

function attempt(name, work) {
  try {
    const got = work();
    rows.push(`${name}: ran${got ? ` (${String(got).trim().split("\n")[0].slice(0, 60)})` : ""}`);
  } catch (error) {
    rows.push(`${name}: refused (${String(error.message).split("\n").filter(Boolean).pop().slice(0, 100)})`);
  }
}
const run = (file, args, options) => execFileSync(file, args, { encoding: "utf8", ...options });

// Children: a program copied out of the system's folders, other shells, the extension's own environment, kill shapes,
// sqlite3, and settings tools in their writing forms; then the read forms that may run.
attempt("copy of /bin/ls run from a writable folder", () => {
  const copy = path.join(os.tmpdir(), "ls");
  fs.copyFileSync("/bin/ls", copy);
  return run(copy, ["-d", "/"]);
});
attempt("zsh -c ls", () => run("/bin/zsh", ["-c", "ls /"]));
attempt("bash -c ls", () => run("/bin/bash", ["-c", "ls /"]));
attempt("sh -c ls with ENV and BASH_ENV set by the extension (runs as ls, no shell)", () => {
  const rc = path.join(os.tmpdir(), "rc.sh");
  fs.writeFileSync(rc, `touch ${os.tmpdir()}/sourced\n`);
  run("/bin/sh", ["-c", "ls -d /"], { env: { ENV: rc, BASH_ENV: rc, PATH: os.tmpdir() } });
  return fs.existsSync(path.join(os.tmpdir(), "sourced")) ? "rc file sourced" : "rc file not sourced";
});
// Review 2's blockers, one row each: a substitution inside double quotes (1), a shell line naming a copied program by a
// relative and by an absolute path (2), a brew shape its views never issue (3); (4) is the osascript row's stdin, logged
// as its length only.
attempt("review 2 (1): sh -c with $(...) inside double quotes", () => run("/bin/sh", ["-c", 'ls "$(/usr/bin/true)"']));
attempt("review 2 (2): sh -c naming a copied program by a relative path", () => {
  const bin = path.join(os.tmpdir(), "deep", "bin");
  fs.mkdirSync(bin, { recursive: true });
  fs.copyFileSync("/bin/ls", path.join(bin, "ls"));
  const up = "../".repeat(40);
  return run("/bin/sh", ["-c", `${up}${bin.slice(1)}/ls -d /`], { cwd: bin });
});
attempt("review 2 (2): sh -c naming a copied program by its absolute path", () => run("/bin/sh", ["-c", `${path.join(os.tmpdir(), "deep", "bin", "ls")} -d /`]));
attempt("review 2 (3): brew info --quiet, a shape Brew's views never issue", () => run("/opt/homebrew/bin/brew", ["info", "--quiet", "t7-probe-none"]));
attempt("kill <harness pid> -<harness pid> (a group after a pid)", () => run("/bin/kill", ["-0", victim, `-${victim}`]));
attempt("kill -0 <harness pid>", () => run("/bin/kill", ["-0", victim]));
attempt("sqlite3 -readonly with a dot command", () => run("/usr/bin/sqlite3", ["-readonly", ":memory:", ".shell id"]));
attempt("pmset -a", () => run("/usr/bin/pmset", ["-a", "displaysleep", "0"]));
attempt("networksetup -setairportpower", () => run("/usr/sbin/networksetup", ["-setairportpower", "en0", "on"]));
attempt("sysctl -w", () => run("/usr/sbin/sysctl", ["-w", "kern.maxfiles=1"]));
attempt("date <time>", () => run("/bin/date", ["0101000026"]));
attempt("hostname <name>", () => run("/bin/hostname", ["t7-probe"]));
attempt("brew pin", () => run("/opt/homebrew/bin/brew", ["pin", "t7-probe-none"]));
attempt("review 2 (4): osascript with a script on stdin (logged as its length)", () => run("/usr/bin/osascript", [], { input: 'tell application "Finder" to return 1' }));
attempt("sysctl -n hw.ncpu (a read)", () => run("/usr/sbin/sysctl", ["-n", "hw.ncpu"]));
attempt("date +%Y (a read)", () => run("/bin/date", ["+%Y"]));

// Files: the shared temporary folders, the host's own TMPDIR around this run's, and this run's own folder.
attempt("write in /private/tmp", () => fs.writeFileSync("/private/tmp/t7-probe", "x"));
attempt("write in the TMPDIR around this run's", () => fs.writeFileSync(path.join(data, "t7-probe"), "x"));
attempt("write in this run's own TMPDIR", () => fs.writeFileSync(path.join(os.tmpdir(), "t7-probe"), "x"));

// node:sqlite: a read, then statements that would write past SQLITE_OPEN_READONLY.
const db = path.join(os.tmpdir(), "probe.db");
fs.copyFileSync(path.join(process.cwd(), "probe.db"), db);
attempt("node:sqlite SELECT", () => new DatabaseSync(db).prepare("SELECT count(*) AS n FROM t").get().n);
attempt("node:sqlite VACUUM INTO", () => new DatabaseSync(db).prepare(`VACUUM INTO '${os.tmpdir()}/copy.db'`).all());
attempt("node:sqlite PRAGMA journal_mode = DELETE", () => new DatabaseSync(db).prepare("PRAGMA journal_mode = DELETE").all());

function Probe() {
  const [fetched, setFetched] = React.useState("fetch POST: waiting");
  React.useEffect(() => {
    fetch("https://example.invalid/t7-probe", { method: "POST", body: "x" })
      .then(() => setFetched("fetch POST: ran"), (error) => setFetched(`fetch POST: refused (${String(error.message).slice(0, 100)})`));
  }, []);
  return React.createElement(List, null, [...rows, fetched].map((title, i) => React.createElement(List.Item, { key: String(i), title })));
}
module.exports.default = Probe;
