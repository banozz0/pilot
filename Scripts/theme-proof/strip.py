"""Actual PilotCLI/private early bar host; persistent real setters, existing ownership and placement."""
import base64
import concurrent.futures
import copy
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import plistlib
import stat
import subprocess
import time

spec = importlib.util.spec_from_file_location('strip_lifecycle', Path(__file__).with_name('lifecycle.py'))
base = importlib.util.module_from_spec(spec)
spec.loader.exec_module(base)
REPO = base.REPO
EVIDENCE = Path(os.environ.get('PILOT_THEME_PROOF_EVIDENCE') or Path.home() / '.local/state/spec' / 'theme-system/T7/cli')
base.EVIDENCE = EVIDENCE


class Fixture(base.Fixture):
    def __init__(self, label):
        super().__init__(label)
        self.home = self.root / 'home'
        (self.home/"Library/Preferences").mkdir(parents=True)
        self.native = self.root / 'native.json'
        self.original_native = dict(palette={'stock': {'_0': 'tokyo-night'}}, material=dict(glass=False, transparency=43, blur='light'))
        self.native.write_text(json.dumps(self.original_native))
        self.suite = 'dev.banozz.pilot.strip-' + self.root.name
        self.settings = dict(root=str(self.root), home=str(self.home), suite=self.suite,
                             state=str(self.root/'state'), packs=str(self.root/'packs'), socket=str(self.socket),
                             control=str(self.control), nativeState=str(self.native), baseline=self.original_native,
                             binding=self.settings['binding'], screens=[
                                 dict(name='wide', x=0, y=0, width=1920, height=1080, strip=30, notch=0),
                                 dict(name='notched', x=-1512, y=0, width=1512, height=982, strip=37, notch=37),
                                 dict(name='small', x=1920, y=-180, width=360, height=640, strip=24, notch=0),
                                 dict(name='tiny', x=2280, y=0, width=200, height=140, strip=22, notch=0)])
        self.manifest.write_text(json.dumps(self.settings))
        self.expected_invalid = False
        (self.root/"manifest-before.json").write_text(json.dumps(self.snapshot(),indent=2))
        assert len(str(self.socket).encode()) < 100

    def start(self, extra_env=None, expect_ready=True):
        assert self.process is None
        self.expected_invalid = not expect_ready
        self.counter += 1
        self.log = (self.root/f'host-{self.counter}.log').open('w')
        env = {k:v for k,v in os.environ.items() if not k.startswith(('PILOT_', 'CFFIXED_'))}
        additions = dict(PILOT_BAR_FIXTURE=str(self.manifest), CFFIXED_USER_HOME=str(self.home))
        additions.update(extra_env or {})
        env.update(additions)
        (self.root/f'host-{self.counter}.command.json').write_text(json.dumps(dict(command=base.HOST, environment=additions)))
        self.process = subprocess.Popen(base.HOST, cwd=REPO, env=env, stdout=self.log, stderr=subprocess.STDOUT)
        (self.root/f'host-{self.counter}.pid').write_text(str(self.process.pid))
        deadline = time.monotonic()+40
        while time.monotonic()<deadline:
            if Path(str(self.socket)+'.hold').exists():
                assert expect_ready, 'unsafe fixture started'
                assert stat.S_IMODE(self.socket.stat().st_mode)==0o600
                return
            if self.process.poll() is not None:
                code=self.process.wait();self.process=None;self.log.close()
                (self.root/f'host-{self.counter}.exit').write_text(str(code))
                assert not expect_ready, (code, (self.root/f'host-{self.counter}.log').read_text()[-6000:])
                return
            time.sleep(.1)
        self.stop()
        raise AssertionError('bar fixture not ready')

    def stop(self, crashed=False):
        if self.process is None:return
        hold=Path(str(self.socket)+'.hold')
        if not crashed:hold.unlink(missing_ok=True)
        try:code=self.process.wait(timeout=40)
        finally:
            if self.process.poll() is None:self.process.terminate();self.process.wait(timeout=10)
            self.process=None;self.log.close();hold.unlink(missing_ok=True)
        (self.root/f'host-{self.counter}.exit').write_text(str(code))
        if crashed:assert code!=0,code  # SwiftPM maps the injected child exit 86 to a failing test target.
        if not crashed:
            assert code==0,code
            assert 'BAR FIXTURE ONLY: Engine=absent live=absent Keychain=absent production-registry=absent effects=recording home=explicit' in (self.root/f'host-{self.counter}.log').read_text()

    def snapshot(self):
        result=super().snapshot()
        for folder in ['home']:
            for path in (self.root/folder).rglob('*'):
                if path.is_file():result[str(path.relative_to(self.root))]=base.digest(path)
        path=self.root/'native.json'
        if path.exists():result['native.json']=base.digest(path)
        return result

    def state(self):return self.call('bar-fixture')
    def saved(self):return self.state()['saved']
    def geometry(self):return self.saved().get('preset')
    def personal(self):
        s=self.saved();s.pop('preset',None);return s
    def defaults_bytes(self):
        self.state()
        path=self.home/'Library/Preferences'/f'{self.suite}.plist'
        data=plistlib.loads(path.read_bytes())['bar.items']
        with (self.root/'defaults-observations.jsonl').open('a') as out:
            out.write(json.dumps(dict(path=str(path),barItems=base64.b64encode(data).decode(),sha256=hashlib.sha256(data).hexdigest()))+'\n')
        return data
    def effects(self):
        p=self.root/'state/effects.jsonl'
        return p.read_bytes() if p.exists() else b''
    def snap(self):
        return dict(saved=self.saved(), native=self.native.read_bytes().hex(), effects=self.effects().hex(),
                    ownership=(self.root/'state/ownership.json').read_bytes().hex() if (self.root/'state/ownership.json').exists() else None)


