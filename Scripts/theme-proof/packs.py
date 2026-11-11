"""Factory packs, real PilotCLI and the early private theme host. Desktop state/effects are explicit fixture data."""
import concurrent.futures
import copy
import importlib.util
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import struct
import time

import hashlib

WIDE = {name: '-wide.heic' for name in ['folio','wisteria','void','garnet','porcelain','toybox-night','toybox']}
def sips_size(path):
    out = subprocess.run(['sips','-g','pixelWidth','-g','pixelHeight',str(path)],capture_output=True,text=True,check=True).stdout.split()
    return int(out[-3]), int(out[-1])

spec = importlib.util.spec_from_file_location('theme_obsidian', Path(__file__).with_name('obsidian.py'))
obsidian = importlib.util.module_from_spec(spec)
spec.loader.exec_module(obsidian)
life = obsidian.life
EVIDENCE = Path(os.environ.get('PILOT_THEME_PROOF_EVIDENCE') or Path.home() / '.local/state/spec' / 'theme-system/T5/p')
life.EVIDENCE = EVIDENCE
# The wallpaper picks (Sven Q45-Q47) are a design file outside the repo: design/theme-packs/wallpaper-matches.json in Pilot's
# project notes. PROVENANCE names each source by file name only, so the repo carries no one's folders.
MATCHES = os.environ.get('PILOT_THEME_PACK_MATCHES')   # checked in run(): editor, custom and agents load this file


class Fixture(obsidian.Fixture):
    def __init__(self, label='p'):
        super().__init__(label)
        shutil.copytree(life.REPO/'Packaging/ThemePacks', self.root/'factory')
        (self.root/'cursors').mkdir()
        shutil.copy2(life.REPO/'Packaging/Cursors/cursors.json',self.root/'cursors/cursors.json')
        self.wall = self.root/'desktop.json'
        image = self.root/'baseline.png'; image.write_bytes(life.WALLPAPER_A)
        self.desktop = dict(sources=[str(image)], preferences=dict(order='shuffle',seed='816',fitShape=True,interval=30,
            folders='perScreen',workspaces='perWorkspace',screenSources={'personal-screen':[str(image)]},
            workspaceSources={'9':[str(image)]},workspaceImages={'9':str(image)},scope='everyScreen',cycling=False),
            displays=[dict(id=key,workspace=workspace,portrait=portrait,image=str(image),pinned=pinned) for key,workspace,portrait,pinned in
                      [('wide','1',False,False),('tall','2',True,False),('personal-screen','3',False,True),('personal-space','9',False,True)]])
        self.write_wall(self.desktop)
        self.settings.update(factoryPacks=str(self.root/'factory'),wallpaperState=str(self.wall),
                             wallpaperBindings=[x['id'] for x in self.desktop['displays']],cursorRoot=str(self.root/'cursors'))
        self.manifest.write_text(json.dumps(self.settings))
        self.factory = self.factory_snapshot()
        self.baseline = self.snapshot(); self.receipt_before(); self.checkpoint('original')

    def factory_snapshot(self):
        return {str(p.relative_to(self.root/'factory')):life.digest(p) for p in (self.root/'factory').rglob('*') if p.is_file()}

    def write_wall(self, value): self.wall.write_text(json.dumps(value))
    def read_wall(self): return json.loads(self.wall.read_text())
    def snapshot(self):
        value=super().snapshot()
        if hasattr(self,'wall'): value['desktop.json']=life.digest(self.wall)
        return value
    def checkpoint(self,label):
        value=super().checkpoint(label)
        if hasattr(self,'wall'):
            (self.root/(label+'-desktop.json')).write_text(json.dumps(self.read_wall(),indent=2))
            for name in ['ownership','pending']:
                path=self.root/'state'/(name+'.json')
                (self.root/(label+'-'+name+'.json')).write_bytes(path.read_bytes() if path.exists() else b'null\n')
        return value
    def appearance(self): return json.loads((self.root/'state/appearance.json').read_text())
    def receipt(self):
        super().receipt()
        (self.root/'factory-final.json').write_text(json.dumps(self.factory_snapshot(),indent=2))
        (self.root/'desktop-final.json').write_text(json.dumps(self.read_wall(),indent=2))


