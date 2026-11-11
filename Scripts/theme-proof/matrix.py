"""Every factory theme through every adapter in a sandbox: Apply, compare, Restore byte exact, then each generated file
checked by what will read it. Ghostty's own validator is read-only and opens no window."""
import importlib.util, json, os, re, subprocess, sys
from pathlib import Path

HERE = Path(__file__).parent
def load(name):
    spec = importlib.util.spec_from_file_location(name, HERE / (name + '.py')); module = importlib.util.module_from_spec(spec); spec.loader.exec_module(module); return module
life = load('lifecycle')
EVIDENCE = life.EVIDENCE
GHOSTTY = '/Applications/Ghostty.app/Contents/MacOS/ghostty'
ROLES = ['text', 'text2', 'text3', 'good', 'amber', 'problem']
GROUNDS = ['ground', 'sidebar', 'surface', 'raised']


def designed():
    src = (life.REPO / 'Sources/PilotCore/PilotTheme.swift').read_text()
    body = src[src.index('public static let designed'):]
    out = {}
    for chunk in body.split('PilotTheme(id: "')[1:]:
        out[chunk[:chunk.index('"')]] = {f: re.search(r'\b%s: 0x([0-9A-Fa-f]{6})' % f, chunk)[1].upper() for f in GROUNDS + ROLES + ['accent']}
        over = re.search(r'onAccent: 0x([0-9A-Fa-f]{6})', chunk[:chunk.index('wallpaper:')])
        out[chunk[:chunk.index('"')]]['onAccent'] = over[1].upper() if over else None
        out[chunk[:chunk.index('"')]]['dark'] = re.search(r'dark: (true|false)', chunk)[1] == 'true'
    return out


def ratio(a, b):
    def lum(h):
        c = [int(h[i:i + 2], 16) / 255 for i in (0, 2, 4)]
        c = [x / 12.92 if x <= .03928 else ((x + .055) / 1.055) ** 2.4 for x in c]
        return .2126 * c[0] + .7152 * c[1] + .0722 * c[2]
    x, y = sorted([lum(a), lum(b)], reverse=True)
    return (x + .05) / (y + .05)


# Review blocker 3: what Obsidian and Zed draw as text, on the backgrounds they draw it on.
OBSIDIAN_TEXT = ['text-normal', 'text-muted', 'text-faint', 'text-accent', 'text-accent-hover', 'text-success', 'text-warning', 'text-error',
                 'color-red', 'color-yellow', 'color-green', 'color-cyan', 'color-blue', 'color-purple', 'code-normal', 'code-comment',
                 'code-function', 'code-keyword', 'code-string', 'code-value', 'code-operator', 'code-punctuation']
OBSIDIAN_GROUNDS = ['background-primary', 'background-primary-alt', 'background-secondary', 'background-secondary-alt']
ZED_TEXT = ['text', 'text.muted', 'text.accent', 'editor.foreground', 'editor.line_number', 'editor.active_line_number', 'terminal.foreground',
            'error', 'warning', 'success', 'info', 'hint']
ZED_GROUNDS = ['background', 'surface.background', 'elevated_surface.background']


def app_text(name, css, zed):
    """Each pair below 4.5:1, from the files Obsidian and Zed read."""
    low = []
    modes = {mode: body for selector, body in re.findall(r'((?:\.theme-(?:dark|light)(?:, )?)+) \{([^{}]*)\}', css) for mode in re.findall(r'\.theme-(dark|light)', selector)}
    assert set(modes) == {'dark', 'light'}, (name, 'the snippet must style both of Obsidian\'s modes', sorted(modes))
    for mode, body in modes.items():
        v = {k: c.lstrip('#') for k, c in re.findall(r'--([a-z-]+): (#[0-9A-Fa-f]{6});', body)}
        for role in OBSIDIAN_TEXT:
            for ground in OBSIDIAN_GROUNDS:
                if ratio(v[role], v[ground]) < 4.5: low.append((name, 'obsidian ' + mode, role, ground, round(ratio(v[role], v[ground]), 2)))
        if ratio(v['text-on-accent'], v['interactive-accent']) < 4.5: low.append((name, 'obsidian ' + mode, 'text-on-accent', 'interactive-accent', round(ratio(v['text-on-accent'], v['interactive-accent']), 2)))
    style = zed['themes'][0]['style']
    inks = [(k, style[k]) for k in ZED_TEXT] + [('syntax.' + k, v['color']) for k, v in style['syntax'].items()]
    for key, ink in inks:
        for ground in ZED_GROUNDS:
            if ratio(ink.lstrip('#'), style[ground].lstrip('#')) < 4.5: low.append((name, 'zed', key, ground, round(ratio(ink.lstrip('#'), style[ground].lstrip('#')), 2)))
    return low