def run(seam_only=False, fixes_only=False):
    if fixes_only:
        return preservation_fixes()
    EVIDENCE.mkdir(parents=True,exist_ok=True)
    fixtures_before=set(EVIDENCE.glob("fixtures/*"))
    checks=[]
    def passed(text):
        checks.append(text);print('PASS '+text,flush=True)
        (EVIDENCE/'strip.log').write_text('\n'.join('PASS '+v for v in checks)+'\n')
    f=Fixture('strip')
    try:
        f.start()
        f.call('bar','move','clock','--side','left','--index','1')
        f.call('set','bar.clock','HH:mm:ss')
        legacy=f.defaults_bytes();personal=f.personal();before=f.snap()
        for args in [('bar',),('list','bar-items'),('list','bar-extensions'),('settings','--page','menuBar'),('bar',)]:f.call(*args)
        assert f.snap()==before and f.defaults_bytes()==legacy
        for args in [('set','topBar.on','true'),('bar','edit'),('bar','exact','on'),('run','engine.topBar'),('system','sleep')]:f.call(*args,ok=False)
        assert f.snap()==before and f.defaults_bytes()==legacy
        f.stop();f.start();assert f.defaults_bytes()==legacy and f.geometry() is None
        passed('old saved layout byte-preserved on reads and new-process reopen; no implicit preset')
        f.call('bar','preset','floatingStrip')
        assert f.personal()==personal
        for key,value in [('height','40'),('spacing','13'),('horizontalMargin','27'),('topMargin','9'),('radius','12'),('border','2'),('padding','7')]:
            f.call('bar','geometry',key,value);assert f.geometry()[key]==float(value)
        f.call('add','bar-items','--item','wifi','--placement','topBar','--side','left','--index','1')
        f.call('add','bar-extensions','--id','fixture','--placement','topBar','--side','centre','--index','0')
        f.call('bar','move','clock','--side','right','--index','0')
        f.call('remove','bar-items','otherApps')
        f.call('set','bar.background','glass')
        edited=f.saved();geometry=edited['preset'];personal=f.personal()
        f.stop();f.start();assert f.saved()==edited and f.call('get','bar.background')=='glass'
        passed('native-shared setters persist order/enabled/side/extensions/spacing/margins/material background across process reopen')
        state=f.state()
        for screen,row in zip(f.settings['screens'],state['screens']):
            x,y,w,h=row['frame'];assert w>0 and h>0 and x>=screen['x'] and y>=screen['y']
            assert x+w<=screen['x']+screen['width'] and y+h<=screen['y']+screen['height']-screen['notch']
            positions=[p for ps in row['placement'].values() for p in ps if p is not None]
            assert all(p>=0 for p in positions)
        assert state['screens'][0]['overflow'] is None and state['screens'][-1]['overflow'] is not None
        passed('same production frame/row placement accepts supplied wide/notched/narrow/small multi-screen geometry and overflow')
        before=f.snap()
        for key,value in [('spacing','nan'),('height','inf'),('radius','-1'),('horizontalMargin','161'),('preset','unsupportedPreset'),('preset','nope')]:f.call('bar','preset',value,ok=False) if key=='preset' else f.call('bar','geometry',key,value,ok=False)
        for value in [dict(geometry,spacing=99),dict(geometry,preset='islands'),dict(geometry,height=None),dict(geometry,unknown=True),dict(geometry,height='NaN')]:
            f.call('bar','geometry',json.dumps(value),ok=False)
        for text in [json.dumps(geometry)[:-1]+',"spacing":1}',json.dumps(dict(geometry,height=float('nan'))),'{"preset":"floatingStrip"}', 'null']:
            f.call('bar','geometry',text,ok=False)
        assert f.snap()==before
        f.call('bar','spacer','nan',ok=False);assert f.snap()==before
        passed('unknown preset/NaN/infinity/range/unknown/null/duplicate/missing geometry payloads are effect-free')
        f.call('bar','preset','floatingStrip');assert f.geometry()!=geometry and f.personal()==personal
        f.call('bar','geometry',json.dumps(geometry));assert f.personal()==personal
        passed('explicit Reset geometry uses the shared preset setter and preserves personal items')
        # Palette-only and item edits never acquire geometry authority.
        for name in ['a','b']:f.apply(name);assert f.geometry()==geometry and f.personal()==personal
        f.restore();assert f.geometry()==geometry and f.personal()==personal and f.call('get','bar.background')=='glass'
        f.call('theme','fixture-style','toybox');assert f.geometry()==geometry and f.personal()==personal
        f.call('theme','fixture-style','instrument');assert f.geometry()==geometry and f.personal()==personal
        passed('palette A/B/Restore and actual per-style palette switches preserve personal geometry and all personal items')
        f.call('theme','follow','bar','pack');f.call('theme','plan','apply','a',ok=False)
        for pack in f.packs:pack['barPreset']='floatingStrip';f.save_pack(pack)
        outgoing=f.root/'strip-export.json';f.call('theme','export','a',str(outgoing))
        transfer=json.loads(outgoing.read_text());assert transfer['pack']['barPreset']=='floatingStrip'
        assert 'geometry' not in transfer['pack'] and 'appearance' not in transfer['pack'] and 'following' not in transfer['pack']
        transfer['pack']['id']='strip-import';incoming=f.root/'strip-import.json';incoming.write_text(json.dumps(transfer))
        f.call('theme','import',str(incoming));second=f.root/'strip-export-2.json';f.call('theme','export','strip-import',str(second))
        assert json.loads(second.read_text())==transfer
        passed('portable export/import round-trips only the typed floatingStrip suggestion')
        f.call('theme','follow','bar','personal');before=f.snap();plan=f.plan('a');f.controls(allow='no')
        f.call('theme','apply',plan,ok=False);assert f.snap()==before
        f.controls();f.call('theme','follow','bar','pack');f.apply('a');preset=f.geometry()
        assert preset!=geometry and f.personal()==personal
        ledger=json.loads((f.root/'state/ownership.json').read_text())
        assert ledger['appearance']['barOwned'] is True and ledger['appearance']['original']['bar']['configuration']==geometry
        f.apply('b');assert json.loads((f.root/'state/ownership.json').read_text())['appearance']['original']['bar']['configuration']==geometry
        f.stop();f.start();assert f.geometry()==preset and f.personal()==personal
        f.restore();assert f.geometry()==geometry and f.personal()==personal
        passed('real pack-follow A/B/new-process Restore restores one original geometry; no suggestion refuses; denial has no effects')
        f.apply('a');f.call('theme','follow','bar','personal');f.apply('b');assert f.geometry()==geometry
        f.restore();assert f.geometry()==geometry and f.personal()==personal
        passed('Personal stages only then releases matching geometry through existing reviewed Apply')
        # Unknown manifest authority and duplicate portable suggestion fail through the actual pack loader.
        f.call('theme','follow','bar','personal')
        path=f.root/'packs/a/manifest.json';original=path.read_bytes();before=f.snap()
        for invalid in [dict(f.packs[0],barPreset=None),dict(f.packs[0],barPreset='unsupportedPreset'),dict(f.packs[0],geometry=geometry)]:
            path.write_text(json.dumps(invalid));f.call('theme','show','a',ok=False)
        path.write_bytes(original[:-1]+b',"barPreset":"floatingStrip"}')
        f.call('theme','show','a',ok=False);path.write_bytes(original);assert f.snap()==before
        passed('portable packs reject geometry/authority/null/unknown/duplicate preset suggestions')
        f.call('theme','follow','bar','pack');plan=f.plan('a');f.call('bar','geometry','spacing','14');before=f.snap()
        f.call('theme','apply',plan,ok=False);assert f.snap()==before
        # The coordinator's brief: a Look part the person changed after Apply is theirs. Restore keeps it; Apply gives it
        # the new theme with theirs as what Restore puts back. Nothing refuses.
        geometry=f.geometry();f.apply('a');f.call('bar','geometry','spacing','15');mine=f.geometry()
        kept=f.call('theme','plan','restore')['review']['kept'];assert [w for w in kept if 'top bar layout' in w and 'stay' in w],kept
        answer=f.restore();assert answer['status']=='restored' and f.geometry()==mine and [w for w in answer['kept'] if w.startswith('Kept the top bar layout')],answer
        f.call('bar','geometry',json.dumps(geometry));f.apply('a');f.call('bar','geometry','spacing','16');mine=f.geometry()
        plan=f.call('theme','plan','apply','b');assert [w for w in plan['review']['kept'] if 'top bar layout' in w and 'take this theme' in w],plan['review']
        assert f.call('theme','apply',plan['id'])['status']=='applied' and f.geometry()!=mine
        assert f.restore()['status']=='restored' and f.geometry()==mine
        f.call('bar','geometry',json.dumps(geometry))
        passed('stale pre-Allow geometry refuses; a later personal layout is let go: Restore keeps it, Apply takes it with it as what Restore puts back')
        # During Allow, a geometry change refuses, whereas an unrelated item change survives a valid Apply.
        for change_geometry in [True,False]:
            plan=f.plan('a');f.controls(hold='yes');(f.root/'asked').unlink(missing_ok=True);(f.root/'go').unlink(missing_ok=True)
            with concurrent.futures.ThreadPoolExecutor(max_workers=1) as pool:
                future=pool.submit(f.call,'theme','apply',plan,ok=not change_geometry)
                deadline=time.monotonic()+20
                while not (f.root/'asked').exists() and time.monotonic()<deadline:time.sleep(.05)
                assert (f.root/'asked').exists()
                if change_geometry:f.call('bar','geometry','spacing','16')
                else:f.call('bar','move','wifi','--side','right','--index','0')
                personal=f.personal();before_effect=f.effects();(f.root/'go').touch();future.result()
                if change_geometry:assert f.effects()==before_effect
                assert f.personal()==personal
            f.controls()
        f.restore();geometry=f.geometry()
        passed('after-Allow geometry freshness enforced; unrelated item changes during Allow are preserved')
        for stage in ['native','after-native','ledger']:
            f.controls(fail=stage);before=f.snap();answer=f.apply('a');assert f.geometry()==geometry and f.personal()==personal
            assert answer['status']!='applied'
            f.controls()
        passed('injected native/after-native/ledger failures roll geometry back through existing journal')
        f.controls(crash='after-native');plan=f.plan('a');f.call('theme','apply',plan,ok=False);f.stop(crashed=True)
        assert (f.root/'state/pending.json').exists();f.controls();f.start();assert f.geometry()==geometry and f.personal()==personal
        passed('new-process recovery restores geometry after crash following native write')
        # Every additive local authority shape is validated before any recovery effect.
        f.apply('a');f.stop();ledger_path=f.root/'state/ownership.json';original_ledger=ledger_path.read_bytes()
        for where in ['barOwned','following','original','last','missing-mask','unknown','duplicate']:
            ledger=json.loads(original_ledger)
            if where=='barOwned':ledger['appearance']['barOwned']=None
            elif where=='following':ledger['appearance']['following']['bar']=None
            elif where=='missing-mask':ledger['appearance'].pop('barOwned')
            elif where=='unknown':ledger['appearance']['barAuthority']=True
            elif where!='duplicate':ledger['appearance'][where]['bar']=None
            text=json.dumps(ledger)
            if where=='duplicate':text=text.replace('"barOwned": true','"barOwned": true,"barOwned": false',1)
            ledger_path.write_text(text);effects=f.effects();f.start(expect_ready=False);assert f.effects()==effects
        ledger_path.write_bytes(original_ledger)
        # Missing new fields remain accepted only as old unowned schema1; no inferred bar ownership.
        old=json.loads(original_ledger);old['appearance'].pop('barOwned');old['appearance']['following'].pop('bar')
        for key in ['original','last']:old['appearance'][key].pop('bar')
        ledger_path.write_text(json.dumps(old));f.start();assert f.call('theme','status')['selected']['id']=='a';f.stop()
        ledger_path.write_bytes(original_ledger);f.start();f.restore();f.stop()
        passed('malformed current native bar authority is refused before effects; missing additive schema1 fields still load')
        # A pending journal embeds typed ledgers; corrupt both outer and embedded native authorities.
        f.start();f.controls(crash='after-native');plan=f.plan('a');f.call('theme','apply',plan,ok=False);f.stop(crashed=True);f.controls()
        pending=f.root/'state/pending.json';pending_bytes=pending.read_bytes()
        for variant in ['outer-null','embedded-null','outer-unknown','outer-duplicate']:
            doc=json.loads(pending_bytes)
            if variant=='outer-null':doc['appearance']['bar']=None
            elif variant=='outer-unknown':doc['appearance']['unknownBar']=True
            elif variant=='outer-duplicate':
                raw=json.dumps(doc);raw=raw.replace('"bar": true','"bar": true,"bar": false',1);pending.write_text(raw)
            else:
                import base64
                embedded=json.loads(base64.b64decode(doc['afterLedger']));embedded['appearance']['last']['bar']=None
                doc['afterLedger']=base64.b64encode(json.dumps(embedded).encode()).decode()
            if variant!='outer-duplicate':pending.write_text(json.dumps(doc))
            effects=f.effects();f.start(expect_ready=False);assert f.effects()==effects
        pending.write_bytes(pending_bytes);f.start();assert f.geometry()==geometry;f.stop()
        passed('outer and embedded journal null/unknown/duplicate native authority refuses before recovery effects')
        f.receipt()
    finally:f.stop()
    # Dispatcher fail-closed and fixture environment isolation happen outside the normal host.
    result=subprocess.run(['python3','Scripts/theme-proof.py','--case','unknown'],cwd=REPO,capture_output=True,text=True)
    assert result.returncode!=0
    (EVIDENCE/'unknown-case.json').write_text(json.dumps(dict(exit=result.returncode,stdout=result.stdout,stderr=result.stderr)))
    f=Fixture('isolation')
    try:
        f.start(extra_env={'PILOT_LIVE':'1'},expect_ready=False)
        f.start(extra_env={'PILOT_SANDBOX_ALLOW':'1'},expect_ready=False)
        f.start(extra_env={'CFFIXED_USER_HOME':str(f.root)},expect_ready=False)
        f.start();saved=f.saved();f.stop()
        prefs=f.home/'Library/Preferences'/f'{f.suite}.plist';original=prefs.read_bytes()
        duplicate=copy.deepcopy(saved);duplicate['entries'].append(copy.deepcopy(saved['entries'][0]))
        unplaced=dict(saved,extensionItems=[dict(id='fixture',on=True,placement='topBar')])
        for malformed in [duplicate,unplaced,dict(saved,preset=None),dict(saved,preset={'preset':'unknown'})]:
            values=plistlib.loads(original);values['bar.items']=json.dumps(malformed).encode()
            encoded=plistlib.dumps(values,fmt=plistlib.FMT_BINARY);prefs.write_bytes(encoded)
            effects=f.effects();f.start(expect_ready=False);assert f.effects()==effects and prefs.read_bytes()==encoded
        prefs.write_bytes(original);f.start();assert f.saved()==saved;f.stop();f.receipt()
        passed('duplicate saved items, unplaced legacy extensions and malformed saved preset refuse before store/live migration, retaining raw bytes')
    finally:f.stop()
    passed('unknown case and mixed/live/home-mismatch fixture environments fail closed')
    fixtures=set(EVIDENCE.glob('fixtures/*'))-fixtures_before
    commands=[json.loads(line) for root in fixtures for p in root.glob('commands.jsonl') for line in p.read_text().splitlines()]
    hashes={str(p.relative_to(REPO)):hashlib.sha256(p.read_bytes()).hexdigest() for p in [REPO/'.build/debug/PilotCLI',*REPO.glob('Sources/PilotCore/BarPreset.swift'),*REPO.glob('Sources/Pilot/Control/BarFixture.swift')]}
    (EVIDENCE/'summary.json').write_text(json.dumps(dict(checks=len(checks),cliResponses=len(commands),hashes=hashes,hosts=sum(len(list(root.glob('host-*.log'))) for root in fixtures),fixtures=sorted(map(str,fixtures)),pass_strip=True),indent=2))
    passed('strip')


