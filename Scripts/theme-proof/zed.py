"""Zed public CLI proof: real coordinator, private fixture roots and recording effects only."""
import concurrent.futures
import importlib.util
import json
import os
from pathlib import Path
import stat
import time

spec = importlib.util.spec_from_file_location('theme_lifecycle', Path(__file__).with_name('lifecycle.py'))
life = importlib.util.module_from_spec(spec)
spec.loader.exec_module(life)
EVIDENCE = Path(os.environ.get('PILOT_THEME_PROOF_EVIDENCE') or Path.home() / '.local/state/spec' / 'theme-system/T3/zed')
life.EVIDENCE = EVIDENCE



def contrast(a, b):
    def lum(h):
        c = [int(h.lstrip('#')[i:i + 2], 16) / 255 for i in (0, 2, 4)]
        c = [x / 12.92 if x <= .03928 else ((x + .055) / 1.055) ** 2.4 for x in c]
        return .2126 * c[0] + .7152 * c[1] + .0722 * c[2]
    x, y = sorted([lum(a), lum(b)], reverse=True)
    return (x + .05) / (y + .05)

class Fixture(life.Fixture):
    def __init__(self, label='z', selected=True, opt_out=False, dynamic=True):
        super().__init__(label)
        self.zroot = self.root / 'zed'
        (self.zroot / 'themes').mkdir(parents=True)
        (self.zroot / 'personal').mkdir()
        self.zactual = self.zroot / 'personal/settings.jsonc'
        self.zsettings = self.zroot / 'settings.json'
        self.zasset = self.zroot / 'themes/pilot-theme.json'
        selector = b'{"mode": "system", /* Mode stays */ "light": "Keep Light", "dark": "Keep Dark",}' if dynamic else b'"Keep Static"'
        self.zoriginal = b'\xef\xbb\xbf{\r\n // User comment\r\n "buffer_font_family":"Keep Editor",\r\n "ui_font_family":"Keep UI", "theme": ' + selector + b',\r\n "theme_overrides": {"Other Theme":{"text":"#123456"}},\r\n "experimental.theme_overrides":{"editor.background":"#998877"},\r\n "unrelated":{"arr":[1,/* comment */2,],},\r\n}\r\n'
        self.zactual.write_bytes(self.zoriginal); self.zactual.chmod(0o640)
        self.zsettings.symlink_to('personal/settings.jsonc')
        if selected:
            self.settings['zed'] = dict(root=str(self.zroot), config='settings.json', generated='themes/pilot-theme.json')
        self.settings['zedOptOut'] = opt_out
        self.manifest.write_text(json.dumps(self.settings))
        for pack in self.packs:
            pack['dark'] = True
            pack['adapters']['zed'] = {}
            self.save_pack(pack)
        self.baseline = self.snapshot()
        self.receipt_before()

    def snapshot(self):
        result = super().snapshot()
        zroot = self.root / 'zed'
        if zroot.exists():
            result.update({str(p.relative_to(self.root)): life.digest(p) for p in zroot.rglob('*') if p.is_file() or p.is_symlink()})
        return result

    def receipt_before(self):
        (self.root / 'manifest-before.json').write_text(json.dumps(self.snapshot(), indent=2))

    def zpreserved(self):
        self.preserved()
        assert self.zsettings.is_symlink() and os.readlink(self.zsettings) == 'personal/settings.jsonc'
        assert stat.S_IMODE(self.zactual.stat().st_mode) == 0o640
        data = self.zactual.read_bytes()
        for text in [b'\xef\xbb\xbf', b'// User comment\r\n', b'"buffer_font_family":"Keep Editor"', b'"ui_font_family":"Keep UI"', b'/* Mode stays */', b'"unrelated":{"arr":[1,/* comment */2,],}']:
            assert text in data, text


