"""Public PilotCLI -> early theme-only private host -> common production editor/store/coordinator.

Portable JSON envelope: {format:1, pack:<schema1 manifest>, files:{relative-path:base64}}.
No destination, local follow, ledger, executable or personal config is portable.
"""
import base64
import concurrent.futures
import copy
import importlib.util
import json
import os
from pathlib import Path
import shutil
import stat
import time

spec = importlib.util.spec_from_file_location('theme_packs', Path(__file__).with_name('packs.py'))
packs = importlib.util.module_from_spec(spec); spec.loader.exec_module(packs)
life = packs.life
EVIDENCE = Path(os.environ.get('PILOT_THEME_PROOF_EVIDENCE') or Path.home() / '.local/state/spec' / 'theme-system/T6/e')
life.EVIDENCE = EVIDENCE


class Fixture(packs.Fixture):
    def __init__(self, label='e'):
        super().__init__(label)
        self.native = self.root/'native.json'
        self.original_native = dict(palette={'stock':{'_0':'lagoon'}}, material=dict(glass=False,transparency=43,blur='light'))
        self.native.write_text(json.dumps(self.original_native))
        self.settings['nativeState'] = str(self.native)
        self.settings['nativeBaseline'] = self.original_native
        self.manifest.write_text(json.dumps(self.settings))
        self.baseline = self.snapshot(); self.receipt_before()
        (self.root/'tree-before.json').write_text(json.dumps(self.full_manifest(),indent=2))

    def snapshot(self):
        result = super().snapshot()
        if hasattr(self,'native'): result['native.json'] = life.digest(self.native)
        return result

    def full_manifest(self):
        values={}
        for path in self.root.rglob('*'):
            info=path.lstat();value=dict(mode=stat.S_IMODE(info.st_mode),kind=stat.S_IFMT(info.st_mode))
            if stat.S_ISREG(info.st_mode):value.update(life.digest(path))
            elif path.is_symlink():value['link']=os.readlink(path)
            values[str(path.relative_to(self.root))]=value
        return values

    def receipt(self):
        super().receipt()
        (self.root/'tree-after.json').write_text(json.dumps(self.full_manifest(),indent=2))
        (self.root/'native-final.json').write_bytes(self.native.read_bytes())

    def native_value(self): return json.loads(self.native.read_text())

    def effects(self):
        return {k:v for k,v in self.snapshot().items() if k.startswith('app/') or k.startswith('zed/') or k.startswith('vault') or k.startswith('state/') or k in ['native.json','desktop.json']}

    def folder(self, pack, name='input', images=None):
        folder=self.root/name;folder.mkdir()
        (folder/'manifest.json').write_text(json.dumps(pack))
        for path,data in (images or {}).items():
            target=folder/path;target.parent.mkdir(parents=True,exist_ok=True);target.write_bytes(data)
        return str(folder)

    def export(self, name, filename='export.json'):
        path=self.root/filename;self.call('theme','export',name,str(path));return path

    def create(self, name='user-a', wallpapers=None, images=None):
        pack=copy.deepcopy(self.packs[0]);pack.update(id=name,title='User '+name,wallpapers=wallpapers or [],adapters={'ghostty':{},'zed':{},'obsidian':{}})
        self.call('theme','new',self.folder(pack,name,images));return pack