def protected(f):
    # SwiftPM writes its own cache when launching a host; every preference/native/effect/authority file is protected.
    return {k: v for k, v in f.snapshot().items() if not k.startswith('home/Library/Caches/')}


def archive(f, label):
    values = {}
    for folder in ['state', 'app', 'packs', 'home/Library/Preferences']:
        for p in (f.root/folder).rglob('*'):
            if p.is_symlink(): values[str(p.relative_to(f.root))] = {'link': os.readlink(p)}
            elif p.is_file(): values[str(p.relative_to(f.root))] = {'hex': p.read_bytes().hex(), 'mode': stat.S_IMODE(p.stat().st_mode)}
    values['native.json'] = {'hex': f.native.read_bytes().hex()}
    (f.root/(label+'.bytes.json')).write_text(json.dumps(values, indent=2))


def preservation_fixes():
    """Real shared loader and interrupted partial-release recovery, without live preferences."""
    EVIDENCE.mkdir(parents=True, exist_ok=True)
    selected = os.environ.get('PILOT_STRIP_FIX_CASE', 'all')
    if selected == 'final': return final_preservation()
    results = []
    if selected in ['all', 'store']:
        f = Fixture('saved-loader')
        try:
            f.settings['loadProbe'] = True
            f.manifest.write_text(json.dumps(f.settings))
            f.start()
            f.call('bar', 'move', 'clock', '--side', 'left', '--index', '1')
            f.call('add', 'bar-extensions', '--id', 'fixture', '--placement', 'topBar', '--side', 'centre')
            f.call('bar', 'preset', 'floatingStrip')
            saved = f.saved(); f.stop()
            prefs = f.home/'Library/Preferences'/f'{f.suite}.plist'
            values = plistlib.loads(prefs.read_bytes()); config = saved['preset']
            malformed = copy.deepcopy(saved); malformed['preset']['height'] = 999
            variants = [('height-range', json.dumps(malformed).encode()),
                        ('key-type', 'existing string, not saved Data'), ('broken-json', b'{broken'),
                        ('preset-type', json.dumps(dict(saved,preset=[])).encode()),
                        ('unknown-id', json.dumps(dict(saved,preset=dict(config,preset='unsupportedPreset'))).encode()),
                        ('null', json.dumps(dict(saved,preset=None)).encode()),
                        ('unknown-field', json.dumps(dict(saved,preset=dict(config,authority=True))).encode()),
                        ('missing-field', json.dumps(dict(saved,preset={'preset':'floatingStrip'})).encode()),
                        ('negative-range', json.dumps(dict(saved,preset=dict(config,padding=-1))).encode()),
                        ('numeric-type', json.dumps(dict(saved,preset=dict(config,height='36'))).encode()),
                        ('duplicate-geometry', json.dumps(dict(saved,preset=config)).replace('"height": 36','"height": 36,"height": 40').encode()),
                        ('duplicate-preset', (json.dumps(saved)[:-1]+',"preset":'+json.dumps(config)+'}').encode())]
            edits = [('bar','preset','legacy'), ('bar','preset','floatingStrip'), ('bar','clear'), ('bar','restore'),
                     ('bar','move','clock','--side','right'), ('bar','style','clock','time'), ('bar','spacer','30'),
                     ('bar','geometry',json.dumps(config)), ('bar','exact','on'),
                     ('set','bar.clock','HH:mm:ss'), ('set','bar.background','glass'), ('set','bar.colour','theme'),
                     ('set','bar.itemColours','false'), ('set','bar.pagePlacement','topBar'),
                     ('set','bar.readingsLook','text'), ('set','bar.clockStyle','time'), ('set','bar.clockZone','none'),
                     ('set','bar.clockEvents','true'), ('add','bar-items','--item','wifi'), ('remove','bar-items','clock'),
                     ('add','bar-extensions','--id','fixture','--placement','topBar'), ('remove','bar-extensions','fixture'),
                     ('theme','plan','apply','a')]
            for i, (label, payload) in enumerate(variants):
                values['bar.items'] = payload
                for key in ['bar.pilotMarkAlone','bar.extensionsApart']:
                    values.pop(key,None)
                    if i % 3 != 2: values[key] = i % 3 == 1
                encoded=plistlib.dumps(values,fmt=plistlib.FMT_BINARY); prefs.write_bytes(encoded)
                archive(f,label+'-input'); before=protected(f)
                f.start()
                archive(f,label+'-loaded')
                assert prefs.read_bytes()==encoded, 'production loader overwrote malformed personal settings/migration flags'
                assert f.state()['loadError'] and not f.state()['native']
                for args in edits:
                    f.call(*args,ok=False)
                    assert protected(f)==before, (label,args)
                f.stop(); f.start(); assert protected(f)==before
                f.stop(); archive(f,label+'-refused-reopened')
                results.append('saved loader '+label+': exact bytes/flags, all real setter refusals and restart')
            # Missing is first launch; an existing valid legacy layout is not first launch.
            values.pop('bar.items'); values.pop('bar.pilotMarkAlone',None); values.pop('bar.extensionsApart',None)
            prefs.write_bytes(plistlib.dumps(values,fmt=plistlib.FMT_BINARY)); f.start()
            assert f.state()['loadError'] is None and f.geometry() is None
            f.stop(); missing=plistlib.loads(prefs.read_bytes())
            assert missing['bar.pilotMarkAlone'] and missing['bar.extensionsApart'] and isinstance(missing['bar.items'],bytes)
            for label,layout in [('valid-legacy',{k:v for k,v in saved.items() if k!='preset'}),('valid-preset',saved)]:
                missing['bar.items']=json.dumps(layout).encode(); encoded=plistlib.dumps(missing,fmt=plistlib.FMT_BINARY)
                prefs.write_bytes(encoded); f.start(); assert f.saved()==layout and f.state()['loadError'] is None
                f.stop(); f.start(); assert prefs.read_bytes()==encoded; f.stop(); archive(f,label)
            legacy=copy.deepcopy(saved); legacy.pop('preset'); legacy['entries']=[x for x in legacy['entries'] if x.get('kind')!='extension']
            missing['bar.items']=json.dumps(legacy).encode(); missing['bar.extensionsApart']=False
            prefs.write_bytes(plistlib.dumps(missing,fmt=plistlib.FMT_BINARY)); f.start()
            assert f.state()['loadError'] is None and any(x.get('extension')=='fixture' for x in f.saved()['entries'])
            f.stop(); archive(f,'explicit-extension-order-migration')
            results.append('missing/valid legacy/valid preset and legacy extension migration use the production loader with explicit fake sources')
        finally:
            f.stop(); f.receipt()
    if selected in ['all', 'release']:
        for component in ['bar','palette','material']:
            f = Fixture('r-'+component[0])
            try:
                f.start(); f.call('bar','preset','floatingStrip'); f.call('bar','geometry','spacing','13')
                geometry=f.geometry()
                for pack in f.packs:
                    pack['barPreset']='floatingStrip'; pack['material']=dict(glass=True,transparency=35,blur='full'); f.save_pack(pack)
                for name in ['bar','material']: f.call('theme','follow',name,'pack')
                f.apply('a'); f.call('theme','follow',component,'personal'); f.controls(crash='after-native')
                plan=f.plan('b'); f.call('theme','apply',plan,ok=False); f.stop(crashed=True); f.controls()
                pending=f.root/'state/pending.json'; valid_pending=pending.read_bytes(); doc=json.loads(valid_pending)
                released = doc['appearance']['after'][component]
                assert released==json.loads(base64.b64decode(doc['beforeLedger']))['appearance']['original'][component]
                later = {'bar':dict(configuration=dict(geometry,spacing=19)),
                         'palette':{'stock':{'_0':'dracula'}},
                         'material':dict(glass=False,transparency=79,blur='off')}[component]
                doc['appearance']['after'][component]=later
                embedded=json.loads(base64.b64decode(doc['afterLedger']))
                assert not embedded['appearance'].get(component+'Owned',False)
                embedded['appearance']['last'][component]=later
                doc['afterLedger']=base64.b64encode(json.dumps(embedded).encode()).decode()
                pending.write_text(json.dumps(doc))
                prefs=f.home/'Library/Preferences'/f'{f.suite}.plist'; valid_prefs=prefs.read_bytes(); valid_native=f.native.read_bytes()
                if component=='bar':
                    values=plistlib.loads(valid_prefs); saved=json.loads(values['bar.items']); saved['preset']=later['configuration']
                    values['bar.items']=json.dumps(saved).encode(); prefs.write_bytes(plistlib.dumps(values,fmt=plistlib.FMT_BINARY))
                else:
                    value=json.loads(valid_native);value[component]=later;f.native.write_text(json.dumps(value))
                before=protected(f);archive(f,'tampered-input')
                (f.root/'tampered-before.json').write_text(json.dumps(before,indent=2))
                try: f.start(expect_ready=False)
                finally:
                    archive(f,'tampered-result');(f.root/'tampered-after.json').write_text(json.dumps(protected(f),indent=2))
                assert protected(f)==before, 'invalid partial release changed current state/effects/recovery records'
                results.append('partial '+component+' release: tampered after/embedded last/current refuse before every effect; recovery retained')
                # Independently malformed authority and mutation masks, based on the valid interrupted partial release.
                pending.write_bytes(valid_pending); prefs.write_bytes(valid_prefs); f.native.write_bytes(valid_native)
                for variant in ['unknown','null','duplicate','mask','unowned']:
                    change=json.loads(valid_pending)
                    if variant=='unknown': change['appearance']['after']['foreignAuthority']=True
                    elif variant=='null': change['appearance']['after']['bar']=None
                    elif variant=='mask': change['appearance'][component]=False
                    elif variant=='unowned':
                        change['appearance']['bar']=False
                        change['appearance']['after']['bar']={'configuration':dict(geometry,spacing=21)}
                        embedded=json.loads(base64.b64decode(change['afterLedger']))
                        embedded['appearance']['last']['bar']=change['appearance']['after']['bar']
                        change['afterLedger']=base64.b64encode(json.dumps(embedded).encode()).decode()
                    raw=json.dumps(change)
                    if variant=='duplicate': raw=raw.replace('"bar": true','"bar": true,"bar": false',1)
                    pending.write_text(raw);before=protected(f);archive(f,variant+'-input')
                    f.start(expect_ready=False);assert protected(f)==before;archive(f,variant+'-refused')
                pending.write_bytes(valid_pending);f.start()
                assert not pending.exists() and f.geometry()==json.loads(valid_pending)['appearance']['before']['bar']['configuration']
                # Complete the same valid partial release and prove Restore/restart retain all original masks.
                f.apply('b');partial=f.snap();f.stop();f.start();assert f.snap()==partial
                f.restore();assert f.geometry()==geometry and json.loads(f.native.read_bytes())==f.original_native
                f.stop();f.start();assert f.geometry()==geometry;f.stop();archive(f,'valid-recovery-partial-restore-restart')
                results.append('partial '+component+' release: strict malformed/mask checks and valid recovery/partial Apply/Restore/restart')
            finally:
                f.stop(); f.receipt()
    for result in results: print('PASS '+result,flush=True)
    (EVIDENCE/'preservation-results.json').write_text(json.dumps(results,indent=2))


