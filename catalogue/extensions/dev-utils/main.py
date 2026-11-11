#!/usr/bin/env python3
"""Dev Utils for Pilot: the clipboard's text turned into what a developer needs, read with pbpaste.

Transform clipboard lists only the transforms that make sense for what the clipboard holds (a JSON row only for JSON,
a decode only for text that decodes), each row showing its result and copying or pasting it. The clipboard's text is
never logged or kept.

The page (Sven, 2026-10-31: a page does its job in place) takes the text in a box (or Use clipboard): its transforms as
rows a click copies, a JWT decoded above them, and Copy new UUID. The hidden use command keeps that text in paths.cache
for TEXT_FOR seconds so the page can draw it; Clear deletes it at once. It is never logged.
"""
import base64
import binascii
import hashlib
import json
import os
import re
import subprocess
import sys
import time
import unicodedata
import uuid
from datetime import datetime, timezone
from urllib.parse import quote, unquote_plus

MAX_INPUT = 1024 * 1024
PREVIEW = 80
B64 = re.compile(r"[A-Za-z0-9+/_-]+={0,2}\Z")
JWT = re.compile(r"[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]*\Z")
PERCENT = re.compile(r"%[0-9A-Fa-f]{2}")
TEXT = "text.json"  # in paths.cache: the page's text
TEXT_FOR = 600  # seconds the page keeps it


def send(message):
    sys.stdout.write(json.dumps(message, ensure_ascii=False) + "\n")


def clipboard():
    try:
        done = subprocess.run(["pbpaste"], capture_output=True, timeout=1)
    except (OSError, subprocess.TimeoutExpired):
        return ""
    return done.stdout[:MAX_INPUT].decode("utf-8", "replace")


def preview(text):
    line = " ".join(text[:PREVIEW * 4].split())
    return line if len(line) <= PREVIEW else line[:PREVIEW - 1] + "…"


def b64decode(text):
    """The text base64 (standard or URL-safe, padding optional) decodes to; None unless it is readable text."""
    s = "".join(text.split())
    if len(s) < 4 or not B64.match(s):
        return None
    try:
        raw = base64.urlsafe_b64decode(s.replace("+", "-").replace("/", "_") + "=" * (-len(s) % 4))
        out = raw.decode("utf-8")
    except (binascii.Error, ValueError):
        return None
    if not out or any(unicodedata.category(c) == "Cc" and c not in "\n\r\t" for c in out):
        return None
    return out


def jwt_parts(text):
    """(header, payload) of a JWT, decoded without checking its signature; None for anything else."""
    s = text.strip()
    if not JWT.match(s):
        return None
    try:
        parts = [json.loads(base64.urlsafe_b64decode(p + "=" * (-len(p) % 4)).decode("utf-8")) for p in s.split(".")[:2]]
    except (binascii.Error, ValueError):
        return None
    if not all(isinstance(p, dict) for p in parts):
        return None
    return parts[0], parts[1]


def iso(moment):
    return moment.isoformat(timespec="seconds").replace("+00:00", "Z")


def epoch_to_date(text):
    s = text.strip()
    if not s.isdigit() or not 9 <= len(s) <= 13:
        return None
    seconds = int(s) / (1000.0 if len(s) >= 12 else 1.0)
    try:
        return datetime.fromtimestamp(seconds, timezone.utc)
    except (OverflowError, OSError, ValueError):
        return None


def date_to_epoch(text):
    s = text.strip()
    if not 8 <= len(s) <= 40 or not s[:4].isdigit():
        return None
    s = s[:-1] + "+00:00" if s.endswith(("Z", "z")) else s
    try:
        moment = datetime.fromisoformat(s.replace(" ", "T", 1) if len(s) > 10 else s)
    except ValueError:
        return None
    if moment.tzinfo is None:
        moment = moment.astimezone()
    return int(moment.timestamp())


def slug(text):
    ascii_text = unicodedata.normalize("NFKD", text).encode("ascii", "ignore").decode()
    return re.sub(r"[^a-z0-9]+", "-", ascii_text.lower()).strip("-")


def row(title, result, keywords="", subtitle=None):
    return {"id": title, "title": title, "subtitle": subtitle or preview(result), "keywords": keywords,
            "actions": [{"type": "copy", "text": result, "title": "Copy result"},
                        {"type": "paste", "text": result, "title": "Paste result"}]}