def run(seam_only=False, fixes_only=False):
    EVIDENCE.mkdir(parents=True,exist_ok=True)
    fixtures=[];groups=[]
    def fixture(label):
        f=Fixture(label);fixtures.append(f);return f
    def passed(message): groups.append(message);print('PASS '+message,flush=True)
    try:
        f=fixture('round');f.start();before=f.effects()
        original=f.create();assert f.effects()==before
        value=f.call('theme','show','user-a');assert value['pack']==original and not value['factory']
        duplicate=f.call('theme','duplicate','lagoon','lagoon-copy','Lagoon copy')
        assert duplicate['id']=='lagoon-copy' and duplicate['palette']==json.loads((f.root/'factory/lagoon/manifest.json').read_text())['palette']
        exported=f.export('lagoon-copy');envelope=json.loads(exported.read_text())
        assert set(envelope)=={'format','pack','files'} and 'PROVENANCE.md' in envelope['files']
        assert base64.b64decode(envelope['files']['PROVENANCE.md'])==(f.root/'factory/lagoon/PROVENANCE.md').read_bytes()
        for relative,encoded in envelope['files'].items(): assert base64.b64decode(encoded)==(f.root/'factory/lagoon'/relative).read_bytes()
        portable=copy.deepcopy(envelope);portable['pack']['id']='imported';portable['pack']['title']='Imported'
        incoming=f.root/'incoming.json';incoming.write_text(json.dumps(portable));f.call('theme','import',str(incoming))
        out=f.export('imported','imported.json');assert json.loads(out.read_text())==portable
        assert f.effects()==before and f.factory_snapshot()==f.factory
        f.call('theme','import',str(incoming),ok=False);f.call('theme','duplicate','lagoon','lagoon','Collision',ok=False)
        f.call('theme','new',str(f.root/'user-a'),ok=False)
        old=f.call('theme','show','user-a')['revision'];edited=copy.deepcopy(original);edited['palette']['accent']='#314159'
        edited['variants']={'light':copy.deepcopy(edited['palette'])};edited['material']=dict(glass=True,transparency=35,blur='full')
        folder=f.folder(edited,'edited');f.call('theme','edit','user-a',folder,old)
        assert f.call('theme','show','user-a')['pack']==edited and f.effects()==before
        f.call('theme','edit','user-a',folder,old,ok=False)
        f.checkpoint('drafts-no-effects');f.stop();f.start();assert f.call('theme','show','user-a')['pack']==edited
        review=f.call('theme','plan','apply','user-a');assert review['native']['before']==f.original_native and review['native']['after']['palette']['pack']['_0']==edited
        assert review['native']['palette'] and not review['native']['material'] and not review['applied'] and f.effects()==before
        f.call('theme','apply',review['id']);a=f.native_value();assert a['palette']['pack']['_0']==edited and a['material']==f.original_native['material']
        pending=f.plan('user-a');rev=f.call('theme','show','user-a')['revision'];edited2=copy.deepcopy(edited);edited2['palette']['accent']='#271828'
        f.call('theme','edit','user-a',f.folder(edited2,'edited2'),rev);assert f.native_value()==a
        f.call('theme','apply',pending,ok=False)
        assert f.call('theme','fixture-colour','theme')['theme']=='#314159'
        f.apply('user-a');assert f.call('theme','fixture-colour','theme')['theme']=='#271828'
        cached=json.loads((f.root/'state/appearance.json').read_text());assert cached['roles']['accent']=='#271828'
        f.restore();assert f.native_value()==f.original_native;f.preserved();f.stop()
        # Explicit import replacement uses the exact observed revision; collision alone never replaces.
        f.start();before=f.effects();path=f.export('user-a','replace-source.json');portable=json.loads(path.read_text());portable['pack']['title']='Explicit replacement'
        path.write_text(json.dumps(portable));revision=f.call('theme','show','user-a')['revision'];saved=(f.root/'user-packs/user-a/manifest.json').read_bytes()
        f.call('theme','import',str(path),ok=False);assert (f.root/'user-packs/user-a/manifest.json').read_bytes()==saved
        f.call('theme','import',str(path),revision);assert f.call('theme','show','user-a')['pack']==portable['pack'] and f.effects()==before
        bad=copy.deepcopy(portable);bad['files']['../escape.png']=base64.b64encode(life.WALLPAPER_A).decode();path.write_text(json.dumps(bad));saved=(f.root/'user-packs/user-a/manifest.json').read_bytes()
        f.call('theme','import',str(path),f.call('theme','show','user-a')['revision'],ok=False);assert (f.root/'user-packs/user-a/manifest.json').read_bytes()==saved
        bad=copy.deepcopy(portable);bad['pack']['adapters']['future']={'config':'/private/config'};path.write_text(json.dumps(bad));f.call('theme','import',str(path),ok=False);f.stop()
        passed('create/duplicate/edit/import/export all apps/roles/variants/provenance; factory immutable; drafts zero effects; same-ID palette/cache revision and stale plan; fresh-process reload')

        f=fixture('many');f.start();images={f'pictures/{i}.png':life.WALLPAPER_A if i%2 else life.WALLPAPER_B for i in range(1,142)}
        images['pictures/.DS_Store']=b'Finder';images['pictures/README.md']=b'metadata'
        value=f.create('many',['pictures'],images);loaded=f.call('theme','show','many')
        assert len(loaded['images'])==141 and [Path(x).name for x in loaded['images'][:3]]==['1.png','2.png','3.png']
        out=f.export('many');portable=json.loads(out.read_text());assert len(portable['files'])==141
        portable['pack']['id']='many-import';(f.root/'many-in.json').write_text(json.dumps(portable));f.call('theme','import',str(f.root/'many-in.json'))
        assert len(f.call('theme','show','many-import')['images'])==141
        f.apply('many-import');wall=f.read_wall();assert wall['preferences']==f.desktop['preferences'];f.restore();assert f.read_wall()==f.desktop
        f.stop();passed('unlimited 141-image folder with hidden metadata; portable bytes/natural order/shared orientation scheduling; personal screen/workspace preferences preserved')

        f=fixture('inuse');f.start();p=f.create(wallpapers=['wall.png'],images={'wall.png':life.WALLPAPER_A});f.apply('user-a')
        assigned=f.root/'user-packs/user-a/wall.png';assert any(x['image']==str(assigned) for x in f.read_wall()['displays'])
        before=f.effects();rev=f.call('theme','show','user-a')['revision'];replacement=f.folder(p,'asset-edit',{'wall.png':life.WALLPAPER_B})
        f.call('theme','edit','user-a',replacement,rev,ok=False);assert assigned.read_bytes()==life.WALLPAPER_A and f.effects()==before
        incoming=f.export('user-a');portable=json.loads(incoming.read_text());portable['files']['wall.png']=base64.b64encode(life.WALLPAPER_B).decode();incoming.write_text(json.dumps(portable))
        f.call('theme','import',str(incoming),rev,ok=False);removed=copy.deepcopy(p);removed['wallpapers']=[]
        f.call('theme','edit','user-a',f.folder(removed,'asset-remove'),rev,ok=False);assert assigned.read_bytes()==life.WALLPAPER_A and f.effects()==before
        palette=copy.deepcopy(p);palette['palette']['accent']='#314159';f.call('theme','edit','user-a',f.folder(palette,'palette-edit',{'wall.png':life.WALLPAPER_A}),rev)
        assert f.effects()==before;rev=f.call('theme','show','user-a')['revision']
        copied=f.call('theme','duplicate','user-a','image-copy','Image copy');copyrev=f.call('theme','show','image-copy')['revision']
        f.call('theme','edit','image-copy',f.folder(copied,'copy-edit',{'wall.png':life.WALLPAPER_B}),copyrev);assert assigned.read_bytes()==life.WALLPAPER_A and f.effects()==before
        f.restore();personal=copy.deepcopy(f.desktop);personal['sources']=[str(assigned)]
        for display in personal['displays']:display['image']=str(assigned)
        f.write_wall(personal);f.apply('b');before=f.effects();f.call('theme','edit','user-a',replacement,rev,ok=False)
        assert assigned.read_bytes()==life.WALLPAPER_A and f.effects()==before
        f.restore();before=f.effects();f.call('theme','edit','user-a',replacement,rev,ok=False);assert assigned.read_bytes()==life.WALLPAPER_A and f.effects()==before
        f.write_wall(f.desktop);before=f.effects();f.call('theme','edit','user-a',replacement,rev);assert assigned.read_bytes()==life.WALLPAPER_B and f.effects()==before;f.stop()
        passed('assigned image bytes and Restore originals stay immutable during draft/import replacement; current personal references protected; palette-only edit and independent duplicate remain effect-free; released images editable')

        f=fixture('zero');f.start();before=f.effects();p=copy.deepcopy(f.packs[0]);p.update(id='zero',adapters={},wallpapers=[])
        f.call('theme','new',f.folder(p));assert f.effects()==before
        f.apply('zero');assert f.read_wall()==f.desktop and f.actual.read_bytes()==f.original
        assert f.call('theme','status')['selected']['id']=='zero';f.stop();f.start();f.restore();assert f.native_value()==f.original_native;f.stop()
        passed('zero apps/zero wallpapers still owns native palette and restores after restart; no desktop/config changes')

        f=fixture('follow');f.start();p=f.create();p['material']=dict(glass=True,transparency=35,blur='off');rev=f.call('theme','show','user-a')['revision']
        f.call('theme','edit','user-a',f.folder(p,'with-material'),rev);f.apply('user-a')
        before=f.native_value();plan=f.plan('user-a');f.call('theme','follow','material','pack');assert f.native_value()==before
        f.call('theme','apply',plan,ok=False);f.apply('user-a');assert f.native_value()['material']==p['material']
        owned=json.loads((f.root/'state/ownership.json').read_text())['appearance'];assert owned['original']['material']==f.original_native['material']
        f.call('theme','follow','palette','personal');f.call('theme','follow','wallpapers','personal');f.apply('user-a')
        assert f.native_value()['palette']==f.original_native['palette'] and f.native_value()['material']==p['material']
        f.call('theme','follow','material','personal');f.apply('user-a');assert f.native_value()==f.original_native
        # Later personal material is unowned: applying palette and Restore must preserve it.
        changed=f.native_value();changed['material']['transparency']=67;f.native.write_text(json.dumps(changed))
        f.call('theme','follow','palette','pack');f.apply('user-a');assert f.native_value()['material']==changed['material']
        f.restore();assert f.native_value()==changed
        f.call('theme','follow','material','pack');f.apply('user-a')
        changed=f.native_value();changed['material']['transparency']=83;f.native.write_text(json.dumps(changed));before=f.effects()
        # The coordinator's brief: an owned part the person changed since is let go; Restore keeps it and finishes the rest.
        answer=f.restore();assert answer['status']=='restored' and f.native_value()['material']==changed['material'],answer
        assert [w for w in answer['kept'] if w.startswith('Kept the glass')],answer['kept']
        f.checkpoint('later-owned-personal-kept');f.stop()
        passed('local follow staged/no effects; immutable freshness; component original captured on first ownership; palette/material release; unowned later material preserved; an owned later edit is kept while Restore finishes')

        f=fixture('style');f.start();p=f.create();p['styles']=['toybox'];rev=f.call('theme','show','user-a')['revision'];f.call('theme','edit','user-a',f.folder(p,'restricted'),rev)
        assert 'user-a' not in [x['id'] for x in f.call('theme','list')] and 'user-a' in [x['id'] for x in f.call('theme','list-all')]
        before=f.effects();f.call('theme','check','user-a',ok=False);f.call('theme','plan','apply','user-a',ok=False);assert f.effects()==before
        f.controls(style='toybox');plan=f.plan('user-a');f.controls(style='instrument');f.call('theme','apply',plan,ok=False)
        f.controls(style='toybox');f.apply('user-a');f.restore();f.stop()
        passed('Toybox compatibility enforced by discovery/check/plan/apply freshness beyond picker; hand-authored restriction and common stock coexist')
        f=fixture('memory');f.start();assert 'toybox' not in [x['id'] for x in f.call('theme','colours')];native=f.native_value();native['palette']={'stock':{'_0':'orchid'}};f.native.write_text(json.dumps(native))
        f.call('theme','fixture-style','toybox');assert 'toybox' in [x['id'] for x in f.call('theme','colours')];native=f.native_value();native['palette']={'stock':{'_0':'toybox'}};f.native.write_text(json.dumps(native))
        assert f.call('theme','fixture-style','instrument')=={'stock':{'_0':'orchid'}}
        assert f.call('theme','fixture-style','toybox')=={'stock':{'_0':'toybox'}}
        f.stop();f.start();assert f.call('theme','fixture-style','instrument')=={'stock':{'_0':'orchid'}};f.stop()
        passed('native shared compatible-style memory returns prior Instrument/Toybox palette and persists across process restart')


        for kind in ['schema','id','colour','traversal','absolute','unknown-app','authority','bad-image','missing','collision','file-directory','material']:
            f=fixture('bad');f.start();p=copy.deepcopy(f.packs[0]);p['id']='invalid-user';images={}
            if kind=='schema':p['schema']=2
            elif kind=='id':p['id']='../escape'
            elif kind=='colour':p['palette']['accent']='#XYZ123'
            elif kind=='traversal':p['wallpapers']=['../outside.png']
            elif kind=='absolute':p['wallpapers']=[str(f.root/'baseline.png')]
            elif kind=='unknown-app':p['adapters']['future']={'privateConfig':'/private/settings'}
            elif kind=='authority':p['factoryRoot']=str(f.root/'factory')
            elif kind=='bad-image':p['wallpapers']=['bad.png'];images={'bad.png':b'not an image'}
            elif kind=='missing':p['wallpapers']=['missing.png']
            elif kind=='collision':p['id']='lagoon'
            elif kind=='file-directory':p['wallpapers']=['asset','asset/image.png'];images={'asset':life.WALLPAPER_A}
            elif kind=='material':p['material']=dict(glass=True,transparency=101,blur='arbitrary')
            folder=f.folder(p,images=images);before=f.effects();f.call('theme','new',folder,ok=False);assert f.effects()==before
            assert not (f.root/'user-packs/invalid-user/manifest.json').exists();f.stop()
        passed('invalid schema/IDs/colours/authority/future adapter data/material/paths/images/missing files/reserved IDs/colliding paths reject before publication')

        for kind in ['symlink','hardlink','fifo','directory-link','parent-link']:
            f=fixture('links');f.start();p=copy.deepcopy(f.packs[0]);p.update(id='unsafe',wallpapers=['asset.png']);folder=Path(f.folder(p));outside=f.root/'outside.png';outside.write_bytes(life.WALLPAPER_A)
            if kind=='symlink':(folder/'asset.png').symlink_to(outside)
            elif kind=='hardlink':os.link(outside,folder/'asset.png')
            elif kind=='fifo':os.mkfifo(folder/'asset.png')
            elif kind=='directory-link':
                p['wallpapers']=['linked'];(folder/'manifest.json').write_text(json.dumps(p));(folder/'linked').symlink_to(f.root,target_is_directory=True)
            else:
                link=f.root/'linked-input';link.symlink_to(folder,target_is_directory=True);folder=link
            before=f.effects();f.call('theme','new',str(folder),ok=False);assert f.effects()==before and outside.read_bytes()==life.WALLPAPER_A;f.stop()
        passed('import writer rejects escaping/symlinked directories/parents, hardlinks, FIFOs and nonregular assets; outside sentinel untouched')

        f=fixture('targets');f.start();f.create();path=f.export('user-a');before=path.read_bytes();f.call('theme','export','user-a',str(path),ok=False);assert path.read_bytes()==before
        outside=f.root/'sentinel';outside.write_bytes(b'keep');link=f.root/'output';link.symlink_to(outside)
        f.call('theme','export','user-a',str(link),ok=False);assert outside.read_bytes()==b'keep'
        for path in [f.root/'state/ownership.json',f.root/'factory/new.json',f.root/'app/export.json']:
            f.call('theme','export','user-a',str(path),ok=False)
        # Same identity in both roots refuses, even with a replacement revision.
        revision=f.call('theme','show','user-a')['revision'];shutil.copytree(f.root/'user-packs/user-a',f.root/'packs/user-a')
        f.call('theme','show','user-a',ok=False);f.call('theme','edit','user-a',str(f.root/'user-a'),revision,ok=False);f.stop()
        passed('export is exclusive/descriptor anchored and blocks protected destinations; same-ID multiple stores refuse rather than overwrite')

        for stage in ['editor-staged','export-staged']:
            f=fixture('parent');f.start();f.create();saved=(f.root/'user-packs/user-a/manifest.json').read_bytes()
            outside=f.root/'outside';outside.mkdir();sentinel=outside/'keep';sentinel.write_bytes(b'untouched')
            if stage=='editor-staged':
                p=copy.deepcopy(f.packs[0]);p.update(id='user-a',title='Replacement');source=f.folder(p,'replacement');rev=f.call('theme','show','user-a')['revision']
                command=('theme','edit','user-a',source,rev);parent=f.root/'user-packs'
            else:
                parent=f.root/'exports';parent.mkdir();command=('theme','export','user-a',str(parent/'theme.json'))
            f.controls(editorHold=stage)
            with concurrent.futures.ThreadPoolExecutor(max_workers=1) as executor:
                future=executor.submit(f.call,*command,ok=False);deadline=time.monotonic()+10
                while not (f.root/'editor-asked').exists() and time.monotonic()<deadline:time.sleep(.02)
                assert (f.root/'editor-asked').exists();backup=f.root/'anchored-parent';parent.rename(backup);parent.symlink_to(outside,target_is_directory=True)
                (f.root/'editor-go').touch();future.result()
            assert list(outside.iterdir())==[sentinel] and sentinel.read_bytes()==b'untouched'
            if stage=='editor-staged':assert (backup/'user-a/manifest.json').read_bytes()==saved
            parent.unlink();backup.rename(parent);f.controls();f.stop()
        passed('actual save/export writer barriers reject destination-parent substitutions; anchored old pack and outside sentinel unchanged')

        for kind in ['staged-manifest','staged-link','later-destination']:
            f=fixture('writer');f.start();f.create();old=(f.root/'user-packs/user-a/manifest.json').read_bytes();revision=f.call('theme','show','user-a')['revision']
            p=copy.deepcopy(f.packs[0]);p.update(id='user-a',title='Replacement',wallpapers=['image.png']);folder=f.folder(p,'replacement',{'image.png':life.WALLPAPER_A})
            sentinel=f.root/'outside-image.png';sentinel.write_bytes(life.WALLPAPER_B);f.controls(editorHold='editor-publish')
            with concurrent.futures.ThreadPoolExecutor(max_workers=1) as executor:
                future=executor.submit(f.call,'theme','edit','user-a',folder,revision,ok=False);deadline=time.monotonic()+10
                while not (f.root/'editor-asked').exists() and time.monotonic()<deadline:time.sleep(.02)
                assert (f.root/'editor-asked').exists();stage=next((f.root/'user-packs').glob('.pilot-draft-*/user-a'))
                if kind=='staged-manifest':(stage/'manifest.json').write_text('{invalid')
                elif kind=='staged-link':(stage/'image.png').unlink();(stage/'image.png').symlink_to(sentinel)
                else:
                    later=json.loads(old);later['palette']['accent']='#ABCDEF';(f.root/'user-packs/user-a/manifest.json').write_text(json.dumps(later));old=(f.root/'user-packs/user-a/manifest.json').read_bytes()
                (f.root/'editor-go').touch();future.result()
            assert (f.root/'user-packs/user-a/manifest.json').read_bytes()==old and sentinel.read_bytes()==life.WALLPAPER_B
            f.controls();f.stop()
        passed('writer revalidates staged manifest/assets and exact destination revision immediately before atomic publication; malicious stage links and later saves are preserved/rejected')

        for stage in ['editor-staged','editor-publish','editor-published']:
            f=fixture('atomic');f.start();p=f.create();saved=(f.root/'user-packs/user-a/manifest.json').read_bytes();revision=f.call('theme','show','user-a')['revision'];p['palette']['accent']='#123456';folder=f.folder(p,'changed')
            f.controls(fail=stage);f.call('theme','edit','user-a',folder,revision,ok=False);assert (f.root/'user-packs/user-a/manifest.json').read_bytes()==saved
            f.controls();assert f.call('theme','show','user-a')['revision']==revision;f.stop();f.start();assert f.call('theme','show','user-a')['revision']==revision;f.stop()
        for stage in ['editor-staged','editor-published']:
            f=fixture('crash');f.start();p=f.create();saved=(f.root/'user-packs/user-a/manifest.json').read_bytes();revision=f.call('theme','show','user-a')['revision'];p['palette']['accent']='#123456';folder=f.folder(p,'changed')
            f.controls(crash=stage);f.call('theme','edit','user-a',folder,revision,ok=False);f.stop(crashed=True);f.controls();f.start();f.call('theme','show','user-a')
            if stage=='editor-staged':assert (f.root/'user-packs/user-a/manifest.json').read_bytes()==saved
            else:assert any(x.read_bytes()==saved for x in (f.root/'user-packs').glob('.pilot-draft-*/user-a/manifest.json'))
            f.stop()
        passed('failed staged/pre-publication/post-publication saves preserve old published bytes; process exits retain complete valid publication and prior recoverable folder')

        f=fixture('gate');f.start();f.create();plan=f.plan('user-a');before=f.effects();f.controls(allow='no');f.call('theme','apply',plan,ok=False);assert f.effects()==before
        f.controls(hold='yes');plan=f.plan('user-a')
        with concurrent.futures.ThreadPoolExecutor(max_workers=1) as executor:
            future=executor.submit(f.call,'theme','apply',plan,ok=False)
            deadline=time.monotonic()+10
            while not (f.root/'asked').exists() and time.monotonic()<deadline:time.sleep(.05)
            assert (f.root/'asked').exists();f.call('theme','duplicate','lagoon','during-allow','Not saved',ok=False)
            changed=f.native_value();changed['material']['transparency']=81;f.native.write_text(json.dumps(changed));(f.root/'go').touch();future.result()
        assert not (f.root/'user-packs/during-allow').exists();f.stop()
        passed('denial has zero effects; single queue rejects concurrent save during Allow; later personal native input invalidates approved plan')

        for stage in ['after-native','after-ledger']:
            f=fixture('nativecrash');f.start();f.create();plan=f.plan('user-a');f.controls(crash=stage);f.call('theme','apply',plan,ok=False);f.stop(crashed=True);assert (f.root/'state/pending.json').exists()
            f.controls();f.start()
            if stage=='after-native':assert f.native_value()==f.original_native
            else:f.restore();assert f.native_value()==f.original_native
            assert not (f.root/'state/pending.json').exists();f.stop()
        passed('native before/after ledger process-exit recovery uses same durable journal; Restore returns original across restart')

        f=fixture('corrupt');f.start();f.create();(f.root/'state/components.json').write_text(json.dumps(dict(palette=True,wallpapers=True,material=False,root='/unauthorized')))
        before=f.effects();f.call('theme','plan','apply','user-a',ok=False);assert f.effects()==before;f.stop()
        f=fixture('journal');f.start();f.create();plan=f.plan('user-a');f.controls(crash='after-native');f.call('theme','apply',plan,ok=False);f.stop(crashed=True)
        path=f.root/'state/pending.json';pending=json.loads(path.read_text());pending['appearance']['root']='/unauthorized';path.write_text(json.dumps(pending));before=f.effects()
        f.controls();f.start(expect_ready=False);assert f.effects()==before and path.exists()
        passed('unknown local component authority and corrupt native journal fields fail closed without rollback/application effects or evidence loss')

        f=fixture('legacy');f.settings.pop('nativeState');f.settings.pop('nativeBaseline');f.manifest.write_text(json.dumps(f.settings));f.start();f.apply('a');f.stop()
        legacy=f.native_value();legacy['palette']={'pack':{'_0':f.packs[0]}};f.native.write_text(json.dumps(legacy))
        f.settings.update(nativeState=str(f.native),nativeBaseline=f.original_native);f.manifest.write_text(json.dumps(f.settings));f.start();f.restore()
        assert f.native_value()==f.original_native and f.actual.read_bytes()==f.original;f.stop()
        passed('missing-field schema1 native ownership migrates with locally captured pre-pack baseline, never adopting the applied pack; legacy file Restore remains exact')

        f=fixture('first');shutil.rmtree(f.root/'packs');shutil.rmtree(f.root/'user-packs');f.start();assert len(f.call('theme','list'))==sum('instrument' in json.loads(x.read_text())['styles'] for x in (life.REPO/'Packaging/ThemePacks').glob('*/manifest.json'))
        p=copy.deepcopy(f.packs[0]);p['id']='first-user';f.call('theme','new',f.folder(p));assert f.call('theme','show','first-user')['pack']==p
        f.stop();(f.root/'user-packs/first-user/manifest.json').write_text('{broken');f.start();f.call('theme','list',ok=False);f.stop()
        passed('legitimate absent first-run user library works; malformed existing pack fails closed')
        review_fixes(fixture, passed)
        rollback_fixes(fixture, passed)
        (EVIDENCE/'editor-results.json').write_text(json.dumps(dict(groups=groups,fixtures=[str(f.root) for f in fixtures]),indent=2))
        print('PASS editor',flush=True)
    finally:
        for f in fixtures:
            f.stop();f.receipt()
        (EVIDENCE/'cleanup.json').write_text(json.dumps(dict(hostsJoined=True,fixtures=[str(f.root) for f in fixtures]),indent=2))


