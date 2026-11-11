#!/usr/bin/env python3
"""Ghostex sessions for Pilot: Sven's Ghostex sessions in Hyper+Space, a menu-bar item with a popover, and a page
(Surfaces v2, Pilot story 165), each session read, replied to, renamed, tagged, slept, woken or closed through the
`ghostex` CLI.

The list is `ghostex sessions --json --full`, read only, which answers in about 0.2 s, so it is asked on every open
under a deadline inside Pilot's limits and never cached. A session is named to the CLI by its globalRef (S..:P..:G..),
checked against REF, so a context can never say `all` and nothing ever acts on more than that one session; free text
(a reply, a title, a tag) always goes as `--flag=value`, so it can never read as a flag or as --help. The Show setting
narrows what the list, the bar and the page show to orchestrators (Ghostex's coordinatorRole) or one agent (agentId);
an action still finds its session among them all.

A row pushes its chat: `read-session-chat <ref> --limit 200 --json`, folded to the last six messages, tool work in one
grey line, Sven's own last message always first among them, asked again every 2 s while it shows. When the same chat was read under LONG_POLL_WINDOW s ago (so it is
Pilot asking again, not a first open) the read long-polls with `--wait-ms` and the last fingerprint, so a change shows
at once. A reply comes in as the run message's `input`: Return queues it until the agent stops
(`queue-session-chat-prompt`) or sends it at once to an agent that is not working, Option+Return interrupts a working
agent first (`interrupt-session-chat`), and a sleeping session is woken, then sent to. These are Ghostex's own chat
verbs, the ones its chat and phone app use; `agents send` needs a calling Ghostex session and labels the text as
another agent's, so Sven's reply would arrive as a peer's.
"""
import json
import os
import re
import shutil
import signal
import subprocess
import sys
import time
from collections import namedtuple
from datetime import datetime, timezone

STARTED = time.monotonic()
BUDGET = {"popover": 3.5, "page": 3.5}  # seconds for the session list; a list or bar gets DEFAULT_BUDGET
DEFAULT_BUDGET = 1.2  # Pilot stops a list or a bar at 2 s; the CLI answers in about 0.2 s
ACTION_TIMEOUT = 20
CHAT_ROWS = 200  # transcript rows read, enough to reach Sven's last message past a long run of tool calls (about 0.1 s)
CHAT_MESSAGES = 6
CHAT_REFRESH = 2
LONG_POLL_MS = 2000
LONG_POLL_WINDOW = 4.5
LONGEST_MESSAGE = 1500
MOST_ROWS = 49
MOST_CHOICES = 8  # Pilot lists eight choices in an ask at most
REF = re.compile(r"[A-Za-z0-9_-]+:[A-Za-z0-9_-]+:[A-Za-z0-9_-]+\Z")
CUSTOM_TAG = re.compile(r"custom-[a-z0-9]{4,40}\Z")
# Ghostex's built-in session tags, in its own order (packages/shared/session-tags.ts).
TAGS = ["favorite", "high-priority", "low-priority", "todo", "research", "in-progress", "testing", "blocked", "on-hold",
        "done", "bug", "feature", "design"]
SENDER = "\n\nMessage from another agent\n"
HARNESS = ("<task-notification>", "<system-reminder>", "<command-name>", "<local-command", "<bash-")
AGENTS = {"claude": "Claude", "codex": "Codex", "hermes-agent": "Hermes"}
# The Show setting's choices besides "all": "coordinator" is Ghostex's coordinatorRole, any other value an agentId or
# the name of a custom agent (designer, reviewer, content), whose agentId Ghostex suffixes per install.
SHOW = {"coordinator": "orchestrator", "claude": "Claude Code", "codex": "Codex", "hermes-agent": "Harry",
        "designer": "designer", "reviewer": "reviewer", "content": "content"}
