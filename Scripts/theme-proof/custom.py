"""Actual CLI/early ThemeFixture/shared engine. All reloads are injected recordings, never processes."""
import base64
import concurrent.futures
import copy
import importlib.util
import json
import os
from pathlib import Path
import stat
import subprocess
import time

spec = importlib.util.spec_from_file_location('theme_editor', Path(__file__).with_name('editor.py'))
editor = importlib.util.module_from_spec(spec); spec.loader.exec_module(editor)
life = editor.life
EVIDENCE = Path(os.environ.get('PILOT_THEME_PROOF_EVIDENCE') or Path.home() / '.local/state/spec' / 'theme-system/T9/e')
life.EVIDENCE = EVIDENCE


class Fixture(editor.Fixture):
    def __init__(self, label='custom', initial=True):
        super().__init__(label)
        self.custom = self.root/'custom'; self.custom.mkdir()
        self.application = self.root/'Compatible.app'
        self.helper = self.application/'Contents/Info.plist'
        self.helper.parent.mkdir(parents=True)
        self.sentinel = self.root/'outside-sentinel'; self.sentinel.write_bytes(b'outside unchanged\n')
        # Deliberately executable payload would create a sentinel if mistakenly launched.
        self.helper.write_text('#!/bin/sh\ntouch "'+str(self.root/'EXECUTED')+'"\n'); self.helper.chmod(0o700)
        # Retain the executable script sentinel and every original assertion. App metadata
        # now carries that sentinel; the approved helper is an inert native signature.
        self.native_helper = self.application/'Contents/MacOS/ThemeReload'
        self.native_helper.parent.mkdir(parents=True)
        self.native_helper.write_bytes(bytes.fromhex('cffaedfe')+b'INERT FIXTURE NEVER EXECUTED')
        self.native_helper.chmod(0o700)
        self.json = self.custom/'settings.jsonc'; self.block = self.custom/'appearance.conf'; self.generated = self.custom/'generated.theme'
        self.original_json = b'\xef\xbb\xbf{\r\n // unrelated user comment\r\n "colors": {"accent": "old", "background":"paper"},\r\n "font":17,\r\n}\r\n'
        self.original_block = b'# personal\nfont=17\n# BEGIN CUSTOM\naccent=old\n# END CUSTOM\n# keep EOF'
        self.json.write_bytes(self.original_json); self.block.write_bytes(self.original_block)
        self.mappings = [dict(id='ink',ownership={'json':{'path':['colors','accent']}},template='"{{accent}}"'),
                         dict(id='paper',ownership={'json':{'path':['colors','background']}},template='"{{background}}"'),
                         dict(id='block',ownership={'block':{'begin':'# BEGIN CUSTOM','end':'# END CUSTOM'}},template='accent={{accent}}\nforeground={{foreground}}'),
                         dict(id='file',ownership={'generatedFile':{}},template='background={{background}}\nforeground={{foreground}}\nline={{native_line}}\n')]
        self.bindings = [dict(id=x['id'],root=str(self.custom),path=('settings.jsonc' if i<2 else 'appearance.conf' if i==2 else 'generated.theme'),app=str(self.application)) for i,x in enumerate(self.mappings)]
        self.bindings[0]['reload'] = dict(executable=str(self.native_helper),arguments=['--reload-theme','literal $(touch NEVER) `false`'])
        for i,pack in enumerate(self.packs):
            pack['palette']['native_line']='#345678' if i==0 else '#456789'
            pack.update(adapters={},customMappings=copy.deepcopy(self.mappings)); self.save_pack(pack)
        if initial: self.settings['custom'] = self.bindings
        self.manifest.write_text(json.dumps(self.settings))
        self.baseline=self.snapshot(); self.receipt_before()

    def start(self, extra_env=None, expect_ready=True):
        assert self.process is None
        self.counter+=1
        self.log=(self.root/f'host-{self.counter}.log').open('w')
        env={k:v for k,v in os.environ.items() if not k.startswith(('PILOT_','CFFIXED_'))}
        env['PILOT_THEME_FIXTURE']=str(self.manifest); env.update(extra_env or {})
        (self.root/f'host-{self.counter}.command.json').write_text(json.dumps(dict(command=life.HOST,environment={'PILOT_THEME_FIXTURE':str(self.manifest),**(extra_env or {})})))
        self.process=subprocess.Popen(life.HOST,cwd=life.REPO,env=env,stdout=self.log,stderr=subprocess.STDOUT)
        (self.root/f'host-{self.counter}.pid.json').write_text(json.dumps(dict(pid=self.process.pid)))
        deadline=time.monotonic()+35
        while time.monotonic()<deadline:
            if Path(str(self.socket)+'.hold').exists():
                assert expect_ready,'unsafe fixture unexpectedly started'
                assert stat.S_IMODE(self.socket.stat().st_mode)==0o600
                rows=subprocess.check_output(['ps','-axo','pid=,ppid=,command='],text=True).splitlines()
                owned={self.process.pid}
                for _ in range(5):
                    for row in rows:
                        parts=row.strip().split(None,2)
                        if len(parts)==3 and int(parts[1]) in owned: owned.add(int(parts[0]))
                selected=[row for row in rows if row.strip().split(None,1) and int(row.strip().split(None,1)[0]) in owned]
                (self.root/f'host-{self.counter}.processes.txt').write_text('\n'.join(selected)+'\n')
                (self.root/f'host-{self.counter}.socket.json').write_text(json.dumps(dict(path=str(self.socket),mode=stat.S_IMODE(self.socket.stat().st_mode),isolated=True)))
                return
            if self.process.poll() is not None:
                code=self.process.wait()
                (self.root/f'host-{self.counter}.exit.json').write_text(json.dumps(dict(pid=self.process.pid,exit=code,expectedRefusal=not expect_ready)))
                self.process=None; self.log.close()
                assert not expect_ready,(code,(self.root/f'host-{self.counter}.log').read_text()[-5000:])
                return
            time.sleep(.1)
        self.stop(); raise AssertionError('fixture host not ready')

    def stop(self, crashed=False):
        process=self.process
        super().stop(crashed=crashed)
        if process is not None:
            (self.root/f'host-{self.counter}.exit.json').write_text(json.dumps(dict(pid=process.pid,exit=process.returncode,expectedCrash=crashed)))

    def snapshot(self):
        value=super().snapshot()
        if hasattr(self,'custom'):
            for root in [self.custom,self.application]:
                for p in root.rglob('*'):
                    if p.is_file() or p.is_symlink(): value[str(p.relative_to(self.root))]=life.digest(p)
            value['outside-sentinel']=life.digest(self.sentinel)
        return value

    def reloads(self):
        p=self.root/'state/reload-effects.jsonl'
        return [json.loads(x) for x in p.read_text().splitlines()] if p.exists() else []

    def assert_safe(self):
        assert not (self.root/'EXECUTED').exists() and self.sentinel.read_bytes()==b'outside unchanged\n'
        assert self.helper.read_text().startswith('#!/bin/sh')
        self.preserved()