def review_fixes(fixture, passed):
    def wait(path):
        deadline=time.monotonic()+10
        while not path.exists() and time.monotonic()<deadline: time.sleep(.01)
        assert path.exists(),str(path)

    # References are supplied independently of the pack's spelling, including recovery-only claims.
    for alias_kind in ['directory','root','ancestor','case','dot','broken']:
        for reference in ['sources','display','preferences','original','last']:
            f=fixture('alias');f.start();p=f.create(wallpapers=['wall.png'],images={'wall.png':life.WALLPAPER_A})
            folder=f.root/'user-packs/user-a';image=folder/'wall.png'
            if alias_kind=='directory':
                alias=f.root/'other-pack-name';alias.symlink_to(folder,target_is_directory=True);path=str(alias/'wall.png')
            elif alias_kind=='root':
                alias=f.root/'other-library';alias.symlink_to(folder.parent,target_is_directory=True);path=str(alias/'user-a/wall.png')
            elif alias_kind=='ancestor':
                alias=f.root/'other-ancestor';alias.symlink_to(f.root,target_is_directory=True);path=str(alias/'user-packs/user-a/wall.png')
            elif alias_kind=='case':
                path=str(f.root/'USER-PACKS/USER-A/WALL.PNG')
                if not Path(path).exists():
                    (f.root/'case-limitation.txt').write_text('Case variant does not resolve on this volume; symlink/identity variants still run.\n');f.stop();continue
                assert Path(path).stat().st_ino==image.stat().st_ino
            elif alias_kind=='dot': path=str(folder)+'/../user-a/./wall.png'
            else:
                alias=f.root/'broken-reference';alias.symlink_to(f.root/'missing-image');path=str(alias)
            wall=copy.deepcopy(f.desktop)
            if reference=='sources':wall['sources']=[path]
            elif reference=='display':wall['displays'][0]['image']=path
            elif reference=='preferences':wall['preferences']['nested']={'images':[[path]]}
            else:
                f.apply('user-a' if reference=='last' else 'lagoon')
                record=f.root/'state/ownership.json';ledger=json.loads(record.read_text())
                # Exercise both source-list and display-image recovered values without changing current appearance.
                for claim in ledger['wallpapers']:
                    value=claim[reference]
                    if 'sources' in value:value['sources']['_0']=[path]
                    elif 'image' in value:value['image']['_0']=path
                record.write_text(json.dumps(ledger))
            f.write_wall(wall);before=f.effects();revision=f.call('theme','show','user-a')['revision'];f.checkpoint('alias-before')
            replacement=f.folder(p,'replacement',{'wall.png':life.WALLPAPER_B})
            f.call('theme','edit','user-a',replacement,revision,ok=False)
            assert image.read_bytes()==life.WALLPAPER_A and f.effects()==before
            # Identical image files permit palette editing even with conservative/broken references.
            p['palette']['accent']='#314159';f.call('theme','edit','user-a',f.folder(p,'palette',{'wall.png':life.WALLPAPER_A}),revision)
            assert image.read_bytes()==life.WALLPAPER_A and f.effects()==before
            f.checkpoint('alias-after');f.stop()
    passed('resolved directory/library/ancestor/case/dot aliases and broken references protect current sources/displays/nested preferences and original/last recovery; refused bytes/effects unchanged; palette-only remains legal')

    f=fixture('protected');f.start();f.create();before=f.effects()
    roots=[f.root/'packs',f.root/'user-packs',f.root/'factory',f.root/'state',f.root/'app',f.root/'zed']
    roots += [Path(x['root']) for x in f.settings['obsidian']]
    for i,root in enumerate(roots):
        for parent in [root,root.with_name(root.name.upper())]:
            if parent.exists():f.call('theme','export','user-a',str(parent/'forbidden.json'),ok=False)
            assert not (root/'forbidden.json').exists()
        alias=f.root/('protected-alias-'+str(i));alias.symlink_to(root,target_is_directory=True)
        f.call('theme','export','user-a',str(alias/'forbidden.json'),ok=False)
    legal=f.root/'exports';legal.mkdir();f.call('theme','export','user-a',str(legal/'legal.json'))
    assert f.effects()==before and json.loads((legal/'legal.json').read_text())['pack']['id']=='user-a';f.stop()
    passed('protected library/factory/state/all bound app export roots reject case/directory aliases; ordinary outside new export succeeds without effects')

    for stage in ['export-staged','export-published']:
        for kind in ['bytes','truncate','replacement','symlink','hardlink','fifo','directory','mode','source']:
            f=fixture('exporttamper');f.start();f.create();out=f.root/'exports';out.mkdir();target=out/'pack.json'
            sentinel=f.root/'sentinel';sentinel.write_bytes(b'later attacker bytes');sentinel.chmod(0o640)
            f.controls(editorHold=stage);before=f.effects();f.checkpoint('tamper-before')
            with concurrent.futures.ThreadPoolExecutor(max_workers=1) as pool:
                future=pool.submit(f.call,'theme','export','user-a',str(target),ok=False)
                wait(f.root/'editor-asked');temp=next(out.glob('.pilot-file-*')) if stage=='export-staged' else target
                if kind=='bytes':temp.write_bytes(b'counterfeit')
                elif kind=='truncate':temp.write_bytes(b'')
                elif kind=='replacement':
                    content=temp.read_bytes();temp.unlink();temp.write_bytes(content);temp.chmod(0o600)
                elif kind in ['symlink','hardlink','fifo','directory']:
                    temp.unlink()
                    if kind=='symlink':temp.symlink_to(sentinel)
                    elif kind=='hardlink':os.link(sentinel,temp)
                    elif kind=='fifo':os.mkfifo(temp)
                    else:temp.mkdir()
                elif kind=='mode':temp.chmod(0o644)
                else:
                    source=f.root/'user-packs/user-a';source.rename(f.root/'source-recovery');shutil.copytree(f.root/'source-recovery',source)
                    before=f.effects()
                info=temp.lstat();attacker=(info.st_ino,info.st_mode,temp.read_bytes() if stat.S_ISREG(info.st_mode) else os.readlink(temp) if temp.is_symlink() else None)
                (f.root/'editor-go').touch();future.result()
            assert temp.exists() or temp.is_symlink()
            info=temp.lstat();assert attacker==(info.st_ino,info.st_mode,temp.read_bytes() if stat.S_ISREG(info.st_mode) else os.readlink(temp) if temp.is_symlink() else None)
            assert stage!='export-staged' or not target.exists()
            assert sentinel.read_bytes()==b'later attacker bytes' and stat.S_IMODE(sentinel.stat().st_mode)==0o640 and f.effects()==before
            f.checkpoint('tamper-after');f.controls();f.stop()
    passed('real export barriers reject altered/truncated/replaced/symlinked/hardlinked/nonregular/mode-tampered files and source swaps before/after publication; later bytes/modes/stages retained, no false success')

    f=fixture('attachment');f.start();f.create();before=f.effects()
    def draft(*words):return f.call('theme','fixture-draft',*words)
    asset=str(f.root/'baseline.png');bad=str(f.root/'not-an-image');Path(bad).write_text('invalid image')
    def pending(pool,key,path=asset):
        future=pool.submit(draft,'attach',path,key);wait(f.root/('attach-'+key+'-asked'));return future
    def release(key): (f.root/('attach-'+key+'-go')).touch()
    with concurrent.futures.ThreadPoolExecutor(max_workers=2) as pool:
        for transition in ['selection','edit','duplicate','cancel','reopen','intervening-edit','close']:
            draft('open','user-a');old=pending(pool,transition)
            if transition=='selection':draft('cancel')
            elif transition=='cancel':draft('cancel')
            elif transition=='close':draft('close')
            elif transition=='intervening-edit':draft('title','Keep intervening edits')
            else:
                if transition=='reopen':draft('cancel')
                draft('open','b' if transition=='edit' else 'user-a')
                if transition=='duplicate':draft('identity','new-copy')
                draft('title','Keep newer draft')
            expected=draft('status');release(transition);old.result();assert draft('status')==expected
        draft('open','user-a');old=pending(pool,'old-success');draft('open','b');new=pending(pool,'new-success')
        expected=draft('status');assert expected['loading'];release('old-success');old.result();assert draft('status')==expected
        release('new-success');new.result();value=draft('status');assert not value['loading'] and value['draft']['pack']['id']=='b' and value['draft']['files']
        draft('open','user-a');old=pending(pool,'late-error',bad);draft('open','b');new=pending(pool,'current-success');expected=draft('status')
        release('late-error');old.result();assert draft('status')==expected
        release('current-success');new.result();assert not draft('status')['error']
        draft('open','user-a');old=pending(pool,'very-late');draft('open','b');new=pending(pool,'current-error',bad)
        release('current-error');new.result();expected=draft('status');assert expected['error'] and not expected['loading']
        release('very-late');old.result();assert draft('status')==expected
        draft('open','user-a');other=f.root/'other.png';other.write_bytes(life.WALLPAPER_B)
        old=pending(pool,'same-old');new=pending(pool,'same-new',str(other))
        release('same-new');new.result();expected=draft('status')
        assert set(expected['draft']['files'])=={'wallpapers/other.png'}
        release('same-old');old.result();assert draft('status')==expected
    assert f.effects()==before;f.checkpoint('attachments-after');f.stop()
    passed('actual compiled shared native draft handler discards delayed attachment across selection/Edit/Duplicate/cancel/reopen/close/intervening edits; out-of-order success/error cannot clear newer loading/error or overwrite work; zero effects')

    for operation in ['first','switch','restore']:
        for side in ['beforeLedger','afterLedger']:
            if operation=='first' and side=='beforeLedger':continue
            if operation=='restore' and side=='afterLedger':continue # Restore has no native ownership after release.
            for damage in ['unknown','nested','null','wrong-type','duplicate','escaped-duplicate','bom-duplicate','utf16-duplicate','utf32-duplicate','utf16be-duplicate']:
                f=fixture('embedded');f.start();f.create()
                if operation!='first':f.apply('user-a')
                plan=f.plan(None if operation=='restore' else 'b' if operation=='switch' else 'user-a')
                f.controls(crash='after-native');f.call('theme','restore' if operation=='restore' else 'apply',plan,ok=False);f.stop(crashed=True)
                path=f.root/'state/pending.json';journal=json.loads(path.read_text());ledger=json.loads(base64.b64decode(journal[side]));value=ledger['appearance']
                if damage=='unknown':value['authority']='unknown'
                elif damage=='nested':value['original']['material']['authority']='unknown'
                elif damage=='null':ledger['appearance']=None
                elif damage=='wrong-type':value['paletteOwned']='yes'
                text=json.dumps(ledger,separators=(',',':'))
                if damage.endswith('duplicate'):
                    text=text.replace('"paletteOwned":true','"paletteOwned":true,"'+('palette\\u004fwned' if damage=='escaped-duplicate' else 'paletteOwned')+'":true',1)
                    assert text.count('paletteOwned')>= (2 if damage=='duplicate' else 1)
                encoded=text.encode('utf-16' if damage=='utf16-duplicate' else 'utf-32' if damage=='utf32-duplicate' else 'utf-16-be' if damage=='utf16be-duplicate' else 'utf-8')
                if damage=='bom-duplicate':encoded=b'\xef\xbb\xbf'+encoded
                journal[side]=base64.b64encode(encoded).decode();path.write_text(json.dumps(journal));f.controls();before=f.effects();saved=path.read_bytes();f.checkpoint('invalid-before')
                f.start(expect_ready=False);assert f.effects()==before and path.read_bytes()==saved
                f.checkpoint('invalid-after')
    passed('interrupted first Apply/switch/Restore reject unknown/nested/null/wrong-typed/duplicate/escaped-duplicate native authority in embedded before/after ledgers before any file/native/wallpaper effect; pending bytes retained')

    # Optional appearance is absent in reviewed older schema-1 records. Recover those exact encodings.
    for legacy in [False,True]:
        for operation in ['first','switch','restore']:
            f=fixture('validpending')
            if legacy:
                f.settings.pop('nativeState');f.settings.pop('nativeBaseline');f.manifest.write_text(json.dumps(f.settings))
            f.start();f.create()
            if operation!='first':f.apply('user-a')
            before=f.effects();before_native=f.native_value();before_wall=f.read_wall();ledger=f.root/'state/ownership.json';saved=ledger.read_bytes() if ledger.exists() else None
            plan=f.plan(None if operation=='restore' else 'b' if operation=='switch' else 'user-a')
            f.controls(crash='after-write:0' if legacy else 'after-native')
            f.call('theme','restore' if operation=='restore' else 'apply',plan,ok=False);f.stop(crashed=True)
            pending=f.root/'state/pending.json';assert pending.exists();f.controls();f.start()
            assert not pending.exists() and (ledger.read_bytes() if ledger.exists() else None)==saved
            # Recovery may append recording rows, but restores all actual owned file/native/wallpaper bytes.
            after=f.effects()
            external=lambda values:{k:v for k,v in values.items() if k.startswith(('app/','zed/','vault'))}
            assert external(after)==external(before) and f.native_value()==before_native and f.read_wall()==before_wall
            f.preserved();f.stop()
    passed('valid current and older missing-native-field schema1 pending first Apply/switch/Restore recover unchanged through real restart and preserve exact ownership/absence')