State = namedtuple("State", "order icon words label badge tone")
# Each state's place in the list (what needs Sven first), icon, words in Hyper+Space, label in the popover and the page's
# stats, badge and tone.
STATES = {"question": State(0, "❓", "asks you something", "Need you", "needs you", "warn"),
          "working": State(1, "🟢", "working", "Working", "working", "fine"),
          "idle": State(2, "⚪", "awake, idle", "Idle", "idle", None),
          "asleep": State(3, "💤", "asleep", "Asleep", "asleep", None),
          "gone": State(4, "⬛", "not running", None, "not running", None)}


def send(message):
    sys.stdout.write(json.dumps(message, ensure_ascii=False) + "\n")


def first_line(text, limit=160):
    line = next((l.strip() for l in (text or "").splitlines() if l.strip()), "")
    return line[:limit]


def ghostex(arguments, timeout):
    """(parsed JSON or None, error text or None) for one ghostex call."""
    binary = shutil.which("ghostex")
    if not binary:
        return None, "ghostex is not installed: open Ghostex once, or put its CLI on your PATH"
    try:
        proc = subprocess.Popen([binary] + arguments, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
                                stderr=subprocess.PIPE, start_new_session=True)
    except OSError as e:
        return None, "could not run ghostex: %s" % e.strerror
    try:
        out, err = proc.communicate(timeout=max(0.1, timeout))
    except subprocess.TimeoutExpired:
        # Its own process group, so a child still holding the pipe goes too and nothing waits on it.
        os.killpg(proc.pid, signal.SIGKILL)
        proc.communicate()
        return None, "Ghostex did not answer in time: is it running?"
    stdout, stderr = out.decode("utf-8", "replace"), err.decode("utf-8", "replace")
    try:
        answer = json.loads(stdout) if stdout.strip() else None
    except ValueError:
        answer = None
    failed = proc.returncode != 0 or (isinstance(answer, dict) and answer.get("ok") is False)
    if failed:
        said = None
        if isinstance(answer, dict):
            said = answer.get("error") or answer.get("message")
            if isinstance(said, dict):
                said = said.get("message")
        return None, first_line(said if isinstance(said, str) else stderr) or "ghostex failed"
    return answer, None


def left(surface):
    return STARTED + BUDGET.get(surface, DEFAULT_BUDGET) - time.monotonic()


# ---- sessions ----

def agent_names(answer):
    """agentId → its name, from every project's custom agents (designer, moody…)."""
    names = {}
    for project in answer.get("projects") or []:
        for agent in (project or {}).get("customAgents") or []:
            if isinstance(agent, dict) and isinstance(agent.get("agentId"), str) and isinstance(agent.get("name"), str):
                names.setdefault(agent["agentId"], agent["name"])
    return names


def agent_of(session, names):
    if session.get("kind") == "terminal":
        return "terminal"
    agent = session.get("agentId") or session.get("agentName")
    if not isinstance(agent, str) or not agent:
        return None
    return names.get(agent) or AGENTS.get(agent) or agent


def state_of(session):
    status = session.get("status")
    if status == "sleep" or session.get("isSleeping"):
        return "asleep"
    if status != "running":
        return "gone"
    if (session.get("pendingQuestionCount") or 0) > 0:
        return "question"
    return "working" if session.get("activity") == "working" else "idle"


def seconds_since(stamp, now):
    if not isinstance(stamp, str):
        return None
    try:
        moment = datetime.strptime(stamp[:19], "%Y-%m-%dT%H:%M:%S").replace(tzinfo=timezone.utc)
    except ValueError:
        return None
    return max(0, now - moment.timestamp())


