#!/usr/bin/env python3
"""Sandbox E2E for Pilot's notifications: the real reader, feed, watcher and verbs against a fake Notification Center.

Nothing here touches the Mac: the host serves a throwaway socket and folder, the tree is a file, and PilotCLI is the only
way in. Run: nice -n 10 python3 Scripts/notifications-proof.py [--shape file.json] [--case NAME]"""
import argparse
import copy
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import time
from pathlib import Path

sys.dont_write_bytecode = True
REPO = Path(__file__).resolve().parent.parent
CLI = REPO / '.build/debug/PilotCLI'
CLOSE = 'Name:Close\nTarget:0x0\nSelector:(null)'
SHOW = 'Name:Show\nTarget:0x0\nSelector:(null)'
SECRET = re.compile(r'Sekret-(?:App|Title|Sub|Body)-\d+')


def named(name):
    return f'Name:{name}\nTarget:0x0\nSelector:(null)'


class Fail(Exception):
    pass


def check(ok, what):
    print(('PASS ' if ok else 'FAIL ') + what, flush=True)
    if not ok:
        raise Fail(what)


class Sandbox:
    def __init__(self, shape):
        try:
            self.base = json.loads(Path(shape).read_text())
        except (OSError, ValueError) as error:
            raise Fail(f'the shape file could not be read ({error}); capture it again on an unlocked screen')
        self.home = None
        self.root = Path(tempfile.mkdtemp(prefix='pn', dir='/tmp'))
        self.folder = self.root / 'nc'
        self.folder.mkdir()
        self.socket = self.root / 'p.sock'
        self.hold = Path(str(self.socket) + '.hold')
        self.generation = 0
        self.offset = 0
        self.proc = None
        self.log = None
        self.log_path = self.root / 'host.log'
        self.widget = None
        self.drop_first = False

    def start(self):
        self.home = self.host(self.base).get('position', [0, 0])
        (self.folder / 'pid').write_text('628\n')
        self.tree(self.first_banners(), bump=False)
        (self.folder / 'generation').write_text('0\n')
        env = {k: v for k, v in os.environ.items() if not k.startswith(('PILOT_', 'CFFIXED_'))}
        env.update(PILOT_SANDBOX=str(self.socket), PILOT_SANDBOX_ALLOW='1', PILOT_SANDBOX_NOTIFICATIONS=str(self.folder))
        self.log = self.log_path.open('w')
        self.proc = subprocess.Popen(['nice', '-n', '10', 'swift', 'test', '--skip-build', '--filter', 'SandboxHost'],
                                     cwd=REPO, env=env, stdout=self.log, stderr=subprocess.STDOUT)
        deadline = time.time() + 240
        while not self.hold.exists():
            if self.proc.poll() is not None or time.time() > deadline:
                raise Fail('host did not start: ' + self.log_path.read_text()[-2000:])
            time.sleep(0.2)
        print('host up', flush=True)

    def stop(self):
        if self.hold.exists():
            self.hold.unlink()
        if self.proc:
            try:
                self.proc.wait(30)
            except subprocess.TimeoutExpired:
                self.proc.kill()
        if self.log:
            self.log.close()
        shutil.rmtree(self.root, ignore_errors=True)

    def pilot(self, *args, ok=True):
        run = subprocess.run([str(CLI), *args], env=dict(os.environ, PILOT_SOCKET=str(self.socket)), capture_output=True, text=True, timeout=60)
        if ok and run.returncode != 0:
            raise Fail(f'pilot {" ".join(args)}: {run.stdout}{run.stderr}')
        return run

    def status(self):
        out = self.pilot('status', '--part', 'notifications').stdout
        return json.loads(out)['notifications']

    def get(self, key):
        return json.loads(self.pilot('get', key).stdout)

    def set(self, key, value):
        return self.pilot('set', key, json.dumps(value))

    # The tree

    def host(self, tree):
        found = next((w for w in tree['windows'] if w.get('subrole') == 'AXSystemDialog'), None)
        if found is None:
            raise Fail('the shape has no AXSystemDialog window: the screen was locked, or macOS changed the host window')
        return found

    def scroll(self, tree):
        """The element banners sit in: the parent of the first one, as the capture found it."""
        def find(node):
            for child in node.get('children', []):
                if child.get('subrole', '').startswith('AXNotificationCenter'):
                    return node
                hit = find(child)
                if hit is not None:
                    return hit
            return None
        found = find(self.host(tree))
        if found is None:
            raise Fail('the shape has no banner in its AXSystemDialog window: capture it while one is up')
        return found

    def first_banners(self):
        return [] if self.drop_first else self.scroll(self.base)['children']

    def tree(self, banners, expanded=False, bump=True, list_rows=None):
        tree = copy.deepcopy(self.base)
        tree['expanded'] = expanded
        self.scroll(tree)['children'] = banners + ([] if list_rows is None else [{'role': 'AXGroup', 'identifier': 'AXNotificationListItems', 'children': list_rows}])
        if self.widget:
            # A capture may hold no widget window; the check still needs one to put the look-alike in.
            widget = next((w for w in tree['windows'] if w.get('subrole') != 'AXSystemDialog'), None)
            if widget is None:
                widget = dict(role='AXWindow', subrole='AXStandardWindow')
                tree['windows'].append(widget)
            widget.setdefault('children', []).append(self.widget)
        (self.folder / 'tree.json').write_text(json.dumps(tree))
        if bump:
            self.bump()

    def bump(self):
        self.generation += 1
        (self.folder / 'generation').write_text(f'{self.generation}\n')

    def pid(self, value):
        (self.folder / 'pid').write_text(f'{value}\n')

    def events(self):
        path = self.folder / 'events.jsonl'
        if not path.exists():
            return []
        return [json.loads(line) for line in path.read_text().splitlines() if line.strip()]

    def new_events(self):
        all_events = self.events()
        fresh, self.offset = all_events[self.offset:], len(all_events)
        return fresh

    def wait_event(self, name, predicate=lambda e: True, seconds=6):
        deadline = time.time() + seconds
        while time.time() < deadline:
            hit = [e for e in self.events()[self.offset:] if e['event'] == name and predicate(e)]
            if hit:
                self.offset = len(self.events())
                return hit[-1]
            time.sleep(0.05)
        raise Fail(f'no {name} event in {seconds}s; saw {[e["event"] for e in self.events()[self.offset:]]}')

    def settled(self, seconds=0.5):
        time.sleep(seconds)


