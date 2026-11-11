#!/usr/bin/env python3
"""Video downloader for Pilot: a YouTube, X or Twitch link, from the search or the clipboard, saved to ~/Downloads by
yt-dlp and ffmpeg (Homebrew), as a video or its audio.

Hyper+Space's list must answer in 2 s and yt-dlp takes longer to read a link, so both slow jobs run detached from the
command that starts them (a double fork into a new session, outside the process tree Pilot stops): the probe, which
writes the link's title and sizes to paths.cache, and the download, which writes its progress to paths.data/job.json.
The list draws whichever is there when it is asked; the page asks again every 2 s while a download runs, and a done
download says so in a HUD through pilot://alert. yt-dlp works only in paths.cache/part, emptied first, and the finished
file is moved to ~/Downloads under a name no file there has: yt-dlp reuses a same-named file where it saves and its audio
step deletes what it converted, so it never sees ~/Downloads. Cancel deletes only the part folder. paths.data/last.json keeps the format picked last, listed first (Q476).
The bar item (Q484) is 📥 while idle and 📥 and the percent while a download runs, asked every 60 s (Pilot's floor) and
at once after Download or Cancel; its popover follows the download every 2 s, and when idle offers the copied link's
formats and a box to paste a link into, Return saving it in the last format used. Only the popover reads the clipboard.
The page (Sven, 2026-10-31) has the same box, a button per format beside it, then the progress and the saved file.
Python 3.9 stdlib only, as macOS's /usr/bin/python3.
"""
import hashlib
import json
import os
import re
import shutil
import signal
import subprocess
import sys
import time
from urllib.parse import quote, urlparse

DOWNLOADS = os.path.expanduser("~/Downloads")
TOOL_DIRS = ["/opt/homebrew/bin", "/usr/local/bin"]
SITES = {"youtube.com": "YouTube", "youtu.be": "YouTube", "x.com": "X", "twitter.com": "X", "twitch.tv": "Twitch"}
PROBE_WAIT = 1.2  # of the list's 2 s, how long the first ask waits for a probe it started
PROBE_STALE = 60  # a probe still pending after this long is started again
MP3_BYTES_PER_SECOND = 320000 // 8

# Each format: its row, what yt-dlp is asked for, and the kind of size the probe reads for it.
FORMATS = [
    {"id": "best", "title": "Video · best", "icon": "🎬", "words": "MP4 · H.264 + AAC",
     "args": ["-f", "bv*[vcodec^=avc1]+ba[ext=m4a]/b[ext=mp4]/bv*+ba/b", "--merge-output-format", "mp4"]},
    {"id": "720", "title": "Video · 720p", "icon": "🎞️", "words": "MP4 · smaller file",
     "args": ["-f", "bv*[vcodec^=avc1][height<=720]+ba[ext=m4a]/b[ext=mp4][height<=720]/bv*[height<=720]+ba/b[height<=720]/b",
              "--merge-output-format", "mp4"]},
    {"id": "m4a", "title": "Audio · M4A", "icon": "🎧", "words": "Best audio · no re-encode",
     "args": ["-f", "ba[ext=m4a]/ba/b", "-x", "--audio-format", "m4a"]},
    {"id": "mp3", "title": "Audio · MP3", "icon": "🎵", "words": "320 kbps · ffmpeg converts",
     "args": ["-f", "ba/b", "-x", "--audio-format", "mp3", "--audio-quality", "320K"]},
]
FORMAT = {f["id"]: f for f in FORMATS}
# What yt-dlp prints as a step after the download, as the page and list say it.
STEPS = {"[Merger]": "Joining video and audio", "[ExtractAudio]": "Saving the audio", "[VideoRemuxer]": "Finishing",
         "[FixupM3u8]": "Finishing", "[FixupM4a]": "Finishing"}