def ago(seconds, suffix=" ago"):
    if seconds is None:
        return None
    if seconds < 60:
        return "just now"
    for size, unit in ((86400, "d"), (3600, "h"), (60, "min")):
        if seconds >= size:
            return "%d %s%s" % (seconds // size, unit, suffix)


def shows(session, show, names):
    """Whether the Show setting (show_of's) keeps the session."""
    if show == "all":
        return True
    if show == "coordinator":
        return session.get("coordinatorRole") == "coordinator"
    agent = session.get("agentId")
    return agent == show or names.get(agent) == show


def show_of(run):
    show = (run.get("preferences") or {}).get("show")
    return show if show in SHOW else "all"


def kind_of(show, many=False):
    """What the Show setting keeps, in words: "session", "orchestrators", "Codex session"…"""
    if show == "coordinator":
        return "orchestrators" if many else "orchestrator"
    noun = "sessions" if many else "session"
    return noun if show == "all" else "%s %s" % (SHOW[show], noun)


def read_sessions(timeout, show="all"):
    """[(session, state, idle seconds)] the Show setting keeps, in the list's order (what needs Sven first, then the
    latest), and the agents' names; or why there are none."""
    answer, error = ghostex(["sessions", "--json", "--full"], timeout)
    if error:
        return None, None, error
    sessions = answer.get("sessions") if isinstance(answer, dict) else None
    if not isinstance(sessions, list):
        return None, None, "ghostex sessions gave no session list"
    now, names = time.time(), agent_names(answer)
    rows = [(s, state_of(s), seconds_since(s.get("lastInteractionAt") or s.get("updatedAt"), now)) for s in sessions
            if isinstance(s, dict) and isinstance(s.get("globalRef"), str) and REF.match(s["globalRef"])
            and shows(s, show, names)]
    rows.sort(key=lambda r: (STATES[r[1]].order, float("inf") if r[2] is None else r[2]))
    return rows, names, None


def find_session(ref, timeout=ACTION_TIMEOUT):
    """(the session the ref names, its state) live, or why not."""
    rows, _, error = read_sessions(timeout)
    if error:
        return None, None, error
    found = next(((s, state) for s, state, _ in rows if s["globalRef"] == ref), None)
    if not found:
        return None, None, "that session is gone from Ghostex"
    return found[0], found[1], None


def title_of(session):
    return session.get("displayTitle") or session.get("title") or "Session %s" % session["globalRef"].rsplit(":", 1)[-1]


def custom_tags():
    """[(id, name)] of Sven's custom session tags in his order; none when Ghostex does not say."""
    answer, error = ghostex(["read-custom-session-tags", "--json"], 1)
    catalog = (answer or {}).get("customSessionTags") if isinstance(answer, dict) else None
    if error or not isinstance(catalog, dict):
        return []
    tags = catalog.get("tags") if isinstance(catalog.get("tags"), dict) else {}
    order = [t for t in catalog.get("order") or [] if t in tags] + sorted(t for t in tags if t not in (catalog.get("order") or []))
    return [(t, tags[t]["name"]) for t in order
            if CUSTOM_TAG.match(t) and isinstance(tags[t], dict) and isinstance(tags[t].get("name"), str)]


def allowed_of(session):
    """What Ghostex says may be done to the session (sleep, wake, kill…)."""
    return session.get("actions") if isinstance(session.get("actions"), dict) else {}


def toggle(ref, state, allowed):
    """Sleep for an awake session, Wake for a sleeping one, as Ghostex allows; None otherwise."""
    if state == "asleep" and allowed.get("wake", True):
        return {"type": "run", "command": "wake", "title": "Wake", "icon": "sun", "context": {"ref": ref}}
    if state not in ("asleep", "gone") and allowed.get("sleep"):
        return {"type": "run", "command": "sleep", "title": "Sleep", "icon": "moon", "context": {"ref": ref}}
    return None


def unavailable(error):
    return [{"type": "markdown", "text": "Ghostex sessions are not available: %s" % error}]


class Board:
    """The sessions as one surface draws them: rows, the tag choices, the counts."""

    def __init__(self, surface, show="all"):
        self.show = show
        self.rows, self.names, self.error = read_sessions(left(surface), show)
        # The bar skips Sven's custom tags: its rows only stand in until the popover answers.
        custom = custom_tags() if surface != "bar" and not self.error else []
        self.tag_titles = dict([(t, t.replace("-", " ").capitalize()) for t in TAGS] + custom)
        if self.error:
            return
        self.count = {state: sum(1 for _, s, _ in self.rows if s == state) for state in STATES}
        used = {}
        for s, _, _ in self.rows:
            used[s.get("sessionTag")] = used.get(s.get("sessionTag"), 0) + 1
        # Sven's own tags first, then the built-ins he uses most, then Ghostex's order.
        self.tags = [t for t, _ in custom] + sorted(TAGS, key=lambda t: (-used.get(t, 0), TAGS.index(t)))

    def tag_choices(self, current):
        choices = [{"title": self.tag_titles[t], "value": t} for t in self.tags if t != current]
        if current:
            return choices[:MOST_CHOICES - 1] + [{"title": "No tag", "value": "none"}]
        return choices[:MOST_CHOICES]

    def item(self, session, state, idle_for, page=False):
        """One session as a row: a click opens its chat; ⋯ renames, tags, sleeps or wakes, focuses and closes it. The
        page adds badges and inline buttons (Reply, Sleep or Wake or else Rename, Close), every inline also in actions for
        an older Pilot."""
        ref, title = session["globalRef"], title_of(session)
        allowed = allowed_of(session)
        asleep = state == "asleep"
        context = {"ref": ref, "title": title}
        chat = {"type": "push", "command": "chat", "title": "Reply" if page else "Open chat", "icon": "bubble",
                "context": context}
        rename = {"type": "run", "command": "rename", "title": "Rename…", "icon": "pencil", "context": context,
                  "ask": {"text": title}}
        current = session.get("sessionTag") if isinstance(session.get("sessionTag"), str) else None
        tag = {"type": "run", "command": "tag", "title": "Tag", "icon": "tag", "context": context,
               "ask": {"choices": self.tag_choices(current)}}
        focus = {"type": "run", "command": "focus", "title": "Open in Ghostex", "context": {"ref": ref, "wake": asleep}}
        close = {"type": "run", "command": "close", "title": "Close…", "icon": "xmark", "destructive": True,
                 "context": context, "ask": {"confirm": "Close %s? Its terminal ends." % title}}
        switch = toggle(ref, state, allowed)
        actions = [chat, rename, tag] + ([switch] if switch else []) + [focus]
        if allowed.get("kill", True):
            actions.append(close)
        agent = agent_of(session, self.names or {})
        project = session.get("projectName") or ""
        row = {"id": ref, "title": title, "icon": STATES[state].icon, "actions": actions,
               "subtitle": " · ".join(x for x in ((None if page else project), agent, ago(idle_for, "")) if x)}
        if page:
            badges = [{"text": STATES[state].badge, "tone": STATES[state].tone}]
            if current in self.tag_titles:
                badges.append({"text": self.tag_titles[current].lower()})
            if session.get("queuedPromptCount"):
                badges.append({"text": "%d queued" % session["queuedPromptCount"],
                               "tone": "alert" if session.get("queuedPromptFailedCount") else None})
            row["badges"] = [dict((k, v) for k, v in b.items() if v is not None) for b in badges]
            # Three at most: Reply, Sleep or Wake (else Rename), and Close, asked first in the row.
            row["inline"] = [chat, switch or rename] + ([close] if allowed.get("kill", True) else [])
        return row

    def popover(self):
        """Need you, Working, Idle, then a row for the sleeping ones."""
        if self.error:
            return unavailable(self.error)
        blocks = []
        for state in ("question", "working", "idle"):
            items = [self.item(s, st, t) for s, st, t in self.rows if st == state][:MOST_ROWS]
            if items:
                blocks.append({"type": "list", "title": STATES[state].label, "items": items})
        if not blocks:
            blocks.append({"type": "markdown", "text": "No %s is awake." % kind_of(self.show)})
        if self.count["asleep"]:
            blocks.append({"type": "list", "items": [{"title": "%d asleep ›" % self.count["asleep"], "icon": "💤",
                                                      "actions": [{"type": "push", "command": "asleep",
                                                                   "title": "Show sleeping sessions"}]}]})
        return blocks

    def page(self):
        """How many sessions are in each state, then one list per project, its sessions in the list's order."""
        if self.error:
            return unavailable(self.error)
        stats = []
        for state in ("question", "working", "idle", "asleep"):
            stat = {"label": STATES[state].label, "value": str(self.count[state])}
            if self.count[state] and STATES[state].tone:
                stat["tone"] = STATES[state].tone
            stats.append(stat)
        blocks = [{"type": "stats", "items": stats}]
        projects = {}
        for s, st, t in self.rows:
            projects.setdefault(s.get("projectName") or "", []).append(self.item(s, st, t, page=True))
        for project, items in projects.items():
            blocks.append({"type": "list", "title": project or "No project", "items": items[:MOST_ROWS]})
        if not self.rows:
            text = ("No Ghostex sessions. Start an agent in Ghostex and it shows here." if self.show == "all" else
                    "No %s. Show, in the extension's settings, picks which." % kind_of(self.show, True))
            blocks.append({"type": "markdown", "text": text})
        return blocks


# ---- Hyper+Space ----

def list_sessions(run):
    """Every session the Show setting keeps as a row; Return focuses it in Ghostex (waking it first when asleep), ⋯
    sleeps or wakes it."""
    show = show_of(run)
    rows, names, error = read_sessions(left(None), show)
    if error:
        send({"type": "list", "items": [{"title": "Ghostex sessions are not available", "subtitle": error, "icon": "⚠️"}]})
        return
    items = []
    for s, state, idle_for in rows:
        ref, asleep = s["globalRef"], state == "asleep"
        agent, project = agent_of(s, names), s.get("projectName") or ""
        allowed = allowed_of(s)
        words = STATES[state].words + (", parked" if s.get("isParked") else "")
        actions = [{"type": "run", "command": "focus", "title": "Wake and focus in Ghostex" if asleep else
                    "Focus in Ghostex", "context": {"ref": ref, "wake": asleep}}]
        if allowed.get("sleep") and not asleep:
            actions.append({"type": "run", "command": "sleep", "title": "Sleep", "context": {"ref": ref}})
        if allowed.get("wake") or asleep:
            actions.append({"type": "run", "command": "wake", "title": "Wake", "context": {"ref": ref}})
        items.append({"id": ref, "title": title_of(s), "icon": STATES[state].icon, "actions": actions,
                      "subtitle": " · ".join(x for x in (project, agent, words, ago(idle_for)) if x),
                      "keywords": " ".join(x for x in (project, agent or "", STATES[state].words, str(s.get("alias") or "")) if x)})
    if not items and show == "all":
        items = [{"title": "No Ghostex sessions", "subtitle": "Start an agent in Ghostex and it shows here", "icon": "👻"}]
    elif not items:
        items = [{"title": "No %s in Ghostex" % kind_of(show, True), "icon": "👻",
                  "subtitle": "Show, in the extension's settings, picks which sessions this lists"}]
    send({"type": "list", "items": items})


# ---- surfaces ----

def bar(run):
    """The bar item: the ghost and how many sessions work, amber with how many need an answer; a click (surface
    popover) asks the same command for the grouped sessions."""
    surface = run.get("surface")
    board = Board(surface, show_of(run))
    if surface == "popover":
        send({"type": "blocks", "blocks": board.popover()})
        return
    if board.error:
        send({"type": "bar", "text": "👻", "blocks": board.popover()})
        return
    need, working = board.count["question"], board.count["working"]
    line = {"type": "bar", "text": "👻 %d" % (need or working) if need or working else "👻", "blocks": board.popover()}
    if need:
        line["tone"] = "warn"
    send(line)


def page(run):
    send({"type": "blocks", "blocks": Board("page", show_of(run)).page()})


def asleep(run):
    """The sleeping sessions, pushed from the popover's "N asleep ›"."""
    board = Board(run.get("surface") or "popover", show_of(run))
    if board.error:
        blocks = board.popover()
    else:
        items = [board.item(s, st, t) for s, st, t in board.rows if st == "asleep"][:MOST_ROWS]
        blocks = [{"type": "list", "items": items}] if items else [{"type": "markdown", "text": "No session is asleep."}]
    send({"type": "blocks", "blocks": blocks})


# ---- chat ----

def texts(message, kind):
    return "\n\n".join(b["text"].strip() for b in message.get("blocks") or []
                       if isinstance(b, dict) and b.get("type") == kind and isinstance(b.get("text"), str) and b["text"].strip())


def short(text):
    """The sender block another agent's message carries, cut to one line; long text cut to LONGEST_MESSAGE."""
    if SENDER in text:
        body, block = text.split(SENDER, 1)
        who = next((l[len("Session: "):] for l in block.splitlines() if l.startswith("Session: ")), "another agent")
        text = "%s\n\n*from %s*" % (body.rstrip(), who)
    return text if len(text) <= LONGEST_MESSAGE else text[:LONGEST_MESSAGE - 1].rstrip() + "…"


def fold(rows):
    """Transcript rows → chat messages: user and assistant text as they are, every run of tool calls (and harness
    rows: task notifications, reminders) as one tool line, "ran Bash" or "ran 3 tools"; the last CHAT_MESSAGES user
    or assistant messages and the tool lines among and after them. When the user's last message is older than those, it
    leads them, then one grey line saying how many messages came between."""
    out, tools = [], []

    def flush():
        if tools:
            out.append({"role": "tool", "text": "ran %s" % (tools[0][0] if len(tools) == 1 else "%d tools" % len(tools)),
                        "at": tools[-1][1]})
            del tools[:]

    for row in rows:
        if not isinstance(row, dict):
            continue
        role = row.get("role")
        at = row["timestamp"] / 1000.0 if isinstance(row.get("timestamp"), (int, float)) else None
        if role not in ("user", "assistant"):
            continue  # tool results belong to their call; system, reasoning and harness rows are not the chat
        text = texts(row, "text")
        if role == "user" and text.startswith(HARNESS):
            tools.append(("Bash" if text.startswith("<bash-") else "a task", at))
            continue
        if text:
            flush()
            message = {"role": role, "text": short(text)}
            if at is not None:
                message["at"] = at
            out.append(message)
        if role == "assistant":
            tools.extend((b["name"] if isinstance(b.get("name"), str) else "a tool", at) for b in row.get("blocks") or []
                         if isinstance(b, dict) and b.get("type") == "tool-call")
    flush()
    spoken = [i for i, m in enumerate(out) if m["role"] != "tool"]
    if len(spoken) < CHAT_MESSAGES:
        return out
    user = next((n for n in range(len(spoken) - 1, -1, -1) if out[spoken[n]]["role"] == "user"), None)
    if user is None or user >= len(spoken) - CHAT_MESSAGES:
        return out[spoken[-CHAT_MESSAGES]:]
    between = len(spoken) - CHAT_MESSAGES - user  # spoken messages after the user's, before the last five
    # Never next to a tool line: Pilot folds tool lines in a row into one "ran N tools".
    gap = [{"role": "tool", "text": "%d more %s" % (between, "message" if between == 1 else "messages")}] if between else []
    return [out[spoken[user]]] + gap + out[spoken[-(CHAT_MESSAGES - 1)]:]


def cache_file(run):
    folder = (run.get("paths") or {}).get("cache") or os.path.join(os.environ.get("TMPDIR", "/tmp"), "pilot-ghostex")
    return os.path.join(folder, "chat.json")


def load_reads(path):
    try:
        with open(path, encoding="utf-8") as f:
            reads = json.load(f)
        return reads if isinstance(reads, dict) else {}
    except (OSError, ValueError):
        return {}


def save_read(path, reads, ref, fingerprint):
    """Remembers this chat's fingerprint and when it was read, dropping reads over a minute old."""
    now = time.time()
    reads = {r: v for r, v in reads.items() if isinstance(v, dict) and now - (v.get("at") or 0) < 60}
    reads[ref] = {"fingerprint": fingerprint, "at": now}
    try:
        os.makedirs(os.path.dirname(path), exist_ok=True)
        tmp = "%s.%d.tmp" % (path, os.getpid())
        with open(tmp, "w", encoding="utf-8") as f:
            json.dump(reads, f)
        os.replace(tmp, path)
    except OSError:
        pass


def context_ref(run):
    context = run.get("context") if isinstance(run.get("context"), dict) else {}
    ref = context.get("ref")
    if not (isinstance(ref, str) and REF.match(ref)):
        send({"type": "error", "text": "got no Ghostex session to act on"})
        return None, context
    return ref, context


def chat(run):
    """One session's chat with a reply box, asked again every CHAT_REFRESH s while it shows."""
    ref, context = context_ref(run)
    if not ref:
        return
    session, state, _ = find_session(ref, 1.5)
    title = title_of(session) if session else context.get("title") if isinstance(context.get("title"), str) else "this session"
    path = cache_file(run)
    reads = load_reads(path)
    last = reads.get(ref) or {}
    arguments = [ref, "--limit", str(CHAT_ROWS), "--json"]
    if isinstance(last.get("fingerprint"), str) and time.time() - (last.get("at") or 0) < LONG_POLL_WINDOW:
        arguments += ["--wait-ms", str(LONG_POLL_MS), "--fingerprint", last["fingerprint"]]
    answer, problem = ghostex(["read-session-chat"] + arguments, 2.6)
    blocks = []
    if problem or not isinstance(answer, dict):
        blocks.append({"type": "markdown", "text": "Can't read this chat: %s" % (problem or "Ghostex gave no chat")})
    else:
        if isinstance(answer.get("fingerprint"), str):
            save_read(path, reads, ref, answer["fingerprint"])
        messages = fold(answer.get("messages") if isinstance(answer.get("messages"), list) else [])
        blocks.append({"type": "chat", "working": answer.get("working") is True, "messages": messages})
    if state == "gone":
        blocks.append({"type": "markdown", "text": "Not running: open it in Ghostex to start it again."})
    else:
        send_context = {"ref": ref, "title": title}
        blocks.append({"type": "input", "placeholder": ("Reply wakes %s…" if state == "asleep" else "Reply to %s…") % title,
                       # Pilot's hint under the box reads the titles: "↩ Queue · ⌥↩ Interrupt and send" while it works.
                       "action": {"type": "run", "command": "send", "title": "Queue" if state in ("working", "question") else "Send",
                                  "context": send_context},
                       "alt": {"type": "run", "command": "send", "title": "Interrupt and send",
                               "context": dict(send_context, interrupt=True)}})
        queued = session.get("queuedPromptCount") if session else 0
        if queued:
            blocks.append({"type": "markdown", "text": "%d waiting in its queue" % queued})
    buttons = [{"type": "run", "command": "focus", "title": "Open in Ghostex", "context": {"ref": ref, "wake": state == "asleep"}}]
    switch = toggle(ref, state, allowed_of(session)) if session else None
    blocks.append({"type": "buttons", "actions": buttons + ([switch] if switch else [])})
    send({"type": "blocks", "refresh": CHAT_REFRESH, "blocks": blocks})


def typed(run):
    text = run.get("input")
    return text.strip() if isinstance(text, str) and text.strip() else None


def act(arguments, failing):
    """One ghostex write; on failure says `failing: why` and is False."""
    _, error = ghostex(arguments, ACTION_TIMEOUT)
    if error:
        send({"type": "error", "text": "%s: %s" % (failing, error)})
    return not error


def reply(run, ref, context):
    """Return: queued until a working agent stops, sent at once otherwise; Option+Return (`interrupt`) interrupts a
    working agent, then sends; a sleeping session is woken first, then sent to."""
    text = typed(run)
    if not text:
        send({"type": "error", "text": "got no reply to send"})
        return
    _, state, error = find_session(ref)
    if error or state == "gone":
        send({"type": "error", "text": "could not send: %s" % (error or "it is not running, open it in Ghostex")})
        return
    target = "--session-id=%s" % ref
    interrupt = context.get("interrupt") is True
    verb, done = "send-session-chat-message", "Sent"
    if state == "asleep":
        if not act(["wake", "--session-id", ref, "--json"], "could not wake it"):
            return
        done = "Woken and sent"
    elif interrupt and state == "working":
        if not act(["interrupt-session-chat", target], "could not interrupt it"):
            return
        done = "Interrupted and sent"
    elif not interrupt and state in ("working", "question"):
        verb, done = "queue-session-chat-prompt", "Queued until it stops"
    if act([verb, target, "--text=%s" % text, "--json"], "could not send"):
        send({"type": "hud", "text": done})


def rename(run, ref, _):
    title = typed(run)
    if not title:
        send({"type": "error", "text": "got no new title"})
    elif act(["rename-session", "--session-id=%s" % ref, "--title=%s" % title[:200], "--json"], "could not rename it"):
        send({"type": "hud", "text": "Renamed"})


def tag(run, ref, _):
    value = typed(run)
    if not (value in TAGS or value == "none" or (value and CUSTOM_TAG.match(value))):
        send({"type": "error", "text": "got no tag to set"})
    elif act(["tag-session", "--session-id=%s" % ref, "--tag=%s" % value, "--json"], "could not tag it"):
        send({"type": "hud", "text": "Tag cleared" if value == "none" else "Tagged"})


def focus(run, ref, context):
    wake = context.get("wake") is True
    if wake and not act(["wake", "--session-id", ref, "--json"], "could not wake it"):
        return
    if not act(["focus", "--session-id", ref, "--json"], "could not focus it"):
        return
    try:
        subprocess.run(["open", "-a", "Ghostex"], capture_output=True, timeout=10, stdin=subprocess.DEVNULL)
    except (subprocess.TimeoutExpired, OSError):
        pass
    send({"type": "hud", "text": "Woken and focused in Ghostex" if wake else "Focused in Ghostex"})


def lifecycle(verb, failing, done):
    """A sleep, wake or kill (Close…, asked first in the row) of the one session."""
    def run_it(run, ref, _):
        if act([verb, "--session-id", ref, "--json"], failing):
            send({"type": "hud", "text": done})
    return run_it


VIEWS = {"sessions": list_sessions, "bar": bar, "page": page, "asleep": asleep, "chat": chat}
# Each acts on the one session its context's ref names, refused before anything runs without one.
WRITES = {"send": reply, "rename": rename, "tag": tag, "focus": focus,
          "sleep": lifecycle("sleep", "could not sleep it", "Session asleep"),
          "wake": lifecycle("wake", "could not wake it", "Session awake"),
          "close": lifecycle("kill", "could not close it", "Session closed")}


def main():
    try:
        run = json.loads(sys.stdin.readline())
    except ValueError:
        send({"type": "error", "text": "got a run message it could not read"})
        return
    command = run.get("command")
    if command in VIEWS:
        VIEWS[command](run)
    elif command in WRITES:
        ref, context = context_ref(run)
        if ref:
            WRITES[command](run, ref, context)
    else:
        send({"type": "error", "text": "has no command %s" % command})


if __name__ == "__main__":
    main()