def banner(n, kind='Banner', actions=(), identifier=None, description=None, title=True, subtitle=True):
    app, head, sub, body = f'Sekret-App-{n}', f'Sekret-Title-{n}', f'Sekret-Sub-{n}', f'Sekret-Body-{n}'
    children = []
    if title:
        children.append(dict(role='AXStaticText', identifier='title', value=head))
    if subtitle:
        children.append(dict(role='AXStaticText', identifier='subtitle', value=sub))
    children.append(dict(role='AXStaticText', identifier='body', value=body))
    return dict(role='AXGroup', subrole=f'AXNotificationCenter{kind}', identifier=identifier or f'id-{n}',
                description=description or f'{app}, {head}, {sub}, {body}', actions=['AXPress', CLOSE, SHOW, *map(named, actions)], children=children)


def only(event, field='cards'):
    check(len(event[field]) == 1, f'one entry in {field}')
    return event[field][0]


def shape(s):
    """The real test of a captured shape: its own banners, delivered as new, must read."""
    captured = [b for b in s.first_banners() if b.get('subrole', '').startswith('AXNotificationCenter')]
    s.tree([], bump=False)
    s.set('notifications.enabled', True)
    s.settled(0.4)
    s.new_events()
    s.tree(captured)
    e = s.wait_event('cards', lambda ev: ev['drawer'])
    print(f'captured banners: {len(captured)}, kinds: {sorted({d["kind"] for d in e["drawer"]})}', flush=True)
    check(len(e['drawer']) == len(captured), 'every captured banner read as a notification')
    for d in e['drawer']:
        empty = [f for f in ('app', 'title', 'kind') if not d[f]]
        check(not empty, f'{d["id"][:12]}: has app, title and kind' + (f' (missing {empty})' if empty else ''))
    s.set('notifications.enabled', False)
    s.wait_event('end')
    s.tree(captured, bump=False)