PROGRESS = "download:PILOT %(progress.downloaded_bytes)s %(progress.total_bytes)s %(progress.total_bytes_estimate)s " \
           "%(progress.speed)s %(progress.eta)s %(info.format_id)s"


def send(message):
    sys.stdout.write(json.dumps(message, ensure_ascii=False) + "\n")
    sys.stdout.flush()


# MARK: Files

def read_json(path):
    try:
        with open(path, encoding="utf-8") as f:
            value = json.load(f)
        return value if isinstance(value, dict) else {}
    except (OSError, ValueError):
        return {}


def write_json(path, value):
    """Whole or not at all: a reader never sees half a file."""
    os.makedirs(os.path.dirname(path), exist_ok=True)
    temp = "%s.%d.tmp" % (path, os.getpid())
    with open(temp, "w", encoding="utf-8") as f:
        json.dump(value, f, ensure_ascii=False)
    os.replace(temp, path)


class Paths:
    def __init__(self, run):
        paths = run.get("paths") or {}
        self.data = paths.get("data") or os.path.expanduser("~/.cache/pilot-video-downloader")
        self.cache = paths.get("cache") or self.data
        self.job = os.path.join(self.data, "job.json")
        self.last = os.path.join(self.data, "last.json")
        self.part = os.path.join(self.cache, "part")
        self.saved_to = os.path.join(self.cache, "saved-to.txt")

    def probe(self, url):
        return os.path.join(self.cache, "probe-%s.json" % hashlib.sha1(url.encode("utf-8")).hexdigest()[:16])


# MARK: Tools and links

def tool(name):
    """The tool's path on PATH (Pilot's holds Homebrew's) or in Homebrew's folders; None when missing."""
    path = os.pathsep.join([os.environ.get("PATH", "")] + TOOL_DIRS)
    return shutil.which(name, path=path)


def site(url):
    """YouTube, X or Twitch for a link to one of them; None for anything else."""
    try:
        parsed = urlparse(url)
    except ValueError:
        return None
    if parsed.scheme not in ("http", "https"):
        return None
    host = (parsed.hostname or "").lower()
    for domain, name in SITES.items():
        if host == domain or host.endswith("." + domain):
            return name
    return None


def link(run):
    """(the link, where it came from): the search when it is a link, else the clipboard; (None, None) when neither."""
    query = (run.get("query") or run.get("input") or "").strip()
    if site(query):
        return query, "From search"
    try:
        copied = subprocess.run(["pbpaste"], capture_output=True, text=True, timeout=1).stdout.strip()
    except (OSError, subprocess.SubprocessError):
        copied = ""
    if site(copied) and "\n" not in copied:
        return copied, "From clipboard"
    return None, None


def short(url):
    parsed = urlparse(url)
    text = (parsed.hostname or "").replace("www.", "") + parsed.path + ("?" + parsed.query if parsed.query else "")
    return text if len(text) <= 60 else text[:59] + "…"


def megabytes(size):
    if not size:
        return None
    return "%.1f GB" % (size / 1e9) if size >= 1e9 else "%d MB" % max(1, round(size / 1e6))


def rate(bytes_per_second):
    return "%.1f MB/s" % (bytes_per_second / 1e6)


