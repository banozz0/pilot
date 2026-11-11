#!/usr/bin/env python3
"""Now playing for Pilot: whatever the Mac is playing, as Control Center's Now Playing shows it (Music, Spotify, a
YouTube tab in Chrome, Safari or Zen, any app that tells macOS), as a menu-bar item ("♫ Artist – Title", a lone ♫ while
paused, nothing when nothing has played), its popover with the track, a progress meter and play or pause, previous and
next (Surfaces v2, Pilot story 165), the same on its page with Show beside them, and the same controls in Hyper+Space.

macOS keeps Now Playing in its MediaRemote framework, private and since macOS 15.4 closed to apps Apple did not sign;
osascript is Apple's, so a JavaScript for Automation script run by it reads MRNowPlayingRequest and sends
MRMediaRemoteSendCommand (2 play or pause, 4 next, 5 previous). No Apple events, so no Automation prompt, and no player
is ever started. Should a macOS update close that door, the item says so with a warn ♫ rather than vanishing.

Favourite is the one thing Now Playing can't do: it shows only while Music plays, and asks Music itself (its favorited
track property, «class pLov»), which raises macOS's Automation prompt once. A Spotify track carries its link instead.

The popover's track is a row: its artwork with the title and the artist beside it; a click goes to what plays. The
artwork is Now Playing's own when a player hands it over (macOS lists most players' artwork without its bytes), else
asked of its source once a track: Music's own artwork (the same Automation prompt as Favourite), Spotify's cover
(Spotify asks once, then i.scdn.co), a YouTube tab's video thumbnail (the tab's address from the browser, the same
prompt as going to the tab, then i.ytimg.com). Either is shrunk by macOS's sips to the thumbnail Pilot draws. In
Chrome, its kin (Brave, Edge, Vivaldi) and Safari that is the tab whose title holds the track's, asked of the browser
itself (macOS asks once whether Pilot may control it); anywhere else, the app.
"""
import base64
import hashlib
import json
import os
import re
import shutil
import subprocess
import sys
import time

BUDGET = {"bar": 1.4, "detail": 1.4, "popover": 4.0, "control": 20.0}  # seconds; Pilot's limits 2, 2, 5 and 30, less
# Python's start (macOS's 3.9 takes a few tenths) and the answer
SETTLE = 0.4  # a player's new track shows this long after a control
REFRESH = {"playing": 5, "idle": 15}  # an open popover asks again; the bar is Pilot's 60 s
GLYPH = "♫"
BAR_ROOM = 24 - 2  # Pilot's bar text is 24 characters; "♫ " takes two
MUSIC = "com.apple.Music"
SPOTIFY = "com.spotify.client"
COMMANDS = {"playpause": 2, "next": 4, "previous": 5}  # MediaRemote's MRMediaRemoteCommand
VERBS = {"playpause": "play or pause", "next": "skip", "previous": "go back to", "favourite": "favourite"}
THUMB = 64  # the artwork's longest side in pixels: Pilot draws it at 28 points, twice that on a Retina screen
LARGEST_THUMB = 64 * 1024  # Pilot keeps a row's picture up to 64 KB
CURL_TIMEOUT = 3
# The hosts artwork is fetched from, and a YouTube address's video id (watch, shorts, live, youtu.be, music.youtube.com).
ART_HOSTS = ("https://i.scdn.co/", "https://i.ytimg.com/")
YOUTUBE = re.compile(r"^https://(?:(?:www|m|music)\.)?(?:youtube\.com/(?:watch\?(?:[^#]*&)?v=|shorts/|live/)|youtu\.be/)([A-Za-z0-9_-]{11})")
# A bar title without what only clutters it (Raycast's Spotify Player cleans the same way): (feat. …), […], remasters.
CLUTTER = re.compile(r"\s*(\((feat|ft|with)\.?\s[^)]*\)|\[[^\]]*\]|\([^)]*remaster[^)]*\)|\s-\s[^-]*remaster.*$)", re.I)