def probe(s):
    check(s.get('notifications.enabled') is False, 'off by default')
    st = s.status()
    check(st['observing'] is False and st['timers'] == 0 and st['workspaceObservers'] == 0, f'off: no observer, no timer, no workspace watch ({st})')
    check([e for e in s.events()[s.offset:] if e['event'] in ('attach', 'read')] == [], 'off: no attach and no tree read')
    s.set('notifications.enabled', True)
    s.wait_event('attach', lambda e: e['pid'] == 628)
    st = s.status()
    check(st['on'] and st['observing'] and st['timers'] == 1 and st['workspaceObservers'] == 3, f'on: observing with one slow timer ({st})')
    s.settled(0.4)
    st = s.status()
    check(st['cards'] == 0 and st['live'] == 0 and st['hostFound'], 'what was already up is seeded, not replayed')
    s.new_events()
    # A walk that can't see the host window (a timeout, a locked screen) says nothing: the card stays.
    s.new_events()
    missed = banner(70)
    s.tree(s.first_banners() + [missed])
    s.wait_event('cards')
    tree_text = (s.folder / 'tree.json').read_text()
    (s.folder / 'tree.json').write_text('{}')
    s.bump()
    s.settled(0.4)
    check(s.status()['cards'] == 1 and [e for e in s.new_events() if e['event'] == 'cards'] == [], 'a walk that can\'t see the host window changes nothing')
    (s.folder / 'tree.json').write_text(tree_text)
    s.bump()
    s.settled(0.3)
    s.tree(s.first_banners())
    s.wait_event('cards')
    s.new_events()
    # A walk that sees the host but reads no banner, twice, with the row already cleared: the card still comes back.
    cleared = banner(71)
    s.tree(s.first_banners() + [cleared])
    s.wait_event('cards')
    command(s, 'clear')
    deadline = time.time() + 3
    while time.time() < deadline and s.status()['drawer'] != 0:
        time.sleep(0.05)
    tree_text = (s.folder / 'tree.json').read_text()
    s.new_events()
    s.tree(s.first_banners())
    s.wait_event('cards', lambda ev: ev['cards'] == [])
    deadline = time.time() + 5
    while time.time() < deadline and len([e for e in s.events()[s.offset:] if e['event'] == 'read']) < 1:
        time.sleep(0.05)
    check(len([e for e in s.events()[s.offset:] if e['event'] == 'read']) >= 1, 'the automatic second look ran (two misses)')
    s.bump()
    s.settled(0.4)
    s.new_events()
    (s.folder / 'tree.json').write_text(tree_text)
    s.bump()
    check(only(s.wait_event('cards'))['id'] == 'id-71', 'cleared, missed twice, then read again: its card comes back')
    s.tree(s.first_banners())
    s.wait_event('cards')
    s.new_events()
    # A banner with every line.
    fresh = banner(1)
    s.tree(s.first_banners() + [fresh])
    e = only(s.wait_event('cards'))
    check((e['app'], e['title'], e['subtitle'], e['body'], e['actions'], e['kind']) ==
          ('Sekret-App-1', 'Sekret-Title-1', 'Sekret-Sub-1', 'Sekret-Body-1', [], 'AXNotificationCenterBanner'), 'reads app, title, subtitle, body')
    # An alert with the app's buttons; Notification Center's own are not the app's.
    alert = banner(2, 'Alert', actions=('Archive', 'Snooze'), subtitle=False)
    s.tree(s.first_banners() + [fresh, alert])
    e = s.wait_event('cards')
    check(e['cards'][0]['actions'] == ['Archive', 'Snooze'] and e['cards'][0]['kind'] == 'AXNotificationCenterAlert', 'reads the app\'s buttons, not Close or Show')
    # macOS 27's Persistent layout: "App Title, Body", no comma after the app.
    persistent = banner(3, 'Alert', identifier='id-3', description='Sekret-App-3 Sekret-Title-3, Sekret-Body-3', subtitle=False)
    s.tree(s.first_banners() + [fresh, alert, persistent])
    e = s.wait_event('cards')
    check(e['cards'][0]['app'] == 'Sekret-App-3' and e['cards'][0]['title'] == 'Sekret-Title-3', 'reads the app from a Persistent banner')
    # Three layout changes for one banner: one card.
    s.bump(); s.bump(); s.bump()
    s.settled(0.4)
    check(len([x for x in s.new_events() if x['event'] == 'cards']) == 0, 'repeat layout changes make no new card')
    # A look-alike element in a widget window is never read.
    s.widget = banner(90, identifier='widget-new')
    s.tree(s.first_banners() + [fresh, alert, persistent])
    s.settled(0.4)
    s.widget = None
    st = s.status()
    check(st['live'] == 3, 'a banner look-alike in a widget window is not walked')
    # Gone.
    s.tree(s.first_banners())
    e = s.wait_event('cards')
    check(e['cards'] == [] and len(e['drawer']) == 4 and all(not d['live'] for d in e['drawer']), 'a banner that went leaves the card and stays in the drawer')
    # Panel rows share the banner subroles.
    s.tree(s.first_banners(), expanded=True, list_rows=[banner(9)])
    s.settled(0.4)
    check(s.status()['panelOpen'] is True and s.status()['live'] == 0, 'open panel: rows are not banners')
    s.tree(s.first_banners(), list_rows=[banner(9)])
    s.settled(0.4)
    check(s.status()['live'] == 0 and s.status()['panelOpen'] is False, 'the panel\'s list is never walked')
    # Notification Center restarts under a new pid.
    s.new_events()
    s.pid(700)
    deadline = time.time() + 20
    while time.time() < deadline and s.status()['reattached'] < 1:
        time.sleep(0.5)
    st = s.status()
    check(st['reattached'] == 1 and st['pid'] == 700 and st['observing'], f'recovers when Notification Center restarts ({st["reattached"]})')
    fresh2 = banner(4)
    s.tree(s.first_banners() + [fresh2])
    check(only(s.wait_event('cards'))['title'] == 'Sekret-Title-4', 'banners read after the restart')
    s.tree(s.first_banners())
    s.settled(0.3)
    # Off.
    s.new_events()
    s.set('notifications.enabled', False)
    s.wait_event('detach')
    st = s.status()
    check(st['observing'] is False and st['timers'] == 0 and st['workspaceObservers'] == 0 and st['drawer'] == 0, 'off again: nothing running, drawer gone from memory')
    s.new_events()
    s.tree(s.first_banners() + [banner(5)])
    s.settled(0.6)
    check([e for e in s.new_events() if e['event'] in ('read', 'cards')] == [], 'off: a layout change reads nothing')


