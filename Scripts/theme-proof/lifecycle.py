"""Real PilotCLI -> private socket -> shared ThemeCoordinator, explicit fixture-only effects.

No unittest or mocked executor: assertions inspect public answers and exact on-disk fixture bytes.
All hosts are joined, including failures; all fixture roots and command/output logs are retained.
"""
import base64
import concurrent.futures
import hashlib
import json
import os
from pathlib import Path
import shutil
import stat
import subprocess
import time
import uuid

REPO = Path(__file__).resolve().parents[2]
EVIDENCE = Path(os.environ.get('PILOT_THEME_PROOF_EVIDENCE') or Path.home() / '.local/state/spec' / 'theme-system/T2')
CLI = REPO / '.build/debug/PilotCLI'
HOST = ['nice', '-n', '10', 'swift', 'test', '-j', '4', '--skip-build', '--filter', 'SandboxHost']


def digest(path):
    if path.is_symlink():
        return {'link': os.readlink(path), 'mode': stat.S_IMODE(path.lstat().st_mode)}
    return {'sha256': hashlib.sha256(path.read_bytes()).hexdigest(), 'mode': stat.S_IMODE(path.stat().st_mode)}


# Two decodable image payloads: stale-asset cases must first be valid packs.
WALLPAPER_A = base64.b64decode('iVBORw0KGgoAAAANSUhEUgAAAAIAAAABCAIAAAB7QOjdAAAADUlEQVR42mOQdEwBIgAEowF9QIvmEgAAAABJRU5ErkJggg==')
WALLPAPER_B = base64.b64decode('iVBORw0KGgoAAAANSUhEUgAAAAEAAAACCAIAAAAW4yFwAAAADklEQVR42mMIEIliAGIABeQBfbSeD6oAAAAASUVORK5CYII=')


class Fixture:
    def __init__(self, label, ghostty=True):
        self.root = EVIDENCE / 'fixtures' / (label + '-' + uuid.uuid4().hex[:6])
        self.root.mkdir(parents=True)
        self.root = self.root.resolve()
        self.process = None
        self.log = None
        self.counter = 0
        self.config = self.root / 'app/config'
        self.actual = self.root / 'app/dotfiles/ghostty'
        self.generated = self.root / 'app/pilot-theme.conf'
        self.fonts = self.root / 'app/pilot.conf'
        for folder in ['packs/a', 'packs/b', 'state', 'user-packs'] + (['app/dotfiles'] if ghostty else []):
            (self.root / folder).mkdir(parents=True)
        rows = json.loads((REPO / 'Packaging/themes.json').read_text())['themes']
        self.packs = []
        for name, row in zip(['a', 'b'], rows):
            pack = dict(schema=1, id=name, title='Fixture ' + name, dark=row['dark'], palette=row['colors'],
                        styles=['instrument', 'toybox'], wallpapers=[], adapters={'ghostty': {}})
            self.packs.append(pack)
            self.save_pack(pack)
        self.original = b'\xef\xbb\xbf# Personal config\r\nfont-size = 17\r\nconfig-file = ?pilot.conf\r\n# keep EOF'
        self.font_original = b'# legacy comment\nfont-family = Keep Me\nbackground = #123456\n'
        if ghostty:
            self.actual.write_bytes(self.original)
            self.actual.chmod(0o640)
            self.config.symlink_to('dotfiles/ghostty')
            self.fonts.write_bytes(self.font_original)
        self.manifest = self.root / 'fixture.json'
        self.socket = self.root / 's'
        self.control = self.root / 'control.json'
        self.controls()
        self.settings = dict(root=str(self.root), packs=str(self.root / 'packs'), writablePacks=str(self.root / 'user-packs'),
                             state=str(self.root / 'state'), socket=str(self.socket), effects='recording', control=str(self.control),
                             binding=dict(root=str(self.root / 'app'), config='config', generated='pilot-theme.conf'))
        self.manifest.write_text(json.dumps(self.settings))
        self.baseline = self.snapshot()
        (self.root / 'manifest-before.json').write_text(json.dumps(self.baseline, indent=2))

    def save_pack(self, pack):
        (self.root / 'packs' / pack['id'] / 'manifest.json').write_text(json.dumps(pack))

    def controls(self, **values):
        self.control.write_text(json.dumps({'allow': 'yes', 'style': 'instrument', **values}))

    def snapshot(self):
        return {str(p.relative_to(self.root)): digest(p) for base in ['packs', 'user-packs', 'app', 'state']
                for p in (self.root / base).rglob('*') if p.is_file() or p.is_symlink()}

    def start(self, extra_env=None, expect_ready=True):
        assert self.process is None
        self.counter += 1
        self.log = (self.root / f'host-{self.counter}.log').open('w')
        env = {k: v for k, v in os.environ.items() if not k.startswith(('PILOT_', 'CFFIXED_'))}
        env['PILOT_THEME_FIXTURE'] = str(self.manifest)
        env.update(extra_env or {})
        (self.root / f'host-{self.counter}.command.json').write_text(json.dumps(dict(command=HOST, environment={'PILOT_THEME_FIXTURE': str(self.manifest), **(extra_env or {})})))
        self.process = subprocess.Popen(HOST, cwd=REPO, env=env, stdout=self.log, stderr=subprocess.STDOUT)
        (self.root / f'host-{self.counter}.pid').write_text(str(self.process.pid))
        deadline = time.monotonic() + 35
        while time.monotonic() < deadline:
            if Path(str(self.socket) + '.hold').exists():
                assert expect_ready, 'unsafe fixture unexpectedly started'
                assert stat.S_IMODE(self.socket.stat().st_mode) == 0o600
                return
            if self.process.poll() is not None:
                code = self.process.returncode
                (self.root / f'host-{self.counter}.exit').write_text(str(code))
                self.process.wait(); self.process = None; self.log.close()
                assert not expect_ready, f'host failed ({code}): {(self.root / f"host-{self.counter}.log").read_text()[-5000:]}'
                return
            time.sleep(.1)
        self.stop()
        raise AssertionError('fixture host not ready')

    def stop(self, crashed=False):
        if self.process is None:
            return
        hold = Path(str(self.socket) + '.hold')
        if not crashed:
            hold.unlink(missing_ok=True)
        try:
            code = self.process.wait(timeout=35)
            (self.root / f'host-{self.counter}.exit').write_text(str(code))
        finally:
            if self.process.poll() is None:
                # Own proof child only, never an installed app or service.
                self.process.terminate(); self.process.wait(timeout=10)
            self.process = None
            self.log.close()
            hold.unlink(missing_ok=True)
        if not crashed:
            assert code == 0, f'host exit {code}'
            text = (self.root / f'host-{self.counter}.log').read_text()
            assert 'THEME FIXTURE ONLY: Engine=absent settings=absent Keychain=absent production-registry=absent effects=recording fallback=none' in text

    def call(self, *words, ok=True):
        env = dict(os.environ, PILOT_SOCKET=str(self.socket))
        env.pop('PILOT_AGENT', None)
        command = [str(CLI), '--json', *words]
        result = subprocess.run(command, cwd=REPO, env=env, text=True, capture_output=True, timeout=35)
        with (self.root / 'commands.jsonl').open('a') as output:
            output.write(json.dumps(dict(command=command, exit=result.returncode, stdout=result.stdout, stderr=result.stderr)) + '\n')
        try:
            answer = json.loads(result.stdout or result.stderr)
        except json.JSONDecodeError:
            assert not ok, (words, result.stdout, result.stderr)
            return {'error': {'message': result.stderr}}
        assert answer.get('ok') == ok, (words, answer)
        return answer.get('result') if ok else answer

    def plan(self, name='a'):
        return (self.call('theme', 'plan', 'restore') if name is None else self.call('theme', 'plan', 'apply', name))['id']

    def apply(self, name='a'):
        return self.call('theme', 'apply', self.plan(name))

    def restore(self):
        return self.call('theme', 'restore', self.plan(None))

    def preserved(self):
        assert self.fonts.read_bytes() == self.font_original
        assert self.config.is_symlink() and os.readlink(self.config) == 'dotfiles/ghostty'
        assert stat.S_IMODE(self.actual.stat().st_mode) == 0o640

    def receipt(self):
        (self.root / 'manifest-after.json').write_text(json.dumps(self.snapshot(), indent=2))


