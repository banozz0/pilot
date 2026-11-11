"""Obsidian real CLI/private theme-only host proof. All vaults are newly created temporary data."""
import base64
import concurrent.futures
import importlib.util
import json
import os
from pathlib import Path
import re
import time

spec = importlib.util.spec_from_file_location('theme_zed', Path(__file__).with_name('zed.py'))
zed = importlib.util.module_from_spec(spec)
spec.loader.exec_module(zed)
life = zed.life
EVIDENCE = Path(os.environ.get('PILOT_THEME_PROOF_EVIDENCE') or Path.home() / '.local/state/spec' / 'theme-system/T4/o')
life.EVIDENCE = EVIDENCE


def document(data):
    text = data.decode('utf-8-sig')
    text = re.sub(r'/\*.*?\*/|//[^\r\n]*', '', text, flags=re.S)
    return json.loads(re.sub(r',\s*([}\]])', r'\1', text))



def contrast(a, b):
    def lum(h):
        c = [int(h.lstrip('#')[i:i + 2], 16) / 255 for i in (0, 2, 4)]
        c = [x / 12.92 if x <= .03928 else ((x + .055) / 1.055) ** 2.4 for x in c]
        return .2126 * c[0] + .7152 * c[1] + .0722 * c[2]
    x, y = sorted([lum(a), lum(b)], reverse=True)
    return (x + .05) / (y + .05)

class Fixture(zed.Fixture):
    def __init__(self, label='o', selected=True):
        super().__init__(label)
        self.vaults, self.originals, self.assets = [], [], []
        for index, folder in enumerate(['.obsidian', '.obsidian-work', '.opted-out']):
            root = self.root / 'vaults' / str(index)
            config = root / folder
            (config / 'snippets').mkdir(parents=True)
            (config / 'plugins/fixture').mkdir(parents=True)
            (root / 'note.md').write_bytes(b'TEMP fixture note, never a personal vault\n')
            (config / 'plugins/fixture/data.json').write_bytes(b'{"temp-plugin":true}\n')
            (config / 'snippets/personal.css').write_bytes(b'body { --text-normal: #010203 !important; }\n')
            (config / 'manifest.json').write_bytes(b'{"temp-fixture":true}\n')
            data = (b'\xef\xbb\xbf{\r\n // Keep comment\r\n "cssTheme":"Keep Theme", "theme":"system",\r\n "textFontFamily":"Keep Font", "baseFontSize":17,\r\n "enabledCssSnippets": ["personal", /* Keep member comment */' +
                    (b'"pilot-theme",' if index == 1 else b'') + b'],\r\n "unrelated":{"x":[1,2,]},\r\n}\r\n')
            (config / 'appearance.json').write_bytes(data)
            (config / 'appearance.json').chmod(0o640)
            self.originals.append(data)
            asset = b'.theme-light { --text-normal: #aabbcc; }\n' if index == 1 else None
            if asset is not None: (config / 'snippets/pilot-theme.css').write_bytes(asset)
            self.assets.append(asset)
            self.vaults.append(dict(root=str(root), config=folder + '/appearance.json', generated=folder + '/snippets/pilot-theme.css'))
        self.settings['obsidian'] = self.vaults[:2] if selected else []
        self.settings['obsidianOptOut'] = False
        self.manifest.write_text(json.dumps(self.settings))
        for pack in self.packs:
            pack['adapters']['obsidian'] = {}; self.save_pack(pack)
        self.untouched = self.protected()
        self.baseline = self.snapshot(); self.receipt_before(); self.checkpoint('original')

    def path(self, index=0, asset=False):
        vault = self.vaults[index]
        return Path(vault['root']) / vault['generated' if asset else 'config']

    def snapshot(self):
        result = super().snapshot()
        for p in (self.root / 'vaults').rglob('*'):
            if p.is_file() or p.is_symlink(): result[str(p.relative_to(self.root))] = life.digest(p)
        return result

    def protected(self):
        return {str(p.relative_to(self.root)): life.digest(p) for p in (self.root / 'vaults').rglob('*')
                if p.is_file() and (p.name in ['note.md', 'data.json', 'manifest.json', 'personal.css'] or '/vaults/2/' in str(p))}

    def checkpoint(self, label):
        paths = [self.path(i, asset) for i in range(2) for asset in [False, True]]
        value = dict(manifest=self.snapshot(), targets={str(p): None if not p.exists() else base64.b64encode(p.read_bytes()).decode() for p in paths})
        (self.root / (label + '.json')).write_text(json.dumps(value, indent=2))
        return value

    def receipt(self):
        super().receipt()
        if hasattr(self, 'untouched'):
            assert self.protected() == self.untouched, 'notes/plugins/manifest/opted-out vault changed'
            self.checkpoint('final')
            (self.root / 'protected-manifest.json').write_text(json.dumps(self.untouched, indent=2))