def privacy(s):
    """Run last: the whole sandbox's logs and CLI answers carry no fixture word."""
    pid = subprocess.run(['pgrep', '-f', f'swiftpm-testing-helper.*{REPO}'], capture_output=True, text=True).stdout.split()
    check(pid != [], f'host pid found ({pid})')
    log = subprocess.run(['/usr/bin/log', 'show', '--last', '10m', '--info', '--debug', '--predicate',
                          f'subsystem == "dev.banozz.pilot" AND processID == {pid[0]}'], capture_output=True, text=True, timeout=120).stdout
    print('log lines:', len(log.splitlines()), flush=True)
    for line in [l for l in log.splitlines() if 'notifications:' in l][:5]:
        print('  log:', line.split('notifications:')[-1].strip(), flush=True)
    check('notifications:' in log, 'the log has our lines')
    check(not SECRET.search(log), 'the log carries shape and counts, no notification text')
    answer = s.pilot('status', '--part', 'notifications').stdout + s.pilot('settings').stdout
    check(not SECRET.search(answer), 'pilot reads carry no notification text')
    support = Path(s.pilot('get', 'notes.folder').stdout.strip().strip('"')).parent
    check(support.is_dir() and support != Path.home() / 'Library/Application Support/Pilot', f'found the throwaway support folder ({support})')
    leaked = subprocess.run(['grep', '-rlaE', SECRET.pattern, str(support)], capture_output=True, text=True).stdout.strip()
    check(leaked == '', f'nothing on disk in Pilot\'s folder holds a notification word ({leaked or "none"})')