def transforms(text):
    rows = [row("New UUID", str(uuid.uuid4()), "uuid guid random id"),
            row("Epoch now", str(int(time.time())), "unix timestamp time now")]
    if not text.strip():
        rows.append({"id": "empty", "title": "The clipboard holds no text", "subtitle": "Copy some text, then open this again"})
        return rows
    parts = jwt_parts(text)
    if parts:
        header, payload = parts
        rows.append({"id": "JWT", "title": "Decode JWT", "keywords": "jwt token bearer decode",
                     "subtitle": "%s · %s · not verified" % (header.get("alg", "no alg"), preview(json.dumps(payload))),
                     "actions": [{"type": "push", "command": "jwt", "title": "Show JWT", "context": {"token": text.strip()}},
                                 {"type": "copy", "text": json.dumps(payload, indent=2, ensure_ascii=False),
                                  "title": "Copy payload"}]})
    try:
        value = json.loads(text)
    except ValueError:
        value = None
    if isinstance(value, (dict, list)):
        rows.append(row("JSON pretty", json.dumps(value, indent=2, ensure_ascii=False), "json format pretty indent"))
        rows.append(row("JSON minify", json.dumps(value, separators=(",", ":"), ensure_ascii=False), "json minify compact"))
    moment = epoch_to_date(text)
    if moment:
        local = moment.astimezone()
        rows.append(row("Epoch to date", iso(moment), "epoch unix timestamp date iso",
                        subtitle="%s · %s" % (iso(moment), local.strftime("%-d %b %Y %H:%M:%S %Z"))))
    seconds = date_to_epoch(text)
    if seconds is not None:
        rows.append(row("Date to epoch", str(seconds), "date iso epoch unix timestamp"))
    decoded = b64decode(text)
    if decoded is not None and not parts:
        rows.append(row("Base64 decode", decoded, "base64 b64 decode"))
    rows.append(row("Base64 encode", base64.b64encode(text.encode("utf-8")).decode(), "base64 b64 encode"))
    if PERCENT.search(text) or "+" in text:
        decoded_url = unquote_plus(text)
        if decoded_url != text:
            rows.append(row("URL decode", decoded_url, "url percent decode unescape"))
    rows.append(row("URL encode", quote(text, safe=""), "url percent encode escape"))
    data = text.encode("utf-8")
    rows.append(row("SHA-256", hashlib.sha256(data).hexdigest(), "sha256 hash digest checksum"))
    rows.append(row("MD5", hashlib.md5(data).hexdigest(), "md5 hash digest checksum"))
    rows.append(row("lowercase", text.lower(), "lower case"))
    rows.append(row("UPPERCASE", text.upper(), "upper case caps"))
    s = slug(text)
    if s:
        rows.append(row("slug", s, "slug kebab url"))
    return rows


def ago(seconds):
    s = abs(seconds)
    unit = next((u for u in ((86400, "day"), (3600, "hour"), (60, "minute")) if s >= u[0]), (1, "second"))
    n = int(s // unit[0])
    words = "%d %s%s" % (n, unit[1], "" if n == 1 else "s")
    return "in " + words if seconds > 0 else words + " ago"


def is_number(value):
    return isinstance(value, (int, float)) and not isinstance(value, bool)


def jwt_detail(context):
    """The token the Decode JWT row pushed, else the clipboard's."""
    token = context.get("token") if isinstance(context.get("token"), str) else clipboard()
    parts = jwt_parts(token)
    if not parts:
        send({"type": "error", "text": "found no JWT on the clipboard"})
        return
    markdown, metadata, actions = jwt_view(*parts)
    send({"type": "detail", "markdown": markdown, "metadata": metadata, "actions": actions})


def jwt_view(header, payload):
    """A decoded JWT's markdown, facts and copy actions, for the detail and the page."""
    now = time.time()
    metadata = [{"label": "Algorithm", "text": str(header.get("alg", "none"))}]
    for key, label in (("iss", "Issuer"), ("sub", "Subject"), ("aud", "Audience")):
        if key in payload:
            value = payload[key]
            metadata.append({"label": label, "text": ", ".join(map(str, value)) if isinstance(value, list) else str(value)})
    for key, label in (("iat", "Issued"), ("nbf", "Not before"), ("exp", "Expires")):
        if is_number(payload.get(key)):
            moment = datetime.fromtimestamp(payload[key], timezone.utc)
            metadata.append({"label": label, "text": "%s (%s)" % (iso(moment), ago(payload[key] - now))})
    if is_number(payload.get("exp")):
        metadata.append({"label": "State", "text": "expired" if payload["exp"] < now else "not expired"})
    head = json.dumps(header, indent=2, ensure_ascii=False)
    body = json.dumps(payload, indent=2, ensure_ascii=False)
    markdown = ("# JWT\n\nDecoded, not verified: the signature is not checked.\n\n## Header\n\n```json\n%s\n```\n\n"
                "## Payload\n\n```json\n%s\n```\n" % (head, body))
    return markdown, metadata, [{"type": "copy", "text": body, "title": "Copy payload"},
                                {"type": "copy", "text": head, "title": "Copy header"}]


def text_path(run):
    folder = (run.get("paths") or {}).get("cache")
    return os.path.join(folder, TEXT) if folder else None


def held_text(run):
    """The page's text while it is younger than TEXT_FOR, else ""."""
    try:
        with open(text_path(run) or "", encoding="utf-8") as f:
            held = json.load(f)
    except (OSError, ValueError):
        return ""
    if not isinstance(held, dict) or time.time() - (held.get("at") or 0) > TEXT_FOR:
        return ""
    return held.get("text") if isinstance(held.get("text"), str) else ""


def use(run):
    """The page's text: what the box holds, or the clipboard's (Use clipboard); an emptied box or Clear deletes it."""
    path = text_path(run)
    if not path:
        return
    context = run.get("context") if isinstance(run.get("context"), dict) else {}
    text = clipboard() if context.get("clipboard") else (run.get("input") or "")
    if context.get("clear") or not text.strip():
        try:
            os.remove(path)
        except OSError:
            pass
        if context.get("clipboard"):
            send({"type": "hud", "text": "The clipboard holds no text"})
        return
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path + ".tmp", "w", encoding="utf-8") as f:
        json.dump({"text": text, "at": time.time()}, f)
    os.replace(path + ".tmp", path)