def final_preservation():
    """Predecode preservation and real production mutation routes; no live sources."""
    EVIDENCE.mkdir(parents=True, exist_ok=True)
    results = []
    f = Fixture('final')
    try:
        f.settings['loadProbe'] = True
        f.manifest.write_text(json.dumps(f.settings))
        f.start()
        assert f.state()['discovery'] == dict(stats=1, extensions=0)
        f.call('bar', 'preset', 'floatingStrip')
        f.call('add', 'bar-extensions', '--id', 'fixture', '--placement', 'topBar')
        # Positive controls reach the same shared native writers and actual stats registration.
        f.call('set', 'stats.combineProcesses', 'true')
        assert f.call('get', 'stats.combineProcesses') is True
        f.call('bar-fixture-edit', 'preset', 'legacy')
        f.call('bar-fixture-edit', 'preset', 'floatingStrip')
        config = f.geometry()
        f.call('bar-fixture-edit', 'geometry', json.dumps(dict(config, spacing=11)))
        f.call('bar-fixture-edit', 'field', 'height', '40')
        assert f.geometry()['spacing'] == 11 and f.geometry()['height'] == 40
        saved = f.saved(); config = saved['preset']; f.stop()
        prefs = f.home/'Library/Preferences'/f'{f.suite}.plist'
        values = plistlib.loads(prefs.read_bytes())
        values.update({'bar.colour':'#123456', 'bar.background':'solid', 'bar.pagePlacement':'menuBar', 'bar.itemColours':True})
        variants = []
        for key, bad in [('clock', 12), ('clockZone', []), ('clockEvents', 'yes'),
                         ('exactMenuItems', {}), ('combineProcesses', 1), ('extensionItems', 'bad')]:
            variants.append(('root-'+key, json.dumps(dict(saved, **{key: bad})).encode()))
        for key in ['clock', 'clockEvents', 'exactMenuItems', 'combineProcesses', 'extensionItems']:
            variants.append(('null-'+key, json.dumps(dict(saved, **{key: None})).encode()))
        for key, bad in [('on','yes'), ('style',{}), ('placement',[]), ('side',99), ('width','wide'), ('extension',True)]:
            layout = copy.deepcopy(saved)
            next(x for x in layout['entries'] if x['kind']=='clock')[key] = bad
            variants.append(('known-item-'+key, json.dumps(layout).encode()))
        for key, bad in [('id',7), ('on','true'), ('placement','future-place')]:
            layout = copy.deepcopy(saved); layout['extensionItems'][0][key] = bad
            variants.append(('extension-'+key, json.dumps(layout).encode()))
        # Independent duplicate shapes: root, nested known item, extension, escaped name, UTF16.
        raw = json.dumps(saved)
        duplicate = raw[:-1] + ',"combineProcesses":false}'
        variants += [('duplicate-root', duplicate.encode()),
                     ('duplicate-root-utf16', duplicate.encode('utf-16')),
                     ('duplicate-item', raw.replace('"kind": "clock"', '"kind":"clock","on":true', 1).encode()),
                     ('duplicate-extension', raw.replace('"extension": "fixture"', '"extension":"fixture","extension":"fixture"', 1).encode()),
                     ('escaped-duplicate', (raw[:-1]+',"clock\\u0045vents":false}').encode())]
        legacy = copy.deepcopy(saved)
        legacy['entries'] = [x for x in legacy['entries'] if x.get('kind')!='extension']
        for label, preset in [('range',dict(config,height=999)), ('unknown',dict(config,foreign=True)), ('null',None)]:
            variants.append(('unplaced-invalid-preset-'+label, json.dumps(dict(legacy,preset=preset)).encode()))
        legacy_raw = json.dumps(legacy)
        variants += [('unplaced-duplicate-preset', (legacy_raw[:-1]+',"preset":'+json.dumps(config)+'}').encode()),
                     ('unplaced-duplicate-known', (legacy_raw[:-1]+',"clockEvents":true}').encode())]
        edits = [('set','stats.combineProcesses','false'), ('set','stats.combineProcesses','true'),
                 ('bar-fixture-edit','preset','legacy'), ('bar-fixture-edit','preset','floatingStrip'),
                 ('bar-fixture-edit','geometry',json.dumps(config)), ('bar-fixture-edit','field','height','42'),
                 ('bar','preset','legacy'), ('bar','preset','floatingStrip'), ('bar','geometry',json.dumps(config)),
                 ('bar','geometry','height','42'), ('bar','clear'), ('bar','restore'),
                 ('bar','move','clock','--side','right'), ('bar','style','clock','time'), ('bar','spacer','30'), ('bar','exact','on'),
                 ('set','bar.clock','HH:mm:ss'), ('set','bar.background','glass'), ('set','bar.colour','theme'),
                 ('set','bar.itemColours','false'), ('set','bar.pagePlacement','topBar'), ('set','bar.readingsLook','text'),
                 ('set','bar.clockStyle','time'), ('set','bar.clockZone','none'), ('set','bar.clockEvents','true'),
                 ('add','bar-items','--item','wifi'), ('remove','bar-items','clock'),
                 ('add','bar-extensions','--id','fixture','--placement','topBar'), ('remove','bar-extensions','fixture'),
                 ('theme','plan','apply','a')]
        for i, (label, payload) in enumerate(variants):
            values['bar.items'] = payload
            for key in ['bar.pilotMarkAlone', 'bar.extensionsApart']:
                values.pop(key, None)
                if i % 3 != 2: values[key] = i % 3 == 1
            encoded = plistlib.dumps(values, fmt=plistlib.FMT_BINARY); prefs.write_bytes(encoded)
            before = protected(f); archive(f, label+'-input'); f.start()
            state = f.state()
            assert state['loadError'] and state['native'] is None, label
            assert state['discovery'] == dict(stats=0, extensions=0), (label, state['discovery'])
            assert protected(f) == before and prefs.read_bytes() == encoded, label
            # One complete public-route matrix; representative shared seams for every malformed shape.
            for args in (edits if i == 0 else edits[:6]):
                answer = f.call(*args, ok=False)
                assert 'saved bar settings are malformed' in answer['error']['message'], (label, args, answer)
                assert protected(f) == before, (label, args)
            # Direct native bindings have no throwing return; prove real observer rollback without recursion.
            if i == 0:
                keys = ['bar.background','bar.colour','bar.pagePlacement','bar.itemColours','stats.combineProcesses']
                before_bindings = [f.call('get', key) for key in keys]
                before_settings = f.saved()
                assert f.call('bar-fixture-edit', 'binding') == 'binding probe completed'
                assert [f.call('get', key) for key in keys] == before_bindings
                assert f.saved() == before_settings and protected(f) == before
            f.stop(); f.start()
            assert f.state()['loadError'] and f.state()['discovery'] == dict(stats=0, extensions=0)
            f.call('set', 'stats.combineProcesses', 'true', ok=False)
            assert protected(f) == before and prefs.read_bytes() == encoded, label
            f.stop(); archive(f, label+'-refused-restarted')
            results.append(label+': exact bytes/flags/effects; zero discovery; real writer and restart refusals')
        # Missing optional fields retain defaults; future kinds/styles keep documented compatibility.
        compatible = {'entries': copy.deepcopy(saved['entries'])}
        compatible['entries'].append(dict(kind='future-item', arbitrary={'future': [1,2]}))
        clock = next(x for x in compatible['entries'] if x['kind']=='clock')
        clock['style'] = 'future-style'
        for key in ['side', 'placement', 'width']: clock.pop(key, None)
        values['bar.items'] = json.dumps(compatible).encode()
        values['bar.pilotMarkAlone'] = values['bar.extensionsApart'] = True
        prefs.write_bytes(plistlib.dumps(values,fmt=plistlib.FMT_BINARY)); f.start()
        assert f.state()['loadError'] is None and f.state()['discovery'] == dict(stats=0,extensions=0)
        assert f.geometry() is None and f.saved()['clock'] == 'HH:mm'
        f.call('set','stats.combineProcesses','true')
        assert f.call('get','stats.combineProcesses') is True
        f.stop(); archive(f,'compatible-missing-future')
        # Valid legacy migration actually needs fake extension discovery, exactly once.
        legacy.pop('preset'); values['bar.items'] = json.dumps(legacy).encode()
        values['bar.extensionsApart'] = False
        prefs.write_bytes(plistlib.dumps(values,fmt=plistlib.FMT_BINARY)); f.start()
        assert f.state()['discovery'] == dict(stats=0,extensions=1) and f.state()['loadError'] is None
        assert any(x.get('extension')=='fixture' for x in f.saved()['entries'])
        f.stop(); migrated = prefs.read_bytes(); f.start()
        assert f.state()['discovery'] == dict(stats=0,extensions=0) and prefs.read_bytes() == migrated
        f.stop(); archive(f,'valid-legacy-migrated-restarted')
        results.append('Positive controls: missing/future compatibility, real stats/native setters, one legacy discovery and persisted restart')
    finally:
        f.stop(); f.receipt()
    for result in results: print('PASS '+result, flush=True)
    (EVIDENCE/'final-preservation-results.json').write_text(json.dumps(dict(groups=len(results),variants=len(variants),routes=edits,results=results),indent=2))
