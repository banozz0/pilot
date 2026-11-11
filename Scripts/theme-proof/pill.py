"""The pill (spec desktop-controls T5) through real PilotCLI -> the private bar host.

The pill item off by default; placed, each fixture screen (wide, notched, small, tiny) gives a drop frame hung from that
screen's bar under the item and inside its visible frame; with no bar it hangs from the visible frame's top; opening it
closes the other drops, and theirs close it (DropKeys).
"""
import importlib.util
import json
import os
from pathlib import Path

spec = importlib.util.spec_from_file_location('pill_strip', Path(__file__).with_name('strip.py'))
strip = importlib.util.module_from_spec(spec)
spec.loader.exec_module(strip)
EVIDENCE = Path(os.environ.get('PILOT_THEME_PROOF_EVIDENCE') or Path.home() / '.local/state/spec' / 'desktop-controls/T5')
strip.EVIDENCE = EVIDENCE
strip.base.EVIDENCE = EVIDENCE


def inside(inner, outer, slack=0.5):
    x, y, w, h = inner
    X, Y, W, H = outer
    return x >= X - slack and y >= Y - slack and x + w <= X + W + slack and y + h <= Y + H + slack


def run(seam_only=False, fixes_only=False):
    EVIDENCE.mkdir(parents=True, exist_ok=True)
    lines = []

    def passed(text):
        lines.append('PASS ' + text)
        print('PASS ' + text, flush=True)

    f = strip.Fixture('pill')
    try:
        f.start()
        entries = {e['kind']: e for e in f.saved()['entries'] if 'kind' in e}
        assert entries['pill']['on'] is False, entries.get('pill')
        assert all(s['pill']['item'] is None for s in f.state()['screens'])
        passed('the pill item is off by default: in no bar on any screen')

        f.call('add', 'bar-items', '--item', 'pill', '--placement', 'topBar')
        f.call('bar', 'move', 'pill', '--side', 'centre', '--index', '0')
        screens = {s['screen']: s for s in f.state()['screens']}
        assert set(screens) == {'wide', 'notched', 'small', 'tiny'}, set(screens)
        for name, screen in screens.items():
            pill = screen['pill']
            x, y, w, h = pill['drop']
            bx, by, bw, bh = pill['bar']
            assert pill['item'] is not None, (name, pill)
            assert abs((y + h) - by) < 0.5, (name, 'not hung from the bar', pill)
            assert inside(pill['drop'], pill['visible']), (name, 'outside the visible frame', pill)
            assert x - 0.5 <= pill['item'] <= x + w + 0.5, (name, 'not under the item', pill)
            assert w > 0 and h > 0, (name, pill)
            if w == 624:  # Room for the whole face: centred under the item unless the screen's edge holds it in.
                vx, _, vw, _ = pill['visible']
                if vx + 8 <= pill['item'] - 312 and pill['item'] + 312 <= vx + vw - 8:
                    assert abs((x + w / 2) - pill['item']) <= 0.5, (name, 'not centred under the item', pill)
            nx, ny, nw, nh = pill['noBar']
            vx, vy, vw, vh = pill['visible']
            assert abs((ny + nh) - (vy + vh)) < 0.5 and inside(pill['noBar'], pill['visible']), (name, 'no-bar drop', pill)
            assert abs((nx + nw / 2) - (vx + vw / 2)) <= 0.5, (name, 'no-bar drop not centred', pill)
        (EVIDENCE / 'pill-frames.json').write_text(json.dumps({n: s['pill'] for n, s in screens.items()}, indent=2))
        sizes = ', '.join(f"{n} {int(s['pill']['drop'][2])}x{int(s['pill']['drop'][3])}" for n, s in sorted(screens.items()))
        passed(f'placed, each screen hangs the drop from its bar, under the item, inside its visible frame ({sizes})')
        passed('with no bar, each screen hangs it from the top of its visible frame, centred')

        steps = f.call('bar-fixture-drops', 'askAI', 'terminal', 'pill', 'askAI', 'pill', 'escape')
        opened = [s['open'] for s in steps]
        assert opened == [['askAI'], ['terminal', 'askAI'], ['pill'], ['askAI'], ['pill'], []], opened
        assert steps[4]['focused'] == 'pill' and steps[5]['focused'] is None, steps
        passed('opening the pill closes the other drops, opening one closes the pill, and one Escape closes it')

        # Attached on every bar shape (Sven on build 2276: on Three islands the drop jutted past the pill's island): the
        # drop's top, shoulders and all, stays on the flat foot of the window the pill stands in, when that fits.
        f.controls(**{'width:kind:pill': '345'})
        for preset in ('threeIslands', 'floatingStrip'):
            f.call('bar', 'preset', preset)
            screens = {s['screen']: s['pill'] for s in f.state()['screens']}
            assert screens['wide']['item'] is not None, (preset, screens['wide'])
            for name, pill in screens.items():
                if pill['item'] is None:  # gone for room on this screen: no drop to hang
                    continue
                x, y, w, h = pill['drop']
                gx, gy, gw, gh = pill['ground']
                assert abs((y + h) - pill['bar'][1]) < 0.5 and inside(pill['drop'], pill['visible']), (preset, name, pill)
                if gw >= w:
                    assert gx - 0.5 <= x and x + w <= gx + gw + 0.5, (preset, name, 'off its ground', pill)
                elif inside([gx + gw / 2 - w / 2, y, w, h], pill['visible']):
                    assert abs((x + w / 2) - (gx + gw / 2)) <= 0.5, (preset, name, 'not centred under a narrow ground', pill)
            wide = screens['wide']
            before = [round(wide['item'] - wide['drop'][2] / 2), *wide['drop'][1:]]
            (EVIDENCE / f'pill-{preset}.json').write_text(json.dumps(screens, indent=2))
            shown = sorted(n for n, p in screens.items() if p['item'] is not None)
            passed(f'{preset} ({", ".join(shown)}): each drop stays on the foot of the pill\'s window (wide: window {wide["window"]}, '
                   f'item-centred {before} -> {wide["drop"]})')
        # The views (T7): order and selection survive a restart; a hidden view is skipped; the pill's extensions are
        # listed in Extensions and asked only while that view shows.
        get = lambda key: f.call('get', key)
        assert (get('pill.views'), get('pill.hidden'), get('pill.view'), get('pill.extensions')) == (
            'music,extensions,activity,controls', 'none', 'music', 'none')
        f.call('set', 'pill.views', 'controls,activity')
        f.call('set', 'pill.view', 'activity')
        chosen = ('controls,activity,music,extensions', 'activity')
        assert (get('pill.views'), get('pill.view')) == chosen
        f.stop()
        f.start()
        assert (get('pill.views'), get('pill.view')) == chosen
        passed('pilot set the views (named lead, the rest follow) and the one showing; a host restart reads both back')

        f.call('set', 'pill.hidden', 'activity')
        assert get('pill.view') == 'controls', get('pill.view')
        refused = f.call('set', 'pill.view', 'activity', ok=False)
        assert 'hidden' in refused['error']['message'], refused
        refused = f.call('set', 'pill.hidden', 'music,extensions,activity,controls', ok=False)
        assert 'one view must show' in refused['error']['message'], refused
        assert (get('pill.hidden'), get('pill.view')) == ('activity', 'controls')
        passed('a hidden view is skipped: the pill shows the first one shown, a hidden one cannot be picked, one always shows')

        ext = f.root / 'extensions/fixture-ext'
        ext.mkdir(parents=True)
        (ext / 'extension.json').write_text(json.dumps(dict(
            id='fixture-ext', title='Fixture ext', icon='🧪', surfaces=dict(bar=dict(command='bar', every=60)),
            commands=[dict(name='bar', title='Bar', mode='no-view', hidden=True, run='run')])))
        (ext / 'run').write_text('#!/bin/sh\n')
        (ext / 'run').chmod(0o755)
        f.call('set', 'pill.extensions', 'fixture-ext')
        away = f.call('bar-fixture-extensions', 'pill')
        assert away == dict(view='controls', asked=[], extensions=['Fixture ext …']), away
        f.call('set', 'pill.view', 'extensions')
        shown = f.call('bar-fixture-extensions', 'pill')
        assert shown == dict(view='extensions', asked=['fixture-ext'], extensions=['Fixture ext fixture-ext 42']), shown
        passed(f"a fixture extension in the pill: not asked while Controls shows ({away['asked']}), "
               f"asked and listed once Extensions shows ({shown['asked']}, {shown['extensions']})")
        print('PASS pill', flush=True)
    finally:
        f.stop()
        (EVIDENCE / 'pill.log').write_text('\n'.join(lines) + '\n')