def resource_rollback(fixture, passed):
    """Crash the real CLI operation; assert resource existence as well as selected values."""
    failures = []

    def expect(condition, message):
        if not condition:
            failures.append(message)
            print('FAIL resource rollback: ' + message, flush=True)

    def setup(kind, dynamic=True):
        f = fixture('rr', dynamic=dynamic)
        f.config.unlink(); f.actual.unlink()
        original = {'absent': None, 'empty': b'', 'nonempty': f.original}[kind]
        (f.root / 'rollback-case.json').write_text(json.dumps(dict(original=kind, dynamic=dynamic, bytes=None if original is None else original.hex())))
        if original is not None:
            f.config.write_bytes(original); f.config.chmod(0o640)
        f.packs[0]['adapters'] = {'zed': {}}
        f.packs[1]['dark'] = False
        for pack in f.packs: f.save_pack(pack)
        f.receipt_before(); f.start()
        assert {v['name'] for v in f.call('schema')['verbs']} == {'ping', 'help', 'schema', 'version', 'theme'}
        assert f.call('theme', 'status')['effects'] == 'recording only'
        assert f.apply()['status'] == 'applied'
        before = f.snapshot()
        (f.root / 'operation-before.json').write_text(json.dumps(before, indent=2))
        plan = f.call('theme', 'plan', 'apply', 'b')
        # Public plan proves the unrelated Zed root contributes two selectors only in dynamic mode.
        zed = [c for c in plan['changes'] if c['path'] == str(f.zsettings)]
        assert len(zed) == (2 if dynamic else 1), plan
        paths = list(dict.fromkeys(c['path'] for c in plan['changes']))
        config_index = paths.index(str(f.config))
        (f.root / 'rollback-plan.json').write_text(json.dumps(plan, indent=2))
        return f, original, before, plan['id'], config_index

    def observe(f, label):
        pending = f.root / 'state/pending.json'
        value = dict(exists=f.config.exists(), bytes=f.config.read_bytes().hex() if f.config.exists() else None,
                     journal=pending.exists(), pending=json.loads(pending.read_text()) if pending.exists() else None,
                     status=f.call('theme', 'status'), snapshot=f.snapshot())
        (f.root / (label + '.json')).write_text(json.dumps(value, indent=2))
        return value

    def interrupt(f, plan, stage):
        f.controls(crash=stage)
        f.call('theme', 'apply', plan, ok=False); f.stop(crashed=True)
        pending = f.root / 'state/pending.json'
        assert pending.exists()
        (f.root / 'interrupted.json').write_text(json.dumps(dict(stage=stage, pending=json.loads(pending.read_text()),
            exists=f.config.exists(), bytes=f.config.read_bytes().hex() if f.config.exists() else None, snapshot=f.snapshot()), indent=2))

    def exact(f, original, label):
        value = observe(f, label)
        expect(value['exists'] == (original is not None) and value['bytes'] == (None if original is None else original.hex()), str(f.root) + ' ' + label + ' exact existence/bytes')
        return value

    def outcome(f, expected):
        line = next(row for row in (f.root / f'host-{f.counter}.log').read_text().splitlines() if row.startswith('THEME recovery:'))
        expect('JSONValue.string("' + expected + '")' in line, str(f.root) + ' recovery outcome ' + expected)

    for kind in ['absent', 'empty', 'nonempty']:
        for dynamic in [True, False]:
            f, original, before, plan, index = setup(kind, dynamic)
            interrupt(f, plan, f'after-write:{index}')
            f.controls(); f.start()
            value = exact(f, original, 'recovered')
            expect(value['snapshot'] == before and not value['journal'] and value['status']['selected']['id'] == 'a', str(f.root) + ' immediate A and cleared rollback')
            f.stop(); outcome(f, 'rollback verified'); f.start()
            again = exact(f, original, 'idempotent')
            expect(again == value, str(f.root) + ' idempotent restart')
            f.stop(); outcome(f, 'clean')

        # A failed rollback is retried after other selectors on the same Zed resource were restored.
        # Mutation 3 is a Zed settings slot: Ghostty's file, Zed's file, Ghostty's block, then Zed's light and dark slots.
        for rollback in [0, 3]:
            f, original, before, plan, _ = setup(kind)
            f.controls(fail=f'ledger+rollback:{rollback}')
            result = f.call('theme', 'apply', plan)
            assert result['status'] == 'failed' and result['recovery']['status'] == 'recovery retained', result
            assert result['recovery']['journal'] == 'retained'
            exact(f, original, 'partial-rollback')
            f.stop(); f.controls(); f.start()
            value = exact(f, original, 'retry')
            expect(value['snapshot'] == before and not value['journal'] and value['status']['selected']['id'] == 'a', str(f.root) + ' partial rollback retry')
            f.stop(); outcome(f, 'rollback verified')

        # Later unrelated bytes on BOTH roots must survive; exact snapshot replacement would lose them.
        f, original, _, plan, index = setup(kind)
        interrupt(f, plan, f'after-write:{index}')
        later = b'\r\n# Later unrelated, no final newline'
        f.config.write_bytes(f.config.read_bytes() + later)
        f.zactual.write_bytes(f.zactual.read_bytes().replace(b'Keep Editor', b'Later Editor'))
        f.controls(); f.start()
        value = exact(f, (original or b'') + later, 'later-edits')
        # Pack a holds both of Zed's slots, so the theme shows in either mode (build 2168).
        expected_zed = f.zoriginal.replace(b'Keep Editor', b'Later Editor').replace(b'"Keep Dark"', b'"Pilot a Dark"').replace(b'"Keep Light"', b'"Pilot a Dark"')
        expect(f.zactual.read_bytes() == expected_zed and not value['journal'] and value['status']['selected']['id'] == 'a', str(f.root) + ' unrelated multi-selector edits')
        f.stop(); outcome(f, 'rollback verified')

        # Ledger-committed recovery is verification, never rollback, even with two Zed selectors.
        f, original, _, plan, _ = setup(kind)
        interrupt(f, plan, 'after-ledger')
        committed = f.snapshot()
        committed.pop('state/pending.json')
        f.controls(); f.start()
        value = observe(f, 'committed')
        expect(value['snapshot'] == committed and not value['journal'] and value['status']['selected']['id'] == 'b', str(f.root) + ' committed verified, not rolled back')
        assert f.restore()['status'] == 'restored'
        exact(f, original, 'restore-after-commit')
        assert f.zactual.read_bytes() == f.zoriginal and not f.zasset.exists()
        f.stop(); outcome(f, 'committed verified')

    # An absent owned block is insufficient to verify a resource's original absence/empty state.
    for committed in [False, True]:
        for kind, residue in [('absent', b''), ('empty', None)]:
            f, original, _, plan, _ = setup(kind)
            if committed:
                assert f.call('theme', 'apply', plan)['status'] == 'applied'
                plan = f.plan(None)
            interrupt(f, plan, 'after-ledger' if committed else 'after-write:0')
            if residue is None: f.config.unlink()
            else: f.config.write_bytes(residue)
            f.controls(); f.start()
            value = exact(f, residue, 'pre-state-mismatch')
            expect(value['journal'], str(f.root) + ' existence mismatch must retain recovery')
            if value['journal']: f.call('theme', 'plan', 'apply', 'a', ok=False)
            f.stop(); outcome(f, 'recovery retained'); f.start()
            repeated = exact(f, residue, 'pre-state-mismatch-retry')
            expect(repeated == value, str(f.root) + ' mismatch retry must preserve bytes/journal')
            f.stop(); outcome(f, 'recovery retained')
            if original is None: f.config.unlink(missing_ok=True)
            else: f.config.write_bytes(original)
            f.start()
            value = exact(f, original, 'resolved-pre-state')
            selected = value['status']['selected']
            expect(not value['journal'] and (selected is None if committed else selected['id'] == 'a'), str(f.root) + ' resolved existence retry')
            f.stop(); outcome(f, 'committed verified' if committed else 'rollback verified')

    assert not failures, '\n'.join(failures)
    passed('resource-local rollback: exact absent/empty/nonempty Ghostty states with unrelated single/multiple Zed selectors; partial retry, idempotence, later edits, early pre-state conflicts and distinct committed recovery')