def run(seam_only=False, fixes_only=False):
    EVIDENCE.mkdir(parents=True, exist_ok=True)
    logs = EVIDENCE / ('seam.log' if seam_only else 'lifecycle.log')
    checks = []

    def passed(text):
        checks.append(text)
        print('PASS ' + text, flush=True)
        logs.write_text('\n'.join('PASS ' + x for x in checks) + '\n')

    f = Fixture('seam' if seam_only else 'lifecycle')
    fixtures = [f]
    try:
        f.start()
        assert f.call('ping') == 'pong'
        assert f.call('theme', 'status')['effects'] == 'recording only'
        verbs = f.call('schema')['verbs']
        assert {v['name'] for v in verbs} == {'ping', 'help', 'schema', 'version', 'theme'}
        for forbidden in ['set', 'run', 'wallpaper', 'system', 'install', 'ai']:
            f.call(forbidden, ok=False)
        f.call('theme', 'list'); f.call('theme', 'show', 'a'); f.call('theme', 'check', 'a'); f.plan()
        assert f.snapshot() == f.baseline
        passed('fixture wiring before Apply/Restore: Engine/settings/Keychain/production registry absent; explicit roots/private 0600 socket; recording effects; read-only CLI leaves fixtures byte-identical')
        if seam_only:
            return

        f.stop()
        review_fixes(passed)
        if fixes_only:
            return
        f.start()

        # No Apply/Restore is executed above this line. The isolation seam is independently logged first.
        f.controls(allow='no')
        f.call('theme', 'apply', f.plan(), ok=False)
        assert f.snapshot() == f.baseline
        f.controls()
        assert f.apply()['status'] == 'applied'
        original_ledger = json.loads((f.root / 'state/ownership.json').read_text())
        assert f.apply('b')['status'] == 'applied'
        second_ledger = json.loads((f.root / 'state/ownership.json').read_text())
        assert [c.get('original') for c in original_ledger['claims']] == [c.get('original') for c in second_ledger['claims']]
        f.stop(); f.start()
        assert f.call('theme', 'status')['selected']['id'] == 'b'
        f.actual.write_bytes(f.actual.read_bytes() + b'\r\n# Later unrelated\r\nfont-size = 19')
        assert f.restore()['status'] == 'restored'
        assert f.actual.read_bytes() == f.original + b'\r\n# Later unrelated\r\nfont-size = 19'
        assert not f.generated.exists()
        f.preserved()
        passed('denial and A/B/restart/Restore preserve original absence, BOM/CRLF/no-final-newline, font bytes, comments, symlink/mode and unrelated later edits; saved packs retained')

        # Existing generated file and existing marked region have distinct original owned states.
        existing = b'# original generated\nbackground = #abcdef\n'
        f.generated.write_bytes(existing)
        f.generated.chmod(0o644)
        f.apply(); f.apply('b'); f.stop(); f.start(); f.restore()
        assert f.generated.read_bytes() == existing
        assert stat.S_IMODE(f.generated.stat().st_mode) == 0o644
        f.preserved()
        passed('existing generated file restored byte-for-byte with mode across switches/restart')

        # The coordinator's brief (Sven Q38): a part the person edited keeps their edit, only that claim goes, and
        # the rest of Restore finishes with a plain line.
        pre = f.actual.read_bytes()
        f.apply()
        mine = f.generated.read_bytes() + b'# Later owned edit\n'
        f.generated.write_bytes(mine)
        kept = f.call('theme', 'plan', 'restore')['review']['kept']
        assert len(kept) == 1 and f.generated.name in kept[0] and 'stays: you edited' in kept[0], kept
        answer = f.restore()
        assert answer['status'] == 'restored' and len(answer['kept']) == 1 and answer['kept'][0].startswith('Kept your change to'), answer
        assert f.generated.read_bytes() == mine and f.actual.read_bytes() == pre and not f.call('theme', 'status')['owned']
        f.generated.unlink()
        f.apply()
        original = f.actual.read_bytes()
        loader = ('config-file = ?' + str(f.generated)).encode()
        assert loader in original
        mine = original.replace(loader, loader + b'-changed', 1)
        f.actual.write_bytes(mine)
        answer = f.restore()
        assert answer['status'] == 'restored' and answer['kept'][0].startswith('Kept your change to'), answer
        assert f.actual.read_bytes() == mine and not f.generated.exists() and not f.call('theme', 'status')['owned']
        f.actual.write_bytes(pre)
        passed('a later edit to the generated file or the loader block stays as the person made it; only that claim goes and Restore finishes the rest')

        for stale in ['target', 'pack', 'asset', 'style', 'binding', 'ledger', 'link']:
            saved = f.snapshot()
            path = f.actual
            if stale == 'asset':
                f.packs[0]['wallpapers'] = ['image.png']; (f.root / 'packs/a/image.png').write_bytes(WALLPAPER_A); f.save_pack(f.packs[0])
            plan = f.plan()
            restore = None
            if stale == 'target':
                old = path.read_bytes(); path.write_bytes(old + b'\n# changed'); restore = lambda: path.write_bytes(old)
            elif stale == 'pack':
                f.packs[0]['title'] += ' changed'; f.save_pack(f.packs[0])
            elif stale == 'asset':
                (f.root / 'packs/a/image.png').write_bytes(WALLPAPER_B)
            elif stale == 'style':
                f.controls(style='toybox')
            elif stale == 'binding':
                old = f.manifest.read_text(); f.manifest.write_text(old + ' '); restore = lambda: f.manifest.write_text(old)
            elif stale == 'ledger':
                state = f.root / 'state/ownership.json'; old = state.read_bytes(); state.write_bytes(old + b' '); restore = lambda: state.write_bytes(old)
            elif stale == 'link':
                f.config.unlink(); f.config.symlink_to('pilot-theme.conf'); restore = lambda: (f.config.unlink(), f.config.symlink_to('dotfiles/ghostty'))
            changed = f.snapshot()
            f.call('theme', 'apply', plan, ok=False)
            assert f.snapshot() == changed
            if restore: restore()
            f.controls()
        passed('immutable plans reject changed files/pack/assets/style/bindings/ledger/link without writes')

        # Changes during the real Allow suspension, plus a concurrent mutation request.
        for stale in ['target', 'pack', 'asset', 'binding', 'ledger', 'style', 'link']:
            for flag in ['asked', 'go']:
                (f.root / flag).unlink(missing_ok=True)
            f.controls(hold='yes')
            plan = f.plan()
            with concurrent.futures.ThreadPoolExecutor() as pool:
                pending = pool.submit(f.call, 'theme', 'apply', plan, ok=False)
                deadline = time.monotonic() + 10
                while not (f.root / 'asked').exists() and time.monotonic() < deadline: time.sleep(.05)
                assert (f.root / 'asked').exists(), 'Allow not reached'
                if stale == 'target':
                    old = f.actual.read_bytes(); f.actual.write_bytes(old + b'\n# Allow edit'); undo = lambda: f.actual.write_bytes(old)
                elif stale == 'pack':
                    target = f.root / 'packs/a/manifest.json'; old = target.read_bytes(); target.write_bytes(old + b' '); undo = lambda: target.write_bytes(old)
                elif stale == 'asset':
                    target = f.root / 'packs/a/image.png'; old = target.read_bytes(); target.write_bytes(WALLPAPER_A if old == WALLPAPER_B else WALLPAPER_B); undo = lambda: target.write_bytes(old)
                elif stale == 'binding':
                    old = f.manifest.read_bytes(); f.manifest.write_bytes(old + b' '); undo = lambda: f.manifest.write_bytes(old)
                elif stale == 'ledger':
                    target = f.root / 'state/ownership.json'; old = target.read_bytes(); target.write_bytes(old + b' '); undo = lambda: target.write_bytes(old)
                elif stale == 'style':
                    f.controls(style='toybox', hold='yes'); undo = lambda: None
                elif stale == 'link':
                    f.config.unlink(); f.config.symlink_to('pilot-theme.conf'); undo = lambda: (f.config.unlink(), f.config.symlink_to('dotfiles/ghostty'))
                unchanged = f.snapshot()
                # Second mutation cannot race the first while approval is outstanding.
                second = f.plan('b') if stale not in ['link'] else plan
                f.call('theme', 'apply', second, ok=False)
                (f.root / 'go').touch()
                pending.result(timeout=10)
                assert f.snapshot() == unchanged
                undo()
            f.controls()
        passed('post-Allow revalidation rejects every changed input; concurrent mutation refused')

        # Schema/role/marker/compatibility and ownership overlap validation.
        for change in [dict(schema=2), dict(palette={}), dict(destination='/outside'), dict(styles=['unknown']),
                       dict(wallpapers=['../outside']), dict(adapters={'ghostty': {'command': 'run'}})]:
            bad = dict(f.packs[0], **change); f.save_pack(bad)
            before = f.snapshot(); f.call('theme', 'check', 'a', ok=False); assert f.snapshot() == before
        f.save_pack(f.packs[0])
        bad = dict(f.packs[0], styles=['toybox']); f.save_pack(bad); f.call('theme', 'plan', 'apply', 'a', ok=False); f.save_pack(f.packs[0])
        old = f.actual.read_bytes()
        for text in [b'\n# >>> Pilot theme pack >>>', b'\n# <<< Pilot theme pack <<<',
                     b'\n# >>> Pilot theme pack >>>\n# >>> Pilot theme pack >>>\n# <<< Pilot theme pack <<<']:
            f.actual.write_bytes(old + text); before = f.snapshot(); f.call('theme', 'plan', 'apply', 'a', ok=False); assert f.snapshot() == before
        f.actual.write_bytes(old)
        passed('unsupported schema/roles/authority/adapters/assets/style and malformed/duplicate markers fail closed')

        # Writer containment: outside sentinel, broken links, initial hard links, file/parent aliasing.
        sentinel = EVIDENCE / ('outside-' + uuid.uuid4().hex[:6]); sentinel.write_bytes(b'OUTSIDE UNCHANGED')
        # A config link out of the folder is now allowed (Sven's dotfiles decision); linked_config proves what still refuses.
        for kind in ['broken', 'hardlink', 'overlap']:
            f.config.unlink()
            if kind == 'broken': f.config.symlink_to('does-not-exist')
            elif kind == 'hardlink': os.link(f.actual, f.config)
            elif kind == 'overlap': f.config.symlink_to('pilot-theme.conf')
            before = f.snapshot(); f.call('theme', 'plan', 'apply', 'a', ok=False); assert f.snapshot() == before
            assert sentinel.read_bytes() == b'OUTSIDE UNCHANGED'
        f.config.unlink(); f.config.symlink_to('dotfiles/ghostty')
        plan = f.plan()
        parent = f.root / 'app/dotfiles'
        moved = f.root / 'app/retained-dotfiles'
        parent.rename(moved)
        parent.symlink_to(EVIDENCE, target_is_directory=True)
        try:
            f.call('theme', 'apply', plan, ok=False)
            assert sentinel.read_bytes() == b'OUTSIDE UNCHANGED'
        finally:
            parent.unlink()
            moved.rename(parent)
        passed('escaping/broken/internal-alias/hardlink targets rejected; outside sentinel unchanged')

        # Every transaction stage and effect failure reports its actual outcome. Baseline stays A on failed B.
        f.apply()
        for stage in ['journal', 'write:0', 'write:1', 'after-write:0', 'after-write:1', 'ledger']:
            before = f.snapshot(); f.controls(fail=stage)
            result = f.call('theme', 'apply', f.plan('b'), ok=stage != 'journal')
            if stage != 'journal':
                assert result['status'] == 'failed' and result['recovery']['status'] == 'rollback verified', result
                assert result['refresh'] == 'not attempted'
            assert f.snapshot() == before, stage
            f.controls()
        f.controls(fail='effect'); result = f.apply('b'); assert result['files'] == 'verified' and 'failed:' in result['refresh']
        result = f.restore()
        assert result['status'] == 'restored' and result['files'] == 'verified' and 'failed:' in result['refresh']
        f.controls()
        passed('journal/each staged write/ledger failures recover immediate pre-operation A; effect failure honestly keeps committed files and reload-needed outcome')

        # Interrupted operations reconcile from observed pre/post state after a host restart.
        for crash in ['after-write:0', 'after-write:1', 'after-ledger']:
            f.apply(); before = f.snapshot()
            f.controls(crash=crash)
            f.call('theme', 'apply', f.plan('b'), ok=False)
            f.stop(crashed=True); f.controls(); f.start()
            selected = f.call('theme', 'status')['selected']['id']
            assert selected == ('b' if crash == 'after-ledger' else 'a')
            assert not (f.root / 'state/pending.json').exists()
            if crash != 'after-ledger': assert f.snapshot() == before
            f.restore()
        passed('pending-operation restart rolls back pre-ledger writes and verifies post-ledger commit')

        # Rollback conflict is retained, recoverable on restart; corrupt ledger never unlocks mutation.
        f.apply()
        f.controls(fail='write:1+rollback:0')
        result = f.apply('b')
        assert result['status'] == 'failed' and result['recovery']['status'] == 'recovery retained'
        assert (f.root / 'state/pending.json').exists()
        f.call('theme', 'plan', 'apply', 'a', ok=False)
        f.stop(); f.controls(); f.start(); f.restore()
        state = f.root / 'state/ownership.json'; good = state.read_bytes(); state.write_text('{bad ledger')
        before = f.snapshot(); f.call('theme', 'plan', 'apply', 'a', ok=False); assert f.snapshot() == before
        state.write_bytes(good)
        passed('failed rollback retains journal/ownership and blocks new work; restart recovers; corrupt ledger refuses mutation')

        f.stop()
        f.start(extra_env={'PILOT_SANDBOX_ALLOW': '1'}, expect_ready=False)
        assert 'incompatible fixture environment' in (f.root / f'host-{f.counter}.log').read_text()
        passed('fixture rejects incompatible generic sandbox auto-Allow environment')

        for baseline in [None, b'', b'# Original LF\n', b'# Original no newline',
                         b'# Before\r\n# >>> Pilot theme pack >>>\r\nconfig-file = ?original.conf\r\n# <<< Pilot theme pack <<<\r\n# After']:
            other = Fixture('bytes'); fixtures.append(other)
            other.config.unlink()
            if baseline is None:
                other.actual.unlink()
            else:
                other.config.write_bytes(baseline)
            other.start(); other.apply(); other.apply('b'); other.stop(); other.start(); other.restore()
            assert other.config.exists() == (baseline is not None)
            if baseline is not None: assert other.config.read_bytes() == baseline
            assert not other.generated.exists()
            other.stop()
        passed('absent/empty/LF/no-final-newline configs and existing marked regions restore exactly across A/B/restart')

        # The newline after an end marker belongs to surrounding text, including a later CRLF suffix.
        for baseline in [b'# LF\n', b'# CRLF\r\n', b'# No final newline']:
            other = Fixture('marker-boundary'); fixtures.append(other)
            other.actual.write_bytes(baseline)
            other.start(); other.apply(); other.apply('b')
            suffix = b'\r\n# Later unrelated CRLF\r\n'
            other.actual.write_bytes(other.actual.read_bytes() + suffix)
            other.stop(); other.start(); other.restore()
            assert other.actual.read_bytes() == baseline + suffix
            other.preserved(); other.stop()
        passed('end-marker boundary excludes later CRLF suffix for LF/CRLF/no-final-newline originals')

        other = Fixture('links'); fixtures.append(other)
        actual_include = other.root / 'app/dotfiles/colours'
        actual_include.write_bytes(b'# Keep original colours\nbackground = #fefefe\n')
        actual_include.chmod(0o640)
        other.generated.symlink_to('dotfiles/colours')
        other.start(); other.apply(); other.apply('b'); other.stop(); other.start(); other.restore()
        assert other.generated.is_symlink() and os.readlink(other.generated) == 'dotfiles/colours'
        assert actual_include.read_bytes() == b'# Keep original colours\nbackground = #fefefe\n'
        assert stat.S_IMODE(actual_include.stat().st_mode) == 0o640
        other.preserved(); other.stop()
        passed('generated include internal symlink and target mode survive Apply/switch/Restore')

        # An unexpected post-crash owned edit remains conflicted; resolving it allows retry without losing unrelated edits.
        other = Fixture('recovery'); fixtures.append(other)
        other.start(); other.apply()
        other.controls(crash='after-write:1')
        other.call('theme', 'apply', other.plan('b'), ok=False); other.stop(crashed=True)
        written = other.generated.read_bytes()
        other.generated.write_bytes(written + b'# external owned edit\n')
        other.actual.write_bytes(other.actual.read_bytes() + b'\r\n# Keep later recovery edit')
        other.controls(); other.start()
        assert (other.root / 'state/pending.json').exists()
        assert other.generated.read_bytes().endswith(b'# external owned edit\n')
        other.call('theme', 'plan', 'restore', ok=False)
        other.stop(); other.generated.write_bytes(written); other.start()
        assert not (other.root / 'state/pending.json').exists()
        other.restore()
        assert other.actual.read_bytes() == other.original + b'\r\n# Keep later recovery edit'
        other.stop()
        passed('unexpected restart state retains recovery and later owned edit; retry preserves unrelated later bytes')
        passed('lifecycle')
    finally:
        for fixture in fixtures:
            fixture.stop()
            fixture.receipt()
        (EVIDENCE / 'latest-fixtures.json').write_text(json.dumps([str(x.root) for x in fixtures], indent=2))


