#!/usr/bin/env python3
"""To-do for Pilot: Hyper+Space is its home (To-do 2.0, Sven's pick B, Q242): type to filter or add, Return ticks a to-do
off, every other action on a key; a menu-bar item counting the open ones with a popover, and a page listing them all.

A to-do may have a due day (Q244). With none set the list reads as one tidy list; once any open one has a day, it is
sectioned by when it is due: Overdue, Today, Upcoming, No date, then Done. A day typed at the end of a new to-do is read
("call mum fri"): today, tomorrow, a weekday, next week, in 3 days, 23 oct.

The list is one JSON file, todos.json in the extension's data folder (`paths.data`): no account, no sync. Every change
reads it, changes it and writes it back under a lock (todos.lock), through a temp file and a rename. A to-do is named
by its id, never by its place in the list. Version 1 files (no order, no due day) are read as they are and written back
as version 2 on the next change, their open ones kept in the order they showed (newest first).
"""
import datetime
import fcntl
import json
import os
import re
import sys
import time
import uuid
from contextlib import contextmanager

STORE = "todos.json"
LOCK = "todos.lock"
VERSION = 2
LONGEST = 500  # characters kept of a to-do's text
MOST_ROWS = 50  # Pilot draws 50 rows of a list block at most
ID_LENGTH = 8
UNDO_SECONDS = 5  # how long a change offers Undo in Hyper+Space
OPEN, DONE = "⚪", "✅"
SECTIONS = ("Overdue", "Today", "Upcoming", "No date")
MOVABLE = ("Today", "No date", None)  # Overdue and Upcoming keep date order
DAYS = ("Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun")
MONTHS = ("jan", "feb", "mar", "apr", "may", "jun", "jul", "aug", "sep", "oct", "nov", "dec")


def send(message):
    sys.stdout.write(json.dumps(message, ensure_ascii=False) + "\n")


def plural(n, word):
    return "%d %s%s" % (n, word, "" if n == 1 else "s")


# ---- due days ----

WEEKDAYS = {"mon": 0, "monday": 0, "tue": 1, "tues": 1, "tuesday": 1, "wed": 2, "weds": 2, "wednesday": 2, "thu": 3,
            "thur": 3, "thurs": 3, "thursday": 3, "fri": 4, "friday": 4, "sat": 5, "saturday": 5, "sun": 6, "sunday": 6}
MONTH_WORDS = "|".join(sorted(set(MONTHS) | {"january", "february", "march", "april", "june", "july", "august",
                                                      "september", "sept", "october", "november", "december"}, key=len,
                              reverse=True))
TRAILING = re.compile(
    r"\s+(today|tonight|tomorrow|tmrw|tmr|next week|in (\d{1,3}) (day|days|week|weeks)|(%s)|(\d{1,2}) (%s)|(%s) (\d{1,2}))$"
    % ("|".join(sorted(WEEKDAYS, key=len, reverse=True)), MONTH_WORDS, MONTH_WORDS), re.IGNORECASE)


def month(word):
    return MONTHS.index(word.lower()[:3]) + 1


def on(year, mon, day, today):
    """That day this year, or next year once it has passed; None for a day the month lacks."""
    try:
        d = datetime.date(year, mon, day)
        return d if d >= today else datetime.date(year + 1, mon, day)
    except ValueError:
        return None


def next_monday(today):
    return today + datetime.timedelta(days=7 - today.weekday())


def parse_due(text, today):
    """(the text without a trailing day, the day) for "call mum fri"; (the text, None) when it ends in none, or is
    nothing but a day."""
    m = TRAILING.search(text)
    if not m or not text[:m.start()].strip():
        return text, None
    word = m.group(1).lower()
    if word in ("today", "tonight"):
        due = today
    elif word in ("tomorrow", "tmrw", "tmr"):
        due = today + datetime.timedelta(days=1)
    elif word == "next week":
        due = next_monday(today)
    elif m.group(2):
        n = int(m.group(2))
        due = today + datetime.timedelta(days=n * (7 if m.group(3).startswith("week") else 1))
    elif m.group(4):
        # A weekday is the next one: "fri" on a Friday is a week away.
        due = today + datetime.timedelta(days=(WEEKDAYS[word] - today.weekday() - 1) % 7 + 1)
    elif m.group(5):
        due = on(today.year, month(m.group(6)), int(m.group(5)), today)
    else:
        due = on(today.year, month(m.group(7)), int(m.group(8)), today)
    if due is None:
        return text, None
    return text[:m.start()].strip(), due