def run(seam_only=False, fixes_only=False):
    if fixes_only: return run_fixes()
    EVIDENCE.mkdir(parents=True,exist_ok=True)
    fixtures=[]; groups=[]
    def fixture(label='c', **kw):
        f=Fixture(label,**kw); fixtures.append(f); return f
    def passed(text):
        groups.append(text); print('PASS '+text,flush=True)
        (EVIDENCE/'custom.log').write_text('\n'.join('PASS '+x for x in groups)+'\n')
    def reject(f,*words):
        before=f.snapshot(); answer=f.call(*words,ok=False); assert f.snapshot()==before; f.assert_safe(); return answer
    def held(f, edit, plan, reload=False):
        asked='reload-asked' if reload else 'asked'; go='reload-go' if reload else 'go'
        for flag in [asked,go]: (f.root/flag).unlink(missing_ok=True)
        f.controls(**({'reloadAllow':'yes','reloadHold':'yes'} if reload else {'hold':'yes'}))
        with concurrent.futures.ThreadPoolExecutor() as pool:
            pending=pool.submit(f.call,'theme','apply',plan,**({} if reload else {'ok':False}))
            deadline=time.monotonic()+12
            while not (f.root/asked).exists() and time.monotonic()<deadline: time.sleep(.03)
            assert (f.root/asked).exists(),(f.root,asked)
            if reload:
                assert json.loads((f.root/'state/ownership.json').read_text())['selected']['id']=='a'
                assert f.generated.exists() and not f.reloads()
            edit(); before=f.snapshot(); (f.root/go).touch(); result=pending.result()
            assert f.snapshot()==before
        f.controls(); return result
    try:
        f=fixture('pure'); f.start(); before=f.snapshot()
        assert f.call('ping')=='pong'
        assert f.call('theme','status')['effects']=='recording only'
        assert {v['name'] for v in f.call('schema')['verbs']}=={'ping','help','schema','version','theme'}
        f.call('theme','check','a'); plan=f.call('theme','plan','apply','a')
        assert len(plan['changes'])==4 and len(plan['reloads'])==1
        for change in plan['changes']:
            assert change['bindingID'] and change['path'].startswith(str(f.custom)+'/') and 'proposedBytes' in change
        assert f.snapshot()==before and not f.reloads()
        (f.root/'plan.json').write_text(json.dumps(plan,indent=2)); f.checkpoint('pure')
        f.assert_safe(); f.stop(); passed('private 0600 early theme-only host; real CLI check/plan pure; exact files/selectors/proposed bytes and fixed local reload shown; no Engine/live/settings/Keychain/desktop/program')
        if seam_only: return

        f=fixture('round'); f.start(); f.controls(allow='no'); reject(f,'theme','apply',f.plan()); f.controls()
        result=f.apply(); assert result['files']=='verified' and 'declined' in result['reloads'][0]['outcome'] and not f.reloads()
        ledger=json.loads((f.root/'state/ownership.json').read_text()); originals=[x.get('original') for x in ledger['claims']]
        assert {x['bindingID'] for x in ledger['claims']}=={'ink','paper','block','file'}
        f.controls(reloadAllow='yes'); result=f.apply('b'); assert 'recorded only' in result['reloads'][0]['outcome'] and len(f.reloads())==1
        assert [x.get('original') for x in json.loads((f.root/'state/ownership.json').read_text())['claims']]==originals
        assert f.packs[1]['palette']['accent'].encode() in f.json.read_bytes()
        assert f.packs[1]['palette']['foreground'].encode() in f.block.read_bytes()
        f.stop(); f.start(); assert len(f.reloads())==1
        later=b'\r\n// later unrelated\r\n'; f.json.write_bytes(f.json.read_bytes()+later)
        block_later=b'\n# later unrelated\nfont=19'; f.block.write_bytes(f.block.read_bytes()+block_later)
        result=f.restore(); assert result['status']=='restored' and len(f.reloads())==1
        assert f.json.read_bytes()==f.original_json+later and f.block.read_bytes()==f.original_block+block_later and not f.generated.exists()
        assert f.call('theme','show','a')['pack']['customMappings']==f.mappings; f.assert_safe(); f.stop()
        passed('denial writes nothing; JSONC two structural keys + named block + generated file A-B-Restore/restart; original-last stable IDs; BOM/CRLF/comments/unrelated later settings and saved packs preserved; approved reload recorded after commit only; Restore/recovery never reload')

        f=fixture('bind',initial=False); f.start(); reject(f,'theme','check','a')
        before=f.snapshot()
        f.controls(allow='no'); reject(f,'theme','bind','custom',json.dumps(f.bindings[0])); f.controls()
        malformed=dict(f.bindings[0],unknownAuthority=True); reject(f,'theme','bind','custom',json.dumps(malformed))
        duplicate=json.dumps(f.bindings[0]).replace('"id": "ink"','"id": "ink", "id": "ink"'); reject(f,'theme','bind','custom',duplicate)
        for binding in f.bindings: f.call('theme','bind','custom',json.dumps(binding))
        assert not f.generated.exists() and f.json.read_bytes()==f.original_json and not f.reloads()
        (f.root/'local-bindings.json').write_bytes((f.root/'state/bindings.json').read_bytes())
        p=f.plan(); f.apply(); reject(f,'theme','bind','custom',json.dumps(f.bindings[0])); f.restore()
        f.call('theme','apply',p,ok=False)
        portable=f.root/'portable.json'; f.call('theme','export','a',str(portable)); envelope=json.loads(portable.read_text())
        assert envelope['pack']['customMappings']==f.mappings and set(envelope)=={'format','pack','files'}
        assert str(f.custom) not in portable.read_text() and str(f.helper) not in portable.read_text()
        envelope['pack']['id']='imported'; portable.write_text(json.dumps(envelope)); before=f.snapshot()
        f.call('theme','import',str(portable)); assert not f.reloads() and f.json.read_bytes()==f.original_json
        f.call('theme','check','imported'); assert not f.reloads()
        f.stop(); f.start(); f.apply('imported'); f.restore(); f.stop()
        passed('explicit shared local bind gate/denial; cannot rebind active ownership; additive binding storage survives restart; portable typed template round-trip excludes destinations/reload; import/check effect-free')

        # Validate data before Save as well as before planning. Imported authority cannot hide in typed fields.
        f=fixture('invalid'); f.start()
        invalid=[]
        x=copy.deepcopy(f.packs[0]); x['customMappings'][0]['template']='"{{unknown}}"'; invalid.append(x)
        x=copy.deepcopy(f.packs[0]); x['customMappings'][0]['template']='"{{accent}"'; invalid.append(x)
        x=copy.deepcopy(f.packs[0]); x['customMappings'][0]['template']='NaN'; invalid.append(x)
        x=copy.deepcopy(f.packs[0]); x['customMappings'][0]['template']='{"duplicate":1,"duplicate":2}'; invalid.append(x)
        x=copy.deepcopy(f.packs[0]); x['customMappings'][3]['template']='bad\0text'; invalid.append(x)
        x=copy.deepcopy(f.packs[0]); x['customMappings'][0]['template']='{"x":1e999}'; invalid.append(x)
        x=copy.deepcopy(f.packs[0]); x['customMappings'][0]['ownership']={'json':{'path':[]}}; invalid.append(x)
        x=copy.deepcopy(f.packs[0]); x['customMappings'][2]['ownership']['block']['end']='# BEGIN CUSTOM'; invalid.append(x)
        x=copy.deepcopy(f.packs[0]); x['customMappings'][0]['root']='/tmp/forbidden'; invalid.append(x)
        x=copy.deepcopy(f.packs[0]); x['customMappings'][0]['ownership']['json']['unknown']=True; invalid.append(x)
        x=copy.deepcopy(f.packs[0]); x['customMappings'].append(x['customMappings'][0]); invalid.append(x)
        x=copy.deepcopy(f.packs[0]); x['schema']=2; invalid.append(x)
        x=copy.deepcopy(f.packs[0]); x['customMappings']=None; invalid.append(x)
        for i,pack in enumerate(invalid):
            pack['id']='bad-'+str(i); folder=f.folder(pack,'bad-'+str(i)); reject(f,'theme','new',folder)
            incoming=f.root/'invalid-portable.json'; incoming.write_text(json.dumps(dict(format=1,pack=pack,files={})))
            reject(f,'theme','import',str(incoming))
            with (f.root/'invalid-inputs.jsonl').open('a') as log: log.write(json.dumps(pack)+'\n')
        for ownership in [{'file':{}},{'jsonMembership':{'path':['x'],'element':'a','removeEmptyContainer':False}}]:
            x=copy.deepcopy(f.packs[0]); x['customMappings'][0]['ownership']=ownership; f.save_pack(x); reject(f,'theme','check','a')
        f.save_pack(f.packs[0])
        for malformed in [f.original_json.replace(b'"accent": "old"',b'"accent":"old", "accent":"duplicate"'),b'{"colors":17}',b'{broken']:
            f.json.write_bytes(malformed); reject(f,'theme','check','a')
        f.json.write_bytes(f.original_json)
        x=copy.deepcopy(f.packs[0]); x['customMappings'][1]['ownership']={'json':{'path':['colors']}}; x['customMappings'][1]['template']='{}'; f.save_pack(x); reject(f,'theme','check','a'); f.save_pack(f.packs[0])
        f.generated.write_bytes(b'personal existing file'); reject(f,'theme','check','a'); f.generated.unlink()
        f.block.write_bytes(f.original_block+b'\n# END CUSTOM'); reject(f,'theme','check','a'); f.block.write_bytes(f.original_block)
        f.stop(); passed('unknown/broken placeholders, unrepresentable JSON/unknown schema/payload/authority/null/duplicates, ambiguous keys/parents/markers, selector overlap and unclaimed whole-file collision refuse before effects')

        f=fixture('absent'); f.json.write_bytes(b'{"colors":{"background":null},"unrelated":[]}')
        f.block.write_bytes(b'# unmarked personal file without newline'); original=f.json.read_bytes(); block=f.block.read_bytes()
        f.start(); f.apply(); f.stop(); f.start()
        suffix=b'\n# later comment'; f.block.write_bytes(f.block.read_bytes()+suffix); f.restore()
        assert f.json.read_bytes()==original and f.block.read_bytes()==block+suffix and not f.generated.exists(); f.stop()
        passed('absent structural key versus explicit null, generated-file absence, and newly inserted block/separator Restore across restart preserve later unrelated bytes')

        f=fixture('conflict'); f.start(); f.apply(); before=f.json.read_bytes(); f.json.write_bytes(before.replace(f.packs[0]['palette']['accent'].encode(),b'#123456'))
        # The coordinator's brief (Sven Q38): the person's later value stays, only that claim goes, the rest restores.
        f.stop(); f.start()
        assert [k for k in f.call('theme','plan','restore')['review']['kept'] if f.json.name in k]
        answer=f.restore(); assert answer['status']=='restored' and answer['kept'] and b'#123456' in f.json.read_bytes(),answer
        assert json.loads((f.root/'state/ownership.json').read_text())['claims']==[]; f.stop()
        passed('a later owned-key edit stays the person\'s across restart while Restore finishes the rest')

        # Revalidation after Allow binds destination bytes, local IDs, program bytes and complete inputs.
        for label, edit in [('file',lambda f:f.json.write_bytes(f.json.read_bytes()+b'// concurrent\n')),
                            ('manifest',lambda f:f.manifest.write_text(f.manifest.read_text()+' ')),
                            ('program',lambda f:f.helper.write_text('changed helper')),
                            ('app',lambda f:(f.application/'Contents/Info.plist').write_text('changed app binding')),
                            ('palette',lambda f: f.save_pack(dict(f.packs[0],title='Changed'))),
                            ('binding',lambda f:(f.root/'state/bindings.json').write_text(json.dumps(dict(zedOptOut=False,custom=list(reversed(f.bindings))))))]:
            f=fixture('stale-'+label); f.start(); p=f.plan(); held(f,lambda:edit(f),p); assert not f.reloads(); f.stop()
        passed('file/pack/local binding revision/manifest context/reload executable stale during Allow refuse without writes or program')

        # Local-only path alias protection includes bound built-ins even when pack opts out.
        for label, edit in [('builtin',lambda f,b:b.update(root=str(f.root/'app'),path='config')),
                            ('alias',lambda f,b:(f.custom/'alias').symlink_to(f.root/'app') or b.update(path='alias/config')),
                            ('escape',lambda f,b:b.update(path='../outside-sentinel')),
                            ('hardlink',lambda f,b:os.link(f.sentinel,f.custom/'hard') or b.update(path='hard')),
                            ('duplicate-alias',lambda f,b:(f.custom/'alias.jsonc').symlink_to('settings.jsonc') or b.update(id='alias',path='alias.jsonc')),
                            ('shell',lambda f,b:b['reload'].update(executable='/bin/sh')),
                            ('remote',lambda f,b:b['reload'].update(arguments=['https://installer.example']))]:
            f=fixture('path-'+label); edit(f,f.bindings[0]); f.settings['custom']=f.bindings; f.manifest.write_text(json.dumps(f.settings)); before=f.snapshot()
            f.start(expect_ready=False); assert f.snapshot()==before; f.assert_safe()
        f=fixture('swap'); f.start(); p=f.plan()
        def swap():
            f.json.unlink(); f.json.symlink_to(f.sentinel)
        held(f,swap,p); f.stop(); f.assert_safe()
        passed('unsafe path/traversal/escape/hardlink/link swap, built-in protected aliases and duplicate destination aliases refused; outside sentinel preserved; shell/remote reload rejected')

        f=fixture('reload-fail'); f.start(); f.controls(reloadAllow='yes',reloadFail='yes'); result=f.apply()
        assert result['status']=='applied' and result['files']=='verified' and 'failed:' in result['reloads'][0]['outcome'] and len(f.reloads())==1
        f.controls(); f.stop(); f.start(); assert len(f.reloads())==1; f.restore(); f.stop()
        f=fixture('reload-stale'); f.start(); p=f.plan(); result=held(f,lambda:f.helper.write_text('changed after file commit'),p,reload=True)
        assert result['status']=='applied' and 'failed:' in result['reloads'][0]['outcome'] and not f.reloads(); f.stop()
        for label in ['ledger','link','app','pack']:
            f=fixture('reload-'+label); f.start(); p=f.plan()
            def edit():
                if label=='ledger':
                    target=f.root/'state/ownership.json'; target.write_text(target.read_text()+' ')
                elif label=='link':
                    clone=f.custom/'clone.jsonc'; clone.write_bytes(f.json.read_bytes()); f.json.unlink(); f.json.symlink_to('clone.jsonc')
                elif label=='app': (f.application/'Contents/Info.plist').write_text('later app metadata')
                else: f.save_pack(dict(f.packs[0],title='Later pack'))
            result=held(f,edit,p,reload=True)
            assert result['status']=='applied' and 'failed:' in result['reloads'][0]['outcome'] and not f.reloads(); f.stop()
        passed('reload refused executes nothing; accepted recorder failure leaves committed files and accurate unverified refresh; reload stale after separate Allow runs nothing; restart never reruns')

        # Relevant existing writer/ledger/native/refresh injection points; no new writer or recovery engine.
        for stage in ['journal','write:0','after-write:0','write:1','after-write:1','write:2','after-write:2','native','after-native','ledger','after-ledger','cleanup','after-cleanup','effect','reload']:
            f=fixture('fail-'+stage.replace(':','-')); f.start(); f.controls(fail=stage,reloadAllow='yes')
            if stage=='journal': reject(f,'theme','apply',f.plan())
            else:
                result=f.apply()
                committed=stage in ['after-ledger','cleanup','after-cleanup','effect','reload']
                assert result['status']==('applied' if committed else 'failed'),(stage,result)
                if committed:
                    assert f.generated.exists() and result['files']=='verified'
                    if stage=='effect': assert result['refresh'].startswith('failed:')
                    if stage=='reload': assert 'failed:' in result['reloads'][0]['outcome'] and not f.reloads()
                else:
                    assert f.json.read_bytes()==f.original_json and f.block.read_bytes()==f.original_block and not f.generated.exists() and not f.reloads() and f.native_value()==f.original_native
            f.controls(); f.stop(); count=len(f.reloads()); f.start(); assert len(f.reloads())==count; f.restore(); f.stop(); f.assert_safe()
        passed('writer/journal/native/ledger/cleanup/refresh/reload faults yield verified rollback or explicit committed-file outcome; no precommit reload and no replay on restart')

        for stage in ['after-write:0','after-write:1','after-write:2','after-native','after-ledger']:
            f=fixture('crash-'+stage.replace(':','-')); f.start(); f.controls(crash=stage,reloadAllow='yes'); f.call('theme','apply',f.plan(),ok=False); f.stop(crashed=True)
            assert (f.root/'state/pending.json').exists() and not f.reloads(); f.controls(); f.start()
            assert not (f.root/'state/pending.json').exists() and not f.reloads()
            if stage=='after-ledger': assert f.generated.exists(); f.restore()
            else: assert f.json.read_bytes()==f.original_json and f.block.read_bytes()==f.original_block and not f.generated.exists()
            f.stop(); f.assert_safe()
        passed('pending restart reconciles partial custom resources/native and committed ledger; exact original rollback, no reload on recovery')
        # Selected custom payload is authority in both current and embedded ledgers, too.
        for location in ['current','beforeLedger','afterLedger']:
            for kind in ['unknown','nested','null','duplicate']:
                f=fixture('authority'); f.start(); f.apply()
                if location!='current':
                    f.controls(crash='after-write:0'); f.call('theme','apply',f.plan('b'),ok=False); f.stop(crashed=True)
                else: f.stop()
                target=f.root/'state'/('ownership.json' if location=='current' else 'pending.json')
                container=json.loads(target.read_text())
                record=container if location=='current' else json.loads(base64.b64decode(container[location]))
                if kind=='unknown': record['selected']['customMappings'][0]['unknownAuthority']=True
                elif kind=='nested': record['selected']['customMappings'][0]['ownership']['json']['unknownAuthority']=True
                elif kind=='null': record['selected']['customMappings']=None
                encoded=json.dumps(record)
                if kind=='duplicate': encoded=encoded.replace('"id": "ink"','"id": "ink", "id": "ink"')
                if location=='current': target.write_text(encoded)
                else:
                    container[location]=base64.b64encode(encoded.encode()).decode(); target.write_text(json.dumps(container))
                before=f.snapshot(); f.controls(); f.start(expect_ready=False); assert f.snapshot()==before and not f.reloads(); f.assert_safe()
        passed('current and embedded before/after selected custom payload rejects unknown/nested/null/duplicate authority before effects; malformed recovery retained')
        passed('custom')
    finally:
        for f in fixtures:
            if f.process is not None: f.stop(crashed=f.process.poll() is not None)
            f.receipt()
        (EVIDENCE/'fixtures.json').write_text(json.dumps([str(f.root) for f in fixtures],indent=2))