# The read, after an optional command (argv[1], then SETTLE s for the player to move): one JSON object, {} when nothing
# has played, {"error"} when Now Playing can't be read. argv[0], when not empty, is a folder for the artwork: its file is
# art-<a hash of the track>.img, written only when missing, and named in the answer's `artwork`.
NOW_PLAYING = '''function run(argv) {
	ObjC.import('Foundation');
	if (!$.NSBundle.bundleWithPath('/System/Library/PrivateFrameworks/MediaRemote.framework/').load)
		return JSON.stringify({error: 'MediaRemote did not load'});
	const request = $.NSClassFromString('MRNowPlayingRequest');
	if (!request || request.isNil()) return JSON.stringify({error: 'no MRNowPlayingRequest'});
	if (argv.length > 1) {
		ObjC.bindFunction('MRMediaRemoteSendCommand', ['bool', ['int', 'id']]);
		$.MRMediaRemoteSendCommand(Number(argv[1]), $());
		delay(%s);
	}
	const item = request.localNowPlayingItem;
	const info = item.isNil() ? item : item.nowPlayingInfo;
	if (info.isNil()) return JSON.stringify({});
	const field = name => {
		const value = info.valueForKey('kMRMediaRemoteNowPlayingInfo' + name);
		return value.isNil() ? null : value;
	};
	const stamp = field('Timestamp');
	const found = {playing: request.localIsPlaying, now: $.NSDate.date.timeIntervalSince1970,
		stamp: stamp ? stamp.timeIntervalSince1970 : null};
	['Title', 'Artist', 'Album', 'Duration', 'ElapsedTime', 'PlaybackRate', 'ContentItemIdentifier'].forEach(name => {
		const value = field(name);
		found[name] = value ? ObjC.unwrap(value) : null;
	});
	try {
		const client = request.localNowPlayingPlayerPath.client;
		found.app = ObjC.unwrap(client.displayName);
		found.bundle = ObjC.unwrap(client.bundleIdentifier);
	} catch (e) {}
	const art = field('ArtworkData');
	if (argv[0] && art) {
		let hash = 5381;
		const key = [found.Title, found.Artist, found.Album, found.bundle, art.length].join('|');
		for (let i = 0; i < key.length; i++) hash = (hash * 33 + key.charCodeAt(i)) >>> 0;
		const name = 'art-' + hash.toString(16) + '.img';
		const path = argv[0] + '/' + name;
		if (!$.NSFileManager.defaultManager.fileExistsAtPath(path)) art.writeToFileAtomically(path, true);
		found.artwork = name;
	}
	return JSON.stringify(found);
}''' % SETTLE

FAVOURITE = '''if application "Music" is running then
	tell application "Music"
		set f to not («class pLov» of current track)
		set «class pLov» of current track to f
		return («class pLov» of current track) as text
	end tell
end if'''


def send(message):
    sys.stdout.write(json.dumps(message, ensure_ascii=False) + "\n")


class Trouble(Exception):
    """osascript did not answer: `why` is denied (macOS said no), slow (a prompt waits, or it hung), failed, or closed
    (Now Playing can't be read)."""

    def __init__(self, why):
        Exception.__init__(self, why)
        self.why = why


def osascript(args, deadline):
    binary = shutil.which("osascript") or "/usr/bin/osascript"
    left = deadline - time.monotonic()
    if left < 0.2:
        raise Trouble("slow")
    try:
        done = subprocess.run([binary] + args, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                              timeout=left)
    except subprocess.TimeoutExpired:
        raise Trouble("slow")
    except OSError:
        raise Trouble("failed")
    if done.returncode != 0:
        raise Trouble("denied" if b"-1743" in done.stderr else "failed")
    return done.stdout.decode("utf-8", "replace").strip()


def text(value):
    return value.strip() if isinstance(value, str) else ""


def seconds(value):
    return max(float(value), 0.0) if isinstance(value, (int, float)) and not isinstance(value, bool) else None


def now_playing(deadline, command=None, art=""):
    """What the Mac plays as a dict (app, bundle, playing, title, artist, album, duration and position in seconds or
    None, item, its artwork's file in `art` or None), or None when nothing has played; `command`, one of COMMANDS, is
    sent first."""
    args = ["-l", "JavaScript", "-e", NOW_PLAYING, art] + ([str(COMMANDS[command])] if command else [])
    try:
        found = json.loads(osascript(args, deadline) or "{}")
    except ValueError:
        raise Trouble("failed")
    if not isinstance(found, dict):
        raise Trouble("failed")
    if found.get("error"):
        raise Trouble("closed")
    title, playing = text(found.get("Title")), found.get("playing") is True
    if not title and not playing:
        return None
    duration, elapsed = seconds(found.get("Duration")), seconds(found.get("ElapsedTime")) or 0.0
    stamp, now = seconds(found.get("stamp")), seconds(found.get("now"))
    if playing and stamp and now:
        rate = seconds(found.get("PlaybackRate")) or 1.0  # Now Playing's elapsed time is as of its stamp
        elapsed += (now - stamp) * rate
    if duration:
        elapsed = min(elapsed, duration)
    return {"app": text(found.get("app")) or "Now Playing", "bundle": text(found.get("bundle")), "playing": playing,
            "title": title, "artist": text(found.get("Artist")), "album": text(found.get("Album")),
            "duration": int(duration) if duration else None, "position": int(elapsed),
            "item": text(found.get("ContentItemIdentifier")),
            "artwork": os.path.join(art, os.path.basename(found["artwork"])) if art and text(found.get("artwork")) else None}