def review_fixes(passed):
    """Independent review regressions through the existing fixture lifecycle, never live targets."""
    failures, fixtures = [], []

    def fixture(label):
        f = Fixture(label); fixtures.append(f); return f

    def case(label, check):
        first = len(fixtures)
        try:
            check()
            passed('review ' + label)
        except Exception as error:
            failures.append(label + ': ' + str(error))
            print('RED review ' + failures[-1], flush=True)
        finally:
            for f in fixtures[first:]:
                f.stop(crashed=f.process is not None and f.process.poll() is not None)
                f.receipt()

    def invalid_data():
        f = fixture('invalid'); f.start()
        errors = []
        for field, value in [('background', '#123456\n'), ('accent', '#123456\r\n'), ('red', '#123456\r'),
                             ('cyan', '#１２３４５６'), ('green', '#12345g'), ('yellow', '#12345600'),
                             ('extra-role', '#123456\n')]:
            pack = dict(f.packs[0], palette=dict(f.packs[0]['palette'], **{field: value}))
            f.save_pack(pack); before = f.snapshot()
            for operation in ['show', 'check', 'plan']:
                try: f.call('theme', operation, *(['apply', 'a'] if operation == 'plan' else ['a']), ok=False)
                except AssertionError: errors.append(f'{operation} accepted {field}={value!r}')
            assert f.snapshot() == before
        for identity in ['a\n', 'a\r\n', '-a', 'A', 'a'*81, 'á', 'a/b']:
            rejected = f.call('theme', 'show', identity, ok=False)
            assert rejected['error']['message'] == 'invalid pack id', rejected
            # Manifest identity is invalid even when the folder itself is valid.
            (f.root / 'packs/a/manifest.json').write_text(json.dumps(dict(f.packs[0], id=identity)))
            try: f.call('theme', 'check', 'a', ok=False)
            except AssertionError: errors.append(f'accepted manifest identity {identity!r}')
        f.save_pack(f.packs[0])
        # The exact crashing example must also be refused before committing/publishing appearance.
        f.save_pack(dict(f.packs[0], palette=dict(f.packs[0]['palette'], background='#123456\n')))
        before = f.snapshot()
        try:
            plan = f.plan(); f.call('theme', 'apply', plan, ok=False)
            errors.append('LF reached Apply; host=' + str(f.process.poll()))
        except AssertionError as error:
            if f.process.poll() is not None: errors.append('LF crashed appearance after persistence: ' + str(error))
        f.stop(crashed=f.process is not None and f.process.poll() is not None)
        if not errors:
            assert f.snapshot() == before
        # A previously malformed persisted selection must refuse startup without a numeric-conversion trap.
        f.save_pack(f.packs[0]); f.controls(); f.start(); f.apply(); f.stop()
        ledger = f.root / 'state/ownership.json'
        good = ledger.read_bytes()
        for value in ['#123456\n', '#123456\r\n']:
            record = json.loads(good); record['selected']['palette']['background'] = value
            ledger.write_text(json.dumps(record)); before = f.snapshot()
            f.start(expect_ready=False)
            log = (f.root / f'host-{f.counter}.log').read_text()
            assert 'invalid schema' in log and 'Unexpectedly found nil' not in log, log[-1000:]
            assert f.snapshot() == before
        appearance_probe()
        assert not errors, '; '.join(errors)

    def interrupted_restore():
        errors = []
        for baseline, suffix in [(b'# LF\n', b'# Later comment'),
                                 (b'# CRLF\r\n', b'\r\n# Other comment'),
                                 (b'# No newline', b'\n# Other placement\n'),
                                 (b'# LF\n', b'# Later terminated\n')]:
            f = fixture('restore-position'); f.actual.write_bytes(baseline)
            f.start(); f.apply(); old_owned = f.actual.read_bytes()
            f.controls(crash='after-write:1'); f.call('theme', 'restore', f.plan(None), ok=False)
            f.stop(crashed=True)
            post = f.actual.read_bytes(); f.actual.write_bytes(post + suffix)
            changed = f.actual.read_bytes(); f.controls(); f.start()
            pending = f.root / 'state/pending.json'
            # Unsafe absent-block insertion must retain exact unrelated bytes and durable recovery.
            if not pending.exists() or f.actual.read_bytes() != changed:
                errors.append(f'baseline={baseline!r} suffix={suffix!r}: journal={pending.exists()} bytes={f.actual.read_bytes()!r}')
            else:
                f.call('theme', 'plan', 'apply', 'a', ok=False)
                f.stop(); f.actual.write_bytes(post); f.start()
                assert not pending.exists() and f.actual.read_bytes() == old_owned
                assert f.restore()['status'] == 'restored' and f.actual.read_bytes() == baseline
            f.stop(); f.preserved()
        assert not errors, '; '.join(errors)

    def protected_aliases():
        errors = []
        for kind in ['direct', 'indirect', 'parent', 'config']:
            f = fixture('legacy-alias')
            if kind == 'config': f.config.unlink(); f.config.symlink_to('pilot.conf')
            elif kind == 'direct': f.generated.symlink_to('pilot.conf')
            elif kind == 'indirect':
                (f.root / 'app/font-alias').symlink_to('pilot.conf'); f.generated.symlink_to('font-alias')
            else:
                (f.root / 'app/parent-link').symlink_to('dotfiles'); (f.root / 'app/dotfiles/font-alias').symlink_to('../pilot.conf')
                f.generated.symlink_to('parent-link/font-alias')
            f.start(); before = f.snapshot()
            try: f.call('theme', 'check', 'a', ok=False)
            except AssertionError:
                errors.append(kind + ' alias accepted'); f.apply()
            if f.snapshot() != before or f.fonts.read_bytes() != f.font_original: errors.append(kind + ' protected bytes mutated')
            f.stop()
        # A protected resource can change to overlap AFTER planning, including through a parent link.
        for during_allow in [False, True]:
            for kind in ['leaf', 'parent']:
                f = fixture('legacy-fresh'); f.generated.write_bytes(b'# separate colours\n')
                if kind == 'parent':
                    (f.root / 'app/fonts').mkdir(); (f.root / 'app/fonts/pilot.conf').write_bytes(f.font_original)
                    (f.root / 'app/old-fonts').symlink_to('fonts', target_is_directory=True)
                    f.fonts.unlink(); f.fonts.symlink_to('old-fonts/pilot.conf')
                    (f.root / 'app/dotfiles/pilot.conf').symlink_to('../pilot-theme.conf')
                f.start(); f.controls(hold='yes' if during_allow else 'no'); plan = f.plan()
                def swap():
                    if kind == 'leaf': f.fonts.unlink(); f.fonts.symlink_to('pilot-theme.conf')
                    else:
                        link = f.root / 'app/old-fonts'; link.unlink(); link.symlink_to('dotfiles', target_is_directory=True)
                if during_allow:
                    with concurrent.futures.ThreadPoolExecutor() as pool:
                        pending = pool.submit(f.call, 'theme', 'apply', plan, ok=False)
                        deadline = time.monotonic() + 10
                        while not (f.root / 'asked').exists() and time.monotonic() < deadline: time.sleep(.05)
                        assert (f.root / 'asked').exists(); swap(); changed = f.snapshot(); (f.root / 'go').touch()
                        try: pending.result(timeout=10)
                        except AssertionError: errors.append(kind + ' post-Allow freshness accepted')
                else:
                    swap(); changed = f.snapshot(); f.controls()
                    try: f.call('theme', 'apply', plan, ok=False)
                    except AssertionError: errors.append(kind + ' freshness accepted')
                if f.snapshot() != changed: errors.append(kind + ' stale alias mutated files')
                f.stop()
        assert not errors, '; '.join(errors)

    def committed_outcomes():
        errors = []
        for operation in ['apply', 'restore']:
            for stage in ['after-ledger', 'cleanup', 'after-cleanup', 'cleanup+recovery-cleanup', 'after-ledger+effect']:
                f = fixture('committed'); f.start(); f.apply()
                f.controls(fail=stage)
                try:
                    result = f.apply('b') if operation == 'apply' else f.restore()
                    selected = 'b' if operation == 'apply' else None
                    ledger = json.loads((f.root / 'state/ownership.json').read_text())
                    f.stop()
                    log = (f.root / f'host-{f.counter}.log').read_text()
                    appearances = [line for line in log.splitlines() if line.startswith('THEME appearance:')]
                    expected = ('THEME appearance: b ground=' + str(int(f.packs[1]['palette']['background'][1:], 16))) if selected else appearances[0]
                    if result.get('status') != ('applied' if selected else 'restored') or result.get('files') != 'verified' or appearances[-1] != expected:
                        errors.append(f'{operation}/{stage}: {result}; last appearance={log.rsplit("THEME appearance:", 1)[-1][:80]}')
                    assert (ledger.get('selected') or {}).get('id') == selected
                    if stage == 'cleanup+recovery-cleanup':
                        if not (f.root / 'state/pending.json').exists(): errors.append('cleanup fault was not exercised')
                    if stage.endswith('effect'): assert 'failed:' in result['refresh']
                    else: assert 'recorded;' in result['refresh']
                    f.stop(); f.controls(); f.start()
                    assert not (f.root / 'state/pending.json').exists()
                    f.stop(); f.preserved()
                except AssertionError as error:
                    errors.append(f'{operation}/{stage}: {error}')
                finally:
                    f.stop()
        assert not errors, '; '.join(errors)

    def native_outcome():
        # Compile the actual native formatter (or the reviewed inline expression), with the real JSONValue.
        source = (REPO / 'Sources/Pilot/UI/LookPage.swift').read_text()
        if '\nfunc themeOutcomeText(' in source:
            function = source[source.index('\nfunc themeOutcomeText(')+1:]
            function = function[:function.index('\n}')+2]
            details = source[source.index('\nfunc themeOutcomeDetails(')+1:]
            function += '\n' + details[:details.index('\n}')+2]
        else:
            begin = source.index('outcome = ["status"')
            end = source.index('.joined(separator: ". ")', begin) + len('.joined(separator: ". ")')
            function = 'func themeOutcomeText(_ result: JSONValue) -> String {\nif case .object(let values) = result {\n' + source[begin:end].replace('outcome =', 'return', 1) + '\n}\nreturn ""\n}'
        scratch = REPO / '.build/theme-outcome-proof'; scratch.mkdir(exist_ok=True)
        main = scratch / 'main.swift'
        main.write_text('import Foundation\n' + function + '\nwhile let line = readLine() {\nlet value = try JSONDecoder().decode(JSONValue.self, from: Data(line.utf8))\nprint(String(data: try JSONEncoder().encode(themeOutcomeText(value) + "\\n" + themeOutcomeDetails(value)), encoding: .utf8)!)\n}\n')
        command = ['nice', '-n', '10', 'swiftc', '-j', '4', str(REPO / 'Sources/PilotCore/JSONValue.swift'), str(main), '-o', str(scratch / 'format')]
        build = subprocess.run(command, text=True, capture_output=True)
        (EVIDENCE / 'native-format-build.json').write_text(json.dumps(dict(command=command, exit=build.returncode, stdout=build.stdout, stderr=build.stderr)))
        (EVIDENCE / 'native-format-source.swift').write_text(main.read_text())
        assert build.returncode == 0, build.stderr
        f = fixture('native-outcome'); f.start(); f.apply(); f.controls(fail='write:1+rollback:0')
        result = f.apply('b'); assert result['recovery']['status'] == 'recovery retained'
        variant = dict(result, recovery=dict(status='rollback verified', rows=[dict(path='nested/other.conf', rollback='attempted; verified')]))
        run = subprocess.run([str(scratch / 'format')], input='\n'.join(json.dumps(x) for x in [result, variant])+'\n', text=True, capture_output=True)
        (EVIDENCE / 'native-format-run.json').write_text(json.dumps(dict(inputs=[result, variant], exit=run.returncode, stdout=run.stdout, stderr=run.stderr)))
        assert run.returncode == 0, run.stderr
        outputs = [json.loads(line) for line in run.stdout.splitlines()]
        for answer, text in zip([result, variant], outputs):
            assert ('could not put everything back' if answer['recovery']['status'] == 'recovery retained' else 'went back as it was') in text, text
            for row in answer['recovery']['rows']:
                assert row['path'] in text and row['rollback'] in text, text
        assert 'themeOutcomeText(result)' in source, 'native view must call the proven formatter'

    def grammar():
        f = fixture('grammar')
        for identity in ['restore', 'restore-near']:
            (f.root / 'packs' / identity).mkdir(); f.save_pack(dict(f.packs[0], id=identity))
        f.start()
        source = (REPO / 'Sources/Pilot/UI/LookPage.swift').read_text()
        assert '.plan(id)' in source and '.store.list()' in source and '.press(id)' in source
        errors = []
        for identity in ['restore', 'restore-near']:
            assert identity in [p['id'] for p in f.call('theme', 'list')]
            for verb in ['show', 'check']: assert f.call('theme', verb, identity)['pack']['id'] == identity
            try:
                plan = f.call('theme', 'plan', 'apply', identity)
                assert plan['pack'] == identity and plan['operation'] == 'apply'
                assert f.call('theme', 'apply', plan['id'])['status'] == 'applied'
                assert f.call('theme', 'status')['selected']['id'] == identity
                restore = f.call('theme', 'plan', 'restore')
                assert restore['operation'] == 'restore' and restore['pack'] is None
                assert f.call('theme', 'restore', restore['id'])['status'] == 'restored'
            except AssertionError as error: errors.append(str(error))
        assert not errors, '; '.join(errors)

    for label, check in [('1 exact ASCII palette and identity', invalid_data),
                         ('2 interrupted Restore placement', interrupted_restore),
                         ('3 protected legacy alias and freshness', protected_aliases),
                         ('4 committed recovery outcomes and appearance', committed_outcomes),
                         ('5 native recovery formatting', native_outcome),
                         ('6 unambiguous CLI operation and accepted IDs', grammar),
                         ('7 participating apps without Ghostty directory', lambda: participation_fixes(passed)),
                         ('8 contained legacy alias for every file adapter', lambda: contained_legacy_aliases(passed)),
                         ('9 detected Zed and Obsidian vaults follow with nothing typed', lambda: detected_apps(passed)),
                         ('10 Ghostty config linked out of its folder, as on a dotfiles Mac', lambda: linked_config(passed)),
                         ('11 Ghostex window and sidebar colour through a recording fake', lambda: ghostex_interface(passed)),
                         ('12 Allow names every app, however many there are', lambda: allow_names_apps(passed)),
                         ('13 the main thread answers while Apply and Restore wait on macOS\'s mode and Ghostex', lambda: main_thread(passed))]:
        case(label, check)
    (EVIDENCE / 'review-fix-fixtures.json').write_text(json.dumps([str(f.root) for f in fixtures], indent=2))
    for name in ['theme-outcome-proof', 'theme-appearance-proof']:
        shutil.rmtree(REPO / '.build' / name, ignore_errors=True)
    assert not failures, '\n'.join(failures)


def participation_fixes(passed):
    """Independently authored inputs at the public CLI seam; never create the Ghostty root."""
    failures = []
    for kind in ['palette', 'zed', 'obsidian', 'custom']:
        f = Fixture('ng-' + kind, ghostty=False)
        native = f.root / 'native.json'
        original_native = dict(palette={'stock': {'_0': 'lagoon'}}, material=dict(glass=False, transparency=43, blur='light'))
        native.write_text(json.dumps(original_native))
        f.settings.update(nativeState=str(native), nativeBaseline=original_native)
        destination = f.root / kind
        destination.mkdir()
        target = destination / 'settings.json'
        if kind == 'zed':
            (destination / 'themes').mkdir()
            target.write_bytes(b'{ /* Keep */ "theme":"Keep theme", "buffer_font_family":"Keep font" }\n')
            f.settings['zed'] = dict(root=str(destination), config=target.name, generated='themes/pilot-theme.json')
        elif kind == 'obsidian':
            (destination / '.obsidian/snippets').mkdir(parents=True)
            target = destination / '.obsidian/appearance.json'
            target.write_bytes(b'{ /* Keep */ "enabledCssSnippets":["personal"], "textFontFamily":"Keep font" }\n')
            f.settings['obsidian'] = [dict(root=str(destination), config='.obsidian/appearance.json', generated='.obsidian/snippets/pilot-theme.css')]
        elif kind == 'custom':
            app = f.root / 'Compatible.app/Contents'
            app.mkdir(parents=True)
            (app / 'Info.plist').write_bytes(b'fixture metadata, never executed\n')
            target.write_bytes(b'{ /* Keep */ "accent":"baseline", "font":"Keep font" }\n')
            f.settings['custom'] = [dict(id='ink', root=str(destination), path=target.name, app=str(app.parent))]
        for pack in f.packs:
            pack['adapters'] = {kind: {}} if kind in ['zed', 'obsidian'] else {}
            if kind == 'custom':
                pack['customMappings'] = [dict(id='ink', ownership={'json': {'path': ['accent']}}, template='"{{accent}}"')]
            f.save_pack(pack)
        f.manifest.write_text(json.dumps(f.settings))
        sentinel = f.root / 'outside-sentinel'
        sentinel.write_bytes(b'outside and fonts stay unchanged\n')

        def files():
            return {str(p.relative_to(f.root)): digest(p) for base in [destination, f.root / 'Compatible.app']
                    for p in base.rglob('*') if p.is_file() or p.is_symlink()}

        original = files()
        (f.root / 'participation-before.json').write_text(json.dumps(original, indent=2))

        def safe():
            assert not (f.root / 'app').exists(), 'nonparticipating Ghostty root was created'
            assert sentinel.read_bytes() == b'outside and fonts stay unchanged\n'

        def restored():
            safe()
            assert files() == original and json.loads(native.read_text()) == original_native
            ledger = json.loads((f.root / 'state/ownership.json').read_text())
            assert ledger['claims'] == [] and ledger.get('selected') is None and ledger.get('appearance') is None
            assert not (f.root / 'state/pending.json').exists()

        try:
            f.start(); safe()
            before = (f.snapshot(), files(), digest(native))
            f.call('theme', 'check', 'a')
            plan = f.call('theme', 'plan', 'apply', 'a')
            assert not any('Ghostty' in warning or 'older settings' in warning for warning in plan['warnings'])
            assert (f.snapshot(), files(), digest(native)) == before
            safe()
            assert f.call('theme', 'apply', plan['id'])['status'] == 'applied'; safe()
            first = json.loads((f.root / 'state/ownership.json').read_text())
            assert f.apply('b')['status'] == 'applied'; safe()
            second = json.loads((f.root / 'state/ownership.json').read_text())
            assert [c.get('original') for c in first['claims']] == [c.get('original') for c in second['claims']]
            assert first['appearance']['original'] == second['appearance']['original']
            f.stop(); safe(); f.start(); safe()
            assert f.call('theme', 'status')['selected']['id'] == 'b'
            assert f.restore()['status'] == 'restored'; restored()
            # Exercise both precommit rollback and committed verification on startup,
            # including an interrupted Restore, without any Ghostty resource available.
            for crash in (['after-native', 'after-ledger'] if kind == 'palette' else ['after-write:0', 'after-native', 'after-ledger']):
                f.apply(); safe()
                before = (files(), json.loads(native.read_text()), (f.root / 'state/ownership.json').read_bytes())
                f.controls(crash=crash)
                f.call('theme', 'apply', f.plan('b'), ok=False); f.stop(crashed=True); safe()
                assert (f.root / 'state/pending.json').exists()
                f.controls(); f.start(); safe()
                assert not (f.root / 'state/pending.json').exists()
                assert f.call('theme', 'status')['selected']['id'] == ('b' if crash == 'after-ledger' else 'a')
                if crash != 'after-ledger':
                    assert (files(), json.loads(native.read_text()), (f.root / 'state/ownership.json').read_bytes()) == before
                f.controls(crash=crash)
                f.call('theme', 'restore', f.plan(None), ok=False); f.stop(crashed=True); safe()
                f.controls(); f.start(); safe()
                assert not (f.root / 'state/pending.json').exists()
                if crash != 'after-ledger': assert f.restore()['status'] == 'restored'
                restored()
            passed(kind + '-only check/plan effectfree; Apply/switch/restart/Restore and interrupted recovery; Ghostty folder always absent; baseline/ledger/outside/font sentinels preserved')
        except Exception as error:
            failures.append(kind + ': ' + str(error))
        finally:
            f.stop(crashed=f.process is not None and f.process.poll() is not None)
            safe(); f.receipt()
            (f.root / 'participation-after.json').write_text(json.dumps(files(), indent=2))
    assert not failures, '\n'.join(failures)
    participation_guards(passed)