def card(s):
    s.new_events()
    (s.folder / 'render').write_text('')
    s.tree(s.first_banners(), bump=False)
    s.set('notifications.enabled', True)
    s.settled(0.4)
    s.new_events()
    # Bottom right of a 3440x1440 screen, above the bell, above the Dock: the card's right edge 16 in, its foot above the bell.
    b1 = banner(11)
    s.tree(s.first_banners() + [b1])
    e = s.wait_event('cards')
    check(e['frame'] == [3440 - 16 - 340, 70 + 16 + 40 + 8, 340, 92], f'card sits bottom right, above the bell ({e["frame"]})')
    check(e['bell'] == [3440 - 16 - 40, 70 + 16], f'bell in the corner ({e["bell"]})')
    deadline = time.time() + 15
    while time.time() < deadline and not (s.folder / 'cards.png').exists():
        time.sleep(0.2)
    check((s.folder / 'cards.png').exists(), 'the card renders offscreen')
    if os.environ.get('NOTIFICATION_RENDER'):
        shutil.copy(s.folder / 'cards.png', os.environ['NOTIFICATION_RENDER'])
    (s.folder / 'render').unlink()
    # Hiding off (the default): macOS's window never moves.
    s.settled(0.3)
    check([e for e in s.new_events() if e['event'] == 'move'] == [], 'hiding off: macOS\'s window stays where it is')
    check(s.status()['hostParked'] is False, 'hiding off: not parked')
    # A banner that was up before the setting went on has no card, so macOS's window must stay.
    s.set('notifications.hideMacBanners', True)
    s.settled(0.4)
    check([e for e in s.new_events() if e['event'] == 'move'] == [], 'a banner with no card keeps macOS\'s window on screen')
    # Hiding on: with only carded banners up the window goes off screen, and comes back after the last, where it was.
    s.drop_first = True
    s.tree([b1])
    m = s.wait_event('move')
    check(m['y'] == -9999 and m['subrole'] == 'AXSystemDialog', f'hiding on: the host window goes off screen ({m})')
    check(s.status()['hostParked'] is True, 'status says parked')
    # Notification Center takes it back (it does when its panel opens): the next walk parks it again.
    (s.folder / 'host-back').write_text('')
    s.bump()
    check(s.wait_event('move')['y'] == -9999, 're-parks when macOS moves it back')
    # Notification Center's own panel opens in the same window: it must stay on screen.
    s.tree(s.first_banners() + [b1], expanded=True)
    check(s.wait_event('move')['y'] == s.home[1], 'its open panel brings the window back at once')
    s.settled(0.5)
    check([e for e in s.new_events() if e['event'] == 'move'] == [], 'and it stays put while the panel is open')
    s.tree(s.first_banners() + [b1])
    check(s.wait_event('move')['y'] == -9999, 'panel closed: hidden again')
    # Five at once: the oldest has no card, so macOS keeps showing it.
    many = [banner(120 + n) for n in range(5)]
    s.tree(s.first_banners() + [b1] + many)
    check(s.wait_event('move')['y'] == s.home[1], 'more banners than cards keeps macOS\'s window on screen')
    s.tree(s.first_banners() + [b1])
    check(s.wait_event('move')['y'] == -9999, 'down to what fits: hidden again')
    # A reply banner stays with macOS: it gets no card, and everything comes back on screen at once.
    reply = banner(12, actions=('Reply',))
    s.tree(s.first_banners() + [b1, reply])
    m = s.wait_event('move')
    check(m['y'] == s.home[1] and m['x'] == s.home[0], f'a reply banner brings macOS\'s window back ({m})')
    st = s.status()
    check(st['leftToMacOS'] == 1 and st['cards'] == 1 and st['hostParked'] is False, 'no card for the reply banner; the other card stays')
    # Reply gone: parks again.
    s.tree(s.first_banners() + [b1])
    check(s.wait_event('move')['y'] == -9999, 'reply gone: hidden again')
    # Last banner gone: after a short hold, back.
    s.new_events()
    started = time.time()
    s.tree(s.first_banners())
    s.settled(0.6)
    check([e for e in s.new_events() if e['event'] == 'move'] == [], 'held off screen just after the last banner goes')
    m = s.wait_event('move', seconds=4)
    check(m['y'] == s.home[1], f'then back on screen ({m}), {time.time() - started:.1f}s after')
    # macOS refusing the move loses nothing.
    (s.folder / 'refuse-move').write_text('')
    s.tree(s.first_banners() + [banner(13)])
    s.wait_event('cards')
    deadline = time.time() + 3
    while time.time() < deadline and s.status()['lastError'] is None:
        time.sleep(0.1)
    st = s.status()
    check(st['hostParked'] is False and st['lastError'] and st['cards'] == 1, f'refused move: card still shows, status says why ({st["lastError"]})')
    (s.folder / 'refuse-move').unlink()
    # A restore macOS refuses (review B1): the window stays off screen, and the next walk puts it back where it was.
    s.bump()
    check(s.wait_event('move')['y'] == -9999, 'move allowed again: parked')
    (s.folder / 'refuse-move').write_text('')
    s.new_events()
    s.tree(s.first_banners())
    m = s.wait_event('move', seconds=4)
    check(m['y'] == s.home[1] and s.status()['hostParked'] is False, f'last banner gone: the restore is tried ({m}) and refused')
    (s.folder / 'refuse-move').unlink()
    s.new_events()
    s.bump()
    m = s.wait_event('move', seconds=4)
    check(m['y'] == s.home[1] and m['x'] == s.home[0], f'the next walk finds it still off screen and puts it back ({m})')
    s.settled(0.4)
    check([e for e in s.new_events() if e['event'] == 'move'] == [], 'and then leaves it alone')
    # Review round 2, B2: after a refused put-back, a carded banner with hiding on brings the window back, then parks it.
    s.tree(s.first_banners() + [banner(15)])
    check(s.wait_event('move', lambda e: e['y'] == -9999)['y'] == -9999, 'a carded banner parks it')
    (s.folder / 'refuse-move').write_text('')
    s.new_events()
    s.tree(s.first_banners())
    m = s.wait_event('move', seconds=4)
    check(m['y'] == s.home[1] and s.status()['hostParked'] is False, f'last banner gone: the put-back is refused ({m})')
    (s.folder / 'refuse-move').unlink()
    s.new_events()
    start = s.offset
    s.tree(s.first_banners() + [banner(16)])
    s.wait_event('move', lambda e: e['y'] == -9999)
    moves = [(e['x'], e['y']) for e in s.events()[start:] if e['event'] == 'move']
    check(moves[0] == tuple(s.home) and moves[-1][1] == -9999 and s.status()['hostParked'] is True,
          f'a carded banner then: the window comes back, then parks again ({moves})')
    s.tree(s.first_banners())
    s.wait_event('move', lambda e: e['y'] == s.home[1], seconds=4)
    # Setting off restores and ends the card.
    s.new_events()
    s.tree(s.first_banners() + [banner(14)])
    s.settled(0.5)
    s.bump()
    s.settled(0.4)
    check(s.status()['hostParked'] is True, 'parked before switching hide off')
    s.new_events()
    s.set('notifications.hideMacBanners', False)
    check(s.wait_event('move')['y'] == s.home[1], 'hide off: macOS\'s window back')
    # Review round 2, B1: the put-back as the setting goes off is refused; with no walk left to help, it retries itself.
    s.set('notifications.hideMacBanners', True)
    s.bump()
    check(s.wait_event('move', lambda e: e['y'] == -9999)['y'] == -9999, 'hiding on again: parked')
    (s.folder / 'refuse-move').write_text('')
    s.new_events()
    s.set('notifications.enabled', False)
    s.wait_event('end')
    m = s.wait_event('move', seconds=4)
    check(m['y'] == s.home[1], f'setting off: the put-back is tried and refused ({m})')
    (s.folder / 'refuse-move').unlink()
    s.new_events()
    m = s.wait_event('move', seconds=6)
    check(m['y'] == s.home[1] and m['x'] == s.home[0], f'the setting off, no walk: it tries again on its own and lands ({m})')
    s.settled(2.5)
    check([e for e in s.new_events() if e['event'] == 'move'] == [], 'and stops once it has')
    s.set('notifications.hideMacBanners', False)
    s.tree(s.first_banners())
    s.settled(0.3)
    s.new_events()
    # A crash left it off screen: attaching puts it back.
    tree = json.loads((s.folder / 'tree.json').read_text())
    s.host(tree)['position'] = [0, -9999]
    (s.folder / 'tree.json').write_text(json.dumps(tree))
    (s.folder / 'host-back').write_text('')
    s.set('notifications.enabled', True)
    m = s.wait_event('move', seconds=4)
    check(m['y'] == s.home[1] and m['x'] == s.home[0], f'a window left off screen by a crash comes back on attach ({m})')
    s.set('notifications.enabled', False)
    s.settled(0.3)
    s.drop_first = False