# Music's artwork: the current track's first, its bytes written by osascript itself to the path given; "none" without one.
MUSIC_ART = '''on run argv
	if not (application "Music" is running) then return "none"
	tell application "Music"
		if (count of artworks of current track) is 0 then return "none"
		set picture to raw data of artwork 1 of current track
	end tell
	set f to open for access (POSIX file (item 1 of argv)) with write permission
	set eof f to 0
	write picture to f
	close access f
	return "ok"
end run'''
SPOTIFY_ART = '''if application "Spotify" is running then
	tell application "Spotify" to return artwork url of current track
end if
return ""'''


def art_key(track):
    return hashlib.sha1("|".join((track["title"], track["artist"], track["album"], track["bundle"])).encode("utf-8")).hexdigest()[:12]


def download(url, path, deadline):
    """Fetches an artwork URL (only from ART_HOSTS) to `path`; whether it came."""
    if not url.startswith(ART_HOSTS):
        return False
    binary = shutil.which("curl") or "/usr/bin/curl"
    left = min(CURL_TIMEOUT, deadline - time.monotonic())
    if left < 0.2:
        return False
    try:
        done = subprocess.run([binary, "-sS", "--fail", "--max-time", "%.1f" % left, "-o", path, url], stdin=subprocess.DEVNULL,
                              stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=left + 1)
    except (OSError, subprocess.TimeoutExpired):
        return False
    return done.returncode == 0 and os.path.isfile(path)


def ask_source(track, path, deadline):
    """Asks what plays for its artwork, written to `path`: True when written, False when it has none (or may not be
    asked), None when it did not answer in time (asked again next time)."""
    try:
        if track["bundle"] == MUSIC:
            return osascript(["-e", MUSIC_ART, path], deadline) == "ok"
        if track["bundle"] == SPOTIFY:
            return download(osascript(["-e", SPOTIFY_ART], deadline), path, deadline)
        if track["bundle"] in TAB_URLS and track["title"]:
            video = YOUTUBE.match(osascript(["-e", TAB_URLS[track["bundle"]], track["title"]], deadline))
            return bool(video) and download("https://i.ytimg.com/vi/%s/mqdefault.jpg" % video.group(1), path, deadline)
    except Trouble as trouble:
        return None if trouble.why == "slow" else False
    return False


def artwork(track, folder, deadline):
    """The track's thumbnail in base64: from Now Playing's own artwork, else from its source, asked once a track (a
    `.none` file remembers a source with none, so a popover asked every few seconds asks it once); None without."""
    source = track.get("artwork")
    if not source:
        source = os.path.join(folder, "art-%s.img" % art_key(track))
        none = source[:-len(".img")] + ".none"
        if not os.path.isfile(source) and not os.path.isfile(none):
            found = ask_source(track, source, deadline)
            if found is False:
                open(none, "w").close()
    return thumbnail(source, deadline)


def thumbnail(source, deadline):
    """The artwork at `source` as a small JPEG in base64, made once a track by sips beside it (the other tracks' files
    removed); None without artwork, or when sips fails or runs out of time."""
    if not os.path.isfile(source):
        return None
    folder, name = os.path.split(source)
    thumb = os.path.join(folder, name[:-len(".img")] + ".jpg")
    if not os.path.isfile(thumb):
        sips = shutil.which("sips") or "/usr/bin/sips"
        try:
            done = subprocess.run([sips, "-Z", str(THUMB), "-s", "format", "jpeg", source, "--out", thumb],
                                  stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                                  timeout=max(deadline - time.monotonic(), 0.1))
        except (OSError, subprocess.TimeoutExpired):
            return None
        if done.returncode != 0:
            return None
        keep = {name, os.path.basename(thumb)}
        for other in os.listdir(folder):
            if other.startswith("art-") and other not in keep:
                try:
                    os.remove(os.path.join(folder, other))
                except OSError:
                    pass
    try:
        with open(thumb, "rb") as f:
            data = f.read(LARGEST_THUMB + 1)
    except OSError:
        return None
    return base64.b64encode(data).decode("ascii") if data and len(data) <= LARGEST_THUMB else None