def day(value):
    """A stored due day ("2026-10-23") as a date; None for none or one unreadable."""
    try:
        return datetime.date.fromisoformat(value) if isinstance(value, str) else None
    except ValueError:
        return None


def due_label(due, today):
    """Today, Tomorrow, Fri within a week, Mon 12 when past, 23 Oct further on (with the year when it is another)."""
    n = (due - today).days
    if n == 0:
        return "Today"
    if n == 1:
        return "Tomorrow"
    if n < 0:
        return "%s %d" % (DAYS[due.weekday()], due.day)
    if n < 7:
        return DAYS[due.weekday()]
    label = "%d %s" % (due.day, MONTHS[due.month - 1].capitalize())
    return label if due.year == today.year else "%s %d" % (label, due.year)


def section(todo, today):
    due = day(todo.get("due"))
    if due is None:
        return "No date"
    return "Overdue" if due < today else "Today" if due == today else "Upcoming"


# ---- the store ----

def data_dir(run):
    """Pilot's data folder for this extension, which it makes on the first run."""
    folder = (run.get("paths") or {}).get("data")
    if not isinstance(folder, str) or not folder:
        send({"type": "error", "text": "Pilot sent no data folder"})
        sys.exit(0)
    os.makedirs(folder, exist_ok=True)
    return folder


def read(folder):
    """The file as stored: {"items": [...], "undo": ...}; empty when it is missing or unreadable."""
    try:
        with open(os.path.join(folder, STORE), encoding="utf-8") as f:
            stored = json.load(f)
    except (OSError, ValueError):
        return {"items": []}
    return stored if isinstance(stored, dict) else {"items": []}


def valid(items):
    if not isinstance(items, list):
        return []
    return [t for t in items if isinstance(t, dict) and isinstance(t.get("id"), str) and isinstance(t.get("text"), str)]


def migrate(items):
    """Version 1 to 2: each to-do gets an order, the open ones the order they showed in (newest first), the done ones
    after them; nothing else changes."""
    if all(isinstance(t.get("order"), (int, float)) for t in items):
        return items
    open_ = sorted((t for t in items if not t.get("done")), key=lambda t: -(t.get("created") or 0))
    done = [t for t in items if t.get("done")]
    for n, t in enumerate(open_ + done):
        if not isinstance(t.get("order"), (int, float)):
            t["order"] = n
    return items


def load(folder):
    """The to-dos, any version, as version 2."""
    return migrate(valid(read(folder).get("items")))


def save(folder, items, undo=None):
    path = os.path.join(folder, STORE)
    temp = "%s.%d.tmp" % (path, os.getpid())
    stored = {"version": VERSION, "items": items}
    if undo:
        stored["undo"] = undo
    with open(temp, "w", encoding="utf-8") as f:
        json.dump(stored, f, ensure_ascii=False, indent=1)
    os.replace(temp, path)


@contextmanager
def locked(folder):
    """One writer at a time."""
    with open(os.path.join(folder, LOCK), "w") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        yield


@contextmanager
def changing(folder, undo=None):
    """The to-dos to change in place, written back as the block ends, one writer at a time. `undo` is Undo's
    title ("Undo delete"): the list as it was is kept so Undo can put it back; any other change forgets it."""
    with locked(folder):
        items = load(folder)
        before = json.loads(json.dumps(items))
        yield items
        record = {"what": undo, "at": time.time(), "items": before} if undo and items != before else None
        save(folder, items, record)


def pending_undo(stored, now):
    """Undo's title for the last change, while it may still be undone in Hyper+Space; None after UNDO_SECONDS."""
    undo = stored.get("undo")
    if isinstance(undo, dict) and isinstance(undo.get("what"), str) and now - (undo.get("at") or 0) < UNDO_SECONDS:
        return undo["what"]
    return None