def page(run):
    """The page: the box and its buttons; with a text, a JWT decoded when it is one, then its transforms, a click
    copying one. Paste stays in Hyper+Space: on the page it would land in Pilot's own window."""
    text = held_text(run)
    buttons = [{"type": "run", "command": "use", "title": "Use clipboard", "context": {"clipboard": True}},
               {"type": "run", "command": "new-uuid", "title": "Copy new UUID"}]
    if text:
        buttons.append({"type": "run", "command": "use", "title": "Clear", "context": {"clear": True}})
    blocks = [{"type": "input", "placeholder": "Paste text to transform: JSON, a JWT, a timestamp, base64…", "live": True,
               "debounce": 400, "action": {"type": "run", "command": "use", "title": "Transform"}},
              {"type": "buttons", "actions": buttons}]
    if not text:
        blocks.append({"type": "markdown", "text": "Paste text above, or Use clipboard: its transforms show here."})
        send({"type": "blocks", "blocks": blocks})
        return
    blocks.append({"type": "markdown", "text": "**%d characters:** %s" % (len(text), preview(text))})
    parts = jwt_parts(text)
    if parts:
        markdown, metadata, actions = jwt_view(*parts)
        facts = "\n".join("- **%s:** %s" % (m["label"], m["text"]) for m in metadata)
        blocks.append({"type": "section", "title": "JWT", "subtitle": "decoded, not verified", "blocks": [
            {"type": "markdown", "text": facts + "\n\n" + markdown.split("\n\n", 2)[2]},
            {"type": "buttons", "actions": actions}]})
    rows = []
    for item in transforms(text):
        copies = [a for a in item.get("actions", []) if a["type"] == "copy"]
        if copies and item["id"] != "JWT":
            rows.append(dict(item, actions=copies))
    blocks.append({"type": "list", "title": "Transforms · click copies", "items": rows})
    send({"type": "blocks", "blocks": blocks})


def main():
    try:
        run = json.loads(sys.stdin.readline())
    except ValueError:
        send({"type": "error", "text": "got a run message it could not read"})
        return
    command = run.get("command")
    if command == "transform":
        send({"type": "list", "items": transforms(clipboard())})
    elif command == "jwt":
        jwt_detail(run.get("context") if isinstance(run.get("context"), dict) else {})
    elif command == "new-uuid":
        value = str(uuid.uuid4())
        send({"type": "action", "action": {"type": "copy", "text": value}})
        send({"type": "action", "action": {"type": "hud", "text": "Copied %s" % value}})
    elif command == "use":
        use(run)
    elif command == "page":
        page(run)
    else:
        send({"type": "error", "text": "has no command %s" % command})


if __name__ == "__main__":
    main()
