"""Real PilotCLI / early file-backed bar fixture over the production final row and panel/hit seams."""
import copy
import hashlib
import importlib.util
import itertools
import json
import os
from pathlib import Path

spec = importlib.util.spec_from_file_location('island_strip', Path(__file__).with_name('strip.py'))
strip = importlib.util.module_from_spec(spec)
spec.loader.exec_module(strip)
REPO = strip.REPO
EVIDENCE = Path(os.environ.get('PILOT_THEME_PROOF_EVIDENCE') or Path.home() / '.local/state/spec' / 'theme-system/T8/cli')
strip.EVIDENCE = strip.base.EVIDENCE = EVIDENCE


class Fixture(strip.Fixture):
    def controls(self, **values):
        # Preserve the existing pinned Pilot item. Its zero fake measurement permits every final visibility mask.
        super().controls(**{'hidden:kind:pilot': 'yes', **values})


def close(a, b):
    assert abs(a-b) < 0.00001, (a, b)


def verify(state):
    """Check real final slots against the same group rectangles consumed by native drawing/window/hit code."""
    geometry = state['saved']['preset']
    for row in state['screens']:
        bx, by, width, height = row['frame']
        expected, gone = {}, []
        for side in ['left', 'centre', 'right']:
            spans = []
            for item, at, measured in zip(row['items'].get(side, []), row['placement'].get(side, []), row['widths'].get(side, [])):
                if at is not None and measured > 0:
                    spans.append((at, at+measured))
                elif measured > 0:
                    gone.append(item)
            if side == 'right' and row['overflow'] is not None:
                spans.append((row['overflow'], row['overflow']+min(24, width)))
            if spans:
                expected[side] = spans
            group = row['groups'][side]
            assert (group is not None) == bool(spans), (row, side)
            if not spans:
                assert group is None  # No geometry, fill, stroke, padding or native input window exists.
                continue
            x, y, w, h = group['frame']
            assert w > 0 and h > 0 and x >= -0.00001 and x+w <= width+0.00001, row
            close(y, 0); close(h, height)
            padding = min(geometry['padding'], max(0, (width-min(width, 24))/2))
            close(x, min(s[0] for s in spans)-padding)
            close(w, max(s[1] for s in spans)-min(s[0] for s in spans)+padding*2)
            assert all(group[key] for key in ['hit','clipInside','clipOutside','clipEmpty']) and group['panel'] is not None, row
            px, py, pw, ph = group['panel']
            close(px, bx+x); close(py, by+height-y-h); close(pw, w); close(ph, h)
            if side == 'left': close(x, 0)
            if side == 'centre': close(x+w/2, width/2)
            if side == 'right': close(x+w, width)
        assert gone == row['gone'], (gone, row['gone'])
        assert bool(gone) == (row['overflow'] is not None), row
        ordered = sorted((g['frame'][0], g['frame'][0]+g['frame'][2]) for g in row['groups'].values() if g)
        assert all(a[1] <= b[0] for a, b in zip(ordered, ordered[1:])), row
        for sample in row['hitSamples']:
            hits = [side for side, group in row['groups'].items() if group and group['frame'][0] <= sample['x'] < group['frame'][0]+group['frame'][2]]
            assert sample['side'] == (hits[0] if hits else None), (row, sample)
    return state