def clock(seconds):
    seconds = int(seconds or 0)
    hours, rest = divmod(seconds, 3600)
    return "%d:%02d:%02d" % (hours, rest // 60, rest % 60) if hours else "%d:%02d" % (rest // 60, rest % 60)


# MARK: Detached work

def detach(work):
    """Runs `work()` in a grandchild in its own session, its stdio on /dev/null, so Pilot's answer ends now and its stop
    of this command's process tree never reaches it. Returns in the caller once the grandchild is on its own."""
    sys.stdout.flush()
    first = os.fork()
    if first:
        os.waitpid(first, 0)
        return
    os.setsid()
    if os.fork():
        os._exit(0)
    null = os.open(os.devnull, os.O_RDWR)
    for fd in (0, 1, 2):
        os.dup2(null, fd)
    code = 0
    try:
        work()
    except Exception:  # nowhere to say it: the job file says what it could
        code = 1
    os._exit(code)


def alive(job):
    """Whether the job's worker is still this extension's process (a pid reused since is not)."""
    pid = job.get("pid")
    if job.get("status") != "running" or not isinstance(pid, int):
        return False
    try:
        os.kill(pid, 0)
        command = subprocess.run(["/bin/ps", "-p", str(pid), "-o", "command="], capture_output=True, text=True, timeout=1).stdout
    except (OSError, subprocess.SubprocessError):
        return False
    return os.path.join(os.path.basename(os.path.dirname(os.path.abspath(__file__))), "main.py") in command


def probe(paths, url):
    """The probe of `url` when it is done, starting one when none is; waits a moment for a new one. None while it runs."""
    path = paths.probe(url)
    found = read_json(path)
    if found and not found.get("pending"):
        return found
    if found.get("pending") and time.time() - found.get("started", 0) < PROBE_STALE:
        return None
    write_json(path, {"pending": True, "started": time.time()})
    detach(lambda: write_json(path, read_link(url)))
    deadline = time.time() + PROBE_WAIT
    while time.time() < deadline:
        time.sleep(0.1)
        found = read_json(path)
        if found and not found.get("pending"):
            return found
    return None


def read_link(url):
    """The title, length and each format's size of `url`, from yt-dlp's format list; an error when it has no video."""
    try:
        done = subprocess.run([tool("yt-dlp"), "-J", "--no-playlist", "--no-warnings", url], capture_output=True, text=True,
                              timeout=60)
    except (OSError, TypeError, subprocess.SubprocessError) as e:
        return {"error": "yt-dlp did not answer (%s)" % e.__class__.__name__}
    if done.returncode != 0:
        lines = [l for l in done.stderr.splitlines() if l.startswith("ERROR")]
        return {"error": (lines[-1][7:] if lines else "yt-dlp could not read this link").strip()[:200]}
    try:
        info = json.loads(done.stdout)
    except ValueError:
        return {"error": "yt-dlp's answer did not read"}
    return {"title": info.get("title") or "", "sizes": sizes(info)}


def sizes(info):
    """Each format's size in bytes as yt-dlp would pick it, roughly; a size no format states is left out."""
    duration = info.get("duration") or 0
    formats = info.get("formats") or []

    def size(f):
        return f.get("filesize") or f.get("filesize_approx") or (f.get("tbr") or 0) * duration * 125 or 0

    def best(pick):
        found = [f for f in formats if pick(f)]
        return max(found, key=lambda f: (f.get("height") or 0, f.get("tbr") or 0)) if found else None

    def video_only(f):
        return f.get("acodec") == "none" and str(f.get("vcodec") or "").startswith("avc1")

    audio = best(lambda f: f.get("vcodec") == "none" and f.get("ext") == "m4a")

    def video(height):
        fits = lambda f: (f.get("height") or 0) <= height
        picked = best(lambda f: video_only(f) and fits(f))
        if picked and audio:
            return size(picked) + size(audio), picked.get("height")
        picked = best(lambda f: f.get("ext") == "mp4" and f.get("vcodec") not in (None, "none")
                      and f.get("acodec") not in (None, "none") and fits(f))
        return (size(picked), picked.get("height")) if picked else (0, None)

    out = {}
    for key, height in (("best", 10 ** 5), ("720", 720)):
        bytes_, h = video(height)
        if bytes_:
            out[key] = bytes_
        if h:
            out[key + "-height"] = h
    if audio and size(audio):
        out["m4a"] = size(audio)
    if duration:
        out["mp3"] = duration * MP3_BYTES_PER_SECOND
    return out


def download(paths, job):
    """The worker: runs yt-dlp, writes its progress to the job file, says how it ended in a HUD. Cancel's SIGTERM stops
    yt-dlp and its ffmpeg, then deletes the part folder."""
    job.update(pid=os.getpid(), status="running", started=time.time(), percent=0, step=None)
    write_json(paths.job, job)
    shutil.rmtree(paths.part, ignore_errors=True)
    os.makedirs(paths.part, exist_ok=True)
    if os.path.exists(paths.saved_to):
        os.remove(paths.saved_to)
    args = [tool("yt-dlp"), "--no-playlist", "--newline", "--no-mtime", "--progress-template", PROGRESS,
            "-P", paths.part, "-o", "%(title).180B.%(ext)s",
            "--print-to-file", "after_move:filepath", paths.saved_to]
    ffmpeg = tool("ffmpeg")
    if ffmpeg:
        args += ["--ffmpeg-location", ffmpeg]
    process = subprocess.Popen(args + FORMAT[job["format"]]["args"] + ["--", job["url"]], stdout=subprocess.PIPE,
                               stderr=subprocess.STDOUT, stdin=subprocess.DEVNULL, text=True, errors="replace",
                               start_new_session=True)

    def cancel(*_):
        try:
            os.killpg(process.pid, signal.SIGTERM)
            process.wait(timeout=3)
        except (OSError, subprocess.TimeoutExpired):
            try:
                os.killpg(process.pid, signal.SIGKILL)
            except OSError:
                pass
        shutil.rmtree(paths.part, ignore_errors=True)
        job.update(status="cancelled", pid=None)
        write_json(paths.job, job)
        os._exit(0)

    signal.signal(signal.SIGTERM, cancel)
    base, current, part_total, error, written = 0, None, 0, None, 0.0
    for line in process.stdout:
        line = line.strip()
        if line.startswith("PILOT "):
            fields = (line.split(" ") + ["NA"] * 7)[1:7]
            got, total, estimate, speed, eta, format_id = [None if v in ("NA", "None") else v for v in fields]
            if format_id != current:  # the next part (the audio after the video): what came before is done
                base, current = base + part_total, format_id
            part_total = number(total) or number(estimate) or part_total
            done = base + (number(got) or 0)
            whole = max(job.get("size") or 0, base + part_total)
            job.update(done=done, total=whole, speed=number(speed), eta=number(eta), step=None,
                       percent=min(99, int(done * 100 / whole)) if whole else 0)
        elif line.startswith("ERROR:"):
            error = line[6:].strip()
        else:
            step = next((words for tag, words in STEPS.items() if line.startswith(tag)), None)
            if step:
                job.update(step=step, percent=99, eta=None, speed=None)
        if time.time() - written > 0.5:
            write_json(paths.job, job)
            written = time.time()
    process.wait()
    saved = keep(read_saved(paths)) if process.returncode == 0 else None
    shutil.rmtree(paths.part, ignore_errors=True)
    took = time.time() - job["started"]
    if saved:
        job.update(status="saved", pid=None, path=saved, percent=100, took=took,
                   size=os.path.getsize(saved) if os.path.exists(saved) else job.get("done"))
        words = "Saved %s" % os.path.basename(saved)
    else:
        job.update(status="failed", pid=None, error=error or "yt-dlp stopped (code %s)" % process.returncode)
        words = "Download failed: %s" % job["error"]
    write_json(paths.job, job)
    alert(words)


def keep(made):
    """Moves the file yt-dlp made into ~/Downloads, " 2", " 3"… before its extension when the name is taken, never over a
    file; its new path, or None when there is none to move."""
    if not made or not os.path.isfile(made):
        return None
    os.makedirs(DOWNLOADS, exist_ok=True)
    stem, ext = os.path.splitext(os.path.basename(made))
    for n in range(1, 1000):
        target = os.path.join(DOWNLOADS, stem + ext if n == 1 else "%s %d%s" % (stem, n, ext))
        try:
            os.link(made, target)  # fails on a taken name, so no file is ever replaced
        except FileExistsError:
            continue
        except OSError:  # another volume: copy into a name made new
            try:
                with open(made, "rb") as source, open(target, "xb") as copy:
                    shutil.copyfileobj(source, copy)
            except FileExistsError:
                continue
        os.remove(made)
        return target
    return None


def number(value):
    try:
        return float(value) if value is not None else None
    except ValueError:
        return None


def read_saved(paths):
    try:
        with open(paths.saved_to, encoding="utf-8") as f:
            lines = [l.strip() for l in f if l.strip()]
        return lines[-1] if lines else None
    except OSError:
        return None


def alert(text):
    """Pilot's HUD, through the link it keeps for scripts; behind the front app, never stealing focus."""
    subprocess.run(["open", "-g", "pilot://alert?text=" + quote(text[:200])], timeout=10)


# MARK: Rows

def run_action(command, title, context=None, **fields):
    action = {"type": "run", "command": command, "title": title}
    if context is not None:
        action["context"] = context
    action.update(fields)
    return action


def saved_actions(path, first):
    """Reveal, Open and Copy file, `first` of them Return's, each also on its key."""
    actions = {"reveal": run_action("reveal", "Reveal in Finder", {"path": path}),
               "open": {"type": "open", "url": path, "title": "Open", "key": "cmd+o"},
               "copy": run_action("copy-file", "Copy file", {"path": path}, key="cmd+shift+c")}
    return [actions[first]] + [a for k, a in actions.items() if k != first]


def install_rows():
    """One row when yt-dlp or ffmpeg is missing: Pilot's Install asks first, then brew runs in a terminal. Install takes
    one package a link, so with both missing it is yt-dlp now and ffmpeg on the next open. Without Homebrew it opens
    brew.sh. None when both are there."""
    missing = [name for name in ("yt-dlp", "ffmpeg") if not tool(name)]
    if not missing:
        return []
    if not tool("brew"):
        return [{"id": "homebrew", "title": "Install Homebrew first", "icon": "🍺",
                 "subtitle": "Video downloader installs %s through it" % " and ".join(missing),
                 "actions": [{"type": "open", "url": "https://brew.sh", "title": "Open brew.sh"}]}]
    name = missing[0]
    then = " · then ffmpeg" if len(missing) > 1 else ""
    return [{"id": "install", "title": "Install %s" % name, "icon": "📦", "subtitle": "brew install %s%s" % (name, then),
             "actions": [{"type": "open", "url": "pilot://install?package=formula:" + name, "title": "Install %s" % name}]}]


def progress_words(job):
    if job.get("step"):
        return job["step"]
    parts = []
    if job.get("done"):
        parts.append("%s of %s" % (megabytes(job["done"]), megabytes(job.get("total")) or "?"))
    if job.get("speed"):
        parts.append(rate(job["speed"]))
    if job.get("eta") is not None:
        parts.append("%s left" % clock(job["eta"]))
    return " · ".join(parts) or "Starting"


def running_rows(job):
    head = "Downloading · %s" % job.get("format_title", "")
    return [{"id": "progress", "section": head, "title": "%d %% · %s" % (job.get("percent", 0), job.get("title") or job["url"]),
             "subtitle": progress_words(job), "icon": "⏳",
             "actions": [run_action("refresh", "Refresh", stay=True),
                         {"type": "open", "url": "pilot://open?tab=page&extension=video-downloader", "title": "Show progress",
                          "key": "cmd+o"},
                         run_action("cancel", "Cancel · deletes the part file", destructive=True, key="cmd+delete")]}]


def saved_rows(job):
    path = job["path"]
    head = "Saved · %s · ~/Downloads · %s" % (megabytes(job.get("size")) or "", clock(job.get("took")))
    rows = []
    for key, title, icon, words in (("reveal", "Reveal in Finder", "📂", os.path.basename(path)),
                                    ("open", "Open", "▶️", None),
                                    ("copy", "Copy file", "📋", "To paste into a chat")):
        row = {"id": "saved-" + key, "section": head, "title": title, "icon": icon, "actions": saved_actions(path, key)}
        if words:
            row["subtitle"] = words
        rows.append(row)
    return rows


def format_rows(url, source, found, last):
    """The four formats under the link's heading, the last one used first; sizes once the probe has them."""
    found = found or {}
    title = found.get("title")
    head = "%s · %s · %s" % (source, site(url), title or short(url))
    sizes_ = found.get("sizes") or {}
    rows = []
    if found.get("error"):
        rows.append({"id": "error", "section": head, "title": "yt-dlp could not read this link", "icon": "⚠️",
                     "subtitle": found["error"], "actions": [run_action("refresh", "Try again", stay=True)]})
    order = sorted(FORMATS, key=lambda f: f["id"] != last)
    for f in order:
        words = f["words"]
        height = sizes_.get(f["id"] + "-height")
        if height and f["id"] == "best":
            words = "MP4 · %dp · H.264 + AAC" % height
        size = megabytes(sizes_.get(f["id"]))
        subtitle = words if found else words + " · reading size…"
        row = {"id": f["id"], "section": head, "title": f["title"], "icon": f["icon"], "subtitle": subtitle,
               "keywords": "%s %s" % (f["id"], "video" if f["id"] in ("best", "720") else "audio"),
               "actions": [run_action("download", "Download", {"url": url, "format": f["id"], "title": title or ""})]}
        if size:
            row["accessory"] = size
        rows.append(row)
    return rows


def matches(row, query):
    words = query.lower().split()
    text = " ".join([row["title"], row.get("subtitle", ""), row.get("keywords", "")]).lower()
    return all(w in text for w in words)


def formats(run, paths):
    rows = install_rows()
    if rows:
        return send({"type": "list", "items": rows})
    job = read_json(paths.job)
    if alive(job):
        return send({"type": "list", "items": running_rows(job)})
    url, source = link(run)
    query = (run.get("query") or "").strip()
    saved = job.get("status") == "saved" and job.get("path") and url in (None, job.get("url"))
    rows = saved_rows(job) if saved else []
    if url:
        last = read_json(paths.last).get("format")
        rows += format_rows(url, source, probe(paths, url), last)
        if job.get("status") == "failed" and job.get("url") == url:
            rows.insert(0, {"id": "failed", "section": rows[0]["section"], "title": "The last try failed", "icon": "⚠️",
                            "subtitle": job.get("error", ""),
                            "actions": [run_action("download", "Try again", {"url": url, "format": job["format"],
                                                                             "title": job.get("title", "")})]})
    elif not saved:
        rows = [{"id": "none", "title": "Copy a YouTube, X or Twitch link", "icon": "📥",
                 "subtitle": "Then open Video downloader again, or paste the link here",
                 "actions": [{"type": "hud", "text": "Copy a YouTube, X or Twitch link first", "title": "OK"}]}]
    if query and not site(query):
        rows = [r for r in rows if matches(r, query)]
    send({"type": "list", "items": rows})


# MARK: Commands

def start(run, paths):
    context = run.get("context") or {}
    url = context.get("url") or (run.get("input") or "").strip()  # the popover's box: a pasted link
    chosen = context.get("format") or read_json(paths.last).get("format") or "best"
    if not site(url or "") or chosen not in FORMAT:
        return send({"type": "error", "text": "needs a YouTube, X or Twitch link" if not site(url or "")
                     else "has no format %s" % chosen})
    if not tool("yt-dlp"):
        return send({"type": "error", "text": "needs yt-dlp: open Video downloader to install it"})
    job = read_json(paths.job)
    if alive(job):
        return send({"type": "hud", "text": "Already downloading %s" % (job.get("title") or short(job["url"]))})
    write_json(paths.last, {"format": chosen})
    found = read_json(paths.probe(url))
    job = {"url": url, "format": chosen, "format_title": FORMAT[chosen]["title"], "title": context.get("title") or "",
           "size": (found.get("sizes") or {}).get(chosen)}
    send({"type": "hud", "text": "Downloading %s" % (job["title"] or short(url))})
    detach(lambda: download(paths, job))


def cancel(paths):
    job = read_json(paths.job)
    if not alive(job):
        return send({"type": "hud", "text": "Nothing is downloading"})
    os.kill(job["pid"], signal.SIGTERM)
    send({"type": "hud", "text": "Cancelled %s" % (job.get("title") or short(job["url"]))})


def saved_path(run):
    """The context's path when it is a file in ~/Downloads, the only place this extension saves."""
    path = (run.get("context") or {}).get("path") or ""
    real = os.path.realpath(path)
    return real if real.startswith(os.path.realpath(DOWNLOADS) + os.sep) and os.path.isfile(real) else None


def reveal(run):
    path = saved_path(run)
    if not path:
        return send({"type": "error", "text": "the saved file is gone from Downloads"})
    subprocess.run(["open", "-R", path], timeout=10)


def copy_file(run):
    path = saved_path(run)
    if not path:
        return send({"type": "error", "text": "the saved file is gone from Downloads"})
    script = ["-e", "on run argv", "-e", "set the clipboard to (POSIX file (item 1 of argv))", "-e", "end run"]
    done = subprocess.run(["osascript"] + script + [path], capture_output=True, timeout=10)
    if done.returncode:
        return send({"type": "error", "text": "could not put the file on the clipboard"})
    send({"type": "hud", "text": "Copied %s" % os.path.basename(path)})


def running_blocks(run, job):
    """A download's progress and Cancel, for the page and the bar's popover."""
    drawn = set((((run.get("pilot") or {}).get("blocks")) or "").split(","))
    name = "%s · %s" % (job.get("title") or short(job["url"]), job.get("format_title", ""))
    items = [{"label": "Done", "value": megabytes(job.get("done")) or "–"},
             {"label": "Speed", "value": rate(job["speed"]) if job.get("speed") else "–"},
             {"label": "Left", "value": clock(job["eta"]) if job.get("eta") is not None else "–"}]
    if "hero" in drawn:
        reading = {"type": "hero", "value": job.get("percent", 0), "unit": "%", "place": job.get("step") or name,
                   "items": items}
    else:
        reading = {"type": "meter", "label": job.get("step") or "Downloading", "percent": job.get("percent", 0),
                   "note": name}
    return [reading, {"type": "buttons", "actions": [run_action("cancel", "Cancel", destructive=True)]}]


def saved_block(job):
    row = {"id": "saved", "title": os.path.basename(job["path"]), "icon": "🎬",
           "subtitle": "%s · ~/Downloads · %s" % (megabytes(job.get("size")) or "", clock(job.get("took"))),
           "actions": saved_actions(job["path"], "reveal")}
    return {"type": "list", "title": "Saved", "items": [row]}


def page_box(last):
    """The page's box (Sven, 2026-10-31): a pasted link, then a format's button, the last one used first and on Return. An
    older Pilot ignores `actions` and draws the box with its arrow, Return saving in the last format."""
    order = sorted(FORMATS, key=lambda f: f["id"] != last)
    runs = [run_action("download", f["title"], {"format": f["id"]}) for f in order]
    return {"type": "section", "title": "Download", "subtitle": "YouTube, X or Twitch · saved to ~/Downloads", "blocks": [
        {"type": "input", "placeholder": "Paste a YouTube, X or Twitch link", "action": runs[0], "actions": runs[1:]}]}


def page(run, paths):
    """The page: a download's progress, asked every 2 s while it runs; else what is missing, or the box to paste a link
    into and pick a format, over the last saved file or why the last try failed."""
    job = read_json(paths.job)
    if alive(job):
        return send({"type": "blocks", "refresh": 2, "blocks": running_blocks(run, job)})
    rows = install_rows()
    if rows:
        return send({"type": "blocks", "blocks": [{"type": "list", "title": "Video downloader needs", "items": rows}]})
    last = read_json(paths.last).get("format")
    blocks = [page_box(last if last in FORMAT else "best")]
    if job.get("status") == "saved" and job.get("path"):
        blocks.append(saved_block(job))
    elif job.get("status") == "failed":
        blocks.append({"type": "markdown", "text": "The last download failed: %s" % job.get("error", "")})
    send({"type": "blocks", "blocks": blocks})


def paste_box(last):
    """The popover's box: a pasted link, Return saving it in the last format used, Option+Return as the other kind."""
    other = "mp3" if last in ("best", "720") else "best"
    return {"type": "input", "placeholder": "Paste a link · ⏎ %s · ⌥⏎ %s" % (FORMAT[last]["title"], FORMAT[other]["title"]),
            "action": run_action("download", "Download"), "alt": run_action("download", FORMAT[other]["title"],
                                                                            {"format": other})}


def bar(run, paths):
    """The bar line (disk only: 📥, the percent while a download runs) and, on a click, its popover: the download's
    progress every 2 s, else what is installed, the copied link's formats, the paste box and the last saved file."""
    job = read_json(paths.job)
    running = alive(job)
    if run.get("surface") != "popover":
        if running:
            return send({"type": "bar", "text": "📥 %d%%" % job.get("percent", 0), "blocks": running_blocks(run, job)})
        line = {"type": "bar", "text": "📥", "blocks": [{"type": "markdown", "text":
                "Click to paste a link, or download the copied one."}]}
        if job.get("status") == "failed":
            line.update(tone="warn", blocks=[{"type": "markdown", "text": "Last download failed: %s" % job.get("error", "")}])
        return send(line)
    if running:
        return send({"type": "blocks", "refresh": 2, "blocks": running_blocks(run, job)})
    rows = install_rows()
    if rows:
        return send({"type": "blocks", "blocks": [{"type": "list", "title": "Video downloader needs", "items": rows}]})
    last = read_json(paths.last).get("format")
    last = last if last in FORMAT else "best"
    blocks, waiting = [], False
    url, _ = link({})
    if url:
        found = probe(paths, url)
        waiting = found is None
        rows = format_rows(url, "Copied", found, last)
        blocks.append({"type": "list", "title": rows[0]["section"],
                       "items": [dict((k, v) for k, v in r.items() if k != "section") for r in rows]})
    blocks.append(paste_box(last))
    if job.get("status") == "failed":
        blocks.append({"type": "markdown", "text": "Last download failed: %s" % job.get("error", "")})
    elif job.get("status") == "saved" and job.get("path"):
        blocks.append(saved_block(job))
    answer = {"type": "blocks", "blocks": blocks}
    if waiting:
        answer["refresh"] = 2  # the copied link's sizes are on their way
    send(answer)


def main():
    try:
        run = json.loads(sys.stdin.readline())
    except ValueError:
        send({"type": "error", "text": "got a run message it could not read"})
        return
    paths = Paths(run)
    command = run.get("command")
    if command == "formats":
        formats(run, paths)
    elif command == "download":
        start(run, paths)
    elif command == "cancel":
        cancel(paths)
    elif command == "refresh":
        pass  # a `stay` run: Pilot asks the list again
    elif command == "reveal":
        reveal(run)
    elif command == "copy-file":
        copy_file(run)
    elif command == "page":
        page(run, paths)
    elif command == "bar":
        bar(run, paths)
    else:
        send({"type": "error", "text": "has no command %s" % command})


if __name__ == "__main__":
    main()