def rollback_fixes(fixture, passed):
    """Actual CLI/store barriers: predecessor data and identity are independent inputs."""
    def tree(folder):
        values={}
        for path in [folder,*sorted(folder.rglob('*'))]:
            info=path.lstat();value=dict(device=info.st_dev,inode=info.st_ino,mode=info.st_mode,links=info.st_nlink)
            if path.is_symlink():value['link']=os.readlink(path)
            elif path.is_file():value.update(life.digest(path))
            values[str(path.relative_to(folder))]=value
        return values

    variants=['normal','asset','manifest','manifest-encoding','asset-mode','folder-mode','provenance','metadata',
              'file-identity','folder-identity','rename','delete','link','file','asset-link','hardlink',
              'stage-parent','library-parent','current-asset','current-manifest','current-extra','current-identity']
    for reference in ['active','original']:
        for kind in variants:
            f=fixture('rb');f.start()
            p=f.create(wallpapers=['wall.png'],images={'wall.png':life.WALLPAPER_A})
            folder=f.root/'user-packs/user-a';image=folder/'wall.png'
            (folder/'PROVENANCE.md').write_text('Original provenance\n')
            (folder/'metadata').write_text('Retained metadata\n')
            if reference=='active':f.apply('user-a')
            else:
                personal=copy.deepcopy(f.desktop);personal['sources']=[str(image)]
                for display in personal['displays']:display['image']=str(image)
                f.write_wall(personal);f.apply('lagoon')
                record=json.loads((f.root/'state/ownership.json').read_text())
                assert str(image) in json.dumps(record['wallpapers'])
            effects=f.effects();revision=f.call('theme','show','user-a')['revision'];original=tree(folder)
            p['palette']['accent']='#314159'
            source=f.folder(p,'palette-only',{'wall.png':life.WALLPAPER_A,'PROVENANCE.md':b'Original provenance\n'})
            f.checkpoint('rollback-before')
            f.controls(editorHold='editor-published',fail='editor-published')
            moved=None;replaced=None
            with concurrent.futures.ThreadPoolExecutor(max_workers=1) as executor:
                future=executor.submit(f.call,'theme','edit','user-a',source,revision,ok=False)
                deadline=time.monotonic()+10
                while not (f.root/'editor-asked').exists() and time.monotonic()<deadline:time.sleep(.01)
                assert (f.root/'editor-asked').exists()
                stage=next((f.root/'user-packs').glob('.pilot-draft-*/user-a'))
                assert tree(stage)==original
                published=tree(folder);sentinel=f.root/'outside.png';sentinel.write_bytes(life.WALLPAPER_B)
                if kind=='asset':(stage/'wall.png').write_bytes(life.WALLPAPER_B)
                elif kind=='manifest':
                    data=json.loads((stage/'manifest.json').read_text());data['palette']['accent']='#ABCDEF';(stage/'manifest.json').write_text(json.dumps(data))
                elif kind=='manifest-encoding':(stage/'manifest.json').write_bytes((stage/'manifest.json').read_bytes()+b'\n')
                elif kind=='asset-mode':(stage/'wall.png').chmod(0o640)
                elif kind=='folder-mode':stage.chmod(0o750)
                elif kind=='provenance':(stage/'PROVENANCE.md').write_text('Changed provenance\n')
                elif kind=='metadata':(stage/'metadata').write_text('Changed retained metadata\n')
                elif kind=='file-identity':
                    file=stage/'wall.png';data=file.read_bytes();file.rename(f.root/'retained-image');file.write_bytes(data);file.chmod(0o600)
                elif kind in ['folder-identity','rename','delete','link','file']:
                    moved=f.root/'retained-predecessor';stage.rename(moved)
                    if kind=='folder-identity':shutil.copytree(moved,stage);assert tree(stage)!=original
                    elif kind=='delete':shutil.rmtree(moved);moved=None
                    elif kind=='link':stage.symlink_to(moved,target_is_directory=True)
                    elif kind=='file':stage.write_text('Later regular file')
                elif kind in ['asset-link','hardlink']:
                    (stage/'wall.png').unlink()
                    if kind=='asset-link':(stage/'wall.png').symlink_to(sentinel)
                    else:os.link(sentinel,stage/'wall.png')
                elif kind in ['stage-parent','library-parent']:
                    replaced=stage.parent if kind=='stage-parent' else folder.parent
                    moved=f.root/'anchored-parent';replaced.rename(moved);shutil.copytree(moved,replaced)
                elif kind=='current-asset':image.write_bytes(life.WALLPAPER_B)
                elif kind=='current-manifest':
                    data=json.loads((folder/'manifest.json').read_text());data['title']='Later current edit';(folder/'manifest.json').write_text(json.dumps(data))
                elif kind=='current-extra':(folder/'later.txt').write_text('Later current data')
                elif kind=='current-identity':
                    moved=f.root/'published-original';folder.rename(moved);shutil.copytree(moved,folder)
                before=tree(folder.parent);movedBefore=tree(moved) if moved else None
                f.checkpoint('rollback-barrier')
                (f.root/'rollback-barrier-tree.json').write_text(json.dumps(dict(reference=reference,variant=kind,original=original,published=published,before=before,moved=movedBefore),indent=2))
                (f.root/'editor-go').touch();answer=future.result()
            assert f.effects()==effects and sentinel.read_bytes()==life.WALLPAPER_B
            message=answer['error']['message']
            if kind=='normal':
                assert tree(folder)==original and f.call('theme','show','user-a')['revision']==revision
                assert 'injected editor-published' in message
                assert tree(stage)==published
            else:
                assert tree(folder.parent)==before,(reference,kind,message)
                if moved:assert tree(moved)==movedBefore
                assert 'conflict' in message or 'substitution' in message,(kind,message)
                if not kind.startswith('current-'):assert image.read_bytes()==life.WALLPAPER_A
            f.checkpoint('rollback-after')
            (f.root/'rollback-result.json').write_text(json.dumps(dict(reference=reference,variant=kind,response=answer,after=tree(folder.parent),effectsUnchanged=f.effects()==effects),indent=2))
            # Restore pathname scaffolding only after preservation assertions; retain attacker objects as evidence.
            if replaced:
                replaced.rename(f.root/'substituted-parent');moved.rename(replaced)
            f.controls();f.stop();f.start();assert f.effects()==effects
            if kind=='normal':
                assert f.call('theme','show','user-a')['revision']==revision
                f.restore()
                if reference=='original':assert any(d['image']==str(image) for d in f.read_wall()['displays'])
                else:assert f.read_wall()==f.desktop
            f.stop()
    passed('rollback verifies complete predecessor bytes/encoding/provenance/metadata/modes and original folder/file identity; altered/missing/linked/type/parent substitutions refuse retaining exact recovery/current/later data and unchanged claims/effects; active and Restore-original images protected; normal rollback/restart/Restore succeeds')

    # An interruption never enters rollback; the whole new pack and predecessor stay recoverable.
    for kind in ['normal','asset']:
        f=fixture('ri');f.start();p=f.create(wallpapers=['wall.png'],images={'wall.png':life.WALLPAPER_A});f.apply('user-a')
        folder=f.root/'user-packs/user-a';revision=f.call('theme','show','user-a')['revision'];effects=f.effects()
        p['palette']['accent']='#314159';source=f.folder(p,'palette-only',{'wall.png':life.WALLPAPER_A})
        f.controls(editorHold='editor-published',crash='editor-published')
        with concurrent.futures.ThreadPoolExecutor(max_workers=1) as executor:
            future=executor.submit(f.call,'theme','edit','user-a',source,revision,ok=False);deadline=time.monotonic()+10
            while not (f.root/'editor-asked').exists() and time.monotonic()<deadline:time.sleep(.01)
            assert (f.root/'editor-asked').exists();stage=next((f.root/'user-packs').glob('.pilot-draft-*/user-a'))
            if kind=='asset':(stage/'wall.png').write_bytes(life.WALLPAPER_B)
            before=tree(folder.parent);(f.root/'editor-go').touch();future.result()
        f.stop(crashed=True);assert tree(folder.parent)==before and f.effects()==effects
        f.controls();f.start();assert tree(folder.parent)==before and f.effects()==effects
        assert (folder/'wall.png').read_bytes()==life.WALLPAPER_A;f.stop()
    passed('interrupted palette-only publication retains exact new pack and untouched/tampered predecessor evidence; restart never promotes recovery image bytes')

    for kind in ['asset','identity','parent']:
        f=fixture('rv');f.start();p=f.create(wallpapers=['wall.png'],images={'wall.png':life.WALLPAPER_A});f.apply('user-a')
        folder=f.root/'user-packs/user-a';revision=f.call('theme','show','user-a')['revision'];effects=f.effects()
        p['palette']['accent']='#314159';source=f.folder(p,'palette-only',{'wall.png':life.WALLPAPER_A})
        f.controls(editorHold='editor-restored',fail='editor-published')
        with concurrent.futures.ThreadPoolExecutor(max_workers=1) as executor:
            future=executor.submit(f.call,'theme','edit','user-a',source,revision,ok=False);deadline=time.monotonic()+10
            while not (f.root/'editor-asked').exists() and time.monotonic()<deadline:time.sleep(.01)
            assert (f.root/'editor-asked').exists();moved=None;replaced=None
            if kind=='asset':(folder/'wall.png').write_bytes(life.WALLPAPER_B)
            else:
                replaced=folder if kind=='identity' else folder.parent;moved=f.root/'restored-original';replaced.rename(moved);shutil.copytree(moved,replaced)
            before=tree(folder.parent);movedBefore=tree(moved) if moved else None
            (f.root/'editor-go').touch();answer=future.result()
        assert 'rollback verification conflict; recovery retained' in answer['error']['message']
        assert tree(folder.parent)==before and f.effects()==effects
        if moved:assert tree(moved)==movedBefore
        (f.root/'rollback-result.json').write_text(json.dumps(dict(variant='restored-'+kind,response=answer,tree=before,effectsUnchanged=True),indent=2))
        if replaced:replaced.rename(f.root/'substituted-restoration');moved.rename(replaced)
        f.controls();f.stop()
    passed('post-restoration content/identity/parent conflicts are reported as unverified rollback with exact later bytes and recovery retained; no cross-process CAS claim')