def run(seam_only=False, fixes_only=False):
    if not MATCHES: raise SystemExit('set PILOT_THEME_PACK_MATCHES to wallpaper-matches.json')
    EVIDENCE.mkdir(parents=True,exist_ok=True)
    fixtures=[]; checks=[]; refusals=[]
    def fixture(label='p'):
        f=Fixture(label); fixtures.append(f); return f
    def passed(text):
        checks.append(text); print('PASS '+text,flush=True)
        (EVIDENCE/'packs.log').write_text('\n'.join('PASS '+x for x in checks)+'\n')
    def negative(f, command=('theme','plan','apply','a')):
        before=f.snapshot(); answer=f.call(*command,ok=False)
        assert answer['error']['code']=='bad-value',answer
        assert f.call('ping')=='pong' and f.snapshot()==before
        return answer
    def held(f,edit,plan):
        for flag in ['asked','go']: (f.root/flag).unlink(missing_ok=True)
        f.controls(hold='yes')
        with concurrent.futures.ThreadPoolExecutor() as pool:
            pending=pool.submit(f.call,'theme','apply',plan,ok=False)
            deadline=time.monotonic()+10
            while not (f.root/'asked').exists() and time.monotonic()<deadline: time.sleep(.05)
            assert (f.root/'asked').exists()
            edit(); before=f.snapshot(); (f.root/'go').touch()
            assert pending.result()['error']['code']=='bad-value'
            assert f.snapshot()==before and f.call('ping')=='pong'
        f.controls()
    def refusal(f,expected):
        before=f.snapshot(); f.start(expect_ready=False)
        log=f.root/f'host-{f.counter}.log'
        assert expected.lower() in log.read_text().lower(),(expected,log.read_text()[-4000:])
        assert f.snapshot()==before and not Path(str(f.socket)+'.hold').exists()
        refusals.append(dict(root=str(f.root),log=str(log),expected=expected))
    def own(f): return json.loads((f.root/'state/ownership.json').read_text())
    def restored(f):
        assert f.read_wall()==f.desktop
        assert not (f.root/'state/pending.json').exists()
        assert own(f).get('wallpapers',[])==[] and own(f)['claims']==[]
        f.preserved()
    def pack(f,name): return json.loads((f.root/'factory'/name/'manifest.json').read_text())
    try:
        # Read-only/isolation checks finish before the first fixture Apply or Restore.
        f=fixture(); f.start()
        assert f.call('ping')=='pong'
        assert {v['name'] for v in f.call('schema')['verbs']}=={'ping','help','schema','version','theme'}
        for verb in ['set','run','wallpaper','system','install','ai']: f.call(verb,ok=False)
        assert f.call('theme','status')['effects']=='recording only'
        assert f.call('theme','status')['wallpaper']==f.desktop
        # Sven Q45-Q47: each pick is its pack's wide wallpaper at the source's own size, HEIC, its source and unchecked licence
        # named; Celadon, Phosphor and every tall image keep the gradient.
        picks=json.loads(Path(MATCHES).read_text())['matches']
        for name,pick in picks.items():
            folder=f.root/'factory'/name; files=sorted(x.name for x in (folder/'wallpapers').iterdir())
            provenance=(folder/'PROVENANCE.md').read_text()
            if pick is None: assert files==[name+'-tall.png',name+'-wide.png'] and 'Source file:' not in provenance,(name,files); continue
            wide=folder/'wallpapers'/(name+'-wide.heic'); assert files==[name+'-tall.png',wide.name],(name,files)
            assert sips_size(wide)==sips_size(Path(pick[0])) and wide.read_bytes()[4:12] in (b'ftypheic',b'ftypheix'),(name,sips_size(wide))
            assert 'Source file: '+Path(pick[0]).name in provenance and 'Licence unverified: check before a public release.' in provenance,name
            assert hashlib.sha256(wide.read_bytes()).hexdigest() in provenance,name
        before=f.snapshot()
        for name in ['tokyo-night','dracula']:
            result=f.call('theme','check',name)
            assert result['valid'] and result['factory'] and len(result['images'])==2
            assert set(result['pack']['adapters'])=={'ghostty','zed','obsidian'}
            plan=f.call('theme','plan','apply',name)
            # Ghostty 2, Zed's theme file and both its light and dark slots 3, two vaults 4.
            assert len(plan['changes'])==9 and len(plan['wallpapers'])==3
        assert f.snapshot()==before
        f.controls(allow='no'); f.call('theme','apply',f.plan('tokyo-night'),ok=False)
        assert f.snapshot()==before; f.controls()
        passed('isolation before Apply: explicit fake display/workspace state and recording callbacks; private socket/core-theme registry; no Engine/settings/desktop APIs; list/check/plan/denial read-only; picked wide wallpapers ship at their own size as HEIC, source and unchecked licence named')
        if seam_only: return
        f.stop(); review_regressions(fixture, passed)
        if fixes_only: return
        f.start()

        source=(life.REPO/'Sources/PilotCore/PilotTheme.swift').read_text()
        raw_words=['binding','owned','passive refresh','assignments verified','status:','files: verified','refresh:','display(','Plan ']
        for name in ['tokyo-night','dracula']:
            manifest=pack(f,name); palette=manifest['palette']
            block=source.split('PilotTheme(id: "'+name+'"')[1].split('PilotTheme(id:')[0]
            expected={key:'#'+value.upper() for key,value in re.findall(r'(\w+): 0x([A-Fa-f0-9]{6})',block)}
            words=f.call('theme','plan','apply',name); shown=json.dumps(words['review'])
            assert 'Wallpaper on Display 1' in shown and words['id'] not in shown and not any(d in shown for d in f.settings['wallpaperBindings']),words['review']
            answer=f.apply(name); assert answer['status']=='applied' and answer['files']=='verified' and 'verified' in answer['wallpaper']
            for raw in raw_words+f.settings['wallpaperBindings']: assert raw not in shown,(raw,shown)
            native=f.appearance()
            assert native['roles']=={key:expected[key] for key in native['roles']},(name,native,expected)
            assert native['graphs']==['#'+x.strip()[2:] for x in re.search(r'graphs: \[([^]]+)\]',block)[1].split(',')]
            assert native['selection']==.16 and native['face']=='Bricolage Grotesque' and native['radius']==1 and native['focus']=='soft'
            ghost=f.generated.read_text()
            for key,role in [('background','background'),('foreground','foreground'),('selection-background','selection'),('cursor-color','bright_foreground')]:
                assert key+' = '+palette[role] in ghost,(key,ghost)
            ansi=['background','red','green','yellow','blue','magenta','cyan','foreground','muted','bright_red','bright_green','bright_yellow','bright_blue','bright_magenta','bright_cyan','bright_foreground']
            for i,role in enumerate(ansi): assert f'palette = {i}={palette[role]}' in ghost
            style=json.loads(f.zasset.read_text())['themes'][0]['style']
            # Review blocker 3: text keeps the palette's colour, or moves until it reads at 4.5:1 on every ground.
            zgrounds=[palette[r] for r in ['background','dark_background','lighter_background']]
            ogrounds=[palette[r] for r in ['background','lighter_background','dark_background','darker_background']]
            reads=lambda got,want,grounds,text=True: got==want or text and all(obsidian.contrast(got,g)>=4.5 for g in grounds)
            for key,role in {'background':'background','text':'foreground','text.muted':'muted','text.accent':'accent','editor.background':'background','editor.foreground':'foreground','terminal.background':'background'}.items():
                assert reads(style[key],palette[role],zgrounds,key.startswith(('text','editor.fore'))),(key,style[key],palette[role])
            for role in ['red','green','yellow','blue','magenta','cyan']:
                assert style['terminal.ansi.'+role]==palette[role] and style['terminal.ansi.bright_'+role]==palette['bright_'+role]
            for key,role in {'comment':'muted','string':'green','keyword':'magenta','function':'blue','number':'yellow'}.items(): assert reads(style['syntax'][key]['color'],palette[role],zgrounds),(key,palette[role])
            for index in range(2):
                css=f.path(index,True).read_text()
                values=dict(re.findall(r'--([a-z-]+): (#[0-9a-fA-F]{6});',css))
                for key,role in {'background-primary':'background','text-normal':'foreground','interactive-accent':'accent','text-selection':'selection','code-comment':'muted','code-string':'green','code-function':'blue','code-keyword':'magenta','code-value':'yellow'}.items():
                    assert reads(values[key],palette[role],ogrounds,key.startswith(('text-normal','code-'))),(key,values[key],palette[role])
            state=f.read_wall(); assert state['preferences']==f.desktop['preferences']
            for d in state['displays']:
                original=next(x for x in f.desktop['displays'] if x['id']==d['id'])
                if d['pinned']: assert d==original
                else: assert d['image'].endswith(name+('-tall.png' if d['portrait'] else WIDE.get(name,'-wide.png')))
            ledger=own(f)
            assert ledger['wallpapers'][0]['original']=={'sources':{'_0':f.desktop['sources']}}
            f.checkpoint(name)
            (f.root/(name+'-palette-proof.json')).write_text(json.dumps(dict(expected=expected,actual=native,ledger=ledger),indent=2))
        f.stop(); f.start(); assert f.call('theme','status')['selected']['id']=='dracula'
        assert f.restore()['status']=='restored'; restored(f); assert f.factory_snapshot()==f.factory
        f.stop(); allows=[x for x in (f.root/f'host-{f.counter}.log').read_text().splitlines() if x.startswith('THEME Allow asked:')]  # The host's log is complete only once it stops.
        assert allows and any('Wallpaper on Display 1' in x and (str(f.root/'app') in x or str(f.root/'app').replace(os.path.expanduser('~'),'~',1) in x) for x in allows),allows
        for raw in raw_words+f.settings['wallpaperBindings']: assert not any(raw in x for x in allows),(raw,allows)
        f.start()
        passed('exact existing Tokyo Night/Dracula native colours, graphs, selection and all three app ANSI/syntax mappings; fixed style geometry/type; matching shape assignments; pins/timer/order/shuffle/fit/workspace preferences untouched; A->B->restart->Restore recovers original baseline')
        f.stop()

        # Line-up of 18: an update retires the applied pack. Its factory folder is gone; the ledger keeps the pack whole, so
        # status still reads it after a restart and Restore puts back the original baseline without the folder.
        f=fixture('retired'); f.start(); f.apply('void'); f.stop()
        shutil.rmtree(f.root/'factory'/'void'); f.factory=f.factory_snapshot()
        f.start(); assert f.call('theme','status')['selected']['id']=='void'
        assert f.restore()['status']=='restored'; restored(f); assert f.factory_snapshot()==f.factory; f.stop()
        passed('a retired pack: applied, its factory folder removed as an update removes it, restart reads it from the ledger and Restore recovers the original baseline')

        # The existing scheduler's ownership seam journals before its recording effect, including after restart.
        for stage in [None,'cycle-journal','cycle-effect','cycle-after-effect','cycle-after-ledger']:
            f=fixture('cycle'); f.start(); f.apply('tokyo-night'); f.stop(); f.start()
            before=f.read_wall(); original=copy.deepcopy(own(f)); plan=f.plan('dracula')
            files={k:v for k,v in f.snapshot().items() if k.startswith(('app/','zed/','vaults/'))}
            after=next(path for path in before['sources'] if path!=before['displays'][0]['image'])
            f.controls(**({'fail':stage} if stage else {}))
            f.call('theme','fixture-cycle','wide',after,ok=stage in [None,'cycle-after-ledger'])
            advanced=stage in [None,'cycle-after-ledger']
            assert own(f)['claims']==original['claims'] and own(f)['selected']==original['selected']
            assert {k:v for k,v in f.snapshot().items() if k.startswith(('app/','zed/','vaults/'))}==files
            assert f.read_wall()['displays'][0]['image']==(after if advanced else before['displays'][0]['image'])
            for claim in own(f)['wallpapers']:
                old=next(x for x in original['wallpapers'] if x['target']==claim['target'])
                assert claim['original']==old['original']
            if advanced:
                # A new assignment invalidates an already prepared plan even though its pack did not change.
                f.call('theme','apply',plan,ok=False)
                assert next(x for x in own(f)['wallpapers'] if x['target']=={'display':{'_0':'wide'}})['last']['image']['_0']==after
            f.controls(); f.stop(); f.start()
            f.apply('dracula'); f.restore(); restored(f); f.stop()
        for stage in ['cycle-after-effect','cycle-after-ledger']:
            f=fixture('cycle-crash'); f.start(); f.apply('tokyo-night'); before=f.read_wall()
            after=next(path for path in before['sources'] if path!=before['displays'][0]['image'])
            f.controls(crash=stage); f.call('theme','fixture-cycle','wide',after,ok=False); f.stop(crashed=True)
            assert (f.root/'state/pending.json').exists(); f.controls(); f.start()
            assert f.read_wall()['displays'][0]['image']==(after if stage=='cycle-after-ledger' else before['displays'][0]['image'])
            assert not (f.root/'state/pending.json').exists(); f.restore(); restored(f); f.stop()
        passed('existing scheduler seam after restart journals before assignment; cycle failures/crashes preserve first baseline, advance only last ownership, leave app files untouched, and recover before A->B->Restore')

        # A custom ID and same-ID revision reach the real cursor palette resolver without stock fallback.
        f=fixture('custom'); custom=copy.deepcopy(f.packs[0]); custom['palette']=copy.deepcopy(pack(f,'tokyo-night')['palette']); custom['wallpapers']=[]
        f.save_pack(custom); f.start(); f.apply(); first=f.appearance()
        custom['palette'].update(accent='#314159',cyan='#271828',native_second='#271828',dark_background='#102030',foreground='#EEDDCC',native_graph1='#314159')
        f.save_pack(custom); f.apply(); second=f.appearance()
        assert first['cachedCursor']==first['cursor'] and second['cachedCursor']==second['cursor']
        assert second['id']=='a' and second['effect']=='#314159' and first['cursor']!=second['cursor']
        assert second['cursor']['quiet']['body']=='#102030' and second['cursor']['classic']['fill']=='#102030'
        assert second['cursor']['duo']['body']=='#314159' and second['cursor']['toybox']['body']=='#314159'
        assert second['cursor']['classic']['outline']=='#EEDDCC'
        assert f.read_wall()==f.desktop and f.call('theme','status')['wallpaperOwned']==[]
        f.restore(); restored(f); f.stop()
        passed('custom and edited same-ID palette drives native/cursor/effect colours; zero images leaves wallpaper alone; selection retains style geometry; Restore retains saved pack')

        # Both explicit files and folders carry arbitrary counts with the same scheduler selection.
        for folder in [False,True]:
            f=fixture('many'); directory=f.root/'packs/a/pictures'; directory.mkdir()
            for i in range(257): (directory/f'{i:04}.png').write_bytes(life.WALLPAPER_A if i%2==0 else life.WALLPAPER_B)
            f.packs[0]['wallpapers']=['pictures'] if folder else [f'pictures/{i:04}.png' for i in range(257)]; f.save_pack(f.packs[0]); f.start()
            result=f.call('theme','check','a'); assert len(result['images'])==257 and not result['factory']
            f.apply(); state=f.read_wall(); assert len(state['sources'])==257 and state['preferences']==f.desktop['preferences']
            assert len(f.call('theme','status')['wallpaperOwned'])==3
            f.apply('b'); assert f.read_wall()==f.desktop # zero-image switch releases previous wallpaper claims
            f.restore(); restored(f); f.stop()
        passed('257 user-supplied paths and 257-image folder: no count cap; existing shape/order/shuffle policy; zero-image switch releases wallpaper to original baseline')

        for kind in ['missing','corrupt','escape','symlink','folder-link','collision','writable-collision','factory-claim','stock-id']:
            f=fixture('invalid'); d=f.root/'packs/a'
            if kind=='missing': f.packs[0]['wallpapers']=['missing.png']; f.save_pack(f.packs[0])
            if kind=='corrupt': (d/'bad.png').write_bytes(b'not an image'); f.packs[0]['wallpapers']=['bad.png']; f.save_pack(f.packs[0])
            if kind=='escape': f.packs[0]['wallpapers']=['../b/manifest.json']; f.save_pack(f.packs[0])
            if kind in ['symlink','folder-link']:
                outside=f.root/'outside'; outside.mkdir(); (outside/'real.png').write_bytes(life.WALLPAPER_A)
                (d/'images').mkdir(); (d/'images/link').symlink_to(outside if kind=='folder-link' else outside/'real.png')
                f.packs[0]['wallpapers']=['images']; f.save_pack(f.packs[0])
            if kind in ['collision','writable-collision']:
                dest=f.root/('packs' if kind=='collision' else 'user-packs')/'tokyo-night'; shutil.copytree(f.root/'factory/tokyo-night',dest)
            if kind=='stock-id':
                dest=f.root/'packs/toybox'; dest.mkdir(); (dest/'manifest.json').write_text(json.dumps(dict(f.packs[0],id='toybox')))
            if kind=='factory-claim': f.save_pack(dict(f.packs[0],factory=True))
            f.start(); negative(f,('theme','plan','apply','tokyo-night' if 'collision' in kind else ('toybox' if kind=='stock-id' else 'a'))); f.stop()
        passed('missing/undecodable/escaping/symlink-folder assets and imported factory self-claims refuse; user and writable-root collisions cannot silently shadow immutable factory data')

        # Every wallpaper input is rechecked after Allow as well as before it, without regenerating a plan.
        for kind in ['source','image','preferences','bindings','asset','added','removed']:
            for during in [False,True]:
                f=fixture('stale'); f.start(); plan=f.plan('tokyo-night')
                def edit():
                    state=f.read_wall()
                    if kind=='source': state['sources'].append(str(f.root/'later.png')); f.write_wall(state)
                    elif kind=='image': state['displays'][0]['image']=str(f.root/'later.png'); f.write_wall(state)
                    elif kind=='preferences': state['preferences']['fitShape']=False; f.write_wall(state)
                    elif kind=='bindings': f.manifest.write_text(f.manifest.read_text()+' ')
                    elif kind=='asset': (f.root/'factory/tokyo-night/wallpapers/tokyo-night-wide.png').write_bytes(life.WALLPAPER_A)
                    elif kind=='added': (f.root/'factory/tokyo-night/wallpapers/new.png').write_bytes(life.WALLPAPER_A)
                    else: (f.root/'factory/tokyo-night/wallpapers/tokyo-night-wide.png').unlink()
                if during: held(f,edit,plan)
                else:
                    edit(); before=f.snapshot(); f.call('theme','apply',plan,ok=False); assert f.snapshot()==before
                assert not (f.root/'state/wallpaper-effects.jsonl').exists(); f.stop()
        passed('sources/current images/preferences/display bindings/assets/folder additions/removals stale before and after Allow: no file/assignment effects, no replacement plan')

        for kind in ['unrelated','owned','pin']:
            f=fixture('later'); f.start(); f.apply('tokyo-night'); state=f.read_wall()
            if kind=='unrelated': state['preferences']['interval']=60; state['preferences']['workspaceSources']['42']=[str(f.root/'later.png')]
            elif kind=='owned': state['displays'][0]['image']=str(f.root/'later.png')
            else: state['displays'][0]['pinned']=True
            f.write_wall(state); f.stop(); f.start()
            if kind=='unrelated':
                f.restore(); expected=copy.deepcopy(f.desktop); expected['preferences']=state['preferences']; assert f.read_wall()==expected
            else:
                # The coordinator's brief for build 2166 (Sven's Apply failed on a moved wallpaper): the person's later
                # image or pin stays, only that claim goes, and the rest of Restore runs.
                kept=copy.deepcopy(state['displays'][0])
                assert f.call('theme','plan','restore')['review']['kept']==['Your wallpaper on one screen stays: you changed it after the theme.']
                answer=f.restore(); assert answer['status']=='restored' and answer['kept']==['Kept your wallpaper on one screen.'],answer
                expected=copy.deepcopy(f.desktop); expected['displays'][0]=kept; assert f.read_wall()==expected,(f.read_wall(),expected)
                assert not (f.root/'state/pending.json').exists() and own(f).get('wallpapers',[])==[] and own(f)['claims']==[]
                f.preserved()
            f.stop()
        passed('later unrelated timer/workspace overrides survive Restore; a later image or new personal pin on one screen stays as the person set it, its claim goes and Restore finishes everything else')

        # Build 2166: a screen moved to another of the theme's images (Pilot's cycle outside the ledger, a gallery pick)
        # is still the theme's; one the person moved outside them is theirs. Neither stops Apply or Restore, across a
        # crash at the first wallpaper effect and a restart.
        def moved(f, kind):
            state=f.read_wall(); claims=own(f)['wallpapers']
            claim=next(x for x in claims if x['target']=={'display':{'_0':'wide'}})['last']['image']['_0']
            theme=next(x for x in claims if x['target']=={'sources':{}})['last']['sources']['_0']
            state['displays'][0]['image']=next(p for p in theme if p!=claim) if kind=='inside' else str(f.root/'later.png')
            f.write_wall(state); f.stop(); f.start(); return state
        for kind in ['inside','outside']:
            for crash in [None,'after-wallpaper:0']:
                for step in ['apply','restore']:
                    f=fixture('moved'); f.start(); f.apply('tokyo-night'); state=moved(f,kind); mine=state['displays'][0]['image']
                    words=f.call('theme','plan','apply','dracula') if step=='apply' else f.call('theme','plan','restore')
                    assert words['review']['kept']==([] if kind=='inside' else ['Your wallpaper on one screen stays: you changed it after the theme.']),words['review']
                    if crash:
                        before=f.read_wall(); ledger=(f.root/'state/ownership.json').read_bytes(); f.controls(crash=crash)
                        f.call('theme','apply' if step=='apply' else 'restore',words['id'],ok=False); f.stop(crashed=True); f.controls(); f.start()
                        assert not (f.root/'state/pending.json').exists() and f.read_wall()==before and (f.root/'state/ownership.json').read_bytes()==ledger
                        words=f.call('theme','plan','apply','dracula') if step=='apply' else f.call('theme','plan','restore')
                    answer=f.call('theme','apply' if step=='apply' else 'restore',words['id'])
                    assert answer['status']==('applied' if step=='apply' else 'restored') and answer['kept']==([] if kind=='inside' else ['Kept your wallpaper on one screen.']),answer
                    wide=next((x for x in own(f).get('wallpapers',[]) if x['target']=={'display':{'_0':'wide'}}),None)
                    if step=='apply':
                        assert f.read_wall()['displays'][1]['image'].endswith('dracula-tall.png')
                        if kind=='inside': assert wide['original']=={'image':{'_0':f.desktop['displays'][0]['image']}} and f.read_wall()['displays'][0]['image'].endswith('dracula-wide.heic')
                        else: assert wide is None and f.read_wall()['displays'][0]['image']==mine
                        f.restore()
                    if kind=='inside': restored(f)
                    else:
                        expected=copy.deepcopy(f.desktop); expected['displays'][0]['image']=mine; assert f.read_wall()==expected,(f.read_wall(),expected)
                        assert own(f).get('wallpapers',[])==[] and own(f)['claims']==[]; f.preserved()
                    f.stop()
        # Pilot's own cycle steps on from a drifted screen instead of stopping there for good.
        f=fixture('moved-cycle'); f.start(); f.apply('tokyo-night')
        back=next(x for x in own(f)['wallpapers'] if x['target']=={'display':{'_0':'wide'}})['last']['image']['_0']; moved(f,'inside')
        f.call('theme','fixture-cycle','wide',back)
        assert f.read_wall()['displays'][0]['image']==back and next(x for x in own(f)['wallpapers'] if x['target']=={'display':{'_0':'wide'}})['last']=={'image':{'_0':back}}
        f.restore(); restored(f); f.stop()
        passed('moved wallpaper: one of the theme\'s images is still the theme\'s (Apply plans from it, Restore puts the original back); one outside them stays the person\'s with only its claim released and "Kept your wallpaper on one screen."; both for Apply and Restore, with and without a crash at the first wallpaper effect; the cycle steps on from a moved screen')

        stages=['journal','write:0','after-write:0','wallpaper:0','after-wallpaper:0','wallpaper:1','after-wallpaper:1','wallpaper:2','after-wallpaper:2','ledger','after-ledger','cleanup','after-cleanup','effect']
        for switching in [False,True]:
            for stage in stages:
                f=fixture('fail'); f.start()
                if switching: f.apply('tokyo-night')
                before=f.read_wall(); plan=f.plan('dracula' if switching else 'tokyo-night')
                f.controls(fail=stage)
                answer=f.call('theme','apply',plan,ok=stage!='journal')
                committed=stage in ['after-ledger','cleanup','after-cleanup','effect']
                if stage!='journal':
                    assert answer['status']==('applied' if committed else 'failed'),(stage,answer)
                    if stage=='effect': assert answer['refresh'].startswith('failed:') and answer['files']=='verified' and 'not attempted' in answer['rollback']
                if not committed: assert f.read_wall()==before,(stage,f.read_wall(),before)
                f.checkpoint('failure-'+stage.replace(':','-')); f.controls(); f.stop(); f.start()
                assert f.call('theme','status')['selected'] is not None if switching or committed else f.call('theme','status')['selected'] is None
                if switching or committed: f.restore(); restored(f)
                f.stop()
        passed('initial and A->B failures at journal/file/every wallpaper/ledger/cleanup/refresh stages: original baseline survives; pre-operation assignment rollback verified; file/effect/refresh outcomes remain truthful')

        for stage in ['after-write:0','after-wallpaper:0','after-wallpaper:1','after-wallpaper:2','after-ledger']:
            f=fixture('crash'); f.start(); f.apply('tokyo-night'); before=f.read_wall(); plan=f.plan('dracula'); f.controls(crash=stage)
            f.call('theme','apply',plan,ok=False); f.stop(crashed=True); f.controls(); f.start()
            if stage=='after-ledger': assert f.call('theme','status')['selected']['id']=='dracula'
            else: assert f.call('theme','status')['selected']['id']=='tokyo-night' and f.read_wall()==before
            assert not (f.root/'state/pending.json').exists(); f.restore(); restored(f); f.stop()
        passed('durable pending journal restart reconciles file-only, partial wallpaper and committed assignments; original pre-Pilot baseline survives A->B crash->Restore')

        # Failed rollback is retained and retried, not called verified or silently discarded.
        f=fixture('retained'); f.start(); f.apply('tokyo-night'); before=f.read_wall(); plan=f.plan('dracula')
        f.controls(fail='ledger+wallpaper-rollback:1'); answer=f.call('theme','apply',plan)
        assert answer['status']=='failed' and answer['recovery']['status']=='recovery retained'
        assert (f.root/'state/pending.json').exists(); f.checkpoint('retained'); f.controls(); f.stop(); f.start()
        assert f.read_wall()==before and not (f.root/'state/pending.json').exists(); f.restore(); restored(f); f.stop()
        passed('failed wallpaper rollback retains durable journal and accurate conflict rows; restart retries only owned assignments and recovers original baseline')

        for phase in ['before','after']:
            f=fixture('callback'); f.start(); f.apply('tokyo-night'); before=f.read_wall(); plan=f.plan('dracula')
            f.controls(wallpaperFail=phase); answer=f.call('theme','apply',plan)
            assert answer['status']=='failed' and answer['refresh']=='not attempted'
            assert answer['recovery']['status']==('rollback verified' if phase=='before' else 'recovery retained'),answer
            f.controls(); f.stop(); f.start(); assert f.read_wall()==before
            assert not (f.root/'state/pending.json').exists(); f.restore(); restored(f); f.stop()
        passed('recording callbacks that throw before or after assignment report failure truthfully; uncertain rollback retains its journal until restart verifies it')

        for kind in ['duplicate','unbound','wrong-value']:
            f=fixture('ledger'); f.start(); f.apply('tokyo-night'); f.stop(); path=f.root/'state/ownership.json'; value=own(f)
            if kind=='duplicate': value['wallpapers'].append(value['wallpapers'][0])
            elif kind=='unbound': value['wallpapers'][1]['target']={'display':{'_0':'unbound'}}
            else: value['wallpapers'][0]['last']={'image':{'_0':str(f.root/'baseline.png')}}
            path.write_text(json.dumps(value))
            if kind!='unbound': refusal(f,'duplicate wallpaper' if kind=='duplicate' else 'target/value mismatch'); continue
            # The coordinator's brief: a screen no longer connected lets go of its claim, and Restore finishes the rest.
            f.start(); words=f.call('theme','plan','restore')['review']['kept']
            assert [x for x in words if 'no longer connected' in x],words
            answer=f.restore(); assert answer['status']=='restored' and [x for x in answer['kept'] if 'no longer connected' in x],answer
            assert own(f).get('wallpapers',[])==[] and not (f.root/'state/pending.json').exists(); f.stop()
        for kind in ['unbound','inconsistent']:
            f=fixture('journal'); f.start(); f.apply('tokyo-night'); plan=f.plan('dracula'); f.controls(crash='after-wallpaper:0')
            f.call('theme','apply',plan,ok=False); f.stop(crashed=True); f.controls(); path=f.root/'state/pending.json'; value=json.loads(path.read_text())
            if kind=='unbound': value['wallpapers'][0]['target']={'display':{'_0':'unbound'}}
            else: value['wallpapers'][0]['after']={'sources':{'_0':[str(f.root/'other.png')]}}
            path.write_text(json.dumps(value)); refusal(f,'unbound wallpaper' if kind=='unbound' else 'inconsistent wallpaper ownership journal')
            assert path.exists()
        passed('a claim on a screen no longer connected is let go while Restore finishes; corrupt/duplicate wallpaper ledger and unbound/inconsistent journals refuse before file or assignment recovery; pending evidence remains intact; schema-1 additive fields do not grant targets')

        for field in ['wallpaperBindings','wallpaperState','factoryPacks','cursorRoot']:
            f=fixture('isolation')
            if field=='wallpaperBindings': f.settings[field]=['unbound']
            else: f.settings[field]='/outside-fixture'
            f.manifest.write_text(json.dumps(f.settings)); refusal(f,'fixture wallpaper outside' if field=='wallpaperBindings' else 'unsafe fixture wallpaper/factory/cursor path')
        passed('unsafe recording state/factory/cursor roots and fake display binding mismatches refuse before host ready; no desktop/settings construction')
        passed('packs')
    finally:
        errors=[]
        for f in fixtures:
            try: f.stop(); f.receipt()
            except Exception as error: errors.append(str(error))
        (EVIDENCE/'startup-refusals.json').write_text(json.dumps(refusals,indent=2))
        (EVIDENCE/'fixture-index.json').write_text(json.dumps([str(f.root) for f in fixtures],indent=2))
        (EVIDENCE/'cleanup.json').write_text(json.dumps(dict(running=[str(f.root) for f in fixtures if f.process is not None],holds=[str(p) for f in fixtures for p in f.root.glob('*.hold')],errors=errors),indent=2))
        assert not errors,errors