def run(seam_only=False, fixes_only=False):
    if fixes_only:
        raise AssertionError('zed has no fixes-only shortcut')
    EVIDENCE.mkdir(parents=True, exist_ok=True)
    fixtures, checks = [], []

    def fixture(*args, **kwargs):
        item = Fixture(*args, **kwargs); fixtures.append(item); return item

    def passed(message):
        checks.append(message)
        print('PASS ' + message, flush=True)
        (EVIDENCE / 'zed.log').write_text('\n'.join('PASS ' + x for x in checks) + '\n')

    def negative(f, expected=None):
        before = f.snapshot()
        answer = f.call('theme', 'plan', 'apply', 'a', ok=False)
        if expected: assert expected.lower() in json.dumps(answer).lower(), answer
        assert f.snapshot() == before

    def palette(f, pack):
        asset = json.loads(f.zasset.read_bytes())
        assert set(asset) == {'$schema', 'name', 'author', 'themes'}
        assert len(asset['themes']) == 1
        theme = asset['themes'][0]
        assert theme['appearance'] == ('dark' if pack['dark'] else 'light')
        assert theme['name'] == 'Pilot ' + pack['id'] + (' Dark' if pack['dark'] else ' Light')
        style, colors = theme['style'], pack['palette']
        roles = {'background': 'background', 'text': 'foreground', 'text.muted': 'muted', 'text.accent': 'accent', 'border.focused': 'accent',
                 'editor.background': 'background', 'editor.foreground': 'foreground', 'surface.background': 'dark_background', 'terminal.background': 'background',
                 'error': 'red', 'warning': 'yellow', 'success': 'green', 'info': 'blue'}
        grounds = [colors[r] for r in ['background', 'dark_background', 'lighter_background']]
        text = {'text', 'text.muted', 'text.accent', 'editor.foreground', 'error', 'warning', 'success', 'info'}
        # Review blocker 3: a text key keeps the palette's colour, or moves until it reads at 4.5:1 on every ground.
        for key, role in roles.items():
            assert style[key] == colors[role] or key in text and all(contrast(style[key], g) >= 4.5 for g in grounds), (key, role, style[key], colors[role])
        for key in ['red', 'green', 'yellow', 'blue', 'magenta', 'cyan']:
            assert style['terminal.ansi.' + key] == colors[key]
            assert style['terminal.ansi.bright_' + key] == colors['bright_' + key]
        assert style['players'][0]['selection'] == colors['selection']
        for key, role in [('comment', 'muted'), ('string', 'green')]:
            got = style['syntax'][key]['color']
            assert got == colors[role] or all(contrast(got, g) >= 4.5 for g in grounds), (key, got, colors[role])
        assert not any('font' in key for key in style)

    try:
        f = fixture(); f.start()
        assert f.call('ping') == 'pong'
        verbs = {v['name'] for v in f.call('schema')['verbs']}
        assert verbs == {'ping', 'help', 'schema', 'version', 'theme'}
        for forbidden in ['set', 'run', 'system', 'wallpaper', 'install', 'ai']:
            f.call(forbidden, ok=False)
        before = f.snapshot()
        f.call('theme', 'show', 'a'); f.call('theme', 'check', 'a')
        plan = f.call('theme', 'plan', 'apply', 'a')
        assert len(plan['changes']) == 5  # Ghostty 2, Zed's theme file and both its light and dark slots.
        assert any('overrides' in w for w in plan['warnings'])
        assert any('should update by itself' in w for w in plan['warnings'])
        assert any('stays automatic' in w for w in plan['warnings'])
        assert f.snapshot() == before
        f.controls(allow='no'); f.call('theme', 'apply', plan['id'], ok=False)
        assert f.snapshot() == before
        f.controls()
        passed('isolated native coordinator through real CLI/private 0600 socket; only core/theme verbs; check/plan/denial write nothing; overrides/missing installation/reload limits explicit')
        if seam_only: return

        f.stop()
        resource_rollback(fixture, passed)
        f.start()

        assert f.apply()['status'] == 'applied'; palette(f, f.packs[0]); f.zpreserved()
        # Pilot holds both slots now (build 2168), so the person's later light theme replaces Pilot's there and stays theirs.
        changed = f.zactual.read_bytes().replace(b'"mode": "system"', b'"mode": "light"').replace(b'"Pilot a Dark"', b'"Later Light"', 1).replace(b'"Keep Editor"', b'"Later Font"')
        f.zactual.write_bytes(changed)
        f.apply('b'); palette(f, f.packs[1])
        f.stop(); f.start(); assert f.call('theme', 'status')['selected']['id'] == 'b'
        assert f.restore()['status'] == 'restored'
        expected = f.zoriginal.replace(b'"mode": "system"', b'"mode": "light"').replace(b'"Keep Light"', b'"Later Light"').replace(b'"Keep Editor"', b'"Later Font"')
        assert f.zactual.read_bytes() == expected
        assert not f.zasset.exists()
        f.stop()
        passed('dynamic A->B->restart->Restore keeps BOM/CRLF/comments/trailing commas, fonts, later mode/opposite/font edits and exact original selection; generated asset originally absent is removed')

        for dynamic in [False, True]:
            f = fixture('switch', dynamic=dynamic)
            f.packs[1]['dark'] = False; f.save_pack(f.packs[1]); f.start()
            f.apply(); palette(f, f.packs[0]); f.apply('b'); palette(f, f.packs[1])
            if dynamic:
                data = f.zactual.read_bytes()
                # The coordinator's brief (build 2168): the theme takes both slots, so it shows in either macOS mode.
                assert b'"dark": "Pilot b Light"' in data and b'"light": "Pilot b Light"' in data
                assert b'"mode": "system"' in data
            f.stop(); f.start(); f.restore()
            assert f.zactual.read_bytes() == f.zoriginal
            assert not f.zasset.exists(); f.stop()
        passed('static and dynamic dark->light switching puts the theme in both of a dynamic selection\'s slots; original selectors return across restart')

        f = fixture('names')
        new = f.config.with_name('settings.json'); f.config.rename(new); f.config = new
        f.settings['binding']['config'] = 'settings.json'; f.manifest.write_text(json.dumps(f.settings))
        f.start(); f.apply(); f.apply('b'); f.stop(); f.start(); f.restore()
        assert f.zactual.read_bytes() == f.zoriginal and f.actual.read_bytes() == f.original
        f.stop()
        f = fixture('only')
        for pack in f.packs: pack['adapters'] = {'zed': {}}; f.save_pack(pack)
        f.start(); f.apply(); f.apply('b'); f.restore()
        assert f.actual.read_bytes() == f.original and not f.generated.exists()
        f.stop()
        f = fixture('retire'); f.packs[1]['adapters'] = {'ghostty': {}}; f.save_pack(f.packs[1])
        f.start(); f.apply(); f.apply('b')
        assert f.zactual.read_bytes() == f.zoriginal and not f.zasset.exists()
        ledger = json.loads((f.root / 'state/ownership.json').read_bytes())
        assert len(ledger['claims']) == 2
        f.restore(); f.stop()
        passed('resource/selector identities distinguish equal settings.json filenames across roots; Zed-only packs preserve Ghostty')

        # The coordinator's brief (Sven Q38): the person's theme choice stays, only that claim goes, the rest runs.
        f = fixture('conf'); f.start(); f.apply(); old = f.zactual.read_bytes()
        mine = old.replace(b'Pilot a Dark', b'User changed'); f.zactual.write_bytes(mine)
        f.stop(); f.start()
        plan = f.call('theme', 'plan', 'apply', 'b')
        assert [x for x in plan['review']['kept'] if 'stays: you edited' in x], plan['review']
        answer = f.call('theme', 'apply', plan['id']); assert answer['status'] == 'applied' and answer['kept'], answer
        assert b'User changed' in f.zactual.read_bytes()
        answer = f.restore(); assert answer['status'] == 'restored', answer
        assert f.zactual.read_bytes() == mine and not f.zasset.exists() and f.actual.read_bytes() == f.original
        f.stop()
        passed('a later edit to Zed\'s theme setting stays across restart, Apply and Restore; only that claim goes')

        # All documents are validated, even malformed content far from the owned key.
        invalid = [b'{"theme":"X"} garbage', b'{"theme":"X", "other":[1 bad]}', b'{"theme":"X", "other":01}', b'{"theme":"X", "other":"bad\x01"}',
                   b'{"theme":"X", /* unclosed', b'{"theme":"X", "theme":"Y"}', b'{"th\\u0065me":"X", "theme":"Y"}',
                   b'{"theme":{"light":"L","dark":"D","dark":"E"}}', b'{"theme":{"mode":"system","mode":"dark","light":"L","dark":"D"}}',
                   b'{"theme":{"light":"L","dark":"D","light":"E"}}', b'\xff{"theme":"X"}', b'[ {"theme":"X"} ]', b'{"theme":null}',
                   b'{"theme":{"mode":"auto","light":"L","dark":"D"}}', b'{"theme":{"mode":"system","dark":"D"}}', b'{"font_size":17}', b'']
        f = fixture('json'); f.start()
        for data in invalid:
            f.zactual.write_bytes(data); negative(f)
        f.zactual.unlink(); f.zsettings.unlink(); negative(f, 'missing')
        f.stop()
        passed('strict full-document JSONC/UTF-8 and escaped duplicate owned keys rejected; null/incomplete/absent/inherited selection and missing settings fail explicitly without choosing defaults')

        f = fixture('opts', selected=False); f.start(); negative(f, 'not selected')
        f.call('theme', 'opt-out', 'zed'); zed_before = {k: v for k, v in f.snapshot().items() if k.startswith('zed/')}
        plan = f.call('theme', 'plan', 'apply', 'a'); assert len(plan['changes']) == 2
        assert any('you turned it off' in w for w in plan['warnings'])
        f.apply(); f.apply('b'); f.restore()
        assert {k: v for k, v in f.snapshot().items() if k.startswith('zed/')} == zed_before
        f.call('theme', 'bind', 'zed', str(f.zroot)); f.apply(); palette(f, f.packs[0])
        f.call('theme', 'opt-out', 'zed', ok=False); f.restore(); f.stop(); f.start(); f.apply(); f.restore(); f.stop()
        passed('missing/non-selected binding cannot silently succeed as Ghostty-only; explicit opt-out preserves all Zed bytes; local CLI/native selection persists; active ownership prevents rebinding')

        f = fixture('pack'); f.start()
        for adapters in [{'ghostty': {}, 'zed': {'root': str(f.zroot)}}, {'ghostty': {}, 'zed': {'reload':'anything'}}, {'ghostty': {}, 'zed': {}, 'unknown': {}}]:
            pack = dict(f.packs[0], adapters=adapters); f.save_pack(pack); negative(f, 'unsupported')
        f.save_pack(f.packs[0]); f.zasset.write_bytes(b'{"personal":true}'); negative(f, 'collision'); f.stop()
        f = fixture('local'); f.start()
        (f.root / 'state/bindings.json').write_text(json.dumps(dict(zed=dict(root='/tmp', config='settings.json', generated='themes/pilot-theme.json'), zedOptOut=False)))
        negative(f, 'unsafe local'); f.stop()
        passed('portable manifest cannot grant destination/reload authority; unknown adapter data and unclaimed generated collisions fail closed')

        for target in ['settings', 'asset', 'pack', 'binding', 'legacy']:
            for during in [False, True]:
                f = fixture('stale'); f.start()
                f.controls(hold='yes' if during else 'no'); plan = f.plan()
                def edit():
                    if target == 'settings': f.zactual.write_bytes(f.zactual.read_bytes() + b'// later\r\n')
                    elif target == 'asset': f.zasset.write_bytes(b'changed')
                    elif target == 'pack': f.save_pack(dict(f.packs[0], title='Later'))
                    elif target == 'binding':
                        f.settings['zedOptOut'] = True; f.manifest.write_text(json.dumps(f.settings))
                    else: f.fonts.write_bytes(b'# changed protected font bytes\n')
                if during:
                    with concurrent.futures.ThreadPoolExecutor() as pool:
                        answer = pool.submit(f.call, 'theme', 'apply', plan, ok=False)
                        deadline = time.monotonic() + 15
                        while not (f.root / 'asked').exists() and time.monotonic() < deadline: time.sleep(.03)
                        assert (f.root / 'asked').exists(); edit(); before = f.snapshot(); (f.root / 'go').touch(); answer.result(timeout=30)
                else:
                    edit(); before = f.snapshot(); f.call('theme', 'apply', plan, ok=False)
                assert f.snapshot() == before; f.stop()
        passed('settings/generated/pack/local binding/protected legacy stale snapshots rejected before and after Allow; no replacement plan or writes')

        for kind in ['escape', 'broken', 'hardlink', 'alias', 'parent', 'generated']:
            f = fixture('paths'); outside = f.root / 'sentinel'; outside.write_bytes(b'outside unchanged')
            if kind in ['escape', 'broken', 'hardlink', 'alias']:
                f.zsettings.unlink()
                if kind == 'hardlink': os.link(f.zactual, f.zsettings)
                elif kind == 'alias':
                    f.zasset.write_bytes(b'"Alias"'); f.zsettings.symlink_to('themes/pilot-theme.json')
                else: f.zsettings.symlink_to('../sentinel' if kind == 'escape' else 'missing')
            elif kind == 'parent':
                (f.zroot / 'themes').rmdir(); (f.zroot / 'themes').symlink_to('../app')
                # A generated file through an escaping parent is refused.
            else: f.zasset.symlink_to('../personal/settings.jsonc')
            f.start(); negative(f); f.stop()
            assert outside.read_bytes() == b'outside unchanged'
        f = fixture('escape'); f.settings['zed']['root'] = '/tmp'; f.manifest.write_text(json.dumps(f.settings)); f.start(expect_ready=False)
        f = fixture('sock'); f.settings['socket'] = str(f.root) + '/zed/../../outside-socket'; f.manifest.write_text(json.dumps(f.settings))
        f.start(expect_ready=False)
        f = fixture('sock'); f.settings['socket'] = str(f.zactual); f.manifest.write_text(json.dumps(f.settings))
        f.start(expect_ready=False); assert f.zactual.read_bytes() == f.zoriginal
        passed('escaping/broken/internal aliases, parent escapes and hardlinks refuse; outside sentinel unchanged; fixture binding root cannot escape')

        f = fixture('fail'); f.start(); f.apply()
        for stage in ['journal', 'write:0', 'after-write:0', 'write:1', 'after-write:1', 'write:2', 'after-write:2', 'write:3', 'after-write:3', 'ledger']:
            before = f.snapshot(); f.controls(fail=stage)
            result = f.call('theme', 'apply', f.plan('b'), ok=stage != 'journal')
            if stage != 'journal': assert result['status'] == 'failed' and result['recovery']['status'] == 'rollback verified', result
            assert f.snapshot() == before, stage
        f.controls(fail='effect'); result = f.apply('b')
        assert result['files'] == 'verified' and 'failed:' in result['refresh']
        f.controls(); f.restore(); f.stop()
        passed('journal/every staged resource write/ledger failure rolls back immediate A; recording refresh failure honestly retains committed B')

        for crash in ['after-write:0', 'after-write:1', 'after-write:2', 'after-write:3', 'after-ledger']:
            f = fixture('crash'); f.start(); f.apply(); before = f.snapshot()
            f.controls(crash=crash); f.call('theme', 'apply', f.plan('b'), ok=False); f.stop(crashed=True)
            f.controls(); f.start()
            assert f.call('theme', 'status')['selected']['id'] == ('b' if crash == 'after-ledger' else 'a')
            if crash != 'after-ledger': assert f.snapshot() == before
            assert not (f.root / 'state/pending.json').exists(); f.restore(); f.stop()
        passed('every partial write and committed-ledger restart safely reconcile shared Ghostty/Zed ownership')

        # Appearance switches compose two independent selectors in one atomic resource replacement.
        for operation in ['switch', 'restore']:
            for stage in ['after-write:1', 'after-write:3', 'after-ledger']:
                f = fixture('mixed'); f.packs[1]['dark'] = False; f.save_pack(f.packs[1]); f.start(); f.apply()
                if operation == 'restore': f.apply('b')
                before = f.snapshot(); f.controls(crash=stage)
                f.call('theme', 'apply', f.plan('b' if operation == 'switch' else None), ok=False); f.stop(crashed=True)
                f.controls(); f.start()
                status = f.call('theme', 'status')['selected']
                if stage == 'after-ledger':
                    assert (status is None if operation == 'restore' else status['id'] == 'b')
                else:
                    assert f.snapshot() == before
                    assert status['id'] == ('a' if operation == 'switch' else 'b')
                if status is not None: f.restore()
                assert f.zactual.read_bytes() == f.zoriginal and not f.zasset.exists(); f.stop()
        passed('dark->light multi-selector and Restore partial/committed restart recover exactly without claiming the opposite slot')

        f = fixture('retain'); f.start(); f.apply(); f.controls(fail='write:3+rollback:1'); result = f.apply('b')
        assert result['status'] == 'failed' and result['recovery']['status'] == 'recovery retained', result
        assert (f.root / 'state/pending.json').exists(); f.call('theme', 'plan', 'apply', 'a', ok=False)
        f.stop(); f.controls(); f.start(); f.restore(); f.stop()
        passed('failed Zed rollback retains pending recovery and blocks mutation; restart recovers original ownership')

        # The actual minimal native controls call the same preparation, selection and apply methods.
        native = (life.REPO / 'Sources/Pilot/UI/LookPage.swift').read_text()
        assert 'ThemeCoordinator.production().plan(id)' in native
        assert 'ThemeCoordinator.production().press(id)' in native  # One press applies (Sven, 2180).
        assert 'ThemeCoordinator.production().stageFollows(' in native  # Sven, T12: the switches replaced the path fields
        passed('native controls share exact coordinator/plan/apply/binding route; attended interaction remains T12')
        passed('zed')
    finally:
        errors = []
        for f in fixtures:
            try: f.stop(); f.receipt()
            except Exception as error: errors.append(str(error))
        (EVIDENCE / 'fixture-index.json').write_text(json.dumps([str(f.root) for f in fixtures], indent=2))
        (EVIDENCE / 'cleanup.json').write_text(json.dumps(dict(running=[str(f.root) for f in fixtures if f.process is not None], holds=[str(p) for f in fixtures for p in f.root.glob('*.hold')], errors=errors), indent=2))
        assert not errors, errors