def css_ok(text):
    """No CSS library here: balanced braces, every declaration a name and a value, every colour a real one."""
    depth = 0
    for ch in re.sub(r'/\*.*?\*/', '', text, flags=re.S):
        depth += (ch == '{') - (ch == '}')
        assert depth >= 0, 'stray }'
    assert depth == 0, 'unbalanced braces'
    blocks = re.findall(r'\{([^{}]*)\}', re.sub(r'/\*.*?\*/', '', text, flags=re.S))
    declarations = [d.strip() for block in blocks for d in block.split(';') if d.strip()]
    assert declarations, 'no declarations'
    for d in declarations:
        name, _, value = d.partition(':')
        assert re.fullmatch(r'--?[\w-]+|[a-z-]+', name.strip()) and value.strip(), d
        for colour in re.findall(r'#[0-9A-Za-z]+', value): assert re.fullmatch(r'#[0-9A-Fa-f]{6}', colour), d
    return len(declarations)


def run(seam_only=False, fixes_only=False):
    assert not seam_only and not fixes_only, 'matrix has one complete proof'
    EVIDENCE.mkdir(parents=True, exist_ok=True)
    themes = designed()
    packs = sorted(p.parent.name for p in (life.REPO / 'Packaging/ThemePacks').glob('*/manifest.json'))
    assert set(themes) <= set(packs), sorted(set(themes) - set(packs))
    bad = EVIDENCE / 'not-a-config.conf'; bad.write_text('background = not-a-colour\n')
    assert subprocess.run([GHOSTTY, '+validate-config', f'--config-file={bad}'], capture_output=True, text=True, timeout=30).returncode != 0, 'the validator passed a broken file'
    table = []; text_low = []
    for name in packs:
        manifest = json.loads((life.REPO / 'Packaging/ThemePacks' / name / 'manifest.json').read_text())
        if name in themes:
            for key, role in [('background', 'ground'), ('foreground', 'text'), ('light_foreground', 'text2'), ('native_text3', 'text3'), ('accent', 'accent'), ('red', 'problem'), ('yellow', 'amber'), ('green', 'good')]:
                assert manifest['palette'][key].lstrip('#').upper() == themes[name][role], (name, key)
        f = life.Fixture('mx', ghostty=True)
        real = f.root / 'dots/config'; real.parent.mkdir(); real.write_bytes(f.original)
        f.config.unlink(); f.actual.unlink(); f.actual.parent.rmdir(); f.config.symlink_to(real)
        home, vault = f.root / 'home', f.root / 'vaults/Notes'
        (home / '.config/zed/themes').mkdir(parents=True)
        # A dynamic selection, as Sven's is: the theme takes both slots, so it shows while macOS is in Dark mode too.
        settings = home / '.config/zed/settings.json'; settings.write_bytes(b'{ /* mine */ "theme": { "mode": "system", "light": "One Light", "dark": "Keep Dark" }, "buffer_font_size": 15 }\n')
        (vault / '.obsidian/snippets').mkdir(parents=True)
        appearance = vault / '.obsidian/appearance.json'; appearance.write_bytes(b'{ "enabledCssSnippets":["personal"] }\n')
        (home / 'Library/Application Support/obsidian').mkdir(parents=True)
        (home / 'Library/Application Support/obsidian/obsidian.json').write_text(json.dumps({'vaults': {'n': {'path': str(vault)}}}))
        f.settings['detectHome'] = str(home)
        f.packs[0] = dict(manifest, id='a', wallpapers=[], styles=['instrument', 'toybox']); f.save_pack(f.packs[0]); f.manifest.write_text(json.dumps(f.settings))
        tree = lambda: {str(p): life.digest(p) for root in (home, vault, f.root / 'app', f.root / 'dots') for p in root.rglob('*') if p.is_file() or p.is_symlink()}
        before = tree(); f.start()
        assert f.apply()['status'] == 'applied', name
        generated, zed, css = f.generated, home / '.config/zed/themes/pilot-theme.json', vault / '.obsidian/snippets/pilot-theme.css'
        assert generated.exists() and zed.exists() and css.exists(), name
        keep = EVIDENCE / 'generated' / name; keep.mkdir(parents=True, exist_ok=True)
        for source, target in [(generated, 'ghostty.conf'), (zed, 'zed.json'), (css, 'obsidian.css')]: (keep / target).write_bytes(source.read_bytes())
        env = {k: v for k, v in os.environ.items() if k != 'GHOSTTY_RESOURCES_DIR'}
        check = subprocess.run([GHOSTTY, '+validate-config', f'--config-file={keep / "ghostty.conf"}'], capture_output=True, text=True, timeout=30, env=env)
        assert check.returncode == 0, (name, check.stdout, check.stderr)
        theme = json.loads(zed.read_text()); assert theme.get('themes') and theme['themes'][0].get('style'), name
        chosen = json.loads(re.sub(r'/\*.*?\*/', '', settings.read_text()))['theme']
        assert chosen['light'] == chosen['dark'] == theme['themes'][0]['name'] and chosen['mode'] == 'system', (name, chosen)
        text_low.extend(app_text(name, css.read_text(), theme))
        declarations = css_ok(css.read_text())
        assert f.restore()['status'] == 'restored', name
        f.stop()
        assert tree() == before, name + ': Restore was not byte exact'
        assert f.config.is_symlink() and real.read_bytes() == f.original, name
        f.receipt()
        table.append(dict(theme=name, ghostty='valid', zed='parsed', css=declarations, restore='byte exact'))
        print(f'PASS matrix {name}: ghostty valid, zed parsed, css {declarations} declarations, Restore byte exact', flush=True)
    low = []
    for name, t in themes.items():
        for role in ROLES:
            for ground in GROUNDS:
                value = ratio(t[role], t[ground])
                if value < 4.5: low.append((name, role, ground, round(value, 2)))
    def luminance(h):
        c = [int(h[i:i + 2], 16) / 255 for i in (0, 2, 4)]
        c = [x / 12.92 if x <= .03928 else ((x + .055) / 1.055) ** 2.4 for x in c]
        return .2126 * c[0] + .7152 * c[1] + .0722 * c[2]
    for name, t in themes.items():
        ink = t['onAccent'] or (t['sidebar'] if t['dark'] and luminance(t['accent']) > .3 else 'FFFFFF')
        if ratio(ink, t['accent']) < 4.5: low.append((name, 'onAccent', 'accent', round(ratio(ink, t['accent']), 2)))
    (EVIDENCE / 'matrix.json').write_text(json.dumps(dict(themes=table, low=low, appText=text_low), indent=1))
    assert not low, low
    assert not text_low, text_low
    print(f'PASS app text: Obsidian\'s {len(OBSIDIAN_TEXT) + 1} text roles in both modes and Zed\'s {len(ZED_TEXT)} text keys and syntax colours, in {len(packs)} themes, all at least 4.5:1; Zed takes the theme in both its light and dark slots', flush=True)
    print(f'PASS contrast: {len(ROLES)} text roles on {len(GROUNDS)} backgrounds in {len(themes)} themes, all at least 4.5:1', flush=True)
    print('PASS matrix', flush=True)