def tagged_image(path, width, height, orientation):
    """Real uncompressed RGB TIFF, including TIFF/EXIF Orientation; ImageIO must fully decode it."""
    fields=[(256,4,1,width),(257,4,1,height),(258,3,3,0),(259,3,1,1),(262,3,1,2),
            (273,4,1,0),(274,3,1,orientation),(277,3,1,3),(278,4,1,height),(279,4,1,width*height*3)]
    bits=8+2+12*len(fields)+4
    fields[2]=(258,3,3,bits); fields[5]=(273,4,1,bits+6)
    data=b'II'+struct.pack('<HI',42,8)+struct.pack('<H',len(fields))
    for tag,kind,count,value in fields:
        data+=struct.pack('<HHI',tag,kind,count)+(struct.pack('<H',value)+b'\0\0' if kind==3 and count==1 else struct.pack('<I',value))
    path.write_bytes(data+struct.pack('<I',0)+struct.pack('<HHH',8,8,8)+bytes([35,88,144])*(width*height))


def review_regressions(fixture, passed):
    def ledger(f): return (f.root/'state/ownership.json').read_bytes()
    def effects(f):
        path=f.root/'state/wallpaper-effects.jsonl'
        return path.read_bytes() if path.exists() else b''
    def rejected(f, *words):
        before=f.snapshot(); recording=effects(f)
        answer=f.call(*words,ok=False)
        assert answer['error']['code']=='bad-value',answer
        assert f.snapshot()==before and effects(f)==recording and f.call('ping')=='pong'
        return answer
    def preferences(f, **values):
        f.desktop['preferences'].update(values); f.write_wall(f.desktop)
    def images(f, names):
        directory=f.root/'packs/a/pictures';directory.mkdir()
        for name in names:
            path=directory/name;path.parent.mkdir(parents=True,exist_ok=True);path.write_bytes(life.WALLPAPER_A)
        f.packs[0]['wallpapers']=['pictures'];f.save_pack(f.packs[0])
        return directory
    def choose(f, display='wide', direction='next'):
        return f.call('theme','fixture-cycle',display,direction)['image']

    # Refused cycles preserve the external choice, exact ledger bytes, pending absence and callback log.
    for kind in ['image','sources','collection','pin','workspace']:
        f=fixture('r1');f.start();f.apply('tokyo-night');owned=f.read_wall();original=ledger(f);later=copy.deepcopy(owned);f.checkpoint('owned')
        after=next(x for x in later['sources'] if x!=later['displays'][0]['image'])
        if kind=='image':later['displays'][0]['image']=str(f.root/'baseline.png')
        elif kind=='sources':later['sources']=list(reversed(later['sources']))
        elif kind=='collection':
            value=json.loads(original);value['wallpapers']=[x for x in value['wallpapers'] if x['target']!={'sources':{}}]
            (f.root/'state/ownership.json').write_text(json.dumps(value))
        else:
            later['displays'][0]['pinned']=True
            if kind=='workspace':later['preferences']['workspaceSources']['1']=[str(f.root/'baseline.png')]
            else:later['preferences']['screenSources']['wide']=[str(f.root/'baseline.png')]
        f.write_wall(later);f.checkpoint('later-'+kind)
        rejected(f,'theme','fixture-cycle','wide',after)
        assert not (f.root/'state/pending.json').exists()
        f.stop();f.start();assert f.read_wall()==later
        rejected(f,'theme','fixture-cycle','wide',after)
        # Restore plans again (build 2166): a later screen choice is kept, a reordered theme collection is still the theme's.
        if kind!='collection':assert f.call('theme','plan','restore')['review']['kept']==([] if kind=='sources' else ['Your wallpaper on one screen stays: you changed it after the theme.'])
        f.checkpoint('refused-'+kind)
        # Only the simulated external actor undoes its edit, so ownership can be deliberately restored.
        (f.root/'state/ownership.json').write_bytes(original);f.write_wall(owned)
        assert f.restore()['status']=='restored' and f.read_wall()==f.desktop
        f.stop()
    passed('R1 claimed current/source/collection conflicts and later screen/workspace pins: no callback/effect, ledger or journal writes; restart retains choice; Restore plans again, keeping a later screen choice')

    # Successful unmanaged and managed selection uses the existing production inventory/order/shape functions.
    f=fixture('r1u');directory=images(f,['1.png','2.png','3.png']);preferences(f,order='name',fitShape=False)
    baseline=copy.deepcopy(f.desktop);baseline['sources']=[str(directory)];f.write_wall(baseline);f.start()
    assert choose(f).endswith('/1.png') and choose(f).endswith('/2.png')
    assert not (f.root/'state/ownership.json').exists() and not (f.root/'state/pending.json').exists()
    f.write_wall(f.desktop);f.apply();original=json.loads(ledger(f));assert choose(f).endswith('/2.png')
    advanced=json.loads(ledger(f));assert advanced['epoch']==original['epoch']+1 and advanced['claims']==original['claims']
    assert [x['original'] for x in advanced['wallpapers']]==[x['original'] for x in original['wallpapers']]
    f.checkpoint('advanced');f.stop();f.start();assert choose(f).endswith('/3.png');f.restore();assert f.read_wall()==f.desktop;f.stop()
    passed('R1 unmanaged folder cycling remains legitimate; real managed next/restart advances only durable last ownership, preserves first baseline/app claims, then Restore succeeds')

    # Hold at the actual async selection boundary; independent edits arrive after before/current was captured.
    for kind in ['image','sources','pin','workspace','order','seed','fitShape']:
        f=fixture('race');images(f,['1.png','2.png']);preferences(f,order='name',fitShape=False);f.start();f.apply();owned=f.read_wall()
        (f.root/'cycle.hold').touch()
        try:
            with concurrent.futures.ThreadPoolExecutor() as pool:
                future=pool.submit(f.call,'theme','fixture-cycle','wide','next',ok=False)
                deadline=time.monotonic()+10
                while not (f.root/'cycle.ready').exists() and time.monotonic()<deadline:time.sleep(.02)
                assert (f.root/'cycle.ready').exists()
                later=copy.deepcopy(owned)
                if kind=='image':later['displays'][0]['image']=str(f.root/'baseline.png')
                elif kind=='sources':later['sources'].reverse()
                elif kind in ['pin','workspace']:
                    later['displays'][0]['pinned']=True
                    later['preferences']['workspaceSources' if kind=='workspace' else 'screenSources']['1' if kind=='workspace' else 'wide']=[str(f.root/'baseline.png')]
                else:later['preferences'][kind]={'order':'shuffle','seed':'177','fitShape':True}[kind]
                f.write_wall(later);before=f.snapshot();recording=effects(f);f.checkpoint('selection-later-'+kind);(f.root/'cycle.hold').unlink()
                assert future.result()['error']['code']=='bad-value'
                assert f.snapshot()==before and effects(f)==recording
        finally:(f.root/'cycle.hold').unlink(missing_ok=True)
        f.write_wall(owned);f.restore();f.stop()
    passed('R1 captured before/current async race: image/source/pin/workspace/order/seed/fit changes refuse before callbacks; production also rechecks its captured order/seed/fit and passes claimed workspace displays to ownership')

    # An interrupted managed cycle retains later image/pin choices and its pending evidence across recovery.
    for stage in ['cycle-after-effect','cycle-after-ledger']:
        f=fixture('r1j');images(f,['1.png','2.png']);preferences(f,order='name',fitShape=False);f.start();f.apply();before=f.read_wall()
        f.controls(crash=stage);f.call('theme','fixture-cycle','wide','next',ok=False);f.stop(crashed=True);f.controls()
        journal=(f.root/'state/pending.json').read_bytes();later=f.read_wall();later['displays'][0]['image']=str(f.root/'baseline.png');f.write_wall(later);f.checkpoint('pending-later');recording=effects(f)
        f.start();assert f.read_wall()==later and (f.root/'state/pending.json').read_bytes()==journal
        assert effects(f)==recording
        rejected(f,'theme','fixture-cycle','wide','next');rejected(f,'theme','plan','restore');f.checkpoint('recovery-retained');f.stop()
        # Simulated actor restores the expected in-flight image; restart now safely reconciles the durable journal.
        later['displays'][0]['image']=str(f.root/'packs/a/pictures/2.png');f.write_wall(later);f.start()
        assert not (f.root/'state/pending.json').exists()
        assert f.read_wall()['displays'][0]['image'].endswith('/'+('2.png' if stage=='cycle-after-ledger' else '1.png'))
        f.restore();assert f.read_wall()==f.desktop;f.stop()
    passed('R1 interrupted managed cycles: later image conflict leaves callback log and pending journal intact on restart/retry; original/last checkpoints survive rollback and committed recovery before Restore')

    f=fixture('r2');d=images(f,['2.png','10.png','sub/3.png']);(d/'.DS_Store').write_bytes(b'metadata');(d/'README').write_text('notes');(d/'.hidden.png').write_bytes(b'not selected')
    preferences(f,order='name',fitShape=False);f.start();answer=f.call('theme','check','a')
    assert [Path(x).name for x in answer['images']]==['2.png','3.png','10.png']
    f.apply();assert choose(f).endswith('/sub/3.png');f.restore();f.stop()
    for kind in ['selected','explicit','hidden-explicit','escape','directory-link','nonimage-link']:
        f=fixture('r2bad');d=images(f,['2.png'])
        if kind in ['selected','explicit','hidden-explicit']:
            name={'selected':'bad.png','explicit':'README','hidden-explicit':'.hidden.png'}[kind];(d/name).write_bytes(b'invalid declared/selected asset')
            if kind!='selected':f.packs[0]['wallpapers']=['pictures/'+name];f.save_pack(f.packs[0])
        else:
            outside=f.root/'outside';outside.mkdir();(outside/'real.png').write_bytes(life.WALLPAPER_A)
            (d/('link.png' if kind=='escape' else 'link')).symlink_to(outside if kind=='directory-link' else outside/'real.png')
        f.start();rejected(f,'theme','check','a');f.stop()
    passed('R2 visible-image inventory ignores .DS_Store/README/hidden garbage; selected corrupt and explicitly declared invalid/hidden assets still fail strict decoding; escaping image/nonimage/folder links remain rejected')

    for explicit in [False,True]:
        f=fixture('r3');d=images(f,['z/2.png','10.png','a/2.png','3.png']);preferences(f,order='name',fitShape=False)
        if explicit:f.packs[0]['wallpapers']=['pictures/10.png','pictures/z/2.png','pictures/3.png','pictures/a/2.png'];f.save_pack(f.packs[0])
        f.start();assert f.call('theme','show','a')['images']==[str(d/x) for x in ['a/2.png','z/2.png','3.png','10.png']]
        f.apply();assert f.read_wall()['displays'][0]['image']==str(d/'a/2.png')
        assert choose(f)==str(d/'z/2.png') and choose(f)==str(d/'3.png') and choose(f)==str(d/'10.png')
        assert choose(f,direction='previous')==str(d/'3.png');f.restore();f.stop()
    for seed in ['816','177','991']:
        f=fixture('r3s');d=images(f,['1.png','2.png','3.png','4.png']);preferences(f,order='shuffle',seed=seed,fitShape=False)
        observed=copy.deepcopy(f.desktop);observed['sources']=[str(d)];f.write_wall(observed);f.start();first=choose(f)
        f.write_wall(f.desktop);f.apply();assert f.read_wall()['displays'][0]['image']==first
        second=choose(f);assert first!=second and choose(f,direction='previous')==first
        f.restore();f.stop()
    passed('R3 real folder/explicit inventory shares natural filename order and full-path ties across subfolders; Apply/next/previous and three stable shuffle seeds agree through common selection')

    for orientation in range(1,9):
        for portrait in [False,True]:
            f=fixture('r4');d=images(f,[]);turned=orientation>=5
            w,h=(2,4) if portrait!=turned else (4,2)
            tagged_image(d/'1-tagged.tiff',w,h,orientation)
            (d/'2-same.png').write_bytes(life.WALLPAPER_B if portrait else life.WALLPAPER_A)
            (d/'3-opposite.png').write_bytes(life.WALLPAPER_A if portrait else life.WALLPAPER_B)
            preferences(f,order='name',fitShape=True);f.start();f.apply();display='tall' if portrait else 'wide';opposite='wide' if portrait else 'tall'
            state=f.read_wall();assert next(x['image'] for x in state['displays'] if x['id']==display)==str(d/'1-tagged.tiff'),(orientation,portrait,state)
            assert next(x['image'] for x in state['displays'] if x['id']==opposite)==str(d/'3-opposite.png')
            assert choose(f,display)==str(d/'2-same.png') and choose(f,display,'previous')==str(d/'1-tagged.tiff')
            f.restore();f.stop()
    for orientation in [1,6]:
        f=fixture('r4sq');d=images(f,[]);tagged_image(d/'1-square.tiff',3,3,orientation);(d/'2-tall.png').write_bytes(life.WALLPAPER_B)
        preferences(f,order='name',fitShape=True);f.start();f.apply();assert f.read_wall()['displays'][0]['image']==str(d/'1-square.tiff')
        assert choose(f)==str(d/'1-square.tiff') and choose(f,'tall')==str(d/'2-tall.png');f.restore();f.stop()
    passed('R4 genuinely tagged TIFF orientations 1-8, rotated portrait/landscape and square: strict pack decode/Apply and real header shape cycle agree on wide/tall targets; competing matches prevent fallback masking')

    f=fixture('r5');f.start();before=f.snapshot();stock=f.call('theme','fixture-colour','theme');assert stock['custom']==stock['renderer']==stock['theme']
    assert f.call('theme','fixture-colour','#ABCDEF')['custom']=='#ABCDEF' and f.snapshot()==before
    custom=copy.deepcopy(f.packs[0]);custom['palette']=copy.deepcopy(json.loads((f.root/'factory/tokyo-night/manifest.json').read_text())['palette'])
    for accent in ['#314159','#271828']:
        custom['palette']['accent']=accent;f.save_pack(custom);f.apply();before=f.snapshot()
        answer=f.call('theme','fixture-colour','theme');assert answer['custom']==answer['renderer']==answer['theme']==accent
        answer=f.call('theme','fixture-colour','#ABCDEF');assert answer['custom']==answer['renderer']=='#ABCDEF' and answer['theme']==accent
        assert f.snapshot()==before;f.checkpoint('picker-'+accent[1:])
    f.restore();assert f.call('theme','fixture-colour','theme')==stock;f.stop()
    passed('R5 actual compiled picker resolver/segment selection seeds Custom from applied and edited same-ID pack, matching renderer; explicit custom and no-pack stock fallback survive; no view/settings/desktop construction')
