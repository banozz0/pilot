"use strict";
// A fixture command in the shape Raycast's build emits (CommonJS, React and @raycast/api left to the host), written by
// hand so it needs no build. At mount it reads each core API (T3) and shows what it got as a Detail: one line per check
// in its markdown, the environment as its metadata, and the common typed actions plus a submenu's callback in its panel.
// The checks run in its support folder only; the fetch asks the server preference (a local server in the proof).
const { useEffect, useState } = require("react");
const { jsx, jsxs } = require("react/jsx-runtime");
const { Action, ActionPanel, Cache, Detail, LocalStorage, environment, getPreferenceValues } = require("@raycast/api");
const fs = require("fs");
const fsp = require("node:fs/promises");
const path = require("path");
const os = require("os");
const crypto = require("crypto");
const { exec, execSync, spawn } = require("child_process");
const { promisify } = require("util");

async function checks() {
  const out = [];
  const say = (name, value) => out.push(`- ${name}: ${value}`);
  const dir = path.join(environment.supportPath, "checks");
  say("path", [path.join("/a/b", "../c", "d.txt"), path.basename("/x/y.js", ".js"), path.extname("n.tar.gz"), path.relative("/a/b", "/a/c/d")].join(" | "));
  say("os", [os.platform(), os.homedir() === process.env.HOME, os.tmpdir().length > 0, os.EOL === "\n"].join(" | "));
  say("crypto", [crypto.createHash("sha256").update("abc").digest("hex").slice(0, 16), crypto.createHash("md5").update("abc").digest("base64"),
    /^[0-9a-f-]{36}$/.test(crypto.randomUUID())].join(" | "));
  fs.mkdirSync(dir, { recursive: true });
  fs.writeFileSync(path.join(dir, "a.txt"), "one");
  fs.appendFileSync(path.join(dir, "a.txt"), "+two");
  await fsp.writeFile(path.join(dir, "b.json"), JSON.stringify({ ok: true }));
  const stat = fs.statSync(path.join(dir, "a.txt"));
  say("fs", [fs.readFileSync(path.join(dir, "a.txt"), "utf8"), JSON.parse(await fsp.readFile(path.join(dir, "b.json"), "utf8")).ok,
    stat.size, stat.isFile(), fs.readdirSync(dir).join(","), fs.existsSync(path.join(dir, "none"))].join(" | "));
  fs.rmSync(dir, { recursive: true });
  say("fs gone", fs.existsSync(dir));
  try { fs.readFileSync(path.join(dir, "missing")); } catch (error) { say("fs error", error.code); }
  await LocalStorage.setItem("runs", ((await LocalStorage.getItem("runs")) ?? 0) + 1);
  await LocalStorage.setItem("word", "kept");
  say("LocalStorage", JSON.stringify(await LocalStorage.allItems()));
  const cache = new Cache();
  cache.set("k", "v");
  say("Cache", [cache.get("k"), cache.has("k"), cache.remove("k"), cache.has("k"), cache.isEmpty].join(" | "));
  say("environment", [environment.commandName, environment.commandMode, environment.extensionName,
    fs.readFileSync(path.join(environment.assetsPath, "note.txt"), "utf8").trim()].join(" | "));
  const url = new URL("/search?q=a+b", "https://example.com");
  url.searchParams.set("page", "2");
  say("web", [url.href, btoa("hi"), atob("aGk="), new TextEncoder().encode("é").length].join(" | "));
  const { server } = getPreferenceValues();
  try {
    const answer = await fetch(server, { headers: { "x-fixture": "core-apis" } });
    say("fetch", [answer.status, answer.ok, answer.headers.get("content-type"), JSON.stringify(await answer.json())].join(" | "));
  } catch (error) { say("fetch", `failed: ${error.message}`); }
  const waited = await new Promise((resolve) => { const t0 = Date.now(); setTimeout(() => resolve(Date.now() - t0 >= 40), 50); });
  say("timers", waited);
  say("execSync", execSync("echo sync $((2+3))", { encoding: "utf8" }).trim());
  const { stdout } = await promisify(exec)("printf 'async %s' ok");
  say("exec", stdout);
  const spawned = await new Promise((resolve) => {
    let text = "";
    const child = spawn("/bin/echo", ["spawned", "line"]);
    child.stdout.on("data", (d) => { text += d; });
    child.on("close", (code) => resolve(`${text.trim()} (exit ${code})`));
  });
  say("spawn", spawned);
  return out;
}

function Command() {
  const [lines, setLines] = useState(null);
  const [pressed, setPressed] = useState(0);
  useEffect(() => { checks().then(setLines, (error) => setLines([`- failed: ${error.stack ?? error}`])); }, []);
  const metadata = jsxs(Detail.Metadata, {
    children: [
      jsx(Detail.Metadata.Label, { title: "Command", text: environment.commandName }),
      jsx(Detail.Metadata.Separator, {}),
      jsx(Detail.Metadata.Link, { title: "Docs", target: "https://developers.raycast.com", text: "developers.raycast.com" }),
      jsxs(Detail.Metadata.TagList, { title: "Tags", children: [jsx(Detail.Metadata.TagList.Item, { text: "core" }), jsx(Detail.Metadata.TagList.Item, { text: "T3" })] }),
    ],
  });
  const actions = jsxs(ActionPanel, {
    children: [
      jsx(Action.OpenInBrowser, { url: "https://example.com/page" }),
      jsx(Action.CopyToClipboard, { content: "copied text", title: "Copy Text" }),
      jsx(Action.Paste, { content: { text: "pasted text" } }),
      jsx(Action.ShowInFinder, { path: "/tmp/fixture/file.txt" }),
      jsx(Action.Open, { target: "/tmp", title: "Open Temp" }),
      jsx(ActionPanel.Submenu, { title: "More", children: jsx(Action, { title: "Press me", onAction: () => setPressed((n) => n + 1) }) }),
      jsx(Action.Push, { title: "Push", target: null }),
    ],
  });
  const markdown = lines ? `# Core APIs\n\nPressed: ${pressed}\n\n${lines.join("\n")}` : "Checking…";
  return jsx(Detail, { markdown, metadata, actions, isLoading: !lines });
}

module.exports = { default: Command };