def participation_guards(passed):
    f = Fixture('required', ghostty=False)
    try:
        f.start(); before = f.snapshot()
        for words in [('check', 'a'), ('plan', 'apply', 'a')]:
            f.call('theme', *words, ok=False)
            assert f.snapshot() == before and not (f.root / 'app').exists()
    finally:
        f.stop(); f.receipt()
    f = Fixture('owned')
    try:
        f.start(); f.apply(); f.controls(crash='after-write:0')
        f.call('theme', 'apply', f.plan('b'), ok=False); f.stop(crashed=True)
        app, held = f.root / 'app', f.root / 'held-app'
        app.rename(held)
        before = f.snapshot(); pending = (f.root / 'state/pending.json').read_bytes()
        held_before = {str(p.relative_to(held)): digest(p) for p in held.rglob('*') if p.is_file() or p.is_symlink()}
        f.controls(); f.start(expect_ready=False)
        assert not app.exists() and f.snapshot() == before and (f.root / 'state/pending.json').read_bytes() == pending
        assert {str(p.relative_to(held)): digest(p) for p in held.rglob('*') if p.is_file() or p.is_symlink()} == held_before
        held.rename(app); f.start()
        assert not (f.root / 'state/pending.json').exists()
        f.stop(); app.rename(held); f.start(); before = f.snapshot()
        f.call('theme', 'plan', 'restore', ok=False); f.call('theme', 'plan', 'apply', 'b', ok=False)
        assert f.snapshot() == before and not app.exists()
        f.stop(); held.rename(app); f.start(); f.restore(); f.preserved()
    finally:
        f.stop(crashed=f.process is not None and f.process.poll() is not None); f.receipt()
    passed('requested and previously owned missing Ghostty root refuse planning/recovery without mutation; pending journal and held font bytes retained; recovery succeeds only after explicit fixture root return')

    for spelling in ['pilot.conf', 'PILOT.CONF', 'alias/pilot.conf']:
        f = Fixture('custom-alias')
        app = f.root / 'Compatible.app/Contents'; app.mkdir(parents=True)
        (app / 'Info.plist').write_bytes(b'never executed\n')
        (f.root / 'app/alias').symlink_to('.', target_is_directory=True)
        f.settings['custom'] = [dict(id='ink', root=str(f.root / 'app'), path=spelling, app=str(app.parent))]
        f.manifest.write_text(json.dumps(f.settings)); before = f.snapshot()
        try:
            f.start(expect_ready=False)
            assert 'custom destination aliases protected built-in/store/state/app resource' in (f.root / 'host-1.log').read_text()
            assert f.snapshot() == before and f.fonts.read_bytes() == f.font_original
        finally:
            f.stop(); f.receipt()
    for parent, during_allow in [(parent, during) for parent in [False, True] for during in [False, True]]:
        f = Fixture('custom-fresh')
        custom = f.root / 'custom'; custom.mkdir()
        target = custom / 'settings.json'; target.write_bytes(b'{"accent":"old", "font":"Keep"}\n')
        app = f.root / 'Compatible.app/Contents'; app.mkdir(parents=True)
        (app / 'Info.plist').write_bytes(b'never executed\n')
        f.settings['custom'] = [dict(id='ink', root=str(custom), path=target.name, app=str(app.parent))]
        for pack in f.packs:
            pack['adapters'] = {}
            pack['customMappings'] = [dict(id='ink', ownership={'json': {'path': ['accent']}}, template='"{{accent}}"')]
            f.save_pack(pack)
        if parent:
            (f.root / 'app/fonts').mkdir(); (f.root / 'app/fonts/settings.json').write_bytes(f.font_original)
            (f.root / 'app/font-parent').symlink_to('fonts', target_is_directory=True)
            f.fonts.unlink(); f.fonts.symlink_to('font-parent/settings.json')
        f.manifest.write_text(json.dumps(f.settings))
        try:
            f.start(); f.controls(hold='yes' if during_allow else 'no'); plan = f.plan()
            def swap():
                if parent:
                    link = f.root / 'app/font-parent'; link.unlink(); link.symlink_to('../custom', target_is_directory=True)
                else:
                    f.fonts.unlink(); f.fonts.symlink_to('../custom/settings.json')
            if during_allow:
                with concurrent.futures.ThreadPoolExecutor() as pool:
                    pending = pool.submit(f.call, 'theme', 'apply', plan, ok=False)
                    deadline = time.monotonic() + 10
                    while not (f.root / 'asked').exists() and time.monotonic() < deadline: time.sleep(.05)
                    assert (f.root / 'asked').exists()
                    swap(); before, target_before = f.snapshot(), digest(target); (f.root / 'go').touch()
                    pending.result(timeout=10)
            else:
                swap(); before, target_before = f.snapshot(), digest(target)
                f.call('theme', 'apply', plan, ok=False)
            assert f.snapshot() == before and digest(target) == target_before
            f.call('theme', 'check', 'a', ok=False)
            assert f.snapshot() == before and digest(target) == target_before
        finally:
            f.stop(); f.receipt()
    passed('custom-only protected legacy aliases refuse direct/alternate/parent spellings and legacy leaf/parent changes after planning; fonts and custom sentinels untouched')


def contained_legacy_aliases(passed):
    """A Ghostty root inside the adapter's own root: a link that passes containment must still never reach pilot.conf."""
    failures, live = [], []
    protected = {'obsidian': b'', 'zed': b'{ "theme":"Keep" }\n', 'custom': b'{ "accent":"baseline" }\n', 'ghostty': b'font-family = Keep\n'}

    def tree(root):
        return {str(p.relative_to(root)): digest(p) for p in root.rglob('*') if p.is_file() or p.is_symlink()}

    def setup(kind, label, target='colours', legacy=True):
        f = Fixture(f'la-{kind[:3]}-{label}', ghostty=False); live.append(f)  # The fixture's socket path stays under 100 bytes.
        vault, root = f.root / 'V', f.root / 'V/.config/ghostty'
        root.mkdir(parents=True)
        f.settings['binding']['root'] = str(root)
        pilot = root / 'pilot.conf'
        if legacy: pilot.write_bytes(protected[kind])
        name, link = 'pilot.conf' if target == 'pilot' else 'colours', 'colours'
        if kind == 'obsidian':
            (vault / '.obsidian/snippets').mkdir(parents=True)
            (vault / '.obsidian/appearance.json').write_bytes(b'{ "enabledCssSnippets":["personal"] }\n')
            (root / 'colours').write_bytes(b'')
            (vault / '.obsidian/snippets/pilot-theme.css').symlink_to('../../.config/ghostty/' + name)
            f.settings['obsidian'] = [dict(root=str(vault), config='.obsidian/appearance.json', generated='.obsidian/snippets/pilot-theme.css')]
        elif kind == 'zed':
            (vault / 'themes').mkdir()
            (root / 'colours').write_bytes(protected['zed'])
            (vault / 'settings.json').symlink_to('.config/ghostty/' + name)
            f.settings['zed'] = dict(root=str(vault), config='settings.json', generated='themes/pilot-theme.json')
        elif kind == 'custom':
            # A custom destination inside the Ghostty root is refused at selection, so its later link leaves that root.
            app = f.root / 'Compatible.app/Contents'; app.mkdir(parents=True)
            (app / 'Info.plist').write_bytes(b'never executed\n')
            if target == 'pilot': (vault / 'settings.json').symlink_to('.config/ghostty/pilot.conf')
            else: (vault / 'settings.json').write_bytes(protected['custom'])
            f.settings['custom'] = [dict(id='ink', root=str(vault), path='settings.json', app=str(app.parent))]
            link = '../../settings.json'
        else:
            (root / 'config').write_bytes(f.original)
            if target == 'pilot': (root / 'pilot-theme.conf').symlink_to('pilot.conf')
            link = 'config'
        for pack in f.packs:
            pack['adapters'] = {} if kind == 'custom' else {kind: {}}
            if kind == 'custom': pack['customMappings'] = [dict(id='ink', ownership={'json': {'path': ['accent']}}, template='"{{accent}}"')]
            f.save_pack(pack)
        f.manifest.write_text(json.dumps(f.settings))
        return f, vault, pilot, link

    def swap(pilot, link):
        pilot.rename(pilot.with_name('pilot.conf.held')); pilot.symlink_to(link)

    def unswap(pilot, original):
        pilot.unlink(); pilot.with_name('pilot.conf.held').rename(pilot)
        assert pilot.read_bytes() == original, 'protected bytes changed'

    def plan_refused(kind):
        f, vault, pilot, _ = setup(kind, 'plan', target='pilot')
        before, original = tree(vault), pilot.read_bytes()
        if kind == 'custom':
            f.start(expect_ready=False)
            assert 'custom destination aliases protected' in (f.root / 'host-1.log').read_text()
        else:
            f.start()
            try:
                f.call('theme', 'check', 'a', ok=False); f.call('theme', 'plan', 'apply', 'a', ok=False)
            except AssertionError:
                f.apply()
                raise AssertionError(f'alias accepted; Apply left pilot.conf = {pilot.read_bytes()[:60]!r}, was {original!r}')
        assert tree(vault) == before and pilot.read_bytes() == original

    def fresh_refused(kind, during_allow):
        f, vault, pilot, link = setup(kind, 'allow' if during_allow else 'fresh')
        original = pilot.read_bytes()
        f.start(); f.controls(hold='yes' if during_allow else 'no'); plan = f.plan()
        if during_allow:
            with concurrent.futures.ThreadPoolExecutor() as pool:
                pending = pool.submit(f.call, 'theme', 'apply', plan, ok=False)
                deadline = time.monotonic() + 10
                while not (f.root / 'asked').exists() and time.monotonic() < deadline: time.sleep(.05)
                assert (f.root / 'asked').exists(), 'Allow not reached'
                swap(pilot, link); changed = tree(vault); (f.root / 'go').touch()
                pending.result(timeout=10)
        else:
            swap(pilot, link); changed = tree(vault)
            f.call('theme', 'apply', plan, ok=False)
        assert tree(vault) == changed, 'wrote through a protected alias'
        unswap(pilot, original)

    def recovery_refused(kind):
        f, vault, pilot, link = setup(kind, 'recover')
        original = pilot.read_bytes()
        f.start(); f.controls(crash='after-write:0')
        f.call('theme', 'apply', f.plan(), ok=False); f.stop(crashed=True)
        pending = f.root / 'state/pending.json'
        assert pending.exists()
        journal, written = pending.read_bytes(), tree(vault)
        swap(pilot, link); changed = tree(vault)
        f.controls(); f.start(expect_ready=False)
        assert tree(vault) == changed and pending.read_bytes() == journal, 'recovery ran over a protected alias'
        unswap(pilot, original)
        assert tree(vault) == written
        f.start()
        assert not pending.exists() and pilot.read_bytes() == original

    def no_legacy(kind):
        f, vault, pilot, _ = setup(kind, 'none', legacy=False)
        before = tree(vault)
        f.start()
        assert f.apply()['status'] == 'applied' and not pilot.exists()
        assert f.restore()['status'] == 'restored' and tree(vault) == before and not pilot.exists()

    def palette_reads_nothing(kind):
        f = Fixture('la-palette', ghostty=False); live.append(f)
        root = f.root / 'gh'; root.mkdir()
        (root / 'pilot.conf').symlink_to('gone')  # Any read of this link throws, so success proves no read happened.
        native = f.root / 'native.json'
        baseline = dict(palette={'stock': {'_0': 'lagoon'}}, material=dict(glass=False, transparency=43, blur='light'))
        native.write_text(json.dumps(baseline))
        f.settings.update(nativeState=str(native), nativeBaseline=baseline)
        f.settings['binding']['root'] = str(root)
        for pack in f.packs:
            pack['adapters'] = {}; f.save_pack(pack)
        f.manifest.write_text(json.dumps(f.settings))
        before = tree(root)
        f.start(); f.call('theme', 'check', 'a')
        assert f.apply()['status'] == 'applied' and f.restore()['status'] == 'restored'
        assert tree(root) == before and json.loads(native.read_text()) == baseline

    def phase(name, kind, body, *arguments):
        live.clear()
        try:
            body(kind, *arguments)
            passed(f'contained legacy {kind} {name}')
        except Exception as error:
            failures.append(f'{kind} {name}: {error}')
            print('RED ' + failures[-1], flush=True)
        finally:
            for f in live:
                try: f.stop(crashed=f.process is not None and f.process.poll() is not None)
                except Exception as error: failures.append(f'{kind} {name} teardown: {error}')
                f.receipt()

    for kind in ['obsidian', 'zed', 'custom', 'ghostty']:
        phase('plan refuses alias; pilot.conf byte-identical', kind, plan_refused)
        phase('freshness refuses legacy swap before Allow', kind, fresh_refused, False)
        phase('freshness refuses legacy swap during Allow', kind, fresh_refused, True)
        phase('recovery refuses; journal and pilot.conf retained', kind, recovery_refused)
        phase('existing root without pilot.conf applies and restores, never creating it', kind, no_legacy)
    phase('no file targets read nothing under an existing root', 'palette', palette_reads_nothing)
    assert not failures, '\n'.join(failures)