def command(s, line):
    (s.folder / 'commands').write_text(line + '\n')


def actions(s):
    s.new_events()
    s.drop_first = True
    s.tree([], bump=False)
    s.set('notifications.enabled', True)
    s.settled(0.4)
    b = banner(21, actions=('Archive', 'Snooze'))
    s.tree(s.first_banners() + [b])
    s.wait_event('cards')
    # A click opens the app: Notification Center's own AXPress, as macOS's banner does it.
    command(s, 'open id-21')
    e = s.wait_event('press')
    check(e['action'] == 'AXPress' and e['id'] == 'id-21', f'click opens it through AXPress ({e})')
    # The X closes it: the element's Close.
    command(s, 'close id-21')
    e = s.wait_event('press')
    check(e['action'] == 'Close' and e['id'] == 'id-21', f'close presses Close ({e})')
    # A stack answers Clear All.
    stack = dict(banner(22), subrole='AXNotificationCenterBannerStack', actions=['AXPress', 'Name:Clear All\nTarget:0x0\nSelector:(null)', SHOW])
    s.tree(s.first_banners() + [stack])
    s.wait_event('cards')
    command(s, 'close id-22')
    e = s.wait_event('press')
    check(e['action'] == 'Clear All', f'a stack closes through Clear All ({e})')
    # One of the app's buttons reaches its own action.
    b = banner(24, actions=('Archive', 'Snooze'))
    s.tree(s.first_banners() + [b])
    s.wait_event('cards')
    command(s, 'button Archive id-24')
    e = s.wait_event('press')
    check(e['action'] == 'Archive' and e['id'] == 'id-24', f'the app\'s button presses its action ({e})')
    s.settled(0.6)
    check([x for x in s.new_events() if x['event'] == 'tip'] == [], 'a button that worked says nothing')
    # A press macOS refuses comes back to macOS's banner, in words.
    s.set('notifications.hideMacBanners', True)
    s.wait_event('move')
    (s.folder / 'refuse-press').write_text('')
    command(s, 'close id-24')
    e = s.wait_event('tip')
    check(e['text'] == "macOS didn't take that: use its banner", f'a refused press says so ({e["text"]})')
    deadline = time.time() + 3
    while time.time() < deadline and s.status()['hostParked']:
        time.sleep(0.05)
    st = s.status()
    check(st['leftToMacOS'] == 1 and st['cards'] == 0 and st['hostParked'] is False, f'a refused press hands that one back to macOS ({st["leftToMacOS"]}, parked {st["hostParked"]})')
    (s.folder / 'refuse-press').unlink()
    # A press on a banner that has gone.
    s.tree(s.first_banners())
    s.wait_event('cards')
    s.new_events()
    command(s, 'close id-24')
    s.settled(0.4)
    check([x for x in s.new_events() if x['event'] in ('press', 'tip')] == [], 'a banner that has gone is left alone')
    # A button that turns out to open a reply field hands off to macOS.
    s.set('notifications.hideMacBanners', False)
    s.settled(0.2)
    c = banner(23, actions=('Comment',))
    s.tree(s.first_banners() + [c])
    s.wait_event('cards')
    s.new_events()
    withfield = dict(c, children=c['children'] + [dict(role='AXTextField', value='')])
    s.tree(s.first_banners() + [withfield])
    command(s, 'button Comment id-23')
    s.wait_event('press')
    e = s.wait_event('tip', seconds=4)
    check('macOS' in e['text'], f'a button that opens a field goes to macOS\'s banner ({e["text"]})')
    check(s.status()['leftToMacOS'] == 1, 'that one has no card now')
    s.tree(s.first_banners())
    s.settled(0.3)
    s.set('notifications.enabled', False)
    s.settled(0.2)
    s.drop_first = False


