"""VS Code, Cursor, Windsurf, Kitty, Alacritty, WezTerm, iTerm2 and btop through a real Allow, in fixtures shaped like each app's
documented files: links out of the folder, comments, trailing commas and missing files. None of these apps is on this Mac."""
import importlib.util, json, os, re, tomllib
from pathlib import Path

HERE = Path(__file__).parent
spec = importlib.util.spec_from_file_location('lifecycle', HERE / 'lifecycle.py'); life = importlib.util.module_from_spec(spec); spec.loader.exec_module(life)
SUPPORT = 'Library/Application Support'
JSONC = b'// mine\n{\n  "editor.fontSize": 14, /* keep */\n  "files.autoSave": "off",\n}\n'


def strip_jsonc(text):
    text = re.sub(r'/\*.*?\*/', '', text, flags=re.S); text = re.sub(r'^\s*//.*$', '', text, flags=re.M); text = re.sub(r',(\s*[}\]])', r'\1', text)
    return json.loads(text)


def setup(label, **options):
    f = life.Fixture('ap-' + label); home = f.root / 'home'
    for pack in f.packs: pack['adapters'] = {'ghostty': {}}; f.save_pack(pack)
    roots = dict(vscode=home / SUPPORT / 'Code/User', cursor=home / SUPPORT / 'Cursor/User', windsurf=home / SUPPORT / 'Windsurf/User',
                 kitty=home / '.config/kitty', alacritty=home / '.config/alacritty', wezterm=home / '.config/wezterm', iterm2=home / SUPPORT / 'iTerm2', btop=home / '.config/btop')
    for kind in options.get('apps', roots):
        roots[kind].mkdir(parents=True, exist_ok=True)
    f.settings['detectHome'] = str(home); f.manifest.write_text(json.dumps(f.settings))
    tree = lambda: {str(p): life.digest(p) for p in home.rglob('*') if p.is_file() or p.is_symlink()}
    return f, home, roots, tree