def arranged(items, today):
    """(open ones by section, done ones latest first): {section: [to-dos]}, a section's open ones by their order, Overdue
    and Upcoming by day first. With no open one dated, every open one is under None: the tidy list."""
    open_ = [t for t in items if not t.get("done")]
    done = sorted((t for t in items if t.get("done")), key=lambda t: -(t.get("doneAt") or 0))
    dated = any(day(t.get("due")) for t in open_)
    groups = {}
    for t in sorted(open_, key=lambda t: t.get("order") or 0):
        groups.setdefault(section(t, today) if dated else None, []).append(t)
    for name in ("Overdue", "Upcoming"):
        if name in groups:
            groups[name].sort(key=lambda t: (t["due"], t.get("order") or 0))
    return [(name, groups[name]) for name in (None,) + SECTIONS if name in groups], done


def top(items):
    """The order that puts a to-do above every other."""
    return min([t.get("order") or 0 for t in items] + [0]) - 1


def today_of(now):
    return datetime.date.fromtimestamp(now)


# ---- rows ----

def run_action(command, title, todo, **more):
    action = {"type": "run", "command": command, "title": title, "context": {"id": todo["id"]}}
    action.update(more)
    return action


def due_choices(todo, today):
    """Today, Tomorrow, the next days by name, Next week, and No date when it has one: eight at most, values as stored."""
    days = [("Today", today), ("Tomorrow", today + datetime.timedelta(days=1))]
    days += [(DAYS[d.weekday()] + " %d" % d.day, d) for d in (today + datetime.timedelta(days=n) for n in range(2, 6))]
    monday = next_monday(today)
    if all(d != monday for _, d in days):
        days.append(("Next week", monday))
    choices = [{"title": t, "value": d.isoformat()} for t, d in days][:7]
    if todo.get("due"):
        choices.append({"title": "No date", "value": ""})
    return choices


def accessory(todo, today):
    due = day(todo.get("due"))
    if due is None or todo.get("done"):
        return None
    n = (due - today).days
    tag = {"text": due_label(due, today)}
    if n <= 0:
        tag["tone"] = "alert" if n < 0 else "warn"
    return tag


def actions(todo, today, name, undo=None, menu=True):
    """Every action of a to-do, Return's first; in Hyper+Space each has a key and the list stays open as it runs
    (`stay`). `undo` is the change Undo puts back, offered second so the foot names it."""
    def menu_only(**fields):
        """In Hyper+Space: its key, and the list stays open as it runs."""
        return dict(fields, stay=True) if menu else {}
    if todo.get("done"):
        toggle = run_action("undone", "Mark not done", todo, **menu_only())
    else:
        toggle = run_action("done", "Mark done", todo, **menu_only())
    out = [toggle]
    if undo:
        out.append(run_action("undo", undo, todo, key="cmd+z", stay=True))
    out.append(run_action("edit", "Edit", todo, ask={"text": todo["text"]}, **menu_only(key="cmd+e")))
    if not todo.get("done"):
        out.append(run_action("due", "Set due date", todo, ask={"choices": due_choices(todo, today)}, **menu_only(key="cmd+d")))
        if menu and name in MOVABLE:
            for title, by, key in (("Move up", -1, "opt+up"), ("Move down", 1, "opt+down")):
                out.append(run_action("move", title, todo, key=key, stay=True, context={"id": todo["id"], "by": by}))
    out.append(dict({"type": "copy", "text": todo["text"], "title": "Copy text"}, **({"key": "cmd+shift+c"} if menu else {})))
    out.append(run_action("delete", "Delete", todo, destructive=True, **menu_only(key="cmd+delete")))
    return out


def menu_row(todo, today, name, undo):
    """A to-do in Hyper+Space: its text, its due day at the right, under its section's heading."""
    row = {"id": todo["id"], "title": todo["text"], "icon": DONE if todo.get("done") else OPEN,
           "actions": actions(todo, today, name, undo)}
    tag = accessory(todo, today)
    if tag:
        row["accessory"] = tag
    heading = "Done" if todo.get("done") else name
    if heading:
        row["section"] = heading
    return row