def run_fixes():
    """Four FIRST T9 rejects: raw external inputs and the compiled production presentation/launch seams."""
    import hashlib
    import shutil
    source_root=Path(os.environ.get('PILOT_THEME_REVIEWED_SOURCE', str(life.REPO)))
    EVIDENCE.mkdir(parents=True, exist_ok=True)
    fixtures=[]; results=[]
    def fixture(label):
        f=Fixture(label); fixtures.append(f); return f
    def check(name, action):
        try:
            action(); results.append(dict(name=name, passed=True)); print('PASS '+name, flush=True)
        except Exception as error:
            results.append(dict(name=name, passed=False, error=repr(error))); print('FAIL '+name+': '+repr(error), flush=True)
        finally:
            for f in fixtures:
                if f.process is not None: f.stop(crashed=f.process.poll() is not None)
        (EVIDENCE/'fix-results.json').write_text(json.dumps(results,indent=2))
    def journal_case(kind):
        f=fixture('j'+kind[:3]); f.start(); f.controls(crash='after-write:2')
        f.call('theme','apply',f.plan(),ok=False); f.stop(crashed=True)
        target=f.root/'state/pending.json'; journal=json.loads(target.read_text())
        f.checkpoint('interrupted')
        def alter(data): return base64.b64encode(data).decode()
        for mutation in journal['mutations']:
            path=mutation['target']['path']
            if kind=='snapshot' and path=='appearance.conf':
                mutation['target']['bytes']=alter(base64.b64decode(mutation['target']['bytes']).replace(b'font=17',b'font=99'))
            if kind=='multi' and path=='settings.jsonc':
                mutation['target']['bytes']=alter(base64.b64decode(mutation['target']['bytes']).replace(b'"font":17',b'"font":99'))
            if kind=='replacement' and path=='appearance.conf':
                mutation['replacement']=alter(base64.b64decode(mutation['replacement'])+b'\nfont=99')
            if kind=='generated' and path=='generated.theme': mutation['target']['bytes']=alter(b'unclaimed previous bytes')
            if kind=='empty' and path=='generated.theme': mutation['target']['bytes']=alter(b'')
            if kind=='absence' and path=='appearance.conf': mutation['target'].pop('bytes',None)
        if kind not in ['valid','later']:
            target.write_text(json.dumps(journal)); f.checkpoint('tampered'); before=f.snapshot(); f.controls()
            f.start(expect_ready=False)
            assert f.snapshot()==before, 'inconsistent journal changed current bytes or effects'
            assert target.exists() and not f.reloads()
        else:
            later=b'\n// unrelated later font choice\n' if kind=='later' else b''
            f.json.write_bytes(f.json.read_bytes()+later); f.controls(); f.start()
            assert not target.exists() and not f.reloads()
            assert f.json.read_bytes()==f.original_json+later
            assert f.block.read_bytes()==f.original_block and not f.generated.exists()
            f.stop()
        f.checkpoint('reconciled'); f.assert_safe()
    def portable_cases():
        f=fixture('raw'); f.start()
        pack=copy.deepcopy(f.packs[0]); pack['id']='raw-import'
        raw=json.dumps(dict(format=1,pack=pack,files={}),separators=(',',':'))
        variants={
            'template':raw.replace('"template":"\\"{{accent}}\\""','"template":"\\"{{accent}}\\"","template":"\\"{{accent}}\\""',1),
            'ownership':raw.replace('"ownership":{"json":{"path":["colors","accent"]}}','"ownership":{"json":{"path":["colors","accent"]}},"ownership":{"json":{"path":["colors","accent"]}}',1),
            'nested':raw.replace('"path":["colors","accent"]','"path":["colors","accent"],"path":["colors","accent"]',1),
            'escaped':raw.replace('"template":"\\"{{accent}}\\""','"template":"\\"{{accent}}\\"","templa\\u0074e":"\\"{{accent}}\\""',1),
            'envelope':raw.replace('"format":1','"format":1,"for\\u006dat":1',1),
            'pack':raw.replace('"pack":', '"pack":'+json.dumps(pack,separators=(',',':'))+',"pack":',1),
            'files':raw[:-1]+',"files":{}}',
            'block':raw.replace('"begin":"# BEGIN CUSTOM"','"begin":"# BEGIN CUSTOM","be\\u0067in":"# BEGIN CUSTOM"',1),
            'generated':raw.replace('"generatedFile":{}','"generatedFile":{},"generatedFile":{}',1),
            'mappingID':raw.replace('"id":"ink"','"id":"ink","id":"ink"',1)}
        failures=[]
        for name,text in variants.items():
            assert text!=raw, name
            for encoding in ['utf-8','utf-8-sig','utf-16','utf-32','utf-16-le','utf-16-be','utf-32-le','utf-32-be']:
                path=f.root/(name+'-'+encoding+'.json'); path.write_bytes(text.encode(encoding)); before=f.snapshot()
                try:
                    f.call('theme','import',str(path),ok=False)
                    assert f.snapshot()==before and not f.reloads()
                except AssertionError as error: failures.append(name+'/'+encoding+': '+str(error))
        # Real exporter -> original raw import, with a fresh stable ID. No normalization in the proof.
        portable=f.export('a','valid-export.json'); valid=portable.read_bytes().replace(b'"id" : "a"',b'"id" : "valid-import"').replace(b'"id":"a"',b'"id":"valid-import"')
        assert b'valid-import' in valid
        incoming=f.root/'valid.json'; incoming.write_bytes(valid); f.call('theme','import',str(incoming))
        assert f.call('theme','show','valid-import')['pack']['customMappings']==f.mappings and not f.reloads()
        f.stop(); assert not failures, '\n'.join(failures)
    def handoff_cases():
        failures=[]
        for kind in ['native','escape','app','metadata','mode','valid']:
            f=fixture('h'+kind[:3]); f.start(); f.controls(reloadAllow='yes',launchHold='yes')
            with concurrent.futures.ThreadPoolExecutor() as pool:
                pending=pool.submit(f.apply)
                deadline=time.monotonic()+12
                while not (f.root/'launch-asked').exists() and time.monotonic()<deadline: time.sleep(.02)
                assert (f.root/'launch-asked').exists(), 'no post-handoff barrier'
                f.checkpoint('approved-detached')
                helper=f.native_helper
                if kind=='native':
                    helper.unlink(); helper.write_bytes(bytes.fromhex('cffaedfe')+b'DIFFERENT NATIVE'); helper.chmod(0o700)
                elif kind=='escape':
                    outside=f.root/'outside-native'; outside.write_bytes(helper.read_bytes()); outside.chmod(0o700)
                    helper.unlink(); helper.symlink_to(outside)
                elif kind=='app':
                    f.application.rename(f.root/'Old.app'); shutil.copytree(f.root/'Old.app',f.application)
                elif kind=='metadata': (f.application/'Contents/Info.plist').write_bytes(b'changed metadata')
                elif kind=='mode': helper.chmod(0o600)
                before=f.snapshot(); (f.root/'launch-go').touch(); result=pending.result()
                assert result['status']=='applied' and result['files']=='verified'
                if kind=='valid': assert len(f.reloads())==1 and 'recorded only' in result['reloads'][0]['outcome']
                else:
                    assert not f.reloads() and 'failed:' in result['reloads'][0]['outcome'],result
                    assert f.snapshot()==before, 'launch refusal must not change committed files/effects'
                assert not (f.root/'EXECUTED').exists()
                f.checkpoint('launch-result')
            f.controls(); f.stop()
        # Multiple real bindings retain individual outcomes and the exact fixed argv.
        f=fixture('hmulti'); f.bindings[1]['reload']=dict(executable=str(f.native_helper),arguments=['--paper'])
        f.settings['custom']=f.bindings; f.manifest.write_text(json.dumps(f.settings)); f.start(); f.controls(reloadAllow='yes')
        result=f.apply(); assert [r['binding'] for r in result['reloads']]==['ink','paper'] and len(f.reloads())==2
        assert [r['command']['arguments'] for r in f.reloads()]==[b['reload']['arguments'] for b in f.bindings[:2]]
        f.controls(); f.restore(); assert len(f.reloads())==2; f.stop()
    def presentation():
        source=(source_root/'Sources/Pilot/UI/LookPage.swift').read_text()
        def function(name):
            start=source.index('\nfunc '+name+'(')+1
            return source[start:source.index('\n}',start)+2]
        formatter=function('themeOutcomeText')+'\n'+function('themeOutcomeDetails')
        planner=function('themePlanText') if '\nfunc themePlanText(' in source else 'func themePlanText(_ value: JSONValue) -> String { return "" }'
        scratch=life.REPO/('.build/theme-t9-format-'+EVIDENCE.name); scratch.mkdir(exist_ok=True)
        main=scratch/'main.swift'
        main.write_text('import Foundation\n'+formatter+'\n'+planner+'\nwhile let line = readLine() { let v = try JSONDecoder().decode(JSONValue.self, from: Data(line.utf8)); print(String(data: try JSONEncoder().encode([themePlanText(v),themeOutcomeText(v)+"\\n"+themeOutcomeDetails(v)]),encoding:.utf8)!) }\n')
        command=['nice','-n','10','swiftc','-j','4',str(life.REPO/'Sources/PilotCore/JSONValue.swift'),str(main),'-o',str(scratch/'format')]
        build=subprocess.run(command,text=True,capture_output=True)
        (EVIDENCE/'presentation-build.json').write_text(json.dumps(dict(command=command,exit=build.returncode,stdout=build.stdout,stderr=build.stderr,source=main.read_text())))
        assert build.returncode==0,build.stderr
        f=fixture('ui'); f.start(); plan=f.call('theme','plan','apply','a')
        outcomes=[]
        for controls in [dict(reloadAllow='yes'),dict(reloadAllow='no'),dict(reloadAllow='yes',reloadFail='yes')]:
            f.controls(**controls); outcomes.append(f.apply()); f.controls(); f.restore()
        multiple=dict(outcomes[0],reloads=outcomes[0]['reloads']+outcomes[1]['reloads']+outcomes[2]['reloads'])
        inputs=[plan,*outcomes,multiple]
        run=subprocess.run([str(scratch/'format')],input='\n'.join(json.dumps(x) for x in inputs)+'\n',text=True,capture_output=True)
        (EVIDENCE/'presentation-run.json').write_text(json.dumps(dict(inputs=inputs,exit=run.returncode,stdout=run.stdout,stderr=run.stderr,binarySHA256=hashlib.sha256((scratch/'format').read_bytes()).hexdigest())))
        assert run.returncode==0,run.stderr
        texts=[json.loads(x) for x in run.stdout.splitlines()]; missing=[]
        for change in plan['changes']:
            for value in [change['path'],change['proposedBytes'] or 'Absent']:
                if value not in texts[0][0]: missing.append(value)
        for binding in plan['reloads']:
            for value in [binding['app'],binding['reload']['executable'],*binding['reload']['arguments']]:
                # argv is JSON escaped; parse-visible fixed strings must appear as their encoded contents.
                if value not in texts[0][0] and json.dumps(value,ensure_ascii=False)[1:-1] not in texts[0][0]: missing.append(value)
        for result,pair in zip(inputs[1:],texts[1:]):
            for row in result['reloads']:
                if row['binding'] not in pair[1] or row['outcome'] not in pair[1]: missing.append(str(row))
            assert 'Theme applied' in pair[1]
        f.stop(); assert not missing, 'native omits: '+repr(missing)
        assert 'ThemePlanReview(plan: details)' in source and 'Text(themePlanText(plan))' in source, 'production View must consume the proven plan formatter'
        shutil.rmtree(scratch)
    try:
        for kind in ['snapshot','replacement','multi','generated','empty','absence','valid','later']:
            check('journal '+kind,lambda kind=kind:journal_case(kind))
        check('raw portable duplicate import',portable_cases)
        check('native review and binding outcomes',presentation)
        check('post-handoff production launch identity',lambda:reload_launch_probe(EVIDENCE/'launch'))
        check('actual private fixture final launch validation',handoff_cases)
    finally:
        for f in fixtures:
            if f.process is not None: f.stop(crashed=f.process.poll() is not None)
            f.receipt()
        (EVIDENCE/'fixtures.json').write_text(json.dumps([str(f.root) for f in fixtures],indent=2))
    assert all(x['passed'] for x in results), 'T9 reject reproductions: '+repr([x['name'] for x in results if not x['passed']])


