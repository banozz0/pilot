"""The Carousel's Wallpapers mode (spec desktop-controls T8) through real PilotCLI -> private socket -> the recording host.

A 200-image fixture pack and a fixture folder; the host's wallpaper state file stands in for the screens, so no pick reaches
NSWorkspace. Assertions read `pilot carousel` answers, the recording effect's log, the ledger and the host's log.
"""
import importlib.util
import json
import os
from pathlib import Path
import struct
import subprocess
import time
import zlib

spec = importlib.util.spec_from_file_location('theme_lifecycle', Path(__file__).with_name('lifecycle.py'))
life = importlib.util.module_from_spec(spec)
spec.loader.exec_module(life)
EVIDENCE = Path(os.environ.get('PILOT_THEME_PROOF_EVIDENCE') or Path.home() / '.local/state/spec' / 'desktop-controls/T8')
life.EVIDENCE = EVIDENCE
DOTS = ['background', 'foreground', 'accent', 'red', 'yellow', 'green', 'blue', 'magenta']
ENV = {'PILOT_THEME_CAROUSEL': '1'}


def png(width, height, colour):
    """A decodable PNG of one colour, so every image is its own file."""
    def chunk(kind, data):
        return struct.pack('>I', len(data)) + kind + data + struct.pack('>I', zlib.crc32(kind + data) & 0xffffffff)
    row = b'\x00' + bytes(colour) * width
    return (b'\x89PNG\r\n\x1a\n' + chunk(b'IHDR', struct.pack('>IIBBBBB', width, height, 8, 2, 0, 0, 0))
            + chunk(b'IDAT', zlib.compress(row * height)) + chunk(b'IEND', b''))


def stem(path):
    return Path(path).stem.lower()


class Fixture(life.Fixture):
    """Lifecycle's host plus a wallpaper state, a pack `w` of 200 images (190 wide, 10 tall) and a folder of 12."""
    def __init__(self, label):
        super().__init__(label)
        images = self.root / 'packs/w/wallpapers'
        images.mkdir(parents=True)
        for i in range(200):
            name = ('shore' if i % 2 else 'dune') + f'-{i:03d}' + ('-tall' if i % 20 == 0 else '') + '.png'
            (images / name).write_bytes(png(2, 4, (i, 40, 90)) if i % 20 == 0 else png(4, 2, (i, 90, 40)))
        pack = dict(self.packs[0], id='w', title='Wavecrest', wallpapers=['wallpapers'])
        self.pack = pack
        self.save_pack(pack)
        self.folder = self.root / 'folder'
        self.folder.mkdir()
        for i in range(12):
            (self.folder / f'mine-{i:02d}.png').write_bytes(png(4, 2, (200, i, 10)))
        (self.root / 'none').mkdir()
        self.baseline_image = self.root / 'baseline.png'
        self.baseline_image.write_bytes(life.WALLPAPER_A)
        self.wall = self.root / 'desktop.json'
        self.write_wall(dict(sources=[str(self.folder)], preferences=dict(order='name', seed='816', fitShape=True),
                             displays=[dict(id='wide', workspace='1', portrait=False, image=str(self.baseline_image), pinned=False),
                                       dict(id='tall', workspace='2', portrait=True, image=str(self.baseline_image), pinned=False)]))
        self.settings.update(wallpaperState=str(self.wall), wallpaperBindings=['wide', 'tall'])
        self.manifest.write_text(json.dumps(self.settings))

    def write_wall(self, value):
        self.wall.write_text(json.dumps(value))

    def read_wall(self):
        return json.loads(self.wall.read_text())

    def effects(self):
        path = self.root / 'state/wallpaper-effects.jsonl'
        return [json.loads(x) for x in path.read_text().splitlines()] if path.exists() else []

    def ledger(self):
        return json.loads((self.root / 'state/ownership.json').read_text())

    def allows(self, counter):
        return [x for x in (self.root / f'host-{counter}.log').read_text().splitlines() if x.startswith('THEME Allow asked:')]