def surface_row(todo, today, name):
    """A to-do in the popover or on the page: a click edits its text in its row (Sven, 2026-10-12: a click must never
    tick it), the circle ticks it, 📅 asks its due day in the row (2026-10-31), ✕ deletes it, ⋯ lists the rest."""
    done = bool(todo.get("done"))
    every = actions(todo, today, name, menu=False)
    edit = next(a for a in every if a.get("command") == "edit")
    toggle, delete = every[0], every[-1]
    tick = dict(toggle, icon="checkmark.circle" if done else "circle")
    inline = [tick]
    if not done:
        inline.append(dict(next(a for a in every if a.get("command") == "due"), icon="📅"))
    row = {"id": todo["id"], "title": todo["text"], "actions": [edit] + [a for a in every if a is not edit],
           "inline": inline + [dict(delete, icon="xmark")]}
    tag = accessory(todo, today)
    if tag:
        row["accessory"] = tag
    return row


def add_input():
    return {"type": "input", "placeholder": "Add a to-do, a day at the end: call mum fri",
            "action": {"type": "run", "command": "add", "title": "Add", "context": {"quiet": True}}}


def section_lists(groups, today, most):
    """A list block per section, titled when the list is sectioned; the tidy list is one untitled list."""
    blocks, left = [], most
    for name, todos in groups:
        if left <= 0:
            break
        block = {"type": "list", "items": [surface_row(t, today, name) for t in todos[:left]]}
        if name:
            block["title"] = name
        if name in MOVABLE:
            block["reorder"] = {"command": "reorder"}
        blocks.append(block)
        left -= len(todos)
    return blocks


def done_blocks(done, today):
    """The done ones, then Delete them (asked first)."""
    count = plural(len(done), "done to-do")
    return [{"type": "list", "title": "Done", "items": [surface_row(t, today, None) for t in done[:MOST_ROWS]]},
            {"type": "buttons", "actions": [{"type": "run", "command": "clear-done", "title": "Delete %s" % count,
                                             "icon": "xmark", "ask": {"confirm": "Delete %s?" % count},
                                             "destructive": True}]}]


# ---- surfaces ----

def bar_text(groups):
    """☑️ 3, or ☑️ 3 · 1 with one due today or overdue."""
    open_count = sum(len(todos) for _, todos in groups)
    due = sum(len(todos) for name, todos in groups if name in ("Overdue", "Today"))
    return "☑️ %d" % open_count + (" · %d" % due if due else "")


def popover_blocks(groups, done, today):
    """Add a to-do, the open ones by section (Overdue and Today first), the done ones folded under N done."""
    blocks = [add_input()] + section_lists(groups, today, MOST_ROWS - 1)
    if done:
        blocks.append({"type": "list", "items": [{"title": "%d done ›" % len(done), "icon": DONE,
                                                   "actions": [{"type": "push", "command": "done-list",
                                                                "title": "Show done to-dos"}]}]})
    if not groups:
        blocks.append({"type": "markdown", "text": "Nothing to do." if not done else "All done."})
    return blocks


def bar(run):
    now = time.time()
    today = today_of(now)
    groups, done = arranged(load(data_dir(run)), today)
    blocks = popover_blocks(groups, done, today)
    if run.get("surface") == "popover":
        send({"type": "blocks", "blocks": blocks})
    else:
        send({"type": "bar", "text": bar_text(groups), "blocks": blocks})


def page(run):
    """Every to-do: counts, Add a to-do, the open ones by section, the done ones, Delete the done ones."""
    now = time.time()
    today = today_of(now)
    groups, done = arranged(load(data_dir(run)), today)
    midnight = time.mktime(time.localtime(now)[:3] + (0, 0, 0, 0, 0, -1))
    open_count = sum(len(todos) for _, todos in groups)
    blocks = [{"type": "stats", "items": [
        {"label": "Open", "value": str(open_count)},
        {"label": "Done today", "value": str(sum(1 for t in done if (t.get("doneAt") or 0) >= midnight)), "tone": "fine"},
        {"label": "Done", "value": str(len(done))}]}, add_input()]
    lists = section_lists(groups, today, MOST_ROWS)
    if len(lists) == 1 and "title" not in lists[0]:
        lists[0]["title"] = "To do"
    blocks += lists or [{"type": "markdown", "text": "Nothing to do."}]
    if done:
        blocks += done_blocks(done, today)
    send({"type": "blocks", "blocks": blocks})