def reload_launch_probe(evidence):
    """Compile actual production launch code; shadow Foundation.Process with a recorder on the reviewed source.

    The fixed source uses the very same synchronous intent.launch seam as the private CLI fixture.
    No branch of this probe can invoke a Foundation.Process, including a valid native sentinel.
    """
    import hashlib
    import shutil
    evidence.mkdir(parents=True,exist_ok=True)
    scratch=life.REPO/('.build/theme-t9-launch-'+evidence.parent.name); scratch.mkdir(exist_ok=True)
    source_root=Path(os.environ.get('PILOT_THEME_REVIEWED_SOURCE', str(life.REPO)))
    coordinator=(source_root/'Sources/Pilot/Look/ThemeCoordinator.swift').read_text()
    mapping=(source_root/'Sources/PilotCore/ThemeMapping.swift').read_text()
    fixed='func launch(' in mapping
    if fixed:
        launch='return try intent.launch { command in try Data("recorded".utf8).write(to: URL(fileURLWithPath: root + "/recorded")); return "recorded only" }'
    else:
        start=coordinator.index('                    let bytes = try Data(contentsOf:')
        end=coordinator.index('\n                }.value',start)
        launch=coordinator[start:end]
    # Preserve the reviewed launch code verbatim, substituting only the type binding through local shadowing.
    recorder='''
final class Process {
 var executableURL: URL?; var arguments: [String]?; var environment: [String:String]?
 var standardInput: Any?; var standardOutput: Any?; var standardError: Any?
 var terminationStatus: Int32 { 0 }
 func run() throws { try Data("recorded".utf8).write(to: URL(fileURLWithPath: CommandLine.arguments[1]+"/recorded")) }
 func waitUntilExit() {}
}
'''
    main=scratch/'main.swift'
    # The snapshots are taken before the detached handoff, exactly as the approval captures them.
    main.write_text('import Foundation\nimport Darwin\n'+recorder+'''
@main struct Probe {
 static func main() async throws {
  let root = CommandLine.arguments[1]
  let app = root + "/Fake.app"
  let command = ThemeReloadCommand(executable: app + "/Contents/MacOS/Reload", arguments:["--reload", "literal $(touch NEVER)"])
  let binding = ThemeMappingBinding(id:"fixture",root:root,path:"target",app:app,reload:command)
  let executable = try ThemeFiles.read(root:app,path:"Contents/MacOS/Reload")
  let appSnapshot = try ThemeFiles.read(root:app,path:"Contents/Info.plist")
'''+('  let intent = ThemeReloadIntent(binding:binding,executable:executable,app:appSnapshot)\n' if fixed else '  _ = (binding, executable, appSnapshot)\n')+'''
  let outcome = await Task.detached { () -> String in
   do {
    try Data("handoff".utf8).write(to:URL(fileURLWithPath:root+"/handoff"))
    for _ in 0..<1000 { if FileManager.default.fileExists(atPath:root+"/go") { break }; usleep(10_000) }
    guard FileManager.default.fileExists(atPath:root+"/go") else { throw ThemeFailure("barrier timed out") }
    '''+launch+'''
   } catch { return "refused: \\(error)" }
  }.value
  print(outcome)
 }
}
''')
    ghostty=scratch/'Ghostty.swift'; ghostty.write_text((life.REPO/'Sources/PilotCore/Ghostty.swift').read_text().split('public enum OmarchyThemes')[0])
    sources=[(source_root/'Sources/PilotCore'/(x+'.swift') if (source_root/'Sources/PilotCore'/(x+'.swift')).exists() else life.REPO/'Sources/PilotCore'/(x+'.swift')) for x in ['JSONValue','PilotTheme','BarPreset','ThemeOwnership','ThemePlan','ZedTheme','ThemeMapping','ThemeTemplate','ThemePack']]
    command=['nice','-n','10','swiftc','-j','4','-parse-as-library',*map(str,sources),str(ghostty),str(main),'-o',str(scratch/'probe')]
    build=subprocess.run(command,text=True,capture_output=True)
    (evidence/'build.json').write_text(json.dumps(dict(command=command,exit=build.returncode,stdout=build.stdout,stderr=build.stderr,source=main.read_text(),productionBody=launch)))
    assert build.returncode==0,build.stderr
    failures=[]
    for kind in ['native-replace','escape-link','app-swap','metadata','mode','script','valid']:
        root=evidence/kind; helper=root/'Fake.app/Contents/MacOS/Reload'; helper.parent.mkdir(parents=True)
        helper.write_bytes(bytes.fromhex('cffaedfe')+b'INERT NATIVE FIXTURE NEVER EXECUTED'); helper.chmod(0o700)
        info=root/'Fake.app/Contents/Info.plist'; info.write_bytes(b'fixture metadata')
        run=subprocess.Popen(['nice','-n','10',str(scratch/'probe'),str(root)],stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True)
        try:
            deadline=time.monotonic()+12
            while not (root/'handoff').exists() and time.monotonic()<deadline: time.sleep(.02)
            assert (root/'handoff').exists(),kind
            if kind=='native-replace':
                helper.unlink(); helper.write_bytes(bytes.fromhex('cffaedfe')+b'DIFFERENT NATIVE'); helper.chmod(0o700)
            elif kind=='escape-link':
                outside=root/'outside'; outside.write_bytes(helper.read_bytes()); outside.chmod(0o700); helper.unlink(); helper.symlink_to(outside)
            elif kind=='app-swap':
                (root/'Fake.app').rename(root/'old.app'); shutil.copytree(root/'old.app',root/'Fake.app')
            elif kind=='metadata': info.write_bytes(b'changed metadata')
            elif kind=='mode': helper.chmod(0o600)
            elif kind=='script': helper.write_bytes(b'#!/bin/sh\ntouch NEVER\n')
            (root/'go').touch(); stdout,stderr=run.communicate(timeout=20)
            recorded=(root/'recorded').exists()
            (root/'result.json').write_text(json.dumps(dict(command=['nice','-n','10',str(scratch/'probe'),str(root)],exit=run.returncode,stdout=stdout,stderr=stderr,recorded=recorded,binarySHA256=hashlib.sha256((scratch/'probe').read_bytes()).hexdigest())))
            if (kind=='valid')!=recorded or run.returncode!=0: failures.append(kind+': '+stdout+stderr)
        finally:
            if run.poll() is None: run.terminate(); run.wait()
    shutil.rmtree(scratch)
    assert not failures,'post-handoff launch mismatch: '+repr(failures)