def comment_removals(fixture, passed):
    """Actual CLI Restore/restart recovery; byte expectations are independent fixture literals."""
    token = b'"pilot-theme"'
    cases = [
        # None means property deletion must refuse, leaving the entire resource unchanged.
        ('exact', b'{}', b'{"enabledCssSnippets":/*Keep*/["pilot-theme"]}', None, [b'/*Keep*/']),
        ('key-block', b'{}', b'{"enabledCssSnippets"/*Key*/:["pilot-theme"]}', None, [b'/*Key*/']),
        ('key-line', b'{}', b'{"enabledCssSnippets"// Key\r\n:["pilot-theme"]}', None, [b'// Key\r\n']),
        ('colon-line', b'{}', b'{"enabledCssSnippets":// Value\n["pilot-theme"]}', None, [b'// Value\n']),
        ('last-property', b'{}', b'{"later":true,"enabledCssSnippets":/*Last*/["pilot-theme"]}', None, [b'/*Last*/']),
        ('bom-escaped', b'{}', b'\xef\xbb\xbf{\r\n"enabledCssSnip\\u0070ets"/* K */:\r\n/* V */["pilot-theme"]\r\n}', None, [b'/* K */', b'/* V */']),
        ('absent-file', None, b'{"enabledCssSnippets":/*Absent*/["pilot-theme"]}', None, [b'/*Absent*/']),
        ('inside-before', b'{}', b'{"enabledCssSnippets":[/*Inside*/"pilot-theme"]}', b'{"enabledCssSnippets":[/*Inside*/]}', [b'/*Inside*/']),
        ('inside-after', b'{}', b'{"enabledCssSnippets":["pilot-theme"// Inside\r\n]}', b'{"enabledCssSnippets":[// Inside\r\n]}', [b'// Inside\r\n']),
        ('inside-comma', b'{}', b'{"enabledCssSnippets":["pilot-theme"/*Element*/,]}', b'{"enabledCssSnippets":[/*Element*/]}', [b'/*Element*/']),
        ('property-comma', b'{}', b'{"enabledCssSnippets":["pilot-theme"]/*Tail*/,"later":true}', b'{/*Tail*/"later":true}', [b'/*Tail*/']),
        ('property-line', b'{}', b'{"enabledCssSnippets":["pilot-theme"]// Tail\r\n,"later":true}', b'{// Tail\r\n"later":true}', [b'// Tail\r\n']),
        ('later-members', b'{}', b'{"enabledCssSnippets"/*Key*/:/*Value*/[/*A*/"personal",/*B*/"pilot-theme"/*C*/,/*D*/"later",],"font":"Keep \\"Q\\""}', b'{"enabledCssSnippets"/*Key*/:/*Value*/[/*A*/"personal",/*B*//*C*//*D*/"later",],"font":"Keep \\"Q\\""}', [b'/*Key*/', b'/*Value*/', b'/*A*/', b'/*B*/', b'/*C*/', b'/*D*/']),
        ('existing-empty', b'{"enabledCssSnippets":[]}', b'{"enabledCssSnippets":/*Existing*/["pilot-theme"]}', b'{"enabledCssSnippets":/*Existing*/[]}', [b'/*Existing*/']),
        ('comment-like-string', b'{}', b'{"url":"https://fixture/\\u002a","enabledCssSnippets":["pilot-theme"]}', b'{"url":"https://fixture/\\u002a"}', []),
    ]
    for operation in ['restore', 'rollback']:
        for name, original, before, after, comments in cases:
            f = fixture('cm'); p = f.path(); pending = f.root/'state/pending.json'
            f.settings['obsidian'] = f.vaults[:1]; f.manifest.write_text(json.dumps(f.settings))
            for pack in f.packs: pack['adapters'] = {'obsidian': {}}; f.save_pack(pack)
            if original is None: p.unlink()
            else: p.write_bytes(original)
            f.receipt_before(); f.checkpoint('comment-original')
            (f.root/'comment-case.json').write_text(json.dumps(dict(operation=operation, name=name, original=None if original is None else original.hex(), before=before.hex(), after=None if after is None else after.hex(), comments=[c.hex() for c in comments]), indent=2))
            unrelated = {k:v for k,v in f.snapshot().items() if k not in [str(p.relative_to(f.root)), str(f.path(0,True).relative_to(f.root))] and not k.startswith('state/')}

            def observe(expected, label):
                f.checkpoint(label)
                assert p.read_bytes() == expected, (operation, name, label, p.read_bytes(), expected)
                assert all(p.read_bytes().count(c) == before.count(c) for c in comments), (name, comments)
                assert {k:v for k,v in f.snapshot().items() if k in unrelated} == unrelated
                assert f.call('ping') == 'pong'  # Never accept host death as a conflict.

            def blocked():
                answer = f.call('theme','plan','restore',ok=False)
                assert answer['error']['code'] == 'bad-value', answer
                assert f.call('ping') == 'pong'

            f.start(); assert f.call('theme','status')['effects'] == 'recording only'
            plan = f.call('theme','plan','apply','a')
            index = next(i for i,c in enumerate(plan['changes']) if c['path'] == str(p))
            if operation == 'restore':
                assert f.call('theme','apply',plan['id'])['status'] == 'applied'
                p.write_bytes(before); f.checkpoint('comment-before')
                if after is None:
                    snapshot = f.snapshot(); blocked(); assert f.snapshot() == snapshot
                    observe(before, 'comment-conflict'); f.stop(); f.start(); blocked(); assert f.snapshot() == snapshot
                    # Explicit later member resolves removal ambiguity without deleting any comment.
                    p.write_bytes(before.replace(token, token + b',"later"'))
                    after = before.replace(token, b'"later"')
                result = f.restore(); assert result['status'] == 'restored' and result['files'] == 'verified', result
                observe(after, 'comment-restored'); assert not pending.exists()
                targets = f.checkpoint('comment-idempotent-before')['targets']; f.restore()
                assert f.checkpoint('comment-idempotent-after')['targets'] == targets
            else:
                f.controls(crash='after-write:'+str(index)); f.call('theme','apply',plan['id'],ok=False); f.stop(crashed=True)
                assert pending.exists(); (f.root/'comment-pending-before.json').write_bytes(pending.read_bytes())
                p.write_bytes(before); f.checkpoint('comment-interrupted'); f.controls(); f.start()
                expected = before if after is None else after
                observe(expected, 'comment-recovered'); retained = after is None or name.startswith('inside-')
                assert pending.exists() == retained, (name, retained)
                if retained:
                    blocked(); snapshot = f.snapshot(); journal = pending.read_bytes(); f.stop()
                    assert 'recovery retained' in (f.root/f'host-{f.counter}.log').read_text()
                    f.start(); observe(expected, 'comment-retry'); assert f.snapshot() == snapshot and pending.read_bytes() == journal
                    if after is None:
                        p.write_bytes(before.replace(token, token + b',"later"')); resolved = before.replace(token,b'"later"')
                    else:
                        resolved = after.replace(b']',b'"later"]',1); p.write_bytes(resolved)
                    f.stop(); f.start(); observe(resolved, 'comment-resolved')
                assert not pending.exists(); assert f.call('theme','status')['selected'] is None
                snapshot = f.snapshot(); f.stop()
                assert 'rollback verified' in (f.root/f'host-{f.counter}.log').read_text()
                f.start(); assert f.snapshot() == snapshot
                observe(resolved if retained else after, 'comment-idempotent')
            f.stop(); f.receipt()
    passed('30 comment-removal Restore/rollback fixtures: full bytes, key/colon/interior/trailing line+block comments, escapes/BOM/CRLF, absent file/container/existing empty, later members, fail-closed no-write conflicts, retained recovery/retry/resolution/idempotence; hosts responsive and joined')