def checks(passed):
    def everything():
        f, home, roots, tree = setup('all')
        dots = f.root / 'dotfiles'; dots.mkdir()
        (roots['vscode'] / 'settings.json').write_bytes(JSONC)
        (dots / 'cursor.json').write_bytes(JSONC); (roots['cursor'] / 'settings.json').symlink_to(dots / 'cursor.json')  # Linked out of its folder.
        (dots / 'kitty.conf').write_bytes(b'# mine\nfont_size 13'); (roots['kitty'] / 'kitty.conf').symlink_to(dots / 'kitty.conf')  # No final newline.
        toml = b'# my terminal\n[window]\nopacity = 0.9\n'
        (roots['alacritty'] / 'alacritty.toml').write_bytes(toml)
        windsurf = roots['windsurf'] / 'settings.json'  # Missing on purpose.
        before, cursor_real = tree(), (dots / 'cursor.json').read_bytes()
        f.start()
        names = {a['kind']: a['on'] for a in f.call('theme', 'status')['apps']['apps']}
        assert set(names) == set(roots) and all(names.values()), names
        plan = f.call('theme', 'plan', 'apply', 'a'); changes = '\n'.join(plan['review']['changes'])
        for name in ['VS Code', 'Cursor', 'Windsurf', 'Kitty', 'Alacritty', 'WezTerm', 'iTerm2', 'btop']: assert name in changes, (name, changes)
        assert str(dots / 'cursor.json') in changes and str(dots / 'kitty.conf') in changes, changes
        steps = '\n'.join(plan['review']['next'])
        assert "config.color_scheme = 'Pilot Theme'" in steps and 'profile named Pilot Theme' in steps, steps
        assert tree() == before, 'Preview wrote'
        f.controls(allow='no'); f.call('theme', 'apply', plan['id'], ok=False); f.controls()
        assert tree() == before, 'a denied Apply wrote'
        assert f.apply()['status'] == 'applied'
        settings = (roots['vscode'] / 'settings.json').read_text()
        assert '// mine' in settings and '/* keep */' in settings and strip_jsonc(settings)['editor.fontSize'] == 14, settings
        colours = strip_jsonc(settings)['workbench.colorCustomizations']
        assert colours['editor.background'] == f.packs[0]['palette']['background'] and 'terminal.ansiBrightWhite' in colours
        assert (roots['cursor'] / 'settings.json').is_symlink() and 'workbench.colorCustomizations' in (dots / 'cursor.json').read_text()
        assert json.loads(windsurf.read_text())['workbench.colorCustomizations']
        assert (roots['kitty'] / 'kitty.conf').is_symlink() and f'include {roots["kitty"]}/pilot-theme.conf' in (dots / 'kitty.conf').read_text()
        assert re.search(r'^color15 #', (roots['kitty'] / 'pilot-theme.conf').read_text(), re.M)
        parsed = tomllib.loads((roots['alacritty'] / 'alacritty.toml').read_text())
        assert parsed['general']['import'] == [str(roots['alacritty'] / 'pilot-theme.toml')] and parsed['window']['opacity'] == .9, parsed
        assert tomllib.loads((roots['alacritty'] / 'pilot-theme.toml').read_text())['colors']['normal']['red'].startswith('#')
        scheme = tomllib.loads((roots['wezterm'] / 'colors/Pilot Theme.toml').read_text())
        assert len(scheme['colors']['ansi']) == 8 and scheme['metadata']['name'] == 'Pilot Theme', scheme
        profile = json.loads((roots['iterm2'] / 'DynamicProfiles/pilot-theme.json').read_text())['Profiles'][0]
        assert profile['Name'] == 'Pilot Theme' and profile['Guid'] and 0 <= profile['Ansi 15 Color']['Red Component'] <= 1, profile
        assert not (roots['wezterm'] / 'wezterm.lua').exists(), 'wrote a Lua config'
        assert f.apply('b')['status'] == 'applied'
        f.stop(); f.start()
        # ln -sf to the same target is no change.
        (roots['kitty'] / 'kitty.conf').unlink(); (roots['kitty'] / 'kitty.conf').symlink_to(dots / 'kitty.conf')
        assert f.restore()['status'] == 'restored'
        assert tree() == before and (dots / 'cursor.json').read_bytes() == cursor_real and (dots / 'kitty.conf').read_bytes() == b'# mine\nfont_size 13', 'Restore was not exact'
        assert not (roots['wezterm'] / 'colors').exists() and not (roots['iterm2'] / 'DynamicProfiles').exists(), 'a made folder stayed'
        f.stop()

    def alacritty_general():
        for text, label in [(b'[general]\nlive_config_reload = true\n\n[window]\nopacity = 1.0\n', 'g'), (b'', 'e')]:
            f, home, roots, tree = setup('ag' + label, apps=['alacritty'])
            target = roots['alacritty'] / 'alacritty.toml'
            if text: target.write_bytes(text)
            before = tree(); f.start(); assert f.apply()['status'] == 'applied'
            parsed = tomllib.loads(target.read_text())
            assert parsed['general']['import'] == [str(roots['alacritty'] / 'pilot-theme.toml')], parsed
            if text: assert parsed['general']['live_config_reload'] is True
            assert f.restore()['status'] == 'restored' and tree() == before, target.read_bytes() if target.exists() else None
            f.stop()
        f, home, roots, tree = setup('ad', apps=['alacritty'])
        (roots['alacritty'] / 'alacritty.toml').write_bytes(b'general.live_config_reload = true\n')
        before = tree(); f.start(); plan = f.call('theme', 'plan', 'apply', 'a')
        assert [s for s in plan['review']['skipped'] if s.startswith('Alacritty skipped') and 'dotted' in s], plan['review']
        f.call('theme', 'apply', plan['id']); assert tree() == before and tomllib.loads((roots['alacritty'] / 'alacritty.toml').read_text())
        f.stop()
        f, home, roots, tree = setup('ai', apps=['alacritty'])
        (roots['alacritty'] / 'alacritty.toml').write_bytes(b'[general]\nimport = ["mine.toml"]\n')
        before = tree(); f.start(); plan = f.call('theme', 'plan', 'apply', 'a')
        line = [s for s in plan['review']['skipped'] if s.startswith('Alacritty skipped')]
        assert line and 'import list' in line[0] and not [c for c in plan['review']['changes'] if 'Alacritty' in c], plan['review']
        f.call('theme', 'apply', plan['id']); assert tree() == before, 'an import list was edited'
        f.stop()

    def made_settings_survive_the_editor():
        # VS Code and its family rewrite settings.json whenever a setting changes in their UI.
        f, home, roots, tree = setup('es', apps=['windsurf'])
        target = roots['windsurf'] / 'settings.json'
        f.start(); assert f.apply()['status'] == 'applied'
        made = target.read_text(); assert json.loads(made)['workbench.colorCustomizations']
        target.write_text(made.replace('{', '{ "editor.fontSize": 15,', 1))
        assert f.restore()['status'] == 'restored', target.read_text()
        assert json.loads(target.read_text()) == {'editor.fontSize': 15}, target.read_text()
        f.stop()
        f, home, roots, tree = setup('et', apps=['windsurf'])
        target = roots['windsurf'] / 'settings.json'; before = tree(); f.start()
        assert f.apply()['status'] == 'applied' and target.exists()
        assert f.restore()['status'] == 'restored' and tree() == before and not target.exists(), 'a made file stayed'
        f.stop()

    def absent_and_switches():
        f, home, roots, tree = setup('sw', apps=['vscode', 'kitty'])
        (roots['vscode'] / 'settings.json').write_bytes(JSONC); (roots['kitty'] / 'kitty.conf').write_bytes(b'font_size 13\n')
        f.start(); plan = f.call('theme', 'plan', 'apply', 'a'); shown = '\n'.join(plan['review']['changes'])
        assert 'VS Code' in shown and 'Kitty' in shown and not any(n in shown for n in ['Cursor', 'Windsurf', 'Alacritty', 'WezTerm', 'iTerm2', 'btop']), shown
        assert not (home / '.config/alacritty').exists(), 'made a config for an absent app'
        before = (roots['vscode'] / 'settings.json').read_bytes()
        f.call('theme', 'follow', 'vscode', 'off')
        assert f.apply()['status'] == 'applied' and (roots['vscode'] / 'settings.json').read_bytes() == before and (roots['kitty'] / 'pilot-theme.conf').exists()
        f.stop(); f.start()
        assert {a['kind']: a['on'] for a in f.call('theme', 'status')['apps']['apps']}['vscode'] is False
        f.call('theme', 'follow', 'vscode', 'on'); assert f.apply('b')['status'] == 'applied' and b'colorCustomizations' in (roots['vscode'] / 'settings.json').read_bytes()
        f.call('theme', 'follow', 'kitty', 'off')
        assert f.apply()['status'] == 'applied' and not (roots['kitty'] / 'pilot-theme.conf').exists(), 'switching off did not release Kitty'
        assert f.restore()['status'] == 'restored' and (roots['vscode'] / 'settings.json').read_bytes() == before
        f.stop()

    def owned_values():
        f, home, roots, tree = setup('ov', apps=['vscode', 'wezterm', 'kitty'])
        settings = roots['vscode'] / 'settings.json'
        mine = b'{\n  "workbench.colorCustomizations": {"editor.background": "#123456"}\n}\n'; settings.write_bytes(mine)
        (roots['kitty'] / 'pilot-theme.conf').write_bytes(b'# somebody else\n')
        (roots['wezterm'] / 'colors').mkdir()
        f.start(); plan = f.call('theme', 'plan', 'apply', 'a')
        assert [s for s in plan['review']['skipped'] if s.startswith('Kitty skipped') and 'somewhere else' in s], plan['review']
        assert [w for w in plan['warnings'] if 'colorCustomizations comes back' in w], plan['warnings']
        assert f.call('theme', 'apply', plan['id'])['status'] == 'applied' and b'#123456' not in settings.read_bytes()
        mine = settings.read_bytes().replace(b'editor.background', b'editor.background2'); settings.write_bytes(mine)
        answer = f.restore()
        assert answer['status'] == 'restored' and [k for k in answer['kept'] if 'settings.json' in k] and settings.read_bytes() == mine, answer
        f.stop()

    def reformatted():
        # Review blocker 1: format on save re-indents, reorders keys and adds a setting. The colours are still Pilot's.
        f, home, roots, tree = setup('fm', apps=['vscode', 'kitty'])
        settings = roots['vscode'] / 'settings.json'; settings.write_bytes(JSONC); (roots['kitty'] / 'kitty.conf').write_bytes(b'font_size 13\n')
        f.start(); assert f.apply()['status'] == 'applied'
        value = strip_jsonc(settings.read_text()); value['workbench.colorCustomizations'] = dict(reversed(list(value['workbench.colorCustomizations'].items())))
        value['editor.tabSize'] = 2; settings.write_text(json.dumps(value, indent=4))
        plan = f.call('theme', 'plan', 'apply', 'b'); assert plan['review']['kept'] == [], plan['review']
        assert f.call('theme', 'apply', plan['id'])['status'] == 'applied'
        assert strip_jsonc(settings.read_text())['workbench.colorCustomizations']['editor.background'] == f.packs[1]['palette']['background']
        settings.write_text(json.dumps(strip_jsonc(settings.read_text()), indent='\t'))
        answer = f.restore(); assert answer['status'] == 'restored' and answer['kept'] == [], answer
        assert strip_jsonc(settings.read_text()) == {**strip_jsonc(JSONC.decode()), 'editor.tabSize': 2}, settings.read_text()
        assert (roots['kitty'] / 'kitty.conf').read_bytes() == b'font_size 13\n' and not (roots['kitty'] / 'pilot-theme.conf').exists()
        # The person's own colour: it stays, only that claim goes, and Kitty still follows.
        f.apply(); value = strip_jsonc(settings.read_text()); value['workbench.colorCustomizations']['editor.background'] = '#010203'
        settings.write_text(json.dumps(value, indent=2))
        plan = f.call('theme', 'plan', 'apply', 'b'); assert [k for k in plan['review']['kept'] if 'settings.json' in k], plan['review']
        answer = f.call('theme', 'apply', plan['id']); assert answer['status'] == 'applied' and answer['kept'], answer
        assert strip_jsonc(settings.read_text())['workbench.colorCustomizations']['editor.background'] == '#010203'
        assert f.packs[1]['palette']['background'] in (roots['kitty'] / 'pilot-theme.conf').read_text()
        assert f.restore()['status'] == 'restored' and strip_jsonc(settings.read_text())['workbench.colorCustomizations']['editor.background'] == '#010203'
        assert not (roots['kitty'] / 'pilot-theme.conf').exists(); f.stop()

    def installed_without_folders():
        # Review blocker 2: installed with no config folder yet, and WezTerm configured by ~/.wezterm.lua alone.
        f, home, roots, tree = setup('in', apps=[])
        (home / SUPPORT).mkdir(parents=True)
        for bundle in ['Visual Studio Code.app', 'kitty.app', 'Alacritty.app', 'iTerm.app']: (home / 'Applications' / bundle).mkdir(parents=True)
        lua = home / '.wezterm.lua'; lua.write_text('local wezterm = require "wezterm"\nreturn {}\n')
        before = tree(); f.start()
        plan = f.call('theme', 'plan', 'apply', 'a'); shown = '\n'.join(plan['review']['changes'])
        for name in ['VS Code', 'Kitty', 'Alacritty', 'WezTerm', 'iTerm2']: assert name in shown, (name, plan['review'])
        assert 'Cursor' not in shown and 'Windsurf' not in shown, shown
        assert tree() == before and not (home / '.config').exists() and not (home / SUPPORT / 'Code').exists(), 'Preview made a folder'
        assert f.call('theme', 'apply', plan['id'])['status'] == 'applied'
        for path in [roots['kitty'] / 'kitty.conf', roots['kitty'] / 'pilot-theme.conf', roots['alacritty'] / 'alacritty.toml', roots['wezterm'] / 'colors/Pilot Theme.toml',
                     roots['vscode'] / 'settings.json', roots['iterm2'] / 'DynamicProfiles/pilot-theme.json']: assert path.exists(), path
        assert tomllib.loads((roots['alacritty'] / 'alacritty.toml').read_text())['general']['import'] == [str(roots['alacritty'] / 'pilot-theme.toml')]
        assert lua.read_text() == 'local wezterm = require "wezterm"\nreturn {}\n', 'wrote the Lua config'
        assert f.restore()['status'] == 'restored' and tree() == before, 'Restore was not exact'
        assert not (home / '.config').exists() and not (home / SUPPORT / 'Code').exists() and not (home / SUPPORT / 'iTerm2').exists(), 'a made folder stayed'
        f.stop()
        # Alacritty reading ~/.alacritty.toml: a new ~/.config one would hide it, so it skips and says why.
        f, home, roots, tree = setup('ah', apps=[])
        (home / 'Applications/Alacritty.app').mkdir(parents=True); (home / '.alacritty.toml').write_text('[window]\nopacity = 0.9\n')
        before = tree(); f.start(); plan = f.call('theme', 'plan', 'apply', 'a')
        assert [x for x in plan['review']['skipped'] if x.startswith('Alacritty skipped') and '.alacritty.toml' in x], plan['review']
        f.call('theme', 'apply', plan['id']); assert tree() == before and not (home / '.config').exists(); f.stop()

    def ghostty_reloads():
        # Apply and Restore press Ghostty › Reload Configuration themselves; the fixture records the press, never a real menu.
        f, home, roots, tree = setup('gr', apps=[])
        f.start(); answer = f.apply()
        assert answer['ghostty'] == 'reloaded' and not [n for n in answer['next'] if 'Ghostty' in n], answer
        log = f.root / 'state/ghostty-reloads.log'
        assert log.read_text() == 'Ghostty › Reload Configuration\n', log.read_text()
        f.controls(ghostty='missing'); answer = f.restore()
        assert answer['ghostty'].startswith('no Reload') and [n for n in answer['next'] if 'Cmd+Shift+,' in n], answer
        f.controls(ghostty='closed'); answer = f.apply()
        assert answer['ghostty'].startswith('not running') and not [n for n in answer['next'] if 'Ghostty' in n], answer
        f.controls(); assert f.restore()['ghostty'] == 'reloaded' and log.read_text().count('Reload') == 2; f.stop()

    def refuses():
        f, home, roots, tree = setup('rf', apps=['kitty'])
        dots = f.root / 'dotfiles'; dots.mkdir(); (roots['kitty'] / 'kitty.conf').symlink_to(dots / 'gone.conf')
        f.start(); plan = f.call('theme', 'plan', 'apply', 'a')
        assert [s for s in plan['review']['skipped'] if s.startswith('Kitty skipped') and 'broken' in s], plan['review']
        f.stop()
        f, home, roots, tree = setup('rg', apps=['kitty'])
        (dots2 := f.root / 'dotfiles').mkdir(); (dots2 / 'c').write_bytes(b'x'); (roots['kitty'] / 'pilot-theme.conf').symlink_to(dots2 / 'c')
        f.start(); plan = f.call('theme', 'plan', 'apply', 'a')
        assert [s for s in plan['review']['skipped'] if s.startswith('Kitty skipped')], plan['review']
        assert (dots2 / 'c').read_bytes() == b'x'; f.stop()

    def many():
        f, home, roots, tree = setup('mn')
        (roots['kitty'] / 'kitty.conf').write_bytes(b''); f.start()
        f.apply(); f.stop()
        allow = [x for x in (f.root / 'host-1.log').read_text().splitlines() if x.startswith('THEME Allow asked:')][-1]
        assert len(allow) < 1200 and all(n in allow for n in ['VS Code', 'Cursor', 'Windsurf', 'Kitty', 'Alacritty', 'WezTerm', 'iTerm2', 'btop']), allow

    def btop():
        # btop v1.4.8 (its source): every key of its Default_theme, the last color_theme line wins, and it rewrites
        # btop.conf from memory, comments dropped, when the file lacks its version header or an option changed.
        keys = ['main_bg', 'main_fg', 'title', 'hi_fg', 'selected_bg', 'selected_fg', 'inactive_fg', 'graph_text', 'meter_bg', 'proc_misc',
                'cpu_box', 'mem_box', 'net_box', 'proc_box', 'div_line'] + [f'{g}_{s}' for g in ['temp', 'cpu', 'free', 'cached', 'available', 'used', 'download', 'upload', 'process']
                for s in ['start', 'mid', 'end']] + ['proc_pause_bg', 'proc_follow_bg', 'proc_banner_bg', 'proc_banner_fg', 'followed_bg', 'followed_fg']
        made = b'#? Config file for btop v.1.4.8\n\n#* Name of a btop++/bpytop/bashtop formatted ".theme" file.\ncolor_theme = "Default"\n\n#* Terminal background transparency.\ntheme_background = true\n\nupdate_ms = 2000\n'
        def theme(path):
            return dict(re.findall(r'^theme\[(\w+)\]="(#[0-9A-Fa-f]{6})"$', path.read_text(), re.M))
        for label, conf in [('sven', None), ('made', made)]:
            f, home, roots, tree = setup('bt' + label, apps=['btop'])
            (roots['btop'] / 'themes').mkdir()  # The shape on Sven's Mac: an empty themes folder, no btop.conf yet.
            for name in ['jade', 'porcelain']:
                pack = json.loads((life.REPO / 'Packaging/ThemePacks' / name / 'manifest.json').read_text())
                # Stock IDs are reserved, so each palette goes in as a pack of its own.
                pack['id'] = 'fx-' + name; pack['adapters'] = {'ghostty': {}}; (f.root / 'packs' / pack['id']).mkdir(); f.save_pack(pack)
            target, generated = roots['btop'] / 'btop.conf', roots['btop'] / 'themes/pilot.theme'
            if conf: target.write_bytes(conf)
            before = tree(); f.start()
            plan = f.call('theme', 'plan', 'apply', 'fx-jade')
            assert [c for c in plan['review']['changes'] if c.startswith('btop')], plan['review']
            assert [n for n in plan['review']['next'] if 'Ctrl+R' in n], plan['review']['next']
            assert tree() == before, 'Preview wrote'
            for name in ['jade', 'porcelain']:
                assert f.apply('fx-' + name)['status'] == 'applied'
                palette = json.loads((life.REPO / 'Packaging/ThemePacks' / name / 'manifest.json').read_text())['palette']
                got = theme(generated)
                assert list(got) == keys, sorted(set(keys) ^ set(got))
                assert got['main_bg'] == palette['background'] and got['cpu_box'] == palette['accent'] and got['process_end'] == palette['magenta'], got
                text = target.read_text()
                assert re.findall(r'^color_theme = "(.*)"$', text, re.M)[-1] == 'pilot' and re.findall(r'^theme_background = (\w+)$', text, re.M)[-1] == 'false', text
                print(f'  btop {label} {name}: main_bg {got["main_bg"]} main_fg {got["main_fg"]} hi_fg {got["hi_fg"]} boxes {got["cpu_box"]} selected_bg {got["selected_bg"]}', flush=True)
            print(f'  btop {label} btop.conf after: ' + repr(target.read_bytes()[-120:]), flush=True)
            assert f.restore()['status'] == 'restored' and tree() == before, (target.read_bytes() if target.exists() else None)
            assert (target.read_bytes() == conf) if conf else not target.exists()
            f.stop()
        # Sven's shape, then btop's first quit: the btop.conf Pilot made has no version header, so btop rewrites it whole.
        # Real btop when it is here (in a throwaway XDG_CONFIG_HOME), else the shape it writes. Other apps still follow.
        f, home, roots, tree = setup('bts', apps=['btop', 'kitty'])
        (roots['btop'] / 'themes').mkdir(); (roots['kitty'] / 'kitty.conf').write_bytes(b'font_size 13\n')
        target = roots['btop'] / 'btop.conf'; f.start()
        assert f.apply()['status'] == 'applied' and b'Pilot theme pack' in target.read_bytes()
        btop = Path('/opt/homebrew/bin/btop')
        if btop.exists():
            import fcntl, pty, select, struct, termios, time
            pid, fd = pty.fork()
            if pid == 0:
                os.environ.update(XDG_CONFIG_HOME=str(home / '.config'), TERM='xterm-256color'); os.execv(str(btop), ['btop'])
            fcntl.ioctl(fd, termios.TIOCSWINSZ, struct.pack('HHHH', 40, 120, 0, 0))  # btop quits on a 0x0 terminal
            def drain(t):
                end = time.time() + t
                while time.time() < end:
                    if select.select([fd], [], [], .1)[0]:
                        try: os.read(fd, 65536)
                        except OSError: return
            drain(2.5); os.write(fd, b'q'); drain(2); os.waitpid(pid, 0)
        else:
            target.write_bytes(b'#? Config file for btop v.1.4.8\n\ncolor_theme = "pilot"\n\ntheme_background = false\n')
        rewritten = target.read_bytes()
        assert rewritten.startswith(b'#? Config file for btop') and b'Pilot theme pack' not in rewritten, rewritten[:200]
        plan = f.call('theme', 'plan', 'apply', 'b'); assert [k for k in plan['review']['kept'] if 'btop.conf' in k], plan['review']
        kitty = (roots['kitty'] / 'pilot-theme.conf').read_bytes()
        assert f.call('theme', 'apply', plan['id'])['status'] == 'applied' and target.read_bytes() == rewritten
        assert (roots['kitty'] / 'pilot-theme.conf').read_bytes() != kitty and theme(roots['btop'] / 'themes/pilot.theme')['main_bg'] == f.packs[1]['palette']['background']
        answer = f.restore(); assert answer['status'] == 'restored', answer
        left = target.read_text()
        assert not (roots['btop'] / 'themes/pilot.theme').exists() and (roots['kitty'] / 'kitty.conf').read_bytes() == b'font_size 13\n'
        print(f"  btop sven-shape after btop's quit ({'real btop' if btop.exists() else 'its shape'}): kept {[k for k in answer.get('kept', []) if 'btop' in k]}; left "
              + repr([l for l in left.splitlines() if l.startswith(('color_theme', 'theme_background'))]), flush=True)
        f.stop()
        # A btop that rewrites btop.conf (an option changed, or the file had no header) keeps Pilot's values and drops its
        # markers: Pilot then counts the file as the person's, keeps following through pilot.theme, and Restore leaves it.
        f, home, roots, tree = setup('btr', apps=['btop'])
        target = roots['btop'] / 'btop.conf'; target.write_bytes(made); f.start()
        assert f.apply()['status'] == 'applied'
        rewritten = made.replace(b'"Default"', b'"pilot"').replace(b'= true', b'= false'); target.write_bytes(rewritten)
        plan = f.call('theme', 'plan', 'apply', 'b'); assert [k for k in plan['review']['kept'] if 'btop.conf' in k], plan['review']
        assert f.call('theme', 'apply', plan['id'])['status'] == 'applied' and target.read_bytes() == rewritten
        assert theme(roots['btop'] / 'themes/pilot.theme')['main_bg'] == f.packs[1]['palette']['background']
        assert f.restore()['status'] == 'restored' and target.read_bytes() == rewritten and not (roots['btop'] / 'themes/pilot.theme').exists()
        f.stop()

    for label, check in [('all eight follow together, Preview names real files, links stay, Restore byte exact', everything),
                         ('Alacritty inside an existing [general], with no file, and skipped with its own import list', alacritty_general),
                         ('a settings file Pilot made survives the editor rewriting it', made_settings_survive_the_editor),
                         ('an absent app gets nothing; each switch persists and releases', absent_and_switches),
                         ("owned-value rules: someone else's file skips, a later edit stays the person's, own colours come back", owned_values),
                         ('a reformatted settings.json is still Pilot\'s; a colour the person changed stays theirs while the rest follows', reformatted),
                         ('installed apps with no config folder yet, and WezTerm by ~/.wezterm.lua, follow; Apply makes the folders and Restore removes them; Alacritty on ~/.alacritty.toml skips with why', installed_without_folders),
                         ('Apply and Restore reload Ghostty through its menu; a missing item or a closed Ghostty says so plainly', ghostty_reloads),
                         ('a broken link and a link for the generated file skip the app and write nothing', refuses),
                         ('btop: every theme key, its config set and put back byte for byte, with a config and without; a btop rewrite keeps it the person\'s', btop),
                         ('Allow names all eight', many)]:
        check(); passed('apps ' + label)


def run(seam_only=False, fixes_only=False):
    assert not seam_only and not fixes_only, 'apps has one complete proof'
    life.EVIDENCE.mkdir(parents=True, exist_ok=True)
    checks(lambda text: print('PASS ' + text, flush=True))
    print('PASS apps', flush=True)