def detected_apps(passed):
    """Production's detection pointed at a fixture home: no explicit binding, the real home never read, obsidian.json only data."""
    failures, live = [], []
    theme, appearance = b'{ /* Keep */ "theme":"Keep theme" }\n', b'{ "enabledCssSnippets":["personal"] }\n'

    def tree(*roots):
        return {str(p): digest(p) for root in roots for p in root.rglob('*') if p.is_file() or p.is_symlink()}

    def setup(label, zed=True, vaults=('one', 'two'), registry=None, folders=True, settings=theme, cursor=None, ghostex=None, ghostty=False, dark=None):
        f = Fixture('da-' + label, ghostty=False); live.append(f)
        home, store = f.root / 'home', f.root / 'vaults'
        home.mkdir(); store.mkdir()
        if zed:
            (home / '.config/zed').mkdir(parents=True)
            (home / '.config/zed/settings.json').write_bytes(settings)
            if folders: (home / '.config/zed/themes').mkdir()
        if ghostex is not None:
            (home / '.config/ghostex/ghostty').mkdir(parents=True)
            (home / '.config/ghostex/ghostty/config.ghostty').write_bytes(ghostex)
        roots = {}
        for name in vaults:
            roots[name] = store / name
            (roots[name] / '.obsidian').mkdir(parents=True)
            (roots[name] / '.obsidian/appearance.json').write_bytes(appearance)
            if folders: (roots[name] / '.obsidian/snippets').mkdir()
        file = home / 'Library/Application Support/obsidian/obsidian.json'
        if registry is not False:
            file.parent.mkdir(parents=True)
            file.write_bytes(json.dumps({'vaults': {n: {'path': str(r), 'ts': 1, 'open': True} for n, r in roots.items()}}).encode() if registry is None else registry)
        f.settings['detectHome'] = str(home)
        baseline = dict(palette={'stock': {'_0': 'lagoon'}}, material=dict(glass=False, transparency=43, blur='light'))
        if cursor: baseline['cursor'] = cursor
        if dark is not None: baseline['dark'] = dark  # macOS's mode as the fixture plays it; the real one is never read here.
        (f.root / 'native.json').write_text(json.dumps(baseline))  # As in the app, Pilot's own look changes even when no other app is here.
        f.settings.update(nativeState=str(f.root / 'native.json'), nativeBaseline=baseline)
        f.settings['binding']['root'] = str(f.root / 'gh')  # Created only for a pack that also themes Ghostty.
        if ghostex is not None:
            (f.root / 'gh').mkdir(); (f.root / 'gh/config').write_bytes(b'font-size = 14\n')
        for pack in f.packs:
            pack['adapters'] = {'zed': {}, 'obsidian': {}, **({'ghostty': {}} if ghostex is not None or ghostty else {})}; f.save_pack(pack)
        f.manifest.write_text(json.dumps(f.settings))
        return f, home, store, roots, file

    def css(root):
        return root / '.obsidian/snippets/pilot-theme.css'

    def zed_followed(home):
        return (home / '.config/zed/themes/pilot-theme.json').exists() and b'Keep theme' not in (home / '.config/zed/settings.json').read_bytes()

    def follows():
        f, home, store, roots, file = setup('full')
        before, registry = tree(home, store), (file.read_bytes(), digest(file))
        f.start(); f.call('theme', 'check', 'a')
        plan = f.call('theme', 'plan', 'apply', 'a')
        assert tree(home, store) == before and not (f.root / 'state/bindings.json').exists(), 'preview wrote'
        assert f.call('theme', 'apply', plan['id'])['status'] == 'applied'
        assert zed_followed(home) and css(roots['one']).exists() and css(roots['two']).exists()
        assert f.apply('b')['status'] == 'applied'
        f.stop(); f.start()
        assert f.call('theme', 'status')['selected']['id'] == 'b'
        assert f.restore()['status'] == 'restored' and tree(home, store) == before
        assert (home / '.config/zed/themes').exists() and (roots['one'] / '.obsidian/snippets').exists(), 'removed a folder Pilot did not make'
        assert (file.read_bytes(), digest(file)) == registry, 'obsidian.json changed'

    def missing_app():
        f, home, store, _, _ = setup('none', zed=False, vaults=(), registry=False)
        before = tree(home, store)
        f.start(); f.call('theme', 'check', 'a')
        plan = f.call('theme', 'plan', 'apply', 'a')
        assert not [w for w in plan['warnings'] if 'Zed' in w or 'Obsidian' in w], plan['warnings']
        assert f.call('theme', 'apply', plan['id'])['status'] == 'applied' and f.restore()['status'] == 'restored'
        assert tree(home, store) == before and not (home / '.config').exists()
        f.stop()
        # A pack that themes Ghostty, on a Mac with no Ghostty config folder.
        f, home, store, _, _ = setup('ngh', zed=False, vaults=(), registry=False, ghostty=True)
        f.start(); f.call('theme', 'check', 'a')
        plan = f.call('theme', 'plan', 'apply', 'a')
        assert not [w for w in plan['warnings'] if 'Ghostty' in w or 'older settings' in w], plan['warnings']
        assert f.call('theme', 'apply', plan['id'])['status'] == 'applied' and f.restore()['status'] == 'restored'
        assert not (f.root / 'gh').exists(), 'created a Ghostty folder'

    def no_config_folder():
        f, home, store, roots, file = setup('bare', vaults=('one',), registry=b'x')
        bare = store / 'bare'; bare.mkdir(); (bare / 'note.md').write_bytes(b'keep\n')
        file.write_text(json.dumps({'vaults': {'a': {'path': str(roots['one'])}, 'b': {'path': str(bare)}}}))
        before = tree(bare)
        f.start(); assert f.apply()['status'] == 'applied'
        assert css(roots['one']).exists() and tree(bare) == before and not (bare / '.obsidian').exists()
        f.restore()

    def malformed():
        f, home, store, _, file = setup('bad', vaults=(), registry=b'{bad')
        outside = EVIDENCE / ('outside-vault-' + uuid.uuid4().hex[:6])
        (outside / '.obsidian/snippets').mkdir(parents=True); (outside / '.obsidian/appearance.json').write_bytes(appearance)
        sentinel = tree(outside)
        f.start()
        for bytes_ in [b'{bad', b'[]', b'{"vaults":[1]}', b'{"vaults":{"x":{"path":7}}}', b'{"vaults":{"x":{"path":"relative/vault"}}}',
                       json.dumps({'vaults': {'x': {'path': str(outside)}}}).encode()]:
            file.write_bytes(bytes_)
            f.call('theme', 'plan', 'apply', 'a')
            assert f.process.poll() is None, 'host crashed on ' + repr(bytes_)
        assert f.apply()['status'] == 'applied' and zed_followed(home) and tree(outside) == sentinel
        f.restore()
        shutil.rmtree(outside)

    def opt_outs():
        f, home, store, roots, file = setup('off')
        before = tree(home, store)
        f.start()
        f.call('theme', 'follow', 'zed', 'off'); f.call('theme', 'follow', 'vault', str(roots['one']), 'off')
        assert f.apply()['status'] == 'applied'
        assert not zed_followed(home) and not css(roots['one']).exists() and css(roots['two']).exists()
        f.stop(); f.start()
        apps = f.call('theme', 'status')['apps']
        assert apps['zedOn'] is False and {v['root']: v['on'] for v in apps['vaults']} == {str(roots['one']): False, str(roots['two']): True}, apps
        f.restore(); assert tree(home, store) == before
        f.call('theme', 'follow', 'obsidian', 'off'); assert f.apply()['status'] == 'applied'
        assert not css(roots['one']).exists() and not css(roots['two']).exists() and not zed_followed(home)
        f.restore(); f.stop(); f.start()
        assert f.call('theme', 'status')['apps']['obsidianOn'] is False
        for words in [('zed', 'on'), ('obsidian', 'on'), ('vault', str(roots['one']), 'on')]: f.call('theme', 'follow', *words)
        assert f.apply()['status'] == 'applied' and zed_followed(home) and css(roots['one']).exists() and css(roots['two']).exists()
        f.restore(); assert tree(home, store) == before

    def owned():
        f, home, store, roots, file = setup('own')
        before = tree(home, store); listed = file.read_bytes()
        f.start(); assert f.apply()['status'] == 'applied'
        # Leaving Obsidian's list while owned must not strand the ledger; Restore still releases it.
        file.write_text(json.dumps({'vaults': {'two': {'path': str(roots['two'])}}}))
        f.stop(); f.start()
        assert f.call('theme', 'status')['selected']['id'] == 'a'
        assert f.restore()['status'] == 'restored' and not css(roots['one']).exists()
        file.write_bytes(listed); assert tree(home, store) == before
        # Switching a vault off while owned releases it on the next Apply and leaves the other following.
        assert f.apply()['status'] == 'applied'
        f.call('theme', 'follow', 'vault', str(roots['one']), 'off')
        assert f.apply('b')['status'] == 'applied'
        assert not css(roots['one']).exists() and css(roots['two']).exists()
        assert f.restore()['status'] == 'restored' and tree(home, store) == before

    def folders():
        f, home, store, roots, _ = setup('mk', folders=False)
        made = [home / '.config/zed/themes', roots['one'] / '.obsidian/snippets', roots['two'] / '.obsidian/snippets']
        before = tree(home, store)
        f.start(); plan = f.call('theme', 'plan', 'apply', 'a')
        assert len([w for w in plan['warnings'] if 'Apply creates' in w]) == 3 and tree(home, store) == before and not any(m.exists() for m in made), plan['warnings']
        f.controls(allow='no'); f.call('theme', 'apply', plan['id'], ok=False); f.controls()
        assert not any(m.exists() for m in made), 'a denied Apply made a folder'
        f.controls(fail='journal'); f.call('theme', 'apply', f.plan(), ok=False); f.controls()
        assert not any(m.exists() for m in made), 'a failed Apply left its folders behind'
        assert f.apply()['status'] == 'applied' and zed_followed(home) and css(roots['one']).exists() and css(roots['two']).exists()
        assert f.apply('b')['status'] == 'applied'
        f.stop(); f.start()
        assert f.restore()['status'] == 'restored' and tree(home, store) == before and not any(m.exists() for m in made)
        assert f.apply()['status'] == 'applied'
        (made[1] / 'mine.css').write_bytes(b'/* mine */\n')
        assert f.restore()['status'] == 'restored' and (made[1] / 'mine.css').exists() and not made[2].exists() and not css(roots['one']).exists()

    def no_theme():
        settings = b'{ /* Keep */ "buffer_font_size":15 }\n'
        f, home, store, _, _ = setup('nt', settings=settings)
        before = tree(home, store); target = home / '.config/zed/settings.json'
        f.start(); assert f.apply()['status'] == 'applied'
        assert b'"theme"' in target.read_bytes() and b'buffer_font_size' in target.read_bytes() and (home / '.config/zed/themes/pilot-theme.json').exists()
        assert f.apply('b')['status'] == 'applied'
        assert f.restore()['status'] == 'restored' and target.read_bytes() == settings and tree(home, store) == before

    def cursor():
        f, home, store, _, _ = setup('cur', cursor='custom')
        state = lambda: json.loads((f.root / 'native.json').read_text()).get('cursor')
        f.start(); plan = f.call('theme', 'plan', 'apply', 'a')
        assert [w for w in plan['warnings'] if w.startswith('Cursor colours: custom')] and state() == 'custom', plan['warnings']
        assert f.call('theme', 'apply', plan['id'])['status'] == 'applied' and state() == 'theme'
        assert f.apply('b')['status'] == 'applied' and state() == 'theme'
        f.stop(); f.start()
        assert f.restore()['status'] == 'restored' and state() == 'custom', 'Restore lost the previous cursor choice'
        f.call('theme', 'follow', 'cursor', 'personal')
        assert f.apply()['status'] == 'applied' and state() == 'custom', 'a personal cursor followed the pack'
        assert f.restore()['status'] == 'restored' and state() == 'custom'
        f.call('theme', 'follow', 'cursor', 'pack')
        f.controls(allow='no'); f.call('theme', 'apply', f.plan(), ok=False); f.controls()
        assert state() == 'custom', 'a denied Apply changed the cursor'
        assert f.apply()['status'] == 'applied' and state() == 'theme'
        f.call('theme', 'follow', 'cursor', 'personal')
        assert f.apply('b')['status'] == 'applied' and state() == 'custom', 'switching to personal did not release the cursor'
        assert f.restore()['status'] == 'restored' and state() == 'custom'
        f.stop()
        f, home, store, _, _ = setup('mac', cursor='custom')
        f.settings['cursorIsMacOS'] = True; f.manifest.write_text(json.dumps(f.settings))
        f.start(); plan = f.call('theme', 'plan', 'apply', 'a')
        # Review blocker 4: no cursor claim, row or Allow line; the honest line shows in Preview, not behind Details.
        assert [w for w in plan['review']['skipped'] if w.startswith("Cursor skipped: macOS's own pointer stays") and 'Look › Cursor' in w], plan['review']
        assert not [w for w in plan['warnings'] if w.startswith('Cursor colours')] and not [c for c in plan['review']['changes'] if 'cursor' in c.lower()], plan
        assert f.call('theme', 'apply', plan['id'])['status'] == 'applied'
        assert json.loads((f.root / 'native.json').read_text()).get('cursor') == 'custom' and not json.loads((f.root / 'state/ownership.json').read_text())['appearance'].get('cursorOwned')
        f.stop()
        allow = [x for x in (f.root / f'host-{f.counter}.log').read_text().splitlines() if x.startswith('THEME Allow asked:')][-1]
        assert 'ursor' not in allow, allow

    def mode():
        # Sven Q43: a light theme switches macOS to Light mode and Restore puts Dark back; with the switch off macOS stays
        # Dark and the light theme still shows in Zed's dark slot and Obsidian's dark mode (the 2168 bug).
        dynamic = b'{ "theme": { "mode": "system", "light": "One Light", "dark": "Keep Dark" } }\n'
        f, home, store, roots, _ = setup('md', dark=True, settings=dynamic)
        native = lambda: json.loads((f.root / 'native.json').read_text())
        light = next(p['id'] for p in f.packs if not p['dark'])
        def shows():
            chosen = json.loads((home / '.config/zed/settings.json').read_text())['theme']
            name = json.loads((home / '.config/zed/themes/pilot-theme.json').read_text())['themes'][0]['name']
            assert chosen == {'mode': 'system', 'light': name, 'dark': name}, chosen
            for root in roots.values():
                text = css(root).read_text(); assert text.startswith('.theme-dark, .theme-light {'), text
        before = tree(home, store)
        f.start(); plan = f.call('theme', 'plan', 'apply', light)
        assert 'macOS: Light mode' in plan['review']['changes'], plan['review']
        assert f.call('theme', 'apply', plan['id'])['status'] == 'applied' and native()['dark'] is False; shows()
        assert json.loads((f.root / 'state/ownership.json').read_text())['appearance']['modeOwned'] is True
        f.stop()
        allow = [x for x in (f.root / f'host-{f.counter}.log').read_text().splitlines() if x.startswith('THEME Allow asked:')][-1]
        assert 'macOS: Light mode' in allow, allow
        f.start(); answer = f.restore()
        assert answer['status'] == 'restored' and native()['dark'] is True and tree(home, store) == before, answer
        # Second review, blocker 3: write never sets macOS's mode, so a failed Apply puts Dark back only through the awaited
        # switch, and an Apply cut off after the switch gets it back at the next launch without launch waiting on it.
        for stage in ('after-native', 'ledger'):
            f.controls(fail=stage); answer = f.call('theme', 'apply', f.plan(light))
            assert answer['status'] == 'failed' and answer['recovery']['status'] == 'rollback verified' and native()['dark'] is True and tree(home, store) == before, answer
        # Third review, blocker 1: Look's parts go first and the mode last, so an Apply or Restore stopped between the two
        # (after-native) or after the switch (after-mode) comes back whole at the next launch, never held as a personal edit.
        for operation in ('apply', 'restore'):
            for stage in ('after-native', 'after-mode'):
                if operation == 'restore': assert f.apply(light)['status'] == 'applied'
                want = (tree(home, store), native())
                f.controls(crash=stage); f.call('theme', operation, f.plan(light if operation == 'apply' else None), ok=False); f.stop(crashed=True)
                assert (f.root / 'state/pending.json').exists() and native()['dark'] is ((operation == 'apply') == (stage == 'after-native')), (operation, stage, native())
                f.controls(); f.start()
                for _ in range(100):
                    if not (f.root / 'state/pending.json').exists(): break
                    time.sleep(.05)
                assert not (f.root / 'state/pending.json').exists() and (tree(home, store), native()) == want, (operation, stage, native())
                f.stop()  # The host's output reaches its log when it exits.
                launch = [x for x in (f.root / f'host-{f.counter}.log').read_text().splitlines() if x.startswith('THEME recovery:')]
                assert launch and ('macOS switching back to' in launch[0]) == (stage == 'after-mode') and 'later personal appearance edit' not in launch[0], (operation, stage, launch)
                f.start()
                if operation == 'restore': assert f.restore()['status'] == 'restored' and tree(home, store) == before
        # The late-switch note: a switch that reports failure but lands is read once more and counts.
        f.controls(modeWait='late'); answer = f.apply(light); f.controls()
        assert answer['status'] == 'applied' and native()['dark'] is False, answer
        assert f.restore()['status'] == 'restored' and native()['dark'] is True and tree(home, store) == before
        # Sven, after 2180: a press in Pilot's own window applies and restores at once, with no Allow: here Allow refuses
        # everything, the presses still land and name what changed, and the CLI's apply is refused.
        dark_pack = next(p['id'] for p in f.packs if p['dark'])
        f.controls(allow='no')
        answer = f.call('theme', 'fixture-press', light)
        assert answer['status'] == 'applied' and 'macOS: Light mode' in answer['changes'] and native()['dark'] is False, answer
        refused = f.call('theme', 'apply', f.plan(dark_pack), ok=False)
        assert refused['error']['code'] == 'denied' and 'not allowed' in refused['error']['message'], refused
        answer = f.call('theme', 'fixture-press', 'restore')
        assert answer['status'] == 'restored' and native()['dark'] is True and tree(home, store) == before, answer
        f.controls()
        # The coordinator's brief: Pilot's own parts the person changed after Apply are let go, never a refusal. Restore keeps
        # them; Apply gives them the new theme with theirs as what Restore puts back.
        dark = next(p['id'] for p in f.packs if p['dark'])
        def personal(**parts):
            value = native(); value.update(parts); (f.root / 'native.json').write_text(json.dumps(value))
        assert f.apply(light)['status'] == 'applied'; personal(dark=True, palette={'stock': {'_0': 'void'}})
        kept = f.call('theme', 'plan', 'restore')['review']['kept']
        assert [w for w in kept if 'Light or Dark mode' in w] and [w for w in kept if 'Pilot colours' in w], kept
        answer = f.restore()
        assert answer['status'] == 'restored' and native()['dark'] is True and native()['palette'] == {'stock': {'_0': 'void'}} and tree(home, store) == before, answer
        assert [w for w in answer['kept'] if w.startswith('Kept the Pilot colours')], answer['kept']
        personal(palette={'stock': {'_0': 'lagoon'}})
        assert f.apply(light)['status'] == 'applied'; personal(palette={'stock': {'_0': 'void'}})
        plan = f.call('theme', 'plan', 'apply', dark); assert [w for w in plan['review']['kept'] if 'Pilot colours' in w and 'take this theme' in w], plan['review']
        assert f.call('theme', 'apply', plan['id'])['status'] == 'applied' and native()['palette'] != {'stock': {'_0': 'void'}}
        assert f.restore()['status'] == 'restored' and native()['palette'] == {'stock': {'_0': 'void'}} and native()['dark'] is True
        personal(palette={'stock': {'_0': 'lagoon'}})
        f.call('theme', 'follow', 'mode', 'personal')
        plan = f.call('theme', 'plan', 'apply', light); assert not [c for c in plan['review']['changes'] if c.startswith('macOS')], plan['review']
        assert f.call('theme', 'apply', plan['id'])['status'] == 'applied' and native()['dark'] is True; shows()
        assert f.restore()['status'] == 'restored' and native()['dark'] is True and tree(home, store) == before
        # Second review, blocker 4: with Auto on, a theme skips the mode switch with a plain line and claims nothing; Auto
        # turned on after Apply is the person's, so Restore leaves it on.
        f.call('theme', 'follow', 'mode', 'pack'); personal(auto=True)
        plan = f.call('theme', 'plan', 'apply', light)
        skipped = [w for w in plan['review']['skipped'] if w.startswith('macOS mode skipped') and 'Auto' in w]
        assert skipped and not [c for c in plan['review']['changes'] if c.startswith('macOS')], plan['review']
        answer = f.call('theme', 'apply', plan['id'])
        assert answer['status'] == 'applied' and skipped[0] in answer['warning'] and native()['dark'] is True and native()['auto'] is True, answer
        assert 'modeOwned' not in json.loads((f.root / 'state/ownership.json').read_text())['appearance']
        assert f.restore()['status'] == 'restored' and native()['dark'] is True and native()['auto'] is True and tree(home, store) == before
        value = native(); value.pop('auto'); (f.root / 'native.json').write_text(json.dumps(value))
        assert f.apply(light)['status'] == 'applied' and native()['dark'] is False and 'auto' not in native()
        personal(auto=True)
        assert [w for w in f.call('theme', 'plan', 'restore')['review']['kept'] if 'Light or Dark mode' in w]
        answer = f.restore()
        assert answer['status'] == 'restored' and native()['dark'] is False and native()['auto'] is True and tree(home, store) == before, answer
        f.stop()
        # Sven, 2180: its Allow reads 'Restore default appearance' (Look's button reads 'Restore default' since Q69).
        asked = [x for x in (f.root / f'host-{f.counter}.log').read_text().splitlines() if x.startswith('THEME Allow asked: Restore')]
        assert asked and all(x.startswith('THEME Allow asked: Restore default appearance:') for x in asked), asked

    def ghostex():
        config = b'font-size = 13\n# mine\n'
        f, home, store, _, _ = setup('gx', zed=False, vaults=(), registry=False, ghostex=config)
        before = tree(home, store)
        f.start(); plan = f.call('theme', 'plan', 'apply', 'a')
        assert not [w for w in plan['warnings'] if 'Ghostex' in w] and not [c for c in plan['changes'] if 'ghostex' in c['path']], plan
        assert f.call('theme', 'status')['apps']['ghostexFound'] is False, 'a test host found the real Ghostex'
        assert f.apply()['status'] == 'applied' and tree(home, store) == before, 'Apply changed Ghostex'
        assert f.restore()['status'] == 'restored' and tree(home, store) == before
        f.stop()
        # A claim left by a build where Ghostex still followed: made here through the Ghostty binding, then handed over.
        for leaving in ['restore', 'next apply']:
            f, home, store, _, _ = setup('gy', zed=False, vaults=(), registry=False, ghostex=config)
            folder, own = home / '.config/ghostex/ghostty', dict(f.settings['binding'])
            before = tree(home, store)
            f.settings['binding'] = dict(root=str(folder), config='config.ghostty', generated='pilot-theme.conf')
            f.manifest.write_text(json.dumps(f.settings))
            f.start(); assert f.apply()['status'] == 'applied'; f.stop()
            assert (folder / 'pilot-theme.conf').exists() and b'Pilot theme pack' in (folder / 'config.ghostty').read_bytes()
            saved = f.root / 'state/bindings.json'
            saved.write_text(json.dumps({**json.loads(saved.read_text() if saved.exists() else '{"zedOptOut":false}'), 'ghostex': f.settings['binding']}))
            f.settings['binding'] = own; f.manifest.write_text(json.dumps(f.settings))
            f.start()
            plan = f.call('theme', 'plan', 'restore' if leaving == 'restore' else 'apply', *([] if leaving == 'restore' else ['b']))
            assert [w for w in plan['warnings'] if w.startswith('Ghostex terminal colours no longer follow')], plan['warnings']
            assert f.call('theme', leaving.split()[-1], plan['id'])['status'] in ('restored', 'applied')
            assert tree(home, store) == before, leaving + ' did not return Ghostex byte for byte'
            f.stop()

    def told_apart():
        f, home, store, roots, file = setup('ta', zed=False, vaults=())
        twins = [store / 'work/Notes', store / 'home/Notes']
        for root in twins:
            (root / '.obsidian/snippets').mkdir(parents=True); (root / '.obsidian/appearance.json').write_bytes(appearance)
        file.write_bytes(json.dumps({'vaults': {str(i): {'path': str(r)} for i, r in enumerate(twins)}}).encode())
        f.start(); plan = f.call('theme', 'plan', 'apply', 'a')
        assert [c for c in plan['review']['changes'] if 'Notes (in work)' in c] and [c for c in plan['review']['changes'] if 'Notes (in home)' in c], plan['review']
        assert f.call('theme', 'apply', plan['id'])['status'] == 'applied'
        (twins[0] / '.obsidian/appearance.json').write_bytes(b'{ "enabledCssSnippets":["personal"] }\n')
        message = json.dumps(f.call('theme', 'plan', 'restore')['review']['kept'])
        assert 'Notes (in work)' in message and 'Notes (in home)' not in message and 'snippet stays off' in message, message
        f.stop()

    def gone():
        f, home, store, roots, _ = setup('gn')
        twoBefore = (roots['two'] / '.obsidian/appearance.json').read_bytes()
        f.start(); assert f.apply()['status'] == 'applied'
        shutil.rmtree(roots['one']); shutil.rmtree(home / '.config/zed')
        plan = f.call('theme', 'plan', 'restore')
        assert len([w for w in plan['warnings'] if 'no longer exists' in w]) == 2 and not roots['one'].exists(), plan['warnings']
        assert f.call('theme', 'restore', plan['id'])['status'] == 'restored'
        assert not roots['one'].exists() and not (home / '.config/zed').exists(), 'recreated a gone root'
        assert not css(roots['two']).exists() and (roots['two'] / '.obsidian/appearance.json').read_bytes() == twoBefore
        f.stop(); f.start()
        assert f.call('theme', 'status')['selected'] is None
        assert f.apply()['status'] == 'applied', 'stuck after a gone root'
        f.restore(); f.stop()
        f, home, store, roots, _ = setup('br')
        f.start(); assert f.apply()['status'] == 'applied'
        shutil.rmtree(roots['two'] / '.obsidian')
        before = tree(home, store)
        f.call('theme', 'plan', 'restore', ok=False); f.call('theme', 'plan', 'apply', 'b', ok=False)
        assert tree(home, store) == before and f.call('theme', 'status')['selected']['id'] == 'a', 'a root that exists but fails was dropped'

    def unusable():
        f, home, store, roots, _ = setup('skip')
        (home / '.config/zed/settings.json').unlink()
        css(roots['one']).write_bytes(b'body { color: red; }\n')
        before = tree(home, store)
        f.start(); plan = f.call('theme', 'plan', 'apply', 'a')
        skipped = [w for w in plan['warnings'] if 'skipped' in w]
        assert len(skipped) == 2 and tree(home, store) == before, plan['warnings']
        assert f.call('theme', 'apply', plan['id'])['status'] == 'applied' and css(roots['two']).exists()
        assert css(roots['one']).read_bytes() == b'body { color: red; }\n' and not (home / '.config/zed/settings.json').exists()
        f.restore(); assert tree(home, store) == before

    for name, body in [('Zed and two vaults follow; preview effect-free; restart; Restore exact; obsidian.json untouched', follows),
                       ('missing apps skip silently and create nothing', missing_app),
                       ('vault without .obsidian skipped untouched', no_config_folder),
                       ('malformed obsidian.json means no vaults; outside entries never touched', malformed),
                       ('opt-outs apply and survive restart; switching back on follows again', opt_outs),
                       ('owned vault outlives Obsidian list; switched-off vault released', owned),
                       ('missing folders made only inside Allow; Restore removes them only when empty and made by Pilot', folders),
                       ('Zed with no theme chosen follows and Restore takes the key out', no_theme),
                       ('cursor colours follow, shown in Preview, Restore returns Custom, keep personal, denied Apply leaves it; macOS\'s pointer claims nothing and asks nothing', cursor),
                       ('a light theme switches macOS to Light mode and Restore puts Dark back; a mode or palette the person changed after is let go (Restore keeps it, Apply takes it); switched off, the light theme still shows in Zed and Obsidian in Dark mode; Look\'s parts go before the mode, and an Apply or Restore stopped between or after the switch recovers at launch; a late switch counts; a press in Pilot\'s window applies and restores with no Allow while the CLI still asks; with Auto on the switch is skipped and nothing claimed', mode),
                       ('Ghostex config left alone; a claim from an earlier build still leaves exact', ghostex),
                       ('two vaults with one folder name are told apart; a snippet turned off names its vault', told_apart),
                       ('owned root that is gone drops with a warning and no write; one that exists but fails still refuses', gone),
                       ('unusable destination skipped with one warning', unusable)]:
        live.clear()
        try:
            body(); passed('detected ' + name)
        except Exception as error:
            failures.append(f'{name}: {error}')
            print('RED ' + failures[-1], flush=True)
        finally:
            for f in live:
                try: f.stop(crashed=f.process is not None and f.process.poll() is not None)
                except Exception as error: failures.append(f'{name} teardown: {error}')
                f.receipt()
    assert not failures, '\n'.join(failures)