def done_list(run):
    done = arranged(load(data_dir(run)), today_of(time.time()))[1]
    if not run.get("surface"):
        send({"type": "hud", "text": plural(len(done), "done to-do")})
        return
    if not done:
        send({"type": "blocks", "blocks": [{"type": "markdown", "text": "Nothing done yet."}]})
        return
    send({"type": "blocks", "blocks": done_blocks(done, today_of(time.time()))})


# ---- Hyper+Space ----

def list_todos(run):
    """The search typed is a new to-do, a day at its end read: Add “…” first, then the to-dos whose text holds every
    word; empty, every to-do by section, the done ones last."""
    now = time.time()
    today = today_of(now)
    query = " ".join((run.get("query") or "").split())
    stored = read(data_dir(run))
    items, undo = migrate(valid(stored.get("items"))), pending_undo(stored, now)
    found = []
    if query:
        text, due = parse_due(query[:LONGEST], today)
        add = {"title": "Add “%s”" % text, "icon": "➕",
               "actions": [{"type": "run", "command": "add", "title": "Add to-do", "clear": True,
                            "context": dict({"text": text, "quiet": True}, **({"due": due.isoformat()} if due else {}))}]}
        if due:
            add["accessory"] = {"text": due_label(due, today)}
        else:
            add["subtitle"] = "New to-do"
        found.append(add)
        words = query.lower().split()
        items = [t for t in items if all(w in t["text"].lower() for w in words)]
    groups, done = arranged(items, today)
    for name, todos in groups:
        found += [menu_row(t, today, name, undo) for t in todos]
    found += [menu_row(t, today, None, undo) for t in done]
    if not found:
        found = [{"title": "Nothing to do", "subtitle": "Type a to-do and press Return to add it", "icon": "☑️"}]
    send({"type": "list", "items": found[:200]})


# ---- changes ----

def typed(run):
    """The to-do's text: what was typed in Add a to-do, else what the row handed on."""
    text = run.get("input")
    if not isinstance(text, str) or not text.strip():
        text = (run.get("context") or {}).get("text")
    text = " ".join(text.split()) if isinstance(text, str) else ""
    return text[:LONGEST]


def add(run):
    """A new to-do at the top. Hyper+Space's Add row hands on the day it read; typed text ("todo buy milk fri", the
    input box) has its trailing day read here. Only the keyword says Added: the others show the list."""
    context = run.get("context") or {}
    today = today_of(time.time())
    text, due = typed(run), day(context.get("due"))
    if due is None and isinstance(run.get("input"), str):
        text, due = parse_due(text, today)
    if not text:
        send({"type": "error", "text": "type a to-do first"})
        return
    folder = data_dir(run)
    with changing(folder) as items:
        ids = {t["id"] for t in items}
        new = uuid.uuid4().hex[:ID_LENGTH]
        while new in ids:
            new = uuid.uuid4().hex[:ID_LENGTH]
        todo = {"id": new, "text": text, "done": False, "created": time.time(), "order": top(items)}
        if due:
            todo["due"] = due.isoformat()
        items.append(todo)
    if not context.get("quiet"):
        send({"type": "hud", "text": "Added: %s" % text + (" · %s" % due_label(due, today) if due else "")})


def named(run, items):
    """The to-do the context names; None, said, when it names none or one gone."""
    todo_id = (run.get("context") or {}).get("id")
    if not isinstance(todo_id, str):
        send({"type": "error", "text": "was not told which to-do"})
        return None
    todo = next((t for t in items if t["id"] == todo_id), None)
    if todo is None:
        send({"type": "error", "text": "that to-do is gone"})
    return todo


