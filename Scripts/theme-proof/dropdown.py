"""The tall Pilot menu's arrangement (spec desktop-controls T4) through real PilotCLI -> the private bar host.

`pilot set` and `pilot get` of dropdown.order, dropdown.hidden and dropdown.pinned, a host restart reading them back
from the fixture home's own defaults, and the refusals: Status hidden, an unknown block, a fixed block moved.
"""
import importlib.util
import os
from pathlib import Path
import plistlib

spec = importlib.util.spec_from_file_location('dropdown_strip', Path(__file__).with_name('strip.py'))
strip = importlib.util.module_from_spec(spec)
spec.loader.exec_module(strip)
EVIDENCE = Path(os.environ.get('PILOT_THEME_PROOF_EVIDENCE') or Path.home() / '.local/state/spec' / 'desktop-controls/T4')
strip.EVIDENCE = EVIDENCE
strip.base.EVIDENCE = EVIDENCE
ALL = 'status,workspaces,switches,extensions,running,sound,connections,display,media,stats,commands'


def run(seam_only=False, fixes_only=False):
    EVIDENCE.mkdir(parents=True, exist_ok=True)
    lines = []

    def passed(text):
        lines.append('PASS ' + text)
        print('PASS ' + text, flush=True)

    f = strip.Fixture('dropdown')
    try:
        f.start()
        get = lambda key: f.call('get', key)
        assert (get('dropdown.order'), get('dropdown.hidden'), get('dropdown.pinned')) == (ALL, 'extensions,sound,connections,display,media,stats', 'none')
        passed('first arrangement: every block in its first order, the six optional blocks hidden, nothing pinned')

        f.call('set', 'dropdown.order', 'commands,running,switches')
        f.call('set', 'dropdown.hidden', 'workspaces,media')
        f.call('set', 'dropdown.pinned', 'status,commands')
        arranged = ('commands,running,switches,status,workspaces,extensions,sound,connections,display,media,stats', 'workspaces,media', 'status,commands')
        assert (get('dropdown.order'), get('dropdown.hidden'), get('dropdown.pinned')) == arranged
        passed('pilot set the order (named blocks lead, the rest follow), hidden and pinned; pilot get reads them back')

        f.stop()
        f.start()
        assert (get('dropdown.order'), get('dropdown.hidden'), get('dropdown.pinned')) == arranged
        prefs = plistlib.loads((f.home / 'Library/Preferences' / f'{f.suite}.plist').read_bytes())
        assert 'dropdown.layout' in prefs, sorted(prefs)
        passed("a host restart reads the same arrangement back from the fixture home's defaults")

        for key, value, words in [('dropdown.hidden', 'status', "status can't be hidden"),
                                  ('dropdown.hidden', 'status,sound', "status can't be hidden"),
                                  ('dropdown.order', 'status,banana', 'no block banana'),
                                  ('dropdown.pinned', 'nowhere', 'no block nowhere'),
                                  ('dropdown.order', 'developer', 'stays where it is'),
                                  ('dropdown.order', 'commands,commands', 'named twice')]:
            refused = f.call('set', key, value, ok=False)
            assert words in refused['error']['message'], (key, value, refused)
        assert (get('dropdown.order'), get('dropdown.hidden'), get('dropdown.pinned')) == arranged
        passed('refused, nothing changed: hiding Status, an unknown block name, moving a fixed block, a block named twice')

        f.call('set', 'dropdown.hidden', 'none')
        assert get('dropdown.hidden') == 'none'
        passed('hidden none shows every block, the optional ones included')

        # The Extensions card (Q74 A, Q75 its own list): its picks survive a restart, are asked only while the menu is
        # open with the card shown, and list in the card with their bar text.
        import json
        ext = f.root / 'extensions/fixture-ext'
        ext.mkdir(parents=True)
        (ext / 'extension.json').write_text(json.dumps(dict(
            id='fixture-ext', title='Fixture ext', icon='🧪', surfaces=dict(bar=dict(command='bar', every=60)),
            commands=[dict(name='bar', title='Bar', mode='no-view', hidden=True, run='run')])))
        (ext / 'run').write_text('#!/bin/sh\n')
        (ext / 'run').chmod(0o755)
        assert get('dropdown.extensions') == 'none'
        f.call('set', 'dropdown.extensions', 'fixture-ext')
        f.stop()
        f.start()
        assert get('dropdown.extensions') == 'fixture-ext'
        passed('pilot set dropdown.extensions; a host restart reads it back')
        closed = f.call('bar-fixture-extensions', 'closed')
        opened = f.call('bar-fixture-extensions', 'menu')
        assert closed['asked'] == [] and opened['asked'] == ['fixture-ext'], (closed, opened)
        assert opened['extensions'] == ['Fixture ext fixture-ext 42'], opened
        f.call('set', 'dropdown.hidden', 'extensions')
        hidden = f.call('bar-fixture-extensions', 'menu')
        assert hidden['asked'] == [] and hidden['extensions'] == [], hidden
        f.call('set', 'dropdown.hidden', 'none')
        passed(f"the card's extension is asked only while the menu is open with the card shown: closed {closed['asked']}, "
               f"open {opened['asked']} listing {opened['extensions']}, card hidden {hidden['asked']}")
        print('PASS dropdown', flush=True)
    finally:
        f.stop()
        (EVIDENCE / 'dropdown.log').write_text('\n'.join(lines) + '\n')