def run_case(prefix, label, check, live, failures, passed):
    """One proof case: its fixtures stop and leave a receipt however it ends."""
    first = len(live)
    try:
        check(); passed(prefix + label)
    except Exception as error:
        failures.append(label + ': ' + str(error)); print('RED ' + prefix + failures[-1], flush=True)
    finally:
        for f in live[first:]:
            try: f.stop(crashed=f.process is not None and f.process.poll() is not None)
            except Exception as error: failures.append(f'{label} teardown: {error}')
            f.receipt()


def linked_config(passed):
    """Ghostty's config as dotfiles users have it: an absolute link out of the Ghostty folder to a real file elsewhere."""
    failures, live = [], []

    def setup(label):
        f = Fixture('lc-' + label); live.append(f)
        dots = f.root / 'dots'; dots.mkdir()
        real = dots / 'config'
        real.write_bytes(f.original); real.chmod(0o640)
        f.config.unlink(); f.actual.unlink(); f.actual.parent.rmdir()
        f.config.symlink_to(real)
        return f, dots, real

    def intact(f, dots, real, extra=()):
        assert f.config.is_symlink() and os.readlink(f.config) == str(real), 'the link did not survive'
        assert sorted(os.listdir(dots)) == sorted(['config', *extra]), os.listdir(dots)
        assert stat.S_IMODE(real.stat().st_mode) == 0o640, 'mode changed'

    def through_link():
        f, dots, real = setup('w'); f.start()
        plan = f.call('theme', 'plan', 'apply', 'a')
        named = [w for w in plan['warnings'] if str(real) in w]
        assert named and [c for c in plan['review']['changes'] if c.startswith('Ghostty') and str(real) in c and str(f.generated) in c], plan
        assert real.read_bytes() == f.original and not f.generated.exists(), 'Preview wrote'
        f.controls(allow='no'); f.call('theme', 'apply', plan['id'], ok=False); f.controls()
        assert real.read_bytes() == f.original and not f.generated.exists(), 'a denied Apply wrote'
        assert f.apply()['status'] == 'applied'
        text = real.read_bytes()
        loader = b'config-file = ?' + str(f.generated).encode()
        assert text.startswith(f.original) and loader in text and b'Pilot theme pack' in text, text
        assert f.generated.exists() and not f.generated.is_symlink() and f.fonts.read_bytes() == f.font_original
        intact(f, dots, real)
        assert f.apply('b')['status'] == 'applied' and real.read_bytes() == text; intact(f, dots, real)
        f.stop(); f.start()  # The ownership record reads back after a restart.
        plan = f.call('theme', 'plan', 'restore')
        assert [w for w in plan['warnings'] if str(real) in w], plan['warnings']
        assert f.call('theme', 'restore', plan['id'])['status'] == 'restored'
        assert real.read_bytes() == f.original and not f.generated.exists(), real.read_bytes()
        intact(f, dots, real); f.stop()

    def around_failures():
        for stage in ['after-write:1', 'ledger', 'write:1+rollback:0']:
            f, dots, real = setup('f'); f.start(); before = real.read_bytes()
            f.controls(fail=stage); result = f.call('theme', 'apply', f.plan()); f.controls()
            if '+rollback' in stage:
                assert result['status'] == 'failed', result
            else:
                assert result['status'] == 'failed' and result['recovery']['status'] == 'rollback verified', result
                assert real.read_bytes() == before and not f.generated.exists(), stage
                intact(f, dots, real)
            f.stop()
        for stage in ['after-ledger', 'cleanup']:  # Committed: verification and recovery re-read through the link.
            f, dots, real = setup('c'); f.start()
            f.controls(fail=stage); result = f.call('theme', 'apply', f.plan()); f.controls()
            assert result['status'] == 'applied' and result['files'] == 'verified' and b'Pilot theme pack' in real.read_bytes(), result
            intact(f, dots, real)
            assert f.restore()['status'] == 'restored' and real.read_bytes() == f.original; intact(f, dots, real)
            f.stop()

    def link_moves():
        for during_allow in [False, True]:
            f, dots, real = setup('m'); other = dots / 'other'; other.write_bytes(b'# other\n'); f.start()
            f.controls(hold='yes' if during_allow else 'no'); plan = f.plan()
            def swap():
                f.config.unlink(); f.config.symlink_to(other)
            if during_allow:
                with concurrent.futures.ThreadPoolExecutor() as pool:
                    pending = pool.submit(f.call, 'theme', 'apply', plan, ok=False)
                    deadline = time.monotonic() + 10
                    while not (f.root / 'asked').exists() and time.monotonic() < deadline: time.sleep(.05)
                    assert (f.root / 'asked').exists(); swap(); (f.root / 'go').touch()
                    pending.result(timeout=10)
            else:
                swap(); f.controls(); f.call('theme', 'apply', plan, ok=False)
            assert real.read_bytes() == f.original and other.read_bytes() == b'# other\n' and not f.generated.exists(), 'a moved link was written'
            f.stop()

    def refusals():
        def broken(f, dots, real): real.unlink()
        def to_folder(f, dots, real): f.config.unlink(); f.config.symlink_to(dots)
        def to_pipe(f, dots, real):
            os.mkfifo(dots / 'pipe'); f.config.unlink(); f.config.symlink_to(dots / 'pipe')
        def hardlinked(f, dots, real): os.link(real, dots / 'second')
        def generated_out(f, dots, real): (dots / 'colours').write_bytes(b'# mine\n'); f.generated.symlink_to(dots / 'colours')
        def linked_ancestor(f, dots, real):
            nested = f.root / 'app/sub'; nested.mkdir(); (nested / 'config').symlink_to(real)
            f.settings['binding'].update(config='sub/config'); f.manifest.write_text(json.dumps(f.settings))
        for name, damage, reason in [('broken link', broken, 'broken symlink'),
                                     ('link to a folder', to_folder, 'regular file'),
                                     ('link to a pipe', to_pipe, 'regular file'),
                                     ('link to a hardlinked file', hardlinked, 'regular file'),
                                     ('pilot-theme.conf linked out', generated_out, 'escapes bound root'),
                                     ('config link below the root', linked_ancestor, 'escapes bound root')]:
            f, dots, real = setup('r'); damage(f, dots, real)
            kept = real.read_bytes() if real.exists() else None; f.start()
            answer = f.call('theme', 'plan', 'apply', 'a', ok=False)
            assert reason in json.dumps(answer), (name, answer)
            assert (real.read_bytes() if real.exists() else None) == kept and (f.generated.is_symlink() or not f.generated.exists()), name
            assert not (dots / 'colours').exists() or (dots / 'colours').read_bytes() == b'# mine\n', name
            f.stop()
        f, dots, real = setup('rl'); f.start()
        (f.root / 'app').rename(f.root / 'app-real'); (f.root / 'app').symlink_to('app-real', target_is_directory=True)
        answer = f.call('theme', 'plan', 'apply', 'a', ok=False)
        assert 'root must be an explicit real directory' in json.dumps(answer) and real.read_bytes() == f.original, answer
        f.stop()

    def relinked():
        f, dots, real = setup('x'); f.start(); assert f.apply()['status'] == 'applied'
        f.config.unlink(); f.config.symlink_to(real)  # What ln -sf does: same target, new link.
        assert f.apply('b')['status'] == 'applied', 'the same link re-made refused a switch'
        f.config.unlink(); f.config.symlink_to(real)
        assert f.restore()['status'] == 'restored' and real.read_bytes() == f.original, 'the same link re-made refused Restore'
        intact(f, dots, real); f.stop()
        f, dots, real = setup('y'); f.start(); assert f.apply()['status'] == 'applied'
        other = dots / 'other'; other.write_bytes(real.read_bytes()); kept = real.read_bytes()
        f.config.unlink(); f.config.symlink_to(other)
        answer = f.call('theme', 'plan', 'restore', ok=False)
        assert 'conflict' in json.dumps(answer) and real.read_bytes() == kept and other.read_bytes() == kept, answer
        f.stop()
        # A claim from build 2136, whose anchor still holds the link's own identity: Sven may have applied with it.
        f, dots, real = setup('z'); f.start(); assert f.apply()['status'] == 'applied'; f.stop()
        ledger = f.root / 'state/ownership.json'; record = json.loads(ledger.read_text())
        info = os.lstat(f.config); identity = f'{info.st_dev}:{info.st_ino}:{info.st_mode}:'
        link = f'|link:{f.config}:'
        claim = [c for c in record['claims'] if c['path'] == 'config'][0]
        if identity not in claim['anchor']: claim['anchor'] = claim['anchor'].replace(link, link + identity)
        assert identity in claim['anchor'], claim['anchor']
        ledger.write_text(json.dumps(record)); f.start()
        assert f.restore()['status'] == 'restored' and real.read_bytes() == f.original, 'an earlier claim conflicted'
        intact(f, dots, real); f.stop()

    for label, check in [('applies through the link, the link stays, Restore is byte exact', through_link),
                         ('ln -sf to the same target keeps ownership, another target refuses, a 2136 claim still reads', relinked),
                         ('a failed Apply rolls back through the link; a committed one verifies', around_failures),
                         ('the link moving after Preview or during Allow refuses', link_moves),
                         ('broken, folder, pipe, hardlinked, other-file and root links refuse', refusals)]:
        run_case('linked config ', label, check, live, failures, passed)
    assert not failures, '\n'.join(failures)