def run(seam_only=False, fixes_only=False):
    EVIDENCE.mkdir(parents=True, exist_ok=True)
    checks = []
    def passed(text):
        checks.append(text)
        print('PASS '+text, flush=True)
        (EVIDENCE/'islands.log').write_text('\n'.join('PASS '+v for v in checks)+'\n')
    f = Fixture('islands')
    try:
        f.settings['screens'] += [dict(name='width-'+str(w), x=4000+w, y=-300, width=w, height=140, strip=22, notch=0) for w in [1, 24, 52, 96]]
        f.manifest.write_text(json.dumps(f.settings))
        f.start()
        legacy = f.defaults_bytes()
        f.state(); f.call('bar'); f.call('list', 'bar-items')
        assert f.defaults_bytes() == legacy and f.geometry() is None
        f.stop(); f.start(); assert f.defaults_bytes() == legacy
        f.call('bar', 'preset', 'floatingStrip')
        strip_saved = f.saved(); strip_bytes = f.defaults_bytes()
        f.stop(); f.start(); assert f.defaults_bytes() == strip_bytes and f.saved() == strip_saved
        passed('legacy and floatingStrip saved bytes/meaning unchanged across reads and new process')
        f.call('bar', 'preset', 'threeIslands')
        cli_geometry = f.geometry()
        f.call('bar-fixture-edit', 'preset', 'threeIslands')
        assert f.geometry() == cli_geometry and f.personal() == {k:v for k,v in strip_saved.items() if k != 'preset'}
        for key, value in [('height','40'), ('spacing','13'), ('horizontalMargin','27'), ('topMargin','9'), ('radius','12'), ('border','2'), ('padding','7')]:
            f.call('bar', 'geometry', key, value)
        geometry = f.geometry()
        f.call('bar-fixture-edit', 'geometry', json.dumps(geometry))
        assert f.geometry() == geometry
        f.call('bar', 'clear', '--placement', 'topBar')
        def add(item, side):
            f.call('add', 'bar-items', '--item', item, '--placement', 'topBar', '--side', side, '--index', '0')
        items = dict(left='volume', centre='clock', right='wifi')
        observations = []
        for mask in itertools.product([False, True], repeat=3):
            f.call('bar', 'clear', '--placement', 'topBar')
            selected = [side for side, on in zip(items, mask) if on]
            for side in selected: add(items[side], side)
            state = verify(f.state()); observations.append(dict(mask=mask, state=state))
            wide = state['screens'][0]
            assert {s for s,g in wide['groups'].items() if g} == set(selected)
        (EVIDENCE/'all-group-combinations.json').write_text(json.dumps(observations, indent=2))
        passed('all eight empty/one/two/three-group combinations: no phantom ground/border/padding/panel/hit; stable edge/centre anchors on explicit wide/notched/narrow rectangles')
        # Each final item removal and restoration leaves the other groups exactly in place.
        f.call('bar', 'clear', '--placement', 'topBar')
        for side, item in items.items(): add(item, side)
        for side, item in items.items():
            before = verify(f.state())['screens'][0]['groups']
            f.call('remove', 'bar-items', item, '--placement', 'topBar')
            empty = verify(f.state())['screens'][0]['groups']
            assert empty[side] is None
            assert {s:g for s,g in empty.items() if s != side} == {s:g for s,g in before.items() if s != side}
            add(item, side)
            assert verify(f.state())['screens'][0]['groups'] == before
        passed('removing each last visible item removes only its island; adding it restores only that island')
        # Saved/on items can draw nothing. Fake measurements enter the same production final-width layout.
        for side, item in items.items():
            f.controls(**{'hidden:kind:'+item:'yes'})
            state = verify(f.state())
            assert state['screens'][0]['groups'][side] is None
        f.controls(**{'hidden:kind:'+item:'yes' for item in items.values()})
        assert all(g is None for row in verify(f.state())['screens'] for g in row['groups'].values())
        f.controls(); f.call('remove', 'bar-items', 'clock', '--placement', 'topBar')
        f.call('add', 'bar-extensions', '--id', 'fixture', '--placement', 'topBar', '--side', 'centre', '--index', '0')
        assert verify(f.state())['screens'][0]['groups']['centre'] is None
        f.controls(extensionVisible='yes')
        assert verify(f.state())['screens'][0]['groups']['centre'] is not None
        f.call('remove', 'bar-extensions', 'fixture', '--placement', 'topBar')
        assert verify(f.state())['screens'][0]['groups']['centre'] is None
        passed('hidden/all-hidden items and actual BarParts extension face visibility feed the same final groups and overflow indices')
        add('clock','centre'); add('appMenus','left')
        f.controls(**{'width:kind:appMenus':'600', 'least:kind:appMenus':'36', 'width:kind:clock':'250', 'width:kind:wifi':'450'})
        folded = verify(f.state())
        assert any(row['gone'] for row in folded['screens'])
        assert any(a < b for row in folded['screens'] for side, values in row['widths'].items() for a,b in zip(values,row['measuredWidths'][side]))
        assert any(row['overflow'] is not None and row['groups']['right'] is not None for row in folded['screens'])
        assert all(row['groups']['centre'] is None or abs(row['groups']['centre']['frame'][0]+row['groups']['centre']['frame'][2]/2-row['frame'][2]/2)<0.00001 for row in folded['screens'])
        (EVIDENCE/'fold-overflow-hit.json').write_text(json.dumps(folded, indent=2))
        f.controls(); personal = f.personal(); edited = f.saved()
        f.stop(); f.start(); assert f.saved() == edited
        verify(f.state())
        passed('folding/overflow retains original slot mapping and centred geometry; persisted layout reopens with a new host PID')
        before = f.snap()
        for args in [('bar','preset','unknownIslands'), ('bar','geometry','spacing','nan'), ('bar','geometry','padding','99'), ('bar-fixture-edit','field','height','inf')]:
            f.call(*args, ok=False); assert f.snap() == before
        for bad in [dict(geometry, preset='unknownIslands'), dict(geometry, authority=True), dict(geometry, height=None)]:
            f.call('bar','geometry',json.dumps(bad),ok=False); assert f.snap() == before
        passed('unknown preset/nonfinite/out-of-range/null/authority setters remain effect-free')
        # Real pack suggestions use the existing ownership engine and contain no personal geometry/order.
        for pack, preset in zip(f.packs, ['floatingStrip','threeIslands']):
            pack['barPreset'] = preset; f.save_pack(pack)
        for name in ['a','b']: f.apply(name); assert f.geometry() == geometry and f.personal() == personal
        f.restore(); assert f.geometry() == geometry and f.personal() == personal
        f.call('theme','fixture-style','toybox'); assert f.geometry() == geometry
        f.call('theme','fixture-style','instrument'); assert f.geometry() == geometry
        f.call('theme','follow','bar','pack'); f.apply('a')
        assert f.geometry()['preset'] == 'floatingStrip' and f.personal() == personal
        f.apply('b'); assert f.geometry()['preset'] == 'threeIslands' and f.personal() == personal
        ledger = json.loads((f.root/'state/ownership.json').read_text())
        assert ledger['appearance']['original']['bar']['configuration'] == geometry
        f.stop(); f.start(); assert f.geometry()['preset'] == 'threeIslands'
        f.restore(); assert f.geometry() == geometry and f.personal() == personal
        f.apply('b'); f.call('theme','follow','bar','personal'); f.apply('a')
        assert f.geometry() == geometry and f.personal() == personal
        f.restore(); assert f.geometry() == geometry
        outgoing = f.root/'islands-export.json'; f.call('theme','export','b',str(outgoing))
        transfer = json.loads(outgoing.read_text())
        assert transfer['pack']['barPreset'] == 'threeIslands'
        for key in ['geometry','appearance','following','items','ownership']: assert key not in transfer['pack']
        transfer['pack']['id'] = 'islands-import'; incoming = f.root/'islands-import.json'; incoming.write_text(json.dumps(transfer))
        f.call('theme','import',str(incoming)); roundtrip = f.root/'islands-export-2.json'; f.call('theme','export','islands-import',str(roundtrip))
        assert json.loads(roundtrip.read_text()) == transfer
        passed('palette/style changes preserve geometry/items; real Follow A/B/Personal/Restore/restart and portable enum-only import/export roundtrip')
        for args in [('set','topBar.on','true'), ('run','engine.topBar'), ('bar','edit'), ('bar','exact','on'), ('system','sleep')]: f.call(*args,ok=False)
        f.stop(); f.receipt()
    finally:
        f.stop()
    # Keep all original malformed-store/recovery assertions. These entry points do not assume the new valid enum is invalid.
    strip.final_preservation()
    os.environ['PILOT_STRIP_FIX_CASE'] = 'release'
    strip.preservation_fixes()
    passed('unchanged T7 final strict-predecode/setter/reentrance and bar/palette/material interrupted-release recovery proofs')
    commands = [json.loads(line) for p in EVIDENCE.glob('fixtures/*/commands.jsonl') for line in p.read_text().splitlines()]
    hashes = {str(p.relative_to(REPO)):hashlib.sha256(p.read_bytes()).hexdigest() for p in [REPO/'.build/debug/PilotCLI', REPO/'.build/out/Products/Debug/PilotTests.xctest/Contents/MacOS/PilotTests'] if p.exists()}
    (EVIDENCE/'summary.json').write_text(json.dumps(dict(checks=len(checks), cliResponses=len(commands), hashes=hashes, pass_islands=True), indent=2))
    passed('islands')