def change(run, verb):
    """Marks the to-do the context names done or not done, or deletes it; Undo can put it back."""
    with changing(data_dir(run), {"delete": "Undo delete", "done": "Undo done", "undone": "Undo not done"}[verb]) as items:
        todo = named(run, items)
        if todo is None:
            return
        if verb == "delete":
            items.remove(todo)
        elif verb == "done":
            todo["done"], todo["doneAt"] = True, time.time()
        else:
            todo["done"] = False
            todo.pop("doneAt", None)
            todo["order"] = top(items)


def edit(run):
    text = " ".join((run.get("input") or "").split())[:LONGEST]
    if not text:
        send({"type": "error", "text": "type the to-do's text"})
        return
    folder = data_dir(run)
    with changing(folder, "Undo edit") as items:
        todo = named(run, items)
        if todo is not None:
            todo["text"] = text


def due(run):
    """Sets the day the ask's choice names ("" for none)."""
    value = run.get("input")
    when = day(value)
    if when is None and value != "":
        send({"type": "error", "text": "got no day"})
        return
    folder = data_dir(run)
    with changing(folder, "Undo date") as items:
        todo = named(run, items)
        if todo is not None:
            if when:
                todo["due"] = when.isoformat()
            else:
                todo.pop("due", None)


def neighbours(items, todo, today):
    """(`todo`'s section, the open to-dos in it as shown)."""
    return next(((name, todos) for name, todos in arranged(items, today)[0] if todo in todos), (None, []))


def place(row, todo, to):
    """Moves `todo` to place `to` (from 0) among `row`, its section's to-dos, keeping the orders the section holds."""
    orders = sorted(t.get("order") or 0 for t in row)
    row = [t for t in row if t is not todo]
    row.insert(max(0, min(to, len(row))), todo)
    for t, order in zip(row, orders):
        t["order"] = order
    # Equal orders (two to-dos added at once) would not move: spread them.
    for n, t in enumerate(row):
        if n and t["order"] <= row[n - 1]["order"]:
            t["order"] = row[n - 1]["order"] + 0.001


def move(run):
    """⌥↑ ⌥↓: one place up or down within its section; Overdue and Upcoming keep date order."""
    by = (run.get("context") or {}).get("by")
    folder = data_dir(run)
    today = today_of(time.time())
    with changing(folder) as items:
        todo = named(run, items)
        if todo is None or todo.get("done") or by not in (-1, 1):
            return
        name, row = neighbours(items, todo, today)
        if row and name in MOVABLE:
            place(row, todo, row.index(todo) + by)


def reorder(run):
    """A page's drag: the row `key` to place `to` in its section's list."""
    context = run.get("context") or {}
    key, to = context.get("key"), context.get("to")
    if not isinstance(key, str) or not isinstance(to, int):
        send({"type": "error", "text": "was not told what to move"})
        return
    with changing(data_dir(run)) as items:
        todo = next((t for t in items if t["id"] == key and not t.get("done")), None)
        if todo is not None:
            place(neighbours(items, todo, today_of(time.time()))[1], todo, to)


def undo(run):
    """Puts the list back as it was before the last change that offered Undo."""
    folder = data_dir(run)
    with locked(folder):
        record = read(folder).get("undo")
        if not isinstance(record, dict) or not isinstance(record.get("items"), list):
            send({"type": "error", "text": "has nothing to undo"})
            return
        save(folder, migrate(valid(record["items"])))


def clear_done(run):
    with changing(data_dir(run), "Undo delete done") as items:
        gone = len(items)
        items[:] = [t for t in items if not t.get("done")]
        gone -= len(items)
    send({"type": "hud", "text": "Deleted %s" % plural(gone, "done to-do")})


def main():
    try:
        run = json.loads(sys.stdin.readline())
    except ValueError:
        send({"type": "error", "text": "got a run message it could not read"})
        return
    command = run.get("command")
    handlers = {"todo": list_todos, "bar": bar, "page": page, "done-list": done_list, "add": add, "edit": edit,
                "due": due, "move": move, "reorder": reorder, "undo": undo, "clear-done": clear_done}
    if command in ("done", "undone", "delete"):
        change(run, command)
    elif command in handlers:
        handlers[command](run)
    else:
        send({"type": "error", "text": "has no command %s" % command})


if __name__ == "__main__":
    main()