def main_thread(passed):
    """Coordinator's brief: Apply and Restore wait for macOS's mode switch and Ghostex off the main thread. A real 1.5 s
    child takes each one's place, as osascript and the Ghostex CLI do in the app, and ping, which the host answers on the
    main actor, keeps answering. The control holds the main thread for the same wait, and ping stalls."""
    import concurrent.futures
    keys = ['sidebarTheme', 'darkThemePreset', 'lightThemePreset', 'customSidebarTitlebarBackgroundTintColor', 'customSidebarTitlebarLightBackgroundTintColor']
    f = Fixture('mt')
    state = f.root / 'ghostex.json'
    state.write_text(json.dumps(dict(installed=True, running=True, values=dict(zip(keys, ['dark-2', 'green', 'slate', '#002934', '#d7d8df'])))))
    native = f.root / 'native.json'
    baseline = dict(palette={'stock': {'_0': 'lagoon'}}, material=dict(glass=False, transparency=43, blur='light'), dark=True)
    native.write_text(json.dumps(baseline))
    f.settings.update(ghostexSettings=str(state), nativeState=str(native), nativeBaseline=baseline); f.manifest.write_text(json.dumps(f.settings))
    light = next(p['id'] for p in f.packs if not p['dark'])

    def watched(work):
        worst, start = 0.0, time.monotonic()
        with concurrent.futures.ThreadPoolExecutor() as pool:
            job = pool.submit(work)
            while not job.done():
                sent = time.monotonic(); assert f.call('ping') == 'pong'; worst = max(worst, time.monotonic() - sent); time.sleep(.05)
            return job.result(), time.monotonic() - start, worst

    def probe(wait, operation, **more):
        # Preview's Ghostex read is watched too (third review, blocker 2): a slow read waits off the main thread.
        f.controls(modeWait=wait, ghostexWait=wait, **more)
        plan, planned, worst_plan = watched(lambda: f.call('theme', 'plan', *(['apply', light] if operation == 'apply' else ['restore']))['id'])
        answer, took, worst = watched(lambda: f.call('theme', operation, plan))
        f.controls()
        return answer, took, max(worst, worst_plan), planned

    original = json.loads(state.read_text())['values']
    f.start()
    answer, took, worst, planned = probe('child', 'apply')
    assert answer['status'] == 'applied' and json.loads(native.read_text())['dark'] is False and took >= 1.5 and planned >= 1.5 and worst < .5, (answer, took, planned, worst)
    answer, back, worst_back, _ = probe('child', 'restore')
    assert answer['status'] == 'restored' and json.loads(native.read_text())['dark'] is True and back >= 1.5 and worst_back < .5, (answer, back, worst_back)
    # A failed Apply's Ghostex rollback is awaited the same way, after the commit has let go of the main actor.
    answer, rolled, worst_roll, _ = probe('child', 'apply', fail='ledger')
    assert answer['status'] == 'failed' and answer['recovery']['status'] == 'rollback verified' and json.loads(state.read_text())['values'] == original and worst_roll < .5, (answer, rolled, worst_roll)
    assert [r for r in answer['recovery']['rows'] if r.get('rollback') == 'attempted; verified' and 'ghostex' in r], answer['recovery']
    answer, held_for, held, _ = probe('block', 'apply')
    assert answer['status'] == 'applied' and held >= 1.0, ('the probe cannot see a held main thread', held)
    assert f.restore()['status'] == 'restored'; f.stop()
    passed(f'main thread: Preview waited {planned:.1f} s on a slow Ghostex read, Apply {took:.1f} s, Restore {back:.1f} s and a failed Apply\'s Ghostex rollback {rolled:.1f} s on child processes in place of osascript and Ghostex while ping answered within {max(worst, worst_back, worst_roll):.2f} s; held on the main thread instead, ping waited {held:.2f} s')