def run(seam_only=False, fixes_only=False):
    EVIDENCE.mkdir(parents=True, exist_ok=True)
    lines = []

    def passed(text):
        lines.append('PASS ' + text)
        print('PASS ' + text, flush=True)

    f = Fixture('carousel')
    try:
        f.start(ENV)
        assert {v['name'] for v in f.call('schema')['verbs']} == {'ping', 'help', 'schema', 'version', 'theme', 'carousel'}

        # No theme: the folders the screen cycles, its shape only, no palette; listing off the main thread.
        mine = sorted(str(p) for p in f.folder.iterdir())
        listed = f.call('carousel', 'list', '--screen', 'wide')
        assert listed['theme'] is None and listed['source'] == 'Your folders' and listed['palette'] == [], listed
        assert listed['images'] == mine and listed['total'] == 12, listed
        passed('no theme: Wallpapers mode lists the 12 images of the cycling folder, "Your folders", no palette')

        # Zero images: the empty state.
        wall = f.read_wall()
        f.write_wall(dict(wall, sources=[str(f.root / 'none')]))
        empty = f.call('carousel', '--screen', 'wide')
        assert empty['empty'] is True and empty['count'] == 0 and empty['centre'] is None, empty
        f.write_wall(wall)
        passed('zero images: the answer is the empty state (empty, count 0, no centre)')

        # A pick with no theme: one recorded assignment, no ledger.
        before = len(f.effects())
        picked = f.call('carousel', 'pick', mine[3], '--screen', 'wide')
        assert picked['assignment'] == 'verified' and len(f.effects()) == before + 1, picked
        assert f.read_wall()['displays'][0]['image'] == mine[3]
        assert not (f.root / 'state/ownership.json').exists() or not f.ledger().get('wallpapers')
        passed('no theme: a pick records exactly one assignment on the recording effect and leaves no ledger')

        # The theme: Apply through its Allow, then the carousel lists the pack's images by the screen's shape.
        f.apply('w')
        state = f.read_wall()
        theme_images = state['sources']
        assert len(theme_images) == 200, len(theme_images)
        wide = sorted((p for p in theme_images if not stem(p).endswith('-tall')), key=lambda p: Path(p).name)
        tall = sorted((p for p in theme_images if stem(p).endswith('-tall')), key=lambda p: Path(p).name)
        listed = f.call('carousel', 'list', '--screen', 'wide')
        assert listed['theme'] == 'w' and listed['source'] == "Wavecrest's wallpapers", listed
        assert listed['images'] == wide and listed['total'] == 190
        assert listed['palette'] == [f.pack['palette'][k] for k in DOTS if k in f.pack['palette']] and len(listed['palette']) == 8
        assert listed['current'] == state['displays'][0]['image'] and listed['centre'] == listed['current']
        assert f.call('carousel', '--screen', 'tall')['images'] == tall
        passed("theme: Wallpapers mode lists the current theme's 200-image pack by shape (190 wide, 10 tall), its palette's 8 dots, centred on the current image")

        # Search: names holding every word.
        found = f.call('carousel', '--screen', 'wide', '--query', 'shore 01')
        expected = [p for p in wide if 'shore' in stem(p) and '01' in stem(p)]
        assert found['images'] == expected and 0 < len(expected) < 190 and found['query'] == 'shore 01', found
        none = f.call('carousel', '--screen', 'wide', '--query', 'nothing-like-this')
        assert none['empty'] is True and none['count'] == 0
        passed(f'search reads back through pilot: "shore 01" keeps {len(expected)} of 190; a word nothing holds gives the empty state')

        # Favourites: F marks and unmarks; Tab shows only them.
        marks = [wide[5], wide[40], wide[120]]
        for path in marks:
            f.call('carousel', 'favourite', path, '--screen', 'wide')
        answer = f.call('carousel', 'favourite', marks[1], '--screen', 'wide')
        assert answer['favourites'] == [marks[0], marks[2]], answer['favourites']
        assert f.call('carousel', '--favourites', '--screen', 'wide')['images'] == [marks[0], marks[2]]
        refused = f.call('carousel', 'favourite', str(f.root / 'baseline.png'), '--screen', 'wide', ok=False)
        assert 'is not one the carousel lists' in refused['error']['message'], refused
        passed('favourites read back through pilot: three marked, one unmarked, Tab lists the two; an unlisted path is refused')

        # Restart: favourites outlast it.
        f.stop()
        f.start(ENV)
        assert f.call('carousel', '--favourites', '--screen', 'wide')['images'] == [marks[0], marks[2]]
        passed('favourites survive a restart of the host')

        # A pick under the theme: exactly one assignment, through the ledger, no Allow.
        before, now = len(f.effects()), f.read_wall()['displays'][0]['image']
        target = next(p for p in wide if p != now and p not in marks)
        picked = f.call('carousel', 'pick', target, '--screen', 'wide')
        effects = f.effects()
        assert picked['assignment'] == 'verified' and len(effects) == before + 1, (picked, len(effects))
        assert 'wide' in json.dumps(effects[-1]['target']), effects[-1]
        assert target in json.dumps(effects[-1]['after']) and not (f.root / 'state/pending.json').exists()
        claim = next(c for c in f.ledger()['wallpapers'] if 'wide' in json.dumps(c['target']))
        assert target in json.dumps(claim['last']), claim
        assert f.read_wall()['displays'][0]['image'] == target
        passed("a pick records exactly one assignment on the recording effect; the theme's ledger now holds it; no pending journal")

        # The next cycle steps on from the pick, with no ownership conflict.
        cycled = f.call('theme', 'fixture-cycle', 'wide', 'next')
        step = wide[wide.index(target) + 1]
        assert cycled['assignment'] == 'verified' and cycled['image'] == step, (cycled, step)
        assert len(f.effects()) == before + 2 and f.read_wall()['displays'][0]['image'] == step
        passed('a cycle after the pick advances to the next image, with no ownership conflict')

        # Listing never runs on the main thread: a held listing leaves the host answering.
        (f.root / 'carousel.hold').write_bytes(b'')
        env = dict(os.environ, PILOT_SOCKET=str(f.socket))
        env.pop('PILOT_AGENT', None)
        held = subprocess.Popen([str(life.CLI), '--json', 'carousel', '--screen', 'wide'], cwd=life.REPO, env=env,
                                stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        deadline = time.monotonic() + 20
        while not (f.root / 'carousel.ready').exists():
            assert time.monotonic() < deadline and held.poll() is None, 'listing never reached its hold'
            time.sleep(.05)
        started = time.monotonic()
        assert f.call('ping') == 'pong'
        answered = time.monotonic() - started
        assert held.poll() is None, 'listing finished while held'
        (f.root / 'carousel.hold').unlink()
        out, _ = held.communicate(timeout=30)
        result = json.loads(out)['result']
        assert result['total'] == 190
        passed(f'listing runs off the main thread: pilot ping answered in {answered:.2f}s while a listing was held')

        f.stop()
        assert f.allows(1) and f.allows(2) == [], (f.allows(1), f.allows(2))
        passed("no Allow is raised by any carousel read, favourite or pick (the only Allow is the theme's Apply, before the restart)")
    finally:
        f.stop()
        f.receipt()
    real_shape(passed)
    themes(passed)
    pictures(passed)
    (EVIDENCE / 'carousel.log').write_text('\n'.join(lines) + '\n')
    print('PASS carousel', flush=True)


def real_shape(passed):
    """Sven's Mac as read on 2026-11-10 (build-test canon 7): Dusk applied from Pilot.app's own packs, so the sources
    are its two image files (a tall PNG, a wide HEIC), not a folder; one wide and one tall screen; no
    ~/Pictures/Wallpapers; no favourites."""
    f = Fixture('carousel-real')
    try:
        factory(f)
        missing = f.root / 'Pictures/Wallpapers'
        f.write_wall(dict(f.read_wall(), sources=[str(missing)]))
        f.start(ENV)
        empty = f.call('carousel', '--screen', 'wide')
        assert empty['empty'] is True and empty['source'] == 'Your folders', empty
        f.call('theme', 'opt-out', 'zed'); f.call('theme', 'opt-out', 'obsidian')  # Not bound in this fixture.
        f.apply('void')
        sources = f.read_wall()['sources']
        assert [Path(p).name for p in sources] == ['void-tall.png', 'void-wide.heic'], sources
        wide, tall = f.call('carousel', '--screen', 'wide'), f.call('carousel', '--screen', 'tall')
        assert wide['theme'] == 'void' and wide['images'] == [sources[1]] and tall['images'] == [sources[0]], (wide, tall)
        assert wide['centre'] == wide['current'] == sources[1] and len(wide['palette']) == 8 and wide['favourites'] == []
        f.stop()
        assert f.allows(1)
        passed("real shape: a missing ~/Pictures/Wallpapers is the empty state; factory Dusk's two files list one per screen shape (HEIC on the wide, PNG on the tall), centred on the current one")
    finally:
        f.stop()
        f.receipt()


def factory(f):
    """Pilot.app's own packs, as this Mac has them."""
    life.shutil.copytree(life.REPO / 'Packaging/ThemePacks', f.root / 'factory')
    f.settings.update(factoryPacks=str(f.root / 'factory'))
    f.manifest.write_text(json.dumps(f.settings))


def detected_home(f):
    """This Mac's app shape as read on 2026-11-10: Zed's folder with settings.json and themes/, one Obsidian vault with
    its own snippet, VS Code's and Cursor's User folders; Ghostty's config is lifecycle's dotfiles link."""
    home, vault = f.root / 'home', f.root / 'vaults/notes'
    (home / '.config/zed/themes').mkdir(parents=True)
    (home / '.config/zed/settings.json').write_bytes(b'{ /* Keep */ "theme": "Keep theme" }\n')
    (vault / '.obsidian/snippets').mkdir(parents=True)
    (vault / '.obsidian/appearance.json').write_bytes(b'{ "enabledCssSnippets": ["own-style"] }\n')
    (vault / '.obsidian/snippets/own-style.css').write_bytes(b'body { --keep: 1; }\n')
    registry = home / 'Library/Application Support/obsidian/obsidian.json'
    registry.parent.mkdir(parents=True)
    registry.write_text(json.dumps({'vaults': {'v': {'path': str(vault), 'ts': 1, 'open': True}}}))
    for app in ['Code', 'Cursor']:
        (home / f'Library/Application Support/{app}/User').mkdir(parents=True)
        (home / f'Library/Application Support/{app}/User/settings.json').write_bytes(b'{\n  "editor.fontSize": 14\n}\n')
    f.settings['detectHome'] = str(home)
    return home, vault


def tree(*roots):
    return {str(p): life.digest(p) for root in roots for p in Path(root).rglob('*') if p.is_file() or p.is_symlink()}


def themes(passed):
    """Themes mode (T9) on the real shape: factory packs plus one user pack, Zed, a vault, VS Code and Cursor found,
    Ghostty's config a dotfiles link. `carousel pick --mode themes` (the CLI) asks Allow; Return, a press in Pilot
    (theme-system T12), applies in one step with none; Restore stays Look's."""
    f = Fixture('carousel-themes')
    try:
        home, vault = detected_home(f)
        factory(f)
        for extra in ['a', 'b']:  # This Mac has one user pack: `w` here.
            life.shutil.rmtree(f.root / 'packs' / extra)
        watched = lambda: tree(f.root / 'app', f.root / 'state', home, vault.parent, f.wall)
        f.start(ENV)

        # Every pack the style takes, by title, the applied one marked; the apps found on this Mac for the previews.
        packs = [json.loads(p.read_text()) for p in sorted((f.root / 'factory').glob('*/manifest.json'))] + [f.pack]
        expected = sorted((p for p in packs if (not p['styles'] or 'instrument' in p['styles']) and p['id'] not in ('toybox', 'toybox-night')),
                          key=lambda p: p['title'].lower())
        before = watched()
        listed = f.call('carousel', '--mode', 'themes', '--screen', 'wide')
        assert [t['id'] for t in listed['themes']] == [p['id'] for p in expected] and listed['total'] == len(expected), [t['id'] for t in listed['themes']]
        assert listed['current'] is None and not any(t['current'] for t in listed['themes'])
        assert listed['apps'] == {'editor': 'Zed', 'terminal': 'Ghostty', 'notes': 'Obsidian'}, listed['apps']
        tokyo = next(t for t in listed['themes'] if t['id'] == 'tokyo-night')
        assert tokyo['image'].endswith('tokyo-night-wide.png') and len(tokyo['palette']) == 8, tokyo
        tall = next(t for t in f.call('carousel', '--mode', 'themes', '--screen', 'tall')['themes'] if t['id'] == 'tokyo-night')
        assert tall['image'].endswith('tokyo-night-tall.png'), tall
        assert f.call('carousel', '--mode', 'themes', '--query', 'drac')['images'] == ['dracula']
        assert "favourites are Wallpapers mode's" in f.call('carousel', '--mode', 'themes', '--favourites', ok=False)['error']['message']
        assert 'takes no --screen' in f.call('carousel', 'pick', 'tokyo-night', '--mode', 'themes', '--screen', 'wide', ok=False)['error']['message']
        assert watched() == before
        passed('themes: Themes mode lists the 15 packs the style takes (14 factory, 1 user) by title, none marked before an Apply, each with its image for the screen shape and 8 palette dots; previews draw Zed, Ghostty and Obsidian; browsing and search change nothing')

        # Tokyo Night applied through the carousel, after its Allow.
        assert f.call('carousel', 'pick', 'tokyo-night', '--mode', 'themes')['status'] == 'applied'
        marked = f.call('carousel', '--mode', 'themes')
        assert marked['current'] == 'tokyo-night' and [t['id'] for t in marked['themes'] if t['current']] == ['tokyo-night']
        wall = f.read_wall()
        applied = watched()

        # Declined: theme, wallpaper and every file as they were.
        f.controls(allow='no')
        refused = f.call('carousel', 'pick', 'dracula', '--mode', 'themes', ok=False)
        assert 'not allowed: ' in refused['error']['message'] and 'Dracula' in refused['error']['message'], refused
        assert f.call('theme', 'status')['selected']['id'] == 'tokyo-night' and f.read_wall() == wall and watched() == applied
        passed('themes: picking Dracula with Tokyo Night applied raises its Apply Allow; declined, the theme, the wallpaper and every file stay as they were')

        # Allowed: Dracula applies, and Wallpapers mode then lists Dracula's images.
        f.controls(allow='yes')
        assert f.call('carousel', 'pick', 'dracula', '--mode', 'themes')['status'] == 'applied'
        assert f.call('theme', 'status')['selected']['id'] == 'dracula'
        walls = f.call('carousel', '--screen', 'wide')
        assert walls['theme'] == 'dracula' and walls['source'] == "Dracula's wallpapers" and walls['images'] and all('/dracula/' in p for p in walls['images']), walls
        zed = (home / '.config/zed/settings.json').read_bytes()
        assert (home / '.config/zed/themes/pilot-theme.json').exists() and (vault / '.obsidian/snippets/pilot-theme.css').exists()
        passed("themes: allowed, Dracula applies to Ghostty, Zed and the vault, and Wallpapers mode then lists Dracula's images")

        # Return is a press in Pilot: Tokyo Night applies in one step, with no Allow (the host's log, read at stop, counts
        # the asks: the press adds none); the CLI's picks above still asked.
        pressed = f.call('carousel', 'fixture-press', 'tokyo-night')
        assert pressed['status'] == 'applied' and f.call('theme', 'status')['selected']['id'] == 'tokyo-night', pressed
        assert f.call('carousel', '--mode', 'themes')['current'] == 'tokyo-night'
        passed('themes: Return (the press) applies Tokyo Night in one step with no Allow, as Look\'s Apply does; the CLI pick still asks')

        # Restore stays Look's, and puts everything back.
        assert f.restore()['status'] == 'restored'
        assert f.call('carousel', '--screen', 'wide')['source'] == 'Your folders' and f.read_wall()['sources'] == [str(f.folder)]
        assert (home / '.config/zed/settings.json').read_bytes() == b'{ /* Keep */ "theme": "Keep theme" }\n' != zed
        assert not (vault / '.obsidian/snippets/pilot-theme.css').exists() and (vault / '.obsidian/snippets/own-style.css').exists()
        assert tree(home, vault.parent) == {k: v for k, v in before.items() if k.startswith((str(home) + '/', str(vault.parent) + '/'))}
        f.preserved()
        f.stop()
        asks = f.allows(1)
        assert len(asks) == 4 and sum('Apply theme' in a for a in asks) == 3 and 'Restore' in asks[3], asks
        assert not any('Tokyo Night' in a for a in asks[1:3]), asks  # Dracula twice between Tokyo Night's CLI pick and Restore: no press ask.
        passed('themes: Look\'s Restore puts back the folders and every byte of Zed, VS Code, Cursor and the vault, and the dotfiles-linked Ghostty config; four Allows asked in all (Tokyo Night, Dracula declined, Dracula, Restore), none while browsing or for the press')
    finally:
        f.stop()
        f.receipt()

    # A plan that fails changes nothing and says why: no Zed found or bound on this Mac.
    g = Fixture('carousel-themes-unbound')
    try:
        factory(g)
        g.start(ENV)
        before = tree(g.root / 'app', g.root / 'state', g.wall)
        failed = g.call('carousel', 'pick', 'tokyo-night', '--mode', 'themes', ok=False)
        assert 'not planned: ' in failed['error']['message'] and 'Zed not selected/bound' in failed['error']['message'], failed
        assert tree(g.root / 'app', g.root / 'state', g.wall) == before
        assert g.call('carousel', '--mode', 'themes')['apps'] == {'editor': None, 'terminal': 'Ghostty', 'notes': None}
        g.stop()
        assert g.allows(1) == []
        passed('themes: a plan that fails (no Zed bound) changes nothing, asks nothing and says why; with no apps found the previews draw generic editor and notes windows')
    finally:
        g.stop()
        g.receipt()


def pictures(passed):
    """A pack's own picture (T14): named by `preview` in its manifest, shown in place of the drawn desktop; a pack without
    one keeps the drawing; a picture outside the folder, a link out of it or an undecodable file is refused as a wallpaper
    is, and the pack is left out of Themes mode."""
    f = Fixture('carousel-pictures')
    try:
        def pack(name, preview, write=None):
            folder = f.root / 'packs' / name
            folder.mkdir(parents=True, exist_ok=True)
            if write: write(folder)
            f.save_pack(dict(f.pack, id=name, title=name.capitalize(), wallpapers=[], preview=preview))
        pack('shot', 'preview.png', lambda d: (d / 'preview.png').write_bytes(png(8, 5, (10, 120, 200))))
        (f.root / 'outside.png').write_bytes(png(8, 5, (1, 2, 3)))
        pack('linked', 'preview.png', lambda d: (d / 'preview.png').symlink_to(f.root / 'outside.png'))
        pack('garbage', 'preview.png', lambda d: (d / 'preview.png').write_bytes(b'not an image'))
        pack('climbs', '../shot/preview.png')
        f.start(ENV)
        listed = {t['id']: t for t in f.call('carousel', '--mode', 'themes')['themes']}
        assert listed['shot']['preview'] == str(f.root / 'packs/shot/preview.png') and listed['shot']['drawn'] is False, listed['shot']
        assert listed['w']['preview'] is None and listed['w']['drawn'] is True, listed['w']
        assert not {'linked', 'garbage', 'climbs'} & set(listed), sorted(listed)
        passed("pictures: a pack whose manifest names its own picture shows it in place of the drawing; a pack without one keeps the drawing")
        for name, words in [('linked', 'escapes bound root'), ('garbage', 'missing/escaping/undecodable pack picture'),
                            ('climbs', 'invalid schema, identity, compatibility, roles or assets')]:
            refused = f.call('theme', 'show', name, ok=False)
            assert words in refused['error']['message'], (name, refused)
        assert f.call('theme', 'show', 'shot')['valid'] is True
        passed('pictures: a link out of the pack, an undecodable file and a path climbing out are refused as wallpapers are, and those packs are left out')
    finally:
        f.stop()
        f.receipt()