def run(seam_only=False, fixes_only=False):
    assert not fixes_only, 'obsidian has no fixes-only shortcut'
    EVIDENCE.mkdir(parents=True, exist_ok=True)
    fixtures, checks = [], []

    def fixture(*args, **kwargs):
        f = Fixture(*args, **kwargs); fixtures.append(f); return f

    def passed(text):
        checks.append(text); print('PASS ' + text, flush=True)
        (EVIDENCE / 'obsidian.log').write_text('\n'.join('PASS ' + x for x in checks) + '\n')

    def negative(f, message=None):
        before = f.snapshot(); answer = f.call('theme', 'plan', 'apply', 'a', ok=False)
        assert answer.get('error', {}).get('code') == 'bad-value', answer
        if message: assert message.lower() in json.dumps(answer).lower(), answer
        assert f.snapshot() == before

    def palette(f, pack, modes=None):
        modes = dict(modes or {('dark' if pack['dark'] else 'light'): pack['palette']})
        # The theme shows in both of Obsidian's modes (build 2168): a mode with no palette of its own takes the theme's.
        for mode in ['dark', 'light']: modes.setdefault(mode, pack['palette'])
        for index in range(2):
            css = f.path(index, True).read_text()
            assert set(re.findall(r'\.theme-(dark|light)', css)) == set(modes)
            assert not re.search(r'@|!important|url\(|font|padding|margin|https?://', css)
            blocks = {mode: body for selector, body in re.findall(r'((?:\.theme-(?:dark|light)(?:, )?)+) \{\n([^}]+)\}', css) for mode in re.findall(r'\.theme-(dark|light)', selector)}
            for mode, colors in modes.items():
                values = dict(re.findall(r'--([a-z-]+): (#[0-9a-fA-F]{6});', blocks[mode]))
                grounds = [colors[r] for r in ['background', 'lighter_background', 'dark_background', 'darker_background'] if r in colors]
                for key, role in {'background-primary':'background', 'background-secondary':'dark_background', 'text-normal':'foreground', 'text-muted':'muted', 'text-accent':'accent', 'text-selection':'selection', 'text-error':'red', 'code-keyword':'magenta', 'code-string':'green'}.items():
                    # Review blocker 3: text keeps the palette's colour, or moves until it reads at 4.5:1 on every ground.
                    text = key.startswith(('text-', 'code-')) and key != 'text-selection'
                    assert values[key] == colors[role] or text and all(contrast(values[key], g) >= 4.5 for g in grounds), (key, values[key], colors[role])
            assert document(f.path(index).read_bytes())['enabledCssSnippets'].count('pilot-theme') == 1
        assert f.protected() == f.untouched
        f.checkpoint('palette-' + pack['id'])

    def held(f, words, edit):
        f.controls(hold='yes')
        with concurrent.futures.ThreadPoolExecutor() as pool:
            answer = pool.submit(f.call, *words, ok=False)
            deadline = time.monotonic() + 15
            while not (f.root / 'asked').exists() and time.monotonic() < deadline: time.sleep(.03)
            assert (f.root / 'asked').exists()
            edit(); before = f.snapshot(); (f.root / 'go').touch(); answer.result(timeout=30)
        assert f.snapshot() == before

    def outcome(f, text):
        assert text in '\n'.join(p.read_text() for p in f.root.glob('host-*.log')), (f.root, text)

    try:
        f = fixture(); f.start()
        assert f.call('ping') == 'pong'
        assert {v['name'] for v in f.call('schema')['verbs']} == {'ping', 'help', 'schema', 'version', 'theme'}
        for forbidden in ['set', 'run', 'system', 'wallpaper', 'install', 'ai']: f.call(forbidden, ok=False)
        before = f.snapshot(); f.call('theme', 'show', 'a'); f.call('theme', 'check', 'a')
        plan = f.call('theme', 'plan', 'apply', 'a')
        assert len(plan['changes']) == 9  # Ghostty 2, Zed 3 (both its light and dark slots), two vaults 4.
        for vault in f.vaults[:2]: assert any(c['path'] == vault['root'] + '/' + vault['config'] and 'jsonMembership' in c['selector'] for c in plan['changes'])
        assert all(f.vaults[2]['root'] not in c['path'] for c in plan['changes'])
        for text in ['reload', 'override these colours', 'base scheme', 'dark and light colours']: assert any(text in w for w in plan['warnings'])
        assert f.snapshot() == before
        f.controls(allow='no'); f.call('theme', 'apply', plan['id'], ok=False); assert f.snapshot() == before
        f.stop(); outcome(f, 'Engine=absent settings=absent Keychain=absent production-registry=absent')
        passed('isolated composition proven before Apply: actual CLI/private 0600 socket, core/theme registry only, explicit mock roots/custom config folder; check/plan/denial write nothing; preview owns individual membership and explains precedence/coverage/reload limits')
        if seam_only: return

        comment_removals(fixture, passed)

        f.controls(); f.start(); f.apply(); palette(f, f.packs[0]); f.apply('b'); palette(f, f.packs[1])
        for i in range(2):
            p = f.path(i); p.write_bytes(p.read_bytes().replace(b'"pilot-theme"', b'"pilot-theme","later"').replace(b'Keep Font', b'Later Font'))
        f.stop(); f.start(); assert f.call('theme', 'status')['selected']['id'] == 'b'; f.restore()
        for i in range(2):
            expected = f.originals[i].replace(b'Keep Font', b'Later Font')
            # Verify every original byte outside membership, plus later membership, without normalising the product file.
            actual = f.path(i).read_bytes()
            assert actual.replace(b'"later",', b'').replace(b',"later"', b'') == expected
            assert document(actual)['enabledCssSnippets'] == (['personal','pilot-theme','later'] if i == 1 else ['personal','later'])
            assert (f.path(i, True).read_bytes() if f.path(i, True).exists() else None) == f.assets[i]
        f.zpreserved(); f.stop()
        passed('two selected vaults follow A->B->restart->Restore; original absent/existing colour assets and existing membership return; later snippets/fonts, BOM/CRLF/comments/modes/cssTheme survive; notes/plugins/manifests and opted-out vault byte-identical')

        for kind in ['absent-file', 'absent-array', 'empty-array', 'existing-element', 'escaped-element', 'trailing-array', 'empty-asset']:
            f = fixture('state')
            data = {'absent-file': None, 'absent-array': b'{"cssTheme":"Keep",\r\n}', 'empty-array': b'{"enabledCssSnippets": [ /* empty */ ],"theme":"system"}', 'existing-element': b'{"enabledCssSnippets":["personal","pilot-theme"]}', 'escaped-element': b'{"enabledCssSnippets":["pilot-\\u0074heme","personal",]}', 'trailing-array': b'{"enabledCssSnippets":["personal",/*last*/],}', 'empty-asset': b'{}'}[kind]
            if data is None: f.path().unlink()
            else: f.path().write_bytes(data)
            if kind == 'empty-asset': f.path(0,True).write_bytes(b'')
            original = f.checkpoint('state-before'); f.start(); f.apply(); f.apply('b'); f.stop(); f.start(); f.restore()
            assert f.checkpoint('state-restored')['targets'] == original['targets'], kind
            f.stop()
        passed('exact original absent appearance file/container versus empty array/assets and existing/escaped membership; insertion/removal preserves original trailing commas and comments across restart')

        f = fixture('later'); f.path().write_bytes(b'{"font":"Keep"}'); f.start(); f.apply()
        p=f.path(); p.write_bytes(p.read_bytes().replace(b'"pilot-theme"', b'"pilot-theme","added"'))
        f.apply('b'); f.restore(); assert document(p.read_bytes()) == {'font':'Keep','enabledCssSnippets':['added']}; f.stop()
        f = fixture('variants'); f.packs[1]['dark'] = False
        f.packs[1]['variants'] = {'dark':f.packs[0]['palette']}; f.save_pack(f.packs[1]); f.start()
        f.apply(); palette(f,f.packs[0]); f.apply('b'); palette(f,f.packs[1],{'dark':f.packs[0]['palette'],'light':f.packs[1]['palette']}); f.restore(); f.stop()
        passed('later additions keep a Pilot-created container alive; only supplied appearances rendered, including explicit paired variants; no opposite appearance invented')

        f=fixture('opts',selected=False); f.start(); negative(f,'not selected')
        f.controls(allow='no'); f.call('theme','bind','obsidian',f.vaults[0]['root'],'.obsidian',ok=False); assert not (f.root/'state/bindings.json').exists()
        f.controls(); f.call('theme','bind','obsidian',f.vaults[0]['root'],'.obsidian'); f.call('theme','bind','obsidian',f.vaults[1]['root'],'.obsidian-work')
        f.call('theme','opt-out','obsidian',f.vaults[0]['root'])
        # A removed vault is poisoned: reading it would refuse the plan. It is not a target.
        f.path().write_bytes(b'not valid JSON'); f.path(0,True).symlink_to('missing')
        f.apply(); assert f.path().read_bytes()==b'not valid JSON' and f.path(0,True).is_symlink()
        f.call('theme','bind','obsidian',f.vaults[0]['root'],'.obsidian',ok=False); f.restore()
        f.call('theme','opt-out','obsidian'); f.apply(); f.restore(); f.stop(); f.start(); f.apply(); f.restore(); f.stop()
        passed('native/CLI local binding uses existing Allow; selected vaults persist; individual/global opt-out supplies no file target even for malformed/broken removed vaults; active ownership blocks rebind')

        f=fixture('json'); f.start()
        for data in [b'',b'[]',b'{"enabledCssSnippets":null}',b'{"enabledCssSnippets":{}}',b'{"enabledCssSnippets":[1]}',b'{"enabledCssSnippets":["pilot-theme","pilot-\\u0074heme"]}',b'{"enabledCssSnippets":[],"enabledCssSnippets":[]}',b'{"enabledCssSnippets":[],"enabledCssSnip\\u0070ets":[]}',b'{"enabledCssSnippets":[],"x":[1 bad]}',b'{"enabledCssSnippets":[]} garbage',b'{/*unterminated',b'\xff{}']:
            f.path().write_bytes(data); negative(f)
        f.path().write_bytes(f.originals[0])
        for css in [b'/*unterminated', b'.theme-dark {--text-normal: #12345;}', b'.theme-dark {--text-normal: #ffffff; broken}', b'@import "https://bad";', b'body {background:url(file:///bad)}', b'.theme-dark {--text-normal:#ffffff!important;}', b'.theme-dark {--font-text-size: #ffffff;}', b'.theme-dark {--text-normal:#ffffff;--text-normal:#aaaaaa;}', b'\xff']:
            f.path(0,True).write_bytes(css); negative(f)
        f.path(0,True).unlink()
        for adapters in [{'obsidian':{'root':str(f.root)}},{'obsidian':{'css':'@import "bad"'}},{'obsidian':{'reload':'bad'}}]:
            f.save_pack(dict(f.packs[0],adapters=adapters)); negative(f,'unsupported')
        for variants in [{'auto':f.packs[0]['palette']}, {'light':{'background':'#123456'}}, {'dark':dict(f.packs[0]['palette'],background='#010203')}, {'light':dict(f.packs[0]['palette'],accent='url(https://bad)')}, {'light':dict(f.packs[0]['palette'],accent=12)}]:
            f.save_pack(dict(f.packs[0],variants=variants)); negative(f)
        f.save_pack(f.packs[0]); f.path().unlink(); (f.path().parent/'snippets').rename(f.path().parent/'missing-snippets'); negative(f,'parent'); f.stop()
        (f.path().parent/'missing-snippets').rename(f.path().parent/'snippets')
        passed('malformed full JSON/CSS, duplicate escaped owned keys/elements, nonstring arrays and imported payload/destination/reload authority fail closed; missing config/snippet parents reported without creation')

        for target in ['appearance','asset','pack','pack-asset','binding','ledger','manifest']:
            for during in [False,True]:
                f=fixture('stale'); f.start()
                if target=='pack-asset':
                    (f.root/'packs/a/color.png').write_bytes(life.WALLPAPER_A); f.packs[0]['wallpapers']=['color.png']; f.save_pack(f.packs[0])
                plan=f.plan()
                def edit():
                    if target=='appearance': f.path().write_bytes(f.path().read_bytes()+b'\r\n')
                    elif target=='asset': f.path(0,True).write_bytes(b'changed')
                    elif target=='pack': f.save_pack(dict(f.packs[0],title='later'))
                    elif target=='pack-asset': (f.root/'packs/a/color.png').write_bytes(life.WALLPAPER_B)
                    elif target=='binding': (f.root/'state/bindings.json').write_text(json.dumps(dict(zed=f.settings['zed'],zedOptOut=False,obsidian=f.vaults[:1])))
                    elif target=='ledger': (f.root/'state/ownership.json').write_text('{"schema":1,"epoch":22,"claims":[]}')
                    else: f.manifest.write_text(f.manifest.read_text()+'\n')
                if during: held(f,('theme','apply',plan),edit)
                else: edit(); before=f.snapshot(); f.call('theme','apply',plan,ok=False); assert f.snapshot()==before
                f.stop()
        f=fixture('bindhold',selected=False); f.start()
        held(f,('theme','bind','obsidian',f.vaults[0]['root'],'.obsidian'),lambda:f.path().write_bytes(b'{}')); f.stop()
        passed('appearance/generated/pack/pack-asset/local-binding/ledger/context revisions rejected before and after Allow; binding itself rechecks target snapshots after Allow; no silent replacement plan')

        for kind in ['escape','broken','hardlink','alias','parent','root','duplicate']:
            f=fixture('path'); sentinel=f.root/'sentinel'; sentinel.write_bytes(b'outside unchanged')
            p=f.path()
            if kind in ['escape','broken','hardlink','alias']:
                p.unlink()
                if kind=='hardlink': os.link(sentinel,p)
                elif kind=='alias': p.symlink_to('../../../app/pilot.conf')
                else: p.symlink_to('../../../sentinel' if kind=='escape' else 'missing')
            elif kind=='parent':
                folder=f.path(0,True).parent; (folder/'personal.css').rename(folder.parent/'personal.css'); folder.rmdir(); folder.symlink_to('../../../app')
                # Protected fixture file was moved deliberately, and is restored before receipt.
            elif kind=='root':
                f.settings['obsidian'][0]['root']='/tmp'; f.manifest.write_text(json.dumps(f.settings))
            else:
                f.settings['obsidian'].append(f.settings['obsidian'][0]); f.manifest.write_text(json.dumps(f.settings))
            before=f.snapshot()
            f.start(expect_ready=kind not in ['root','duplicate'])
            if kind not in ['root','duplicate']: negative(f); f.stop()
            else: assert f.snapshot()==before
            if kind=='parent':
                folder.unlink(); folder.mkdir(); (folder.parent/'personal.css').rename(folder/'personal.css')
            assert sentinel.read_bytes()==b'outside unchanged'
        f=fixture('alias'); p=f.path(0,True); p.symlink_to('personal.css'); f.start(); negative(f); f.stop()
        passed('path escapes/broken links/aliases/hardlinks/parent escapes/nonlocal roots/duplicate bindings fail closed; legacy font aliases protected; outside sentinel unchanged')

        f=fixture('conflict'); f.start(); f.apply(); good=f.path().read_bytes()
        f.path().write_bytes(good.replace(b'"pilot-theme"',b'"pilot-theme","pilot-theme"')); negative(f); f.call('theme','plan','restore',ok=False)
        f.stop(); f.start(); f.call('theme','plan','restore',ok=False); f.path().write_bytes(good)
        # The coordinator's brief (Sven Q38): a snippet the person turned off stays off; only that claim goes.
        mine=good.replace(b'"pilot-theme"',b'"user-edit"'); f.path().write_bytes(mine)
        assert [x for x in f.call('theme','plan','restore')['review']['kept'] if 'snippet stays off' in x]
        answer=f.restore(); assert answer['status']=='restored' and [x for x in answer['kept'] if 'snippet off' in x],answer
        assert f.path().read_bytes()==mine and json.loads((f.root/'state/ownership.json').read_text())['claims']==[]; f.stop()
        for journal in [False,True]:
            f=fixture('claims'); f.start(); f.apply(); f.stop()
            ledger=f.root/'state/ownership.json'; record=json.loads(ledger.read_text()); claim=next(c for c in record['claims'] if 'jsonMembership' in c['selector'])
            duplicate=json.loads(json.dumps(claim)); duplicate['selector']['jsonMembership']['removeEmptyContainer']=not duplicate['selector']['jsonMembership']['removeEmptyContainer']
            if not journal:
                record['claims'].append(duplicate); ledger.write_text(json.dumps(record)); f.start(expect_ready=False)
            else:
                f.start(); f.controls(crash='after-write:4'); f.call('theme','apply',f.plan('b'),ok=False); f.stop(crashed=True)
                path=f.root/'state/pending.json'; pending=json.loads(path.read_text()); mutation=next(m for m in pending['mutations'] if 'jsonMembership' in m['selector']); duplicate=json.loads(json.dumps(mutation)); duplicate['selector']['jsonMembership']['removeEmptyContainer']=not duplicate['selector']['jsonMembership']['removeEmptyContainer']; pending['mutations'].append(duplicate); path.write_text(json.dumps(pending)); f.controls(); f.start(expect_ready=False); assert path.exists()
        passed('a snippet turned off stays off while Restore finishes; duplicate membership conflicts across restart; duplicate/overlapping claims with differing container flags reject ledger and pending journal without clearing recovery')

        f=fixture('fail'); f.start(); f.apply()
        for stage in ['journal']+[s+str(i) for i in range(8) for s in ['write:','after-write:']]+['ledger']:
            before=f.snapshot(); f.controls(fail=stage); result=f.call('theme','apply',f.plan('b'),ok=stage!='journal')
            if stage!='journal': assert result['status']=='failed' and result['recovery']['status']=='rollback verified',result
            assert f.snapshot()==before,stage
        f.controls(fail='effect'); result=f.apply('b'); assert result['files']=='verified' and 'failed:' in result['refresh']
        f.controls(); f.restore(); f.stop()
        passed('journal/every staged write/ledger failure rolls back immediate A; file outcome remains distinct from recording refresh failure after committed B')

        for stage in ['after-write:'+str(i) for i in range(8)]+['after-ledger']:
            f=fixture('crash'); f.start(); f.apply(); before=f.snapshot(); f.controls(crash=stage); f.call('theme','apply',f.plan('b'),ok=False); f.stop(crashed=True)
            f.controls(); f.start(); assert f.call('theme','status')['selected']['id']==('b' if stage=='after-ledger' else 'a')
            if stage!='after-ledger': assert f.snapshot()==before
            assert not (f.root/'state/pending.json').exists(); f.restore(); f.stop(); outcome(f,'committed verified' if stage=='after-ledger' else 'rollback verified')
        f=fixture('retain'); f.start(); f.apply(); f.controls(fail='write:7+rollback:2'); result=f.apply('b')
        assert result['status']=='failed' and result['recovery']['status']=='recovery retained'; assert (f.root/'state/pending.json').exists(); f.call('theme','plan','apply','a',ok=False)
        f.stop(); f.controls(); f.start(); f.restore(); f.stop()
        passed('all partial-write and committed restart points reconcile multi-vault ownership; rollback failure retains journal and blocks mutation until safe restart recovery')

        # New membership/container states must not be inferred from an absent element alone.
        for original, residue in [(None,b'{"enabledCssSnippets":[]}'),(b'{}',b'{"enabledCssSnippets":[]}'),(b'{"enabledCssSnippets":[]}',b'{}')]:
            f=fixture('container')
            if original is None: f.path().unlink()
            else: f.path().write_bytes(original)
            f.start(); f.controls(crash='after-write:6'); f.call('theme','apply',f.plan(),ok=False); f.stop(crashed=True)
            f.path().write_bytes(residue); f.controls(); f.start(); assert (f.root/'state/pending.json').exists(); f.call('theme','plan','restore',ok=False); f.stop(); outcome(f,'recovery retained')
            if original is None: f.path().unlink()
            else: f.path().write_bytes(original)
            f.start(); assert not (f.root/'state/pending.json').exists(); f.stop(); outcome(f,'rollback verified')
        for operation in ['switch','restore']:
            for stage in ['after-write:2','after-write:6','after-ledger']:
                f=fixture('mixed'); f.path().unlink(); f.packs[1]['dark']=False; f.save_pack(f.packs[1]); f.start(); f.apply()
                if operation=='restore': f.apply('b')
                before=f.snapshot(); f.controls(crash=stage); f.call('theme','apply',f.plan('b' if operation=='switch' else None),ok=False); f.stop(crashed=True)
                f.controls(); f.start(); selected=f.call('theme','status')['selected']
                if stage=='after-ledger': assert (selected is None if operation=='restore' else selected['id']=='b')
                else: assert f.snapshot()==before
                if selected is not None: f.restore()
                assert not f.path().exists(); f.stop()
        f=fixture('memberretry'); f.start(); f.apply(); f.controls(fail='write:3+rollback:2'); result=f.restore()
        assert result['status']=='failed' and result['recovery']['status']=='recovery retained'
        f.stop(); f.controls(); f.start(); assert not (f.root/'state/pending.json').exists(); f.restore(); f.stop()
        f=fixture('memberlater'); f.path().write_bytes(b'{"font":"Keep"}'); f.start(); f.apply(); f.controls(crash='after-write:2'); f.call('theme','restore',f.plan(None),ok=False); f.stop(crashed=True)
        p=f.path(); p.write_bytes(p.read_bytes().replace(b'}',b',"enabledCssSnippets":["later"]}'))
        f.controls(); f.start(); assert document(p.read_bytes())['enabledCssSnippets']==['later','pilot-theme']; assert not (f.root/'state/pending.json').exists(); f.restore(); assert document(p.read_bytes())['enabledCssSnippets']==['later']; f.stop()
        passed('absent versus empty container mismatches retain recovery until resolved; mixed multi-selector Zed/Obsidian switch and Restore crashes preserve exact absent files; partial membership rollback retries honestly and preserves later unrelated additions')

        native=(life.REPO/'Sources/Pilot/UI/LookPage.swift').read_text()
        assert 'ThemeCoordinator.production().stageFollows(' in native and 'ThemeCoordinator.production().press(id)' in native
        passed('minimal native controls share binding/preview/Apply/Restore coordinator; attended interaction/visual coverage remains T12')
    finally:
        errors=[]
        for f in fixtures:
            try: f.stop(); f.receipt()
            except Exception as error: errors.append(str(error))
        (EVIDENCE/'fixture-index.json').write_text(json.dumps([str(f.root) for f in fixtures],indent=2))
        (EVIDENCE/'cleanup.json').write_text(json.dumps(dict(running=[str(f.root) for f in fixtures if f.process is not None],holds=[str(p) for f in fixtures for p in f.root.glob('*.hold')],errors=errors),indent=2))
        assert not errors,errors
    passed('obsidian')