def ghostex_interface(passed):
    """The settings route with a recording fake in place of the CLI: no process runs, and the real Ghostex is only read."""
    failures, live = [], []
    keys = ['sidebarTheme', 'darkThemePreset', 'lightThemePreset', 'customSidebarTitlebarBackgroundTintColor', 'customSidebarTitlebarLightBackgroundTintColor', 'sessionChatTheme', 'themeSidebarContrast', 'themeWorkAreaContrast']
    # Colourfulness is a number, as the real CLI lists it: Sven's Subtle, +4 points.
    original = dict(zip(keys, ['dark-2', 'green', 'slate', '#002934', '#d7d8df', 'dark', 4, 4]))
    real_cli = '/Applications/Ghostex.app/Contents/Resources/CLI/ghostex'

    def real_values():
        if not os.path.exists(real_cli): return None
        return [json.loads(subprocess.run([real_cli, 'settings', 'get', key, '--json'], capture_output=True, text=True, timeout=15).stdout)['current'] for key in keys]

    def setup(label, installed=True, running=True):
        f = Fixture('gi-' + label); live.append(f)
        f.state_file = f.root / 'ghostex.json'
        f.state_file.write_text(json.dumps(dict(installed=installed, running=running, values=original)))
        f.settings['ghostexSettings'] = str(f.state_file); f.manifest.write_text(json.dumps(f.settings))
        return f

    def values(f): return json.loads(f.state_file.read_text())['values']
    def put(f, **fields):
        data = json.loads(f.state_file.read_text()); data.update(fields); f.state_file.write_text(json.dumps(data))
    def edit(f, key, value): put(f, values={**values(f), key: value})
    def calls(f):
        log = f.root / 'state/ghostex-effects.jsonl'
        return [json.loads(line) for line in log.read_text().splitlines()] if log.exists() else []
    def tint(pack):  # A dark pack's panel colour, a light pack's ground (Sven on 2189: a near-black ground read as Ghostex's default).
        return pack['palette'].get('lighter_background', pack['palette']['background']) if pack['dark'] else pack['palette']['background']
    def wanted(pack):
        colour = tint(pack)
        return dict(zip(keys, ['dark-2' if pack['dark'] else 'plain-light', 'custom', 'custom', colour, colour, 'dark' if pack['dark'] else 'light', -24, -24]))
    def claims(f): return json.loads((f.root / 'state/ownership.json').read_text()).get('ghostexSettings')

    def apply_restore():
        f = setup('a'); f.start()
        assert f.call('theme', 'status')['apps']['ghostexFound'] is True
        plan = f.call('theme', 'plan', 'apply', 'a')
        line = [w for w in plan['review']['changes'] if w.startswith('Ghostex window and sidebar')]
        assert line and 'Terminal colours stay' in line[0] and tint(f.packs[0]) in line[0] and 'Dark mode colour' in line[0] and 'Sidebar colourfulness' in line[0], plan['review']
        assert [c['key'] for c in plan['ghostex']] == [k for k in keys if wanted(f.packs[0])[k] != original[k]], plan['ghostex']
        assert values(f) == original and not calls(f), 'Preview wrote'
        f.controls(allow='no'); f.call('theme', 'apply', plan['id'], ok=False); f.controls()
        assert values(f) == original and not calls(f), 'a denied Apply wrote'
        assert f.apply()['status'] == 'applied' and values(f) == wanted(f.packs[0]), values(f)
        assert [c[0] for c in calls(f)] == ['set'] * len(plan['ghostex']), calls(f)
        assert f.apply('b')['status'] == 'applied' and values(f) == wanted(f.packs[1])
        # Full colourfulness goes over as -24 after `--`, claimed with Sven's +4 as its original.
        assert [c for c in calls(f) if c[1] == 'themeWorkAreaContrast' and c[2] == '-24'], calls(f)
        full = [c for c in claims(f) if c['key'] in ('themeSidebarContrast', 'themeWorkAreaContrast')]
        assert len(full) == 2 and all(c['original'] == '4' and c['last'] == '-24' for c in full), claims(f)
        assert '["settings", "set", "--json", "--", key, value]' in (REPO / 'Sources/Pilot/Look/GhostexColours.swift').read_text(), 'the real write must pass the value after --'
        f.stop(); log = (f.root / 'host-1.log').read_text()
        assert 'Ghostex window and sidebar' in log, 'Allow did not name Ghostex'
        f.start()
        # Sven, 2180: a light theme turns Ghostex's chat Light too, claimed with its own original, and Restore puts Dark back.
        light = next(p for p in f.packs if not p['dark'])
        assert f.apply(light['id'])['status'] == 'applied' and values(f)['sessionChatTheme'] == 'light', values(f)
        chat = [c for c in claims(f) if c['key'] == 'sessionChatTheme']
        assert chat and chat[0]['original'] == 'dark' and chat[0]['last'] == 'light', claims(f)
        assert f.restore()['status'] == 'restored' and values(f) == original and not claims(f), values(f)
        f.stop()

    def changed_since():
        f = setup('c'); f.start(); assert f.apply()['status'] == 'applied'
        edit(f, 'darkThemePreset', 'pink'); count = len(calls(f))
        plan = f.call('theme', 'plan', 'restore')
        assert [w for w in plan['warnings'] if 'Dark mode colour changed since' in w], plan['warnings']
        assert f.call('theme', 'restore', plan['id'])['status'] == 'restored'
        assert values(f) == {**original, 'darkThemePreset': 'pink'}, values(f)
        assert not [c for c in calls(f)[count:] if c[1] == 'darkThemePreset'], 'the changed value was written'
        f.stop()
        f = setup('n'); f.start(); assert f.apply()['status'] == 'applied'
        edit(f, 'customSidebarTitlebarBackgroundTintColor', '#123456')
        assert f.apply('b')['status'] == 'applied'
        assert values(f) == {**wanted(f.packs[1]), 'customSidebarTitlebarBackgroundTintColor': '#123456'}, values(f)
        assert f.restore()['status'] == 'restored' and values(f) == {**original, 'customSidebarTitlebarBackgroundTintColor': '#123456'}, values(f)
        f.stop()

    def closed_absent():
        f = setup('o', running=False); f.start()
        plan = f.call('theme', 'plan', 'apply', 'a')
        assert [w for w in plan['warnings'] if w == 'Ghostex skipped: it is not running'] and not plan['ghostex'], plan['warnings']
        assert f.call('theme', 'apply', plan['id'])['status'] == 'applied' and values(f) == original and not calls(f)
        f.restore(); f.stop()
        f = setup('g', installed=False, running=False); f.start()
        assert f.call('theme', 'status')['apps']['ghostexFound'] is False
        plan = f.call('theme', 'plan', 'apply', 'a')
        assert 'Ghostex skipped: not installed' in plan['warnings'], plan['warnings']
        assert f.call('theme', 'apply', plan['id'])['status'] == 'applied' and not calls(f)
        f.restore(); f.stop()
        # Closed at Restore: everything else restores, Ghostex waits, and a later Restore finishes it.
        f = setup('w'); f.start(); assert f.apply()['status'] == 'applied'; applied = values(f)
        put(f, running=False)
        plan = f.call('theme', 'plan', 'restore')
        assert [w for w in plan['warnings'] if w.startswith('Ghostex skipped: it is closed')], plan['warnings']
        assert f.call('theme', 'restore', plan['id'])['status'] == 'restored' and values(f) == applied and claims(f), claims(f)
        put(f, running=True)
        assert f.restore()['status'] == 'restored' and values(f) == original and not claims(f), values(f)
        f.stop()
        f = setup('u'); f.start(); assert f.apply()['status'] == 'applied'; put(f, installed=False, running=False)
        plan = f.call('theme', 'plan', 'restore')
        assert [w for w in plan['warnings'] if w.startswith('Ghostex is no longer installed')], plan['warnings']
        assert f.call('theme', 'restore', plan['id'])['status'] == 'restored' and not claims(f)
        f.stop()

    def partial_failure():
        for control in [dict(fail='ghostex:2'), dict(fail='after-ghostex:1'), dict(ghostexFail='lightThemePreset')]:
            f = setup('p'); f.start()
            f.controls(**control); result = f.call('theme', 'apply', f.plan()); f.controls()
            assert result['status'] == 'failed' and result['recovery']['status'] == 'rollback verified', (control, result)
            assert values(f) == original and not (f.root / 'state/ownership.json').exists(), (control, values(f))
            f.stop()
        f = setup('r'); f.start()
        f.controls(crash='after-ghostex:1'); f.call('theme', 'apply', f.plan(), ok=False)
        f.process.wait(timeout=10); f.stop(crashed=True); f.controls(); f.start()
        for _ in range(100):  # Launch leaves the Ghostex rollback to its awaited step, off the main thread.
            if not (f.root / 'state/pending.json').exists(): break
            time.sleep(.05)
        assert values(f) == original and not (f.root / 'state/pending.json').exists(), values(f)
        f.stop()

    def switch_and_stale():
        f = setup('s'); f.start(); assert f.apply()['status'] == 'applied'
        f.call('theme', 'follow', 'ghostex', 'off')
        plan = f.call('theme', 'plan', 'apply', 'b')
        assert [c for c in plan['review']['changes'] if c.startswith('Ghostex window and sidebar')], plan['review']
        assert f.call('theme', 'apply', plan['id'])['status'] == 'applied' and values(f) == original
        f.stop(); f.start()
        assert f.call('theme', 'status')['apps']['ghostexOn'] is False
        f.call('theme', 'follow', 'ghostex', 'on')
        assert f.apply()['status'] == 'applied' and values(f) == wanted(f.packs[0])
        count = len(calls(f)); stale = f.plan('b'); edit(f, 'lightThemePreset', 'teal')
        answer = f.call('theme', 'apply', stale, ok=False)
        assert 'preview again' in json.dumps(answer) and len(calls(f)) == count, answer
        f.stop()

    before = real_values()
    for label, check in [('applies in one Allow, Restore returns the exact values', apply_restore),
                         ('a value changed since stays, on Restore and on the next Apply', changed_since),
                         ('closed or absent skips with a line; closed at Restore waits; uninstalled drops', closed_absent),
                         ('a failed set or crash rolls back and fails the Apply', partial_failure),
                         ('switch releases and persists; a change after Preview refuses', switch_and_stale)]:
        run_case('ghostex interface ', label, check, live, failures, passed)
    assert real_values() == before, 'the real Ghostex changed during the proof'
    passed('ghostex interface the real Ghostex was only read')
    assert not failures, '\n'.join(failures)


def allow_names_apps(passed):
    """Allow refuses a question over 1200 characters; nothing may fall off it silently."""
    # The pure shortening, compiled alone with every tier forced.
    import re
    scratch = REPO / '.build/theme-allow-proof'; scratch.mkdir(exist_ok=True)
    main = scratch / 'main.swift'
    main.write_text(r"""
import Foundation
let home = "/Users/person"
func entry(_ n: String, _ k: Int, linked: Bool = false) -> ThemeAllowText.Entry {
    .init(name: n, paths: (0..<k).map { "\(home)/.config/\(n.lowercased().replacingOccurrences(of: " ", with: "-"))/long-directory-name-for-padding/file-\($0).conf" }, linked: linked)
}
let dot = ThemeAllowText.Entry(name: "Ghostty", paths: [home + "/.config/ghostty/pilot-theme.conf", home + "/code/dotfiles/ghostty/config"], linked: true)
let screens = (1...8).map { ThemeAllowText.Entry(name: "Wallpaper on Screen \($0)", screen: true) }
let skip = (0..<3).map { "App\($0) skipped: a long reason that wording trims away first" }
var cases: [[String: Any]] = []
func run(_ name: String, _ e: [ThemeAllowText.Entry], _ s: [String]) {
    let text = ThemeAllowText.fit(lead: "Lagoon", entries: e, skipped: s, limit: 1200, home: home)
    cases.append(["case": name, "text": text, "names": e.filter { !$0.screen }.map(\.name), "paths": e.flatMap(\.paths).count])
}
run("short", [dot], [])
run("screens", [dot] + screens + (0..<7).map { entry("App \($0)", 2) }, skip)
run("many", (0..<30).map { entry("App \($0)", 2) } + [dot], skip)
run("absurd", (0..<400).map { entry("App \($0)", 2) } + [dot], skip)
print(String(data: try JSONSerialization.data(withJSONObject: cases), encoding: .utf8)!)
""")
    build = subprocess.run(['nice', '-n', '10', 'swiftc', '-j', '4', str(REPO / 'Sources/PilotCore/ThemeAllowText.swift'), str(main), '-o', str(scratch / 'fit')], text=True, capture_output=True)
    assert build.returncode == 0, build.stderr
    results = {c['case']: c for c in json.loads(subprocess.run([str(scratch / 'fit')], text=True, capture_output=True, check=True).stdout)}
    for name, row in results.items(): assert len(row['text']) <= 1200, (name, len(row['text']))
    assert '/Users/person/code/dotfiles/ghostty/config' in results['short']['text']
    assert 'Wallpaper on 8 screens' in results['screens']['text'] and 'Screen 3' not in results['screens']['text'], results['screens']['text']
    assert all(n in results['screens']['text'] for n in results['screens']['names']) and 'more, listed' not in results['screens']['text'], results['screens']['text']
    many = results['many']['text']
    assert all(n + '.' in many or n + ':' in many or n + ' in ' in many for n in results['many']['names']), many
    assert '~/code/dotfiles/ghostty/config' in many and 'more, listed in Preview' in many, many
    named = sum(many.count(f'file-{i}.conf') for i in (0, 1)); hidden = int(re.search(r'and (\d+) more', many)[1])
    assert named + hidden == results['many']['paths'] - 2, (named, hidden)
    absurd = results['absurd']['text']
    assert '~/code/dotfiles/ghostty/config' in absurd and re.search(r'and \d+ more, listed in Preview', absurd), absurd
    shutil.rmtree(scratch)
    passed('allow text shortens by wording first; counts what it cannot name; the linked file survives')
    # The same through a real Allow: 14 vaults, Zed, a dotfiles link.
    f = Fixture('many'); home, store = f.root / 'home', f.root / 'vaults'; home.mkdir(); store.mkdir()
    real = f.root / 'dots/config'; real.parent.mkdir(); real.write_bytes(f.original)
    f.config.unlink(); f.actual.unlink(); f.actual.parent.rmdir(); f.config.symlink_to(real)
    (home / '.config/zed/themes').mkdir(parents=True); (home / '.config/zed/settings.json').write_bytes(b'{"theme":"Keep"}\n')
    names = [f'Vault number {i:02d} with a long folder name' for i in range(14)]
    for name in names:
        (store / name / '.obsidian/snippets').mkdir(parents=True); (store / name / '.obsidian/appearance.json').write_bytes(b'{}\n')
    (home / 'Library/Application Support/obsidian').mkdir(parents=True)
    (home / 'Library/Application Support/obsidian/obsidian.json').write_text(json.dumps({'vaults': {n: {'path': str(store / n)} for n in names}}))
    f.settings['detectHome'] = str(home); f.manifest.write_text(json.dumps(f.settings))
    for pack in f.packs: pack['adapters'] = {'ghostty': {}, 'zed': {}, 'obsidian': {}}; f.save_pack(pack)
    f.start(); plan = f.call('theme', 'plan', 'apply', 'a')
    assert all(any(n in c for c in plan['review']['changes']) for n in names) and sum(str(store) in c for c in plan['review']['changes']) == 14, plan['review']
    assert f.call('theme', 'apply', plan['id'])['status'] == 'applied'
    f.stop(); allow = [x for x in (f.root / 'host-1.log').read_text().splitlines() if x.startswith('THEME Allow asked:')][-1].removeprefix('THEME Allow asked: ')
    assert len(allow) <= 1200 and 'Zed' in allow and 'dots/config' in allow, allow
    assert all(n in allow for n in names), allow
    assert 'more, listed in Preview' in allow, allow
    f.receipt()
    passed('a real Allow with 14 vaults names every app and the dotfiles file, and counts the rest')


def appearance_probe(pack_source=None):
    """Execute the actual numeric-conversion boundary, including direct Codable construction."""
    scratch = REPO / '.build/theme-appearance-proof'; scratch.mkdir(exist_ok=True)
    source = scratch / 'ThemePack.swift'; source.write_text(pack_source or (REPO / 'Sources/PilotCore/ThemePack.swift').read_text())
    main = scratch / 'main.swift'
    main.write_text('import Foundation\nlet bytes = FileHandle.standardInput.readDataToEndOfFile()\nlet pack = try JSONDecoder().decode(ThemePack.self, from: bytes)\nprint(pack.appearance(keeping: .standard).ground)\n')
    ghostty = scratch / 'OmarchyTheme.swift'
    ghostty.write_text((REPO / 'Sources/PilotCore/Ghostty.swift').read_text().split('public enum OmarchyThemes')[0])
    sources = [REPO / 'Sources/PilotCore' / (name + '.swift') for name in ['JSONValue', 'PilotTheme', 'BarPreset', 'ThemeOwnership', 'ThemePlan', 'ZedTheme', 'ThemeMapping', 'ThemeTemplate']]
    sources.append(ghostty)
    command = ['nice', '-n', '10', 'swiftc', '-j', '4', *map(str, sources), str(source), str(main), '-o', str(scratch / 'appearance')]
    build = subprocess.run(command, text=True, capture_output=True)
    (EVIDENCE / 'appearance-build.json').write_text(json.dumps(dict(command=command, exit=build.returncode, stdout=build.stdout, stderr=build.stderr)))
    (EVIDENCE / 'appearance-pack-source.swift').write_text(source.read_text())
    assert build.returncode == 0, build.stderr
    row = json.loads((REPO / 'Packaging/themes.json').read_text())['themes'][0]
    errors = []
    with (EVIDENCE / 'appearance-runs.jsonl').open('w') as log:
        for palette in [dict(row['colors'], background='#123456\n'), dict(row['colors'], background='#123456\r\n'), {}]:
            pack = dict(schema=1, id='a', title='Direct Codable boundary', dark=True, palette=palette, styles=[], wallpapers=[], adapters={'ghostty': {}})
            run = subprocess.run([str(scratch / 'appearance')], input=json.dumps(pack), text=True, capture_output=True)
            log.write(json.dumps(dict(input=pack, exit=run.returncode, stdout=run.stdout, stderr=run.stderr))+'\n')
            if run.returncode != 0: errors.append('unsafe direct appearance: ' + repr(palette.get('background')) + f' exit={run.returncode}')
    assert not errors, '; '.join(errors)