def drawer(s):
    s.new_events()
    s.tree(s.first_banners(), bump=False)
    s.set('notifications.enabled', True)
    s.wait_event('begin')
    s.settled(0.4)
    check(s.status()['unread'] == 0, 'bell up, nothing unread')
    # Everything that arrives counts and stays listed, newest first, after it goes.
    a, b = banner(31), banner(32)
    s.tree(s.first_banners() + [a, b])
    e = s.wait_event('cards')
    check(e['unread'] == 2 and [d['title'] for d in e['drawer']] == ['Sekret-Title-31', 'Sekret-Title-32'], 'the drawer lists what arrived, as macOS ordered it')
    s.tree(s.first_banners() + [b])
    e = s.wait_event('cards')
    st = s.status()
    check(st['drawer'] == 2 and st['live'] == 1, 'one went, the drawer keeps both')
    # Opening the drawer clears the count.
    s.new_events()
    (s.folder / 'render').write_text('')
    command(s, 'drawer')
    s.wait_event('drawer')
    check(s.status()['unread'] == 0, 'opening the drawer clears the count')
    deadline = time.time() + 10
    while time.time() < deadline and not (s.folder / 'drawer.png').exists():
        time.sleep(0.2)
    check((s.folder / 'drawer.png').exists(), 'the drawer and bell render offscreen')
    if os.environ.get('NOTIFICATION_RENDER_DRAWER'):
        shutil.copy(s.folder / 'drawer.png', os.environ['NOTIFICATION_RENDER_DRAWER'])
    (s.folder / 'render').unlink()
    # A row's × on a live one also closes macOS's.
    s.new_events()
    command(s, 'remove id-32')
    e = s.wait_event('press')
    check(e['action'] == 'Close' and e['id'] == 'id-32', 'removing a live row closes its banner')
    check(s.status()['drawer'] == 1, 'and it leaves the drawer')
    # A row whose banner has gone opens its app by name, through the presenter.
    s.new_events()
    s.tree(s.first_banners())
    s.wait_event('cards')
    command(s, 'open id-31')
    e = s.wait_event('open-app')
    check(e['app'] == 'Sekret-App-31', 'a row whose banner went opens its app')
    # Bounded in memory.
    s.new_events()
    s.tree(s.first_banners() + [banner(100 + n) for n in range(120)])
    s.wait_event('cards')
    check(s.status()['drawer'] == 100, 'the drawer is capped at 100')
    command(s, 'clear')
    s.settled(0.3)
    check(s.status()['drawer'] == 0, 'clear all empties it')
    # Focus: macOS shows no banner, so Pilot has nothing: no card and no drawer entry.
    s.tree(s.first_banners())
    s.settled(0.3)
    s.new_events()
    s.bump()
    s.settled(0.3)
    st = s.status()
    check(st['cards'] == 0 and st['drawer'] == 0, 'no banner from macOS means nothing drawn or kept: Focus holds by construction')
    s.set('notifications.enabled', False)
    s.wait_event('end')
    # The drawer action with the setting off says where to switch it on and opens nothing.
    s.new_events()
    command(s, 'drawer')
    e = s.wait_event('tip')
    check('off' in e['text'], f'the action with the setting off explains itself ({e["text"]})')
    check(s.status()['drawer'] == 0, 'memory empty after off')


def no_host(s, bump=True):
    """macOS 27.2's idle tree (measured 2026-11-10): the app answers, with no AXSystemDialog window."""
    tree = copy.deepcopy(s.base)
    tree['windows'] = [w for w in tree['windows'] if w.get('subrole') != 'AXSystemDialog']
    (s.folder / 'tree.json').write_text(json.dumps(tree))
    if bump:
        s.bump()


def nohost(s):
    """No host window until the first banner, as on macOS 27.2: that first banner gets a card, and its window going clears it."""
    check(s.get('notifications.enabled') is False, 'starts off')
    s.drop_first = True
    no_host(s, bump=False)
    s.set('notifications.enabled', True)
    s.wait_event('attach')
    s.settled(0.4)
    st = s.status()
    check(st['hostFound'] is False and st['cards'] == 0, f'on with nothing up: no host window, no card ({st["hostFound"]}, {st["cards"]})')
    s.new_events()
    first = banner(80)
    s.tree([first])
    check(only(s.wait_event('cards'))['title'] == 'Sekret-Title-80', 'the first banner after switching on gets a card, not seeded away')
    no_host(s)
    s.wait_event('cards', lambda ev: ev['cards'] == [])
    check(s.status()['drawer'] == 1, 'its window going clears the card; the drawer keeps it')
    s.new_events()
    (s.folder / 'tree.json').write_text('{}')
    s.bump()
    s.settled(0.4)
    check([e for e in s.new_events() if e['event'] == 'cards'] == [], 'a read that failed changes nothing')
    s.tree([banner(81)])
    e = s.wait_event('cards', lambda ev: ev['cards'])
    check([c['title'] for c in e['cards']] == ['Sekret-Title-81'] and s.status()['drawer'] == 2, 'the next banner gets its card')
    no_host(s)
    s.wait_event('cards', lambda ev: ev['cards'] == [])
    s.set('notifications.enabled', False)
    s.wait_event('detach')
    s.drop_first = False
    s.tree(s.first_banners(), bump=False)