# ---- words ----

def clock(value):
    if value is None:
        return "–"
    hours, rest = divmod(value, 3600)
    return "%d:%02d:%02d" % (hours, rest // 60, rest % 60) if hours else "%d:%02d" % (rest // 60, rest % 60)


def fit(words, room):
    return words if len(words) <= room else words[:max(room - 1, 1)].rstrip() + "…"


def bar_text(track, mode):
    """"♫ Artist – Title" playing, the title cleaned, when it fits Pilot's 24 characters, else the title alone; a lone ♫
    paused."""
    if not track["playing"] or mode == "glyph":
        return GLYPH
    title = CLUTTER.sub("", track["title"]).strip() or track["title"] or track["app"]
    both = "%s – %s" % (track["artist"], title)
    if mode == "artist-title" and track["artist"] and track["title"] and len(both) <= BAR_ROOM:
        return "%s %s" % (GLYPH, both)
    return "%s %s" % (GLYPH, fit(title, BAR_ROOM))


def byline(track):
    return " · ".join(p for p in (track["artist"], track["album"]) if p)


def spoken(track):
    """"Title – Artist" for a HUD."""
    return " – ".join(p for p in (track["title"], track["artist"]) if p) or track["app"]


def share_link(track):
    """A Spotify track's spotify:track:ID as the web link anyone can open; None for anything else."""
    match = re.match(r"spotify:track:([A-Za-z0-9]+)\Z", track["item"])
    return "https://open.spotify.com/track/%s" % match.group(1) if match else None


def trouble_words(trouble, app="Music"):
    if trouble.why == "closed":
        return "This macOS doesn't share what's playing with Pilot (Now Playing is closed to it)."
    if trouble.why == "denied":
        return "macOS doesn't let Pilot control %s: allow it in System Settings › Privacy & Security › Automation › Pilot." % app
    if trouble.why == "slow":
        return "Now Playing did not answer in time; if macOS asks whether Pilot may control %s, choose Allow." % app
    return "Now Playing did not answer."


# ---- the views ----

def buttons(track, words=False):
    """Play or pause first, the main press; then previous, next, and Favourite while Music plays (a Spotify track: Copy
    link). The popover's are glyphs, `words` Hyper+Space's Cmd+K titles."""
    playing = track["playing"]
    if words:
        titles = ("Pause" if playing else "Play", "Previous track", "Next track", "Favourite or unfavourite")
    else:
        titles = ("⏸\ufe0e Pause" if playing else "▶\ufe0e Play", "⏮\ufe0e", "⏭\ufe0e", "♡ Favourite")
    commands = ("playpause", "previous", "next") + (("favourite",) if track["bundle"] == MUSIC else ())
    found = [{"type": "run", "command": command, "title": title} for command, title in zip(commands, titles)]
    link = share_link(track)
    if link:
        found.append({"type": "copy", "text": link, "title": "Copy link"})
    return found


def show_action(track):
    return {"type": "run", "command": "show", "title": "Show in %s" % track["app"]}


def track_row(track, image):
    """The track as a row: its artwork (or ♫'s emoji), the title, the artist beside it; a click goes to what plays. No
    badge, so Pilot keeps the artist on the title's line."""
    row = {"id": track["item"] or "track", "title": track["title"] or "Playing", "icon": "🎵",
           "keywords": " ".join(p for p in (track["artist"], track["album"], track["app"]) if p), "actions": [show_action(track)]}
    if track["artist"]:
        row["subtitle"] = track["artist"]
    if image:
        row["image"] = image
    return row


def track_section(track, image=None):
    """Where it plays (Paused beside it while paused) over the track's row, how far in, and the controls."""
    section = {"type": "section", "aside": track["app"]}
    if not track["playing"]:
        section["asideNote"] = "Paused"
    inner = [{"type": "list", "items": [track_row(track, image)]}]
    if track["duration"]:
        inner.append({"type": "meter", "label": clock(track["position"]), "value": "/ %s" % clock(track["duration"]),
                      "percent": round(100.0 * track["position"] / track["duration"], 1)})
    section["blocks"] = inner + [{"type": "buttons", "actions": buttons(track)}]
    return section


def drawable(run, blocks):
    """`blocks` as this Pilot draws them: a note (Q138) is plain markdown where its run message's `pilot.blocks` lacks it."""
    pilot = run.get("pilot")
    listed = [k.strip() for k in str(pilot.get("blocks") or "").split(",")] if isinstance(pilot, dict) else []
    return [b if b["type"] != "note" or "note" in listed else {"type": "markdown", "text": b["text"]} for b in blocks]


def art_folder(run):
    """Pilot's cache folder for the artwork, made on first use; "" without one (no artwork then)."""
    folder = (run.get("paths") or {}).get("cache")
    if not isinstance(folder, str) or not folder:
        return ""
    try:
        os.makedirs(folder, exist_ok=True)
    except OSError:
        return ""
    return folder


def answer(run, budget, art=True):
    """(what plays or None, its blocks, the trouble or None); `art` reads the artwork, which only the popover shows."""
    deadline = time.monotonic() + budget
    folder = art_folder(run) if art else ""
    try:
        track = now_playing(deadline, art=folder)  # Now Playing's own artwork, when a player hands it over
    except Trouble as trouble:
        return None, drawable(run, [{"type": "note", "text": trouble_words(trouble), "icon": "info"}]), trouble
    if track is None:
        return None, [{"type": "markdown", "text": "Nothing is playing: play something in any app or browser tab."}], None
    return track, [track_section(track, artwork(track, folder, deadline) if folder else None)], None


def bar(run):
    popover = run.get("surface") == "popover"
    track, blocks, trouble = answer(run, BUDGET["popover" if popover else "bar"], art=popover)
    if popover:
        playing = track is not None and track["playing"]
        send({"type": "blocks", "blocks": blocks, "refresh": REFRESH["playing" if playing else "idle"]})
    elif trouble:
        send({"type": "bar", "text": GLYPH, "tone": "warn", "blocks": blocks})
    elif track is None:
        send({"type": "bar", "text": "", "blocks": blocks})  # no text hides the item
    else:
        mode = str((run.get("preferences") or {}).get("bar") or "artist-title")
        send({"type": "bar", "text": bar_text(track, mode), "blocks": blocks})


def page(run):
    """Its page (Sven, 2026-10-31: a page does its job in place): the popover's track, how far in and its controls, with
    Show in <app> as a button too, asked again on the popover's pace."""
    track, blocks, _ = answer(run, BUDGET["popover"])
    if track is not None:
        blocks[0]["blocks"][-1]["actions"].append(show_action(track))
    playing = track is not None and track["playing"]
    send({"type": "blocks", "blocks": blocks, "refresh": REFRESH["playing" if playing else "idle"]})


def detail(run):
    """Hyper+Space's Now playing: the track, how far in, and the controls on Return and Cmd+K."""
    track, blocks, trouble = answer(run, BUDGET["detail"], art=False)
    if trouble or track is None:
        send({"type": "detail", "markdown": blocks[0]["text"]})
        return
    lines = ["# %s" % (track["title"] or "Playing"), "", byline(track)]
    metadata = [{"label": "Playing in", "text": track["app"]},
                {"label": "State", "text": "Playing" if track["playing"] else "Paused"}]
    if track["duration"]:
        metadata.append({"label": "Position", "text": "%s / %s" % (clock(track["position"]), clock(track["duration"]))})
    send({"type": "detail", "markdown": "\n".join(lines), "metadata": metadata,
          "actions": buttons(track, words=True) + [show_action(track)]})


# ---- the controls ----

# A browser's tab by its title: the first whose title holds the track's comes to the front in its window, the window
# to the front, the browser active; "app" when none holds it (the browser is still brought forward), "gone" when the
# browser quit meanwhile, so the tell never starts it. Chromium's tabs have a title and an active tab index, Safari's
# a name and a current tab.
TAB_SCRIPT = '''on run argv
	if not (application id "%(bundle)s" is running) then return "gone"
	set wanted to item 1 of argv
	tell application id "%(bundle)s"
		repeat with w in windows
			set i to 0
			repeat with t in tabs of w
				set i to i + 1
				if %(name)s of t contains wanted then
					%(select)s
					set index of w to 1
					activate
					return "tab"
				end if
			end repeat
		end repeat
		activate
	end tell
	return "app"
end run'''
CHROMIUM = {"name": "title", "select": "set active tab index of w to i"}
# The browsers whose tabs can be picked by title, by bundle id, each its script.
BROWSERS = (("com.google.Chrome", CHROMIUM), ("com.brave.Browser", CHROMIUM), ("com.microsoft.edgemac", CHROMIUM),
            ("com.vivaldi.Vivaldi", CHROMIUM), ("com.apple.Safari", {"name": "name", "select": "set current tab of w to t"}))
TABS = {bundle: TAB_SCRIPT % dict(words, bundle=bundle) for bundle, words in BROWSERS}
# The address of that same tab, for its artwork: nothing selected, nothing brought forward, "" when no tab holds it.
TAB_URL = '''on run argv
	if not (application id "%(bundle)s" is running) then return ""
	set wanted to item 1 of argv
	tell application id "%(bundle)s"
		repeat with w in windows
			repeat with t in tabs of w
				if %(name)s of t contains wanted then return URL of t
			end repeat
		end repeat
	end tell
	return ""
end run'''
TAB_URLS = {bundle: TAB_URL % dict(words, bundle=bundle) for bundle, words in BROWSERS}


def open_app(bundle):
    binary = shutil.which("open") or "/usr/bin/open"
    try:
        return subprocess.run([binary, "-b", bundle], stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL,
                              stderr=subprocess.DEVNULL, timeout=10).returncode == 0
    except (OSError, subprocess.TimeoutExpired):
        return False


def show():
    """Goes to what plays: a browser's tab that holds the track's title, else the app playing it."""
    deadline = time.monotonic() + BUDGET["control"]
    try:
        track = now_playing(deadline)
    except Trouble as trouble:
        send({"type": "error", "text": trouble_words(trouble)})
        return
    if track is None or not track["bundle"]:
        send({"type": "hud", "text": "Nothing is playing" if track is None else "Can't tell which app plays %s" % spoken(track)})
        return
    script = TABS.get(track["bundle"])
    if script and track["title"]:
        try:
            if osascript(["-e", script, track["title"]], deadline) == "gone":
                send({"type": "hud", "text": "%s is no longer open" % track["app"]})  # opening it would start a player
            return
        except Trouble as trouble:
            if trouble.why == "denied":
                open_app(track["bundle"])
                send({"type": "hud", "text": "To go to the tab: " + trouble_words(trouble, track["app"])})
                return
    if not open_app(track["bundle"]):
        send({"type": "hud", "text": "Can't bring %s forward" % track["app"]})

def control(run, verb):
    """Sends `verb` to whatever plays, then says what plays now; Favourite asks Music, only while it is what plays."""
    deadline = time.monotonic() + BUDGET["control"]
    try:
        if verb == "favourite":
            track = now_playing(deadline)
            if track is None or track["bundle"] != MUSIC:
                send({"type": "hud", "text": "Favourite works while Music plays; %s can't be favourited from Pilot."
                                             % (track["app"] if track else "nothing")})
                return
            said = osascript(["-e", FAVOURITE], deadline)
            send({"type": "hud", "text": "♥ Favourited" if said == "true" else "♡ No longer a favourite"})
            return
        if now_playing(deadline) is None:
            send({"type": "hud", "text": "Nothing to %s: nothing has played yet." % VERBS[verb]})
            return
        track = now_playing(deadline, verb)
    except Trouble as trouble:
        if verb == "favourite" and trouble.why == "failed":
            send({"type": "hud", "text": "Music can't favourite this track: add it to your library first."})
        else:
            send({"type": "error", "text": trouble_words(trouble)})
        return
    if track is None:
        send({"type": "hud", "text": "Stopped"})
    elif track["playing"]:
        send({"type": "hud", "text": "▶\ufe0e %s" % spoken(track)})
    else:
        send({"type": "hud", "text": "⏸\ufe0e Paused"})


def main():
    try:
        run = json.loads(sys.stdin.readline() or "{}")
    except ValueError:
        run = {}
    command = run.get("command")
    if command == "bar":
        bar(run)
    elif command == "now":
        detail(run)
    elif command == "page":
        page(run)
    elif command in VERBS:
        control(run, command)
    elif command == "show":
        show()
    else:
        send({"type": "error", "text": "Now playing has no command %s" % command})


if __name__ == "__main__":
    main()