def bell(s):
    """The bell goes anywhere, at a pulled size, remembered per display, with the drawer opening beside it (Q42, Q55)."""
    def place(line):
        s.new_events()
        command(s, line)
        return s.wait_event('bell-place')
    e = place('bell main')
    check(e['bell'] == [3384, 86, 40, 40] and e['drawer'] == [3044, 134, 380, 440], f'first: the corner, drawer above it ({e["bell"]}, {e["drawer"]})')
    check(e['cards'] == [3084, 134, 340, 92], f'cards sit just above the 40 pt corner bell ({e["cards"]})')
    (s.folder / 'render').write_text('')
    e = place('bell-drop main 100 1300 64')
    check(e['bell'] == [100, 1300, 64, 64] and e['last'] == 'main', f'dropped top left at 64: kept there ({e["bell"]})')
    check(e['drawer'] == [100, 852, 380, 440], f'top left: the drawer opens below it, flush left ({e["drawer"]})')
    check(e['cards'] == [3084, 134, 340, 92], f'bell away from the corner: cards keep their place ({e["cards"]})')
    deadline = time.time() + 15
    while time.time() < deadline and not (s.folder / 'bell.png').exists():
        time.sleep(0.2)
    check((s.folder / 'bell.png').exists(), 'the 64 pt bell renders offscreen')
    if os.environ.get('NOTIFICATION_RENDER_BELL'):
        shutil.copy(s.folder / 'bell.png', os.environ['NOTIFICATION_RENDER_BELL'])
    (s.folder / 'render').unlink()
    e = place('bell-drop side 5000 -50 200')
    check(e['bell'] == [5000, 0, 96, 96] and e['last'] == 'side', f'on the second display: pulled past the largest, kept at 96 and on screen ({e["bell"]})')
    check(e['drawer'] == [4716, 104, 380, 440], f'bottom right of that display: the drawer above it ({e["drawer"]})')
    e = place('bell main')
    check(e['bell'] == [100, 1300, 64, 64] and e['last'] == 'side', f'each display keeps its own place ({e["bell"]})')
    e = place('bell-drop main 3328 86 96')
    check(e['bell'] == [3328, 86, 96, 96] and e['cards'] == [3084, 190, 340, 92], f'a 96 pt bell in the corner: cards rise above it ({e["bell"]}, {e["cards"]})')
    e = place('bell-drop main 5000 5000 10')
    check(e['bell'] == [3412, 1382, 28, 28], f'dropped past the edge at 10: kept inside, at the smallest ({e["bell"]})')
    check(e['drawer'] == [3044, 934, 380, 440], f'top right: the drawer below it, inside the screen ({e["drawer"]})')
    # The drawer keeps its size, never its place (Q55): 2182's autosave name put it back bottom right over the bell's place.
    e = place('drawer-closed 500 600\nbell main')
    check(e['drawer'] == [2924, 774, 500, 600], f'closed at 500x600: opens beside the top-right bell at that size ({e["drawer"]})')
    e = place('drawer-closed 100 100\nbell-drop main 200 200 64')
    check(e['bell'] == [200, 200, 64, 64] and e['drawer'] == [200, 272, 300, 200],
          f'the bell moved bottom left: the drawer follows it, at its smallest 300x200 ({e["bell"]}, {e["drawer"]})')
    panels = (REPO / 'Sources/Pilot/UI/NotificationPanels.swift').read_text()
    check('setFrameAutosaveName' not in panels and 'setFrameUsingName' not in panels, 'the drawer panel keeps no saved frame of its own')
    # The app's wiring of B2: the cards' panel is placed against the bell panel's frame, and again when the bell drops or the
    # screens change.
    dropped = panels[panels.index('private func bellDropped'):panels.index('private func placeCards')]
    replace = panels[panels.index('private func replace()'):]
    check(panels.count('bell: self?.bellPanel?.frame') == 1 and panels.count('bell: bellPanel?.frame') == 1
          and 'placeCards()' in dropped and 'placeCards()' in replace.split('\n    }')[0],
          'the app places cards against its bell panel, and again on a drop and a screen change')
    check(not SECRET.search(json.dumps([x for x in s.events() if x['event'] == 'bell-place'])), 'bell events carry no notification text')


def setting(s):
    settings = s.pilot('settings').stdout
    for key, words in [('notifications.enabled', "Show other apps' notifications as Pilot cards, bottom right"),
                       ('notifications.hideMacBanners', "Hide macOS's own banner while Pilot's card shows")]:
        check(key in settings and words in settings, f'{key} is listed, in plain words')
    check(s.get('notifications.enabled') is False and s.get('notifications.hideMacBanners') is False, 'both are off by default')
    wrong = s.pilot('set', 'notifications.enabled', '"maybe"', ok=False)
    check(wrong.returncode != 0, 'a bad value is refused')
    for key in ('notifications.enabled', 'notifications.hideMacBanners'):
        print(f'pilot get {key}:', s.pilot('get', key).stdout.strip(), flush=True)
    run = s.pilot('actions').stdout
    check('system.notificationDrawer' in run, 'the drawer action is registered with no default key')
    st = s.status()
    print('status:', json.dumps(st, sort_keys=True), flush=True)
    check(not SECRET.search(json.dumps(st)), 'status carries counts only')


CASES = dict(shape=shape, probe=probe, nohost=nohost, card=card, actions=actions, drawer=drawer, bell=bell, setting=setting)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--case', choices=[*CASES, 'all'], default='all')
    parser.add_argument('--shape', default=str(REPO / 'Scripts/notifications-proof/shape-27.json'))
    args = parser.parse_args()
    try:
        s = Sandbox(args.shape)
    except Fail as failure:
        print(f'STOPPED: {failure}', flush=True)
        sys.exit(1)
    try:
        s.start()
        for name, case in CASES.items():
            if args.case in ('all', name):
                print(f'--- {name}', flush=True)
                s.offset = len(s.events())
                case(s)
        print('--- privacy', flush=True)
        privacy(s)
        print('ALL PASS', flush=True)
    except Fail as failure:
        print(f'STOPPED: {failure}', flush=True)
        if s.log_path.exists():
            print('host log tail:\n' + s.log_path.read_text()[-1200:], flush=True)
        sys.exit(1)
    finally:
        s.stop()


if __name__ == '__main__':
    main()
