#!/usr/bin/env python3
"""External proof dispatcher. Unknown cases fail; each adapter supplies its own public-boundary proof."""
import argparse
import hashlib
import json
import os
import subprocess
import sys
sys.dont_write_bytecode = True
import importlib.util
from pathlib import Path

CASES = ('lifecycle', 'zed', 'obsidian', 'packs', 'editor', 'strip', 'islands', 'custom', 'agents', 'matrix', 'apps', 'carousel', 'dropdown', 'pill')
parser = argparse.ArgumentParser()
parser.add_argument('--case', required=True, choices=[*CASES, 'all'])
parser.add_argument('--seam-only', action='store_true')
parser.add_argument('--fixes-only', action='store_true')
args = parser.parse_args()
directory = Path(__file__).with_name('theme-proof')
if {p.stem for p in directory.glob('*.py')} != set(CASES):
    parser.error('declared cases and proof files differ; every case must be registered and present')
if args.case == 'all':
    if args.seam_only or args.fixes_only:
        parser.error('--case all requires complete cases; subset flags are unsupported')
    if os.environ.get('PILOT_STRIP_FIX_CASE') or os.environ.get('PILOT_THEME_REVIEWED_SOURCE'):
        parser.error('--case all requires the complete local source proof, without case/source overrides')
    evidence = Path(os.environ.get('PILOT_THEME_PROOF_EVIDENCE') or Path.home() / '.local/state/spec' / 'theme-system/T11/p')
    evidence.mkdir(parents=True, exist_ok=True)
    repo = directory.parent.parent
    inputs = [Path(__file__), *sorted(directory.glob('*.py')),
              *sorted((repo / 'Sources').rglob('*.swift')),
              *sorted((repo / 'Tests').rglob('*.swift')),
              repo / 'Package.swift', repo / 'Package.resolved', repo / 'Packaging/themes.json',
              *sorted(p for p in (repo / 'Packaging/ThemePacks').rglob('*') if p.is_file()),
              *sorted(p for p in (repo / 'catalogue/themes').rglob('*') if p.is_file()), repo / 'catalogue/index.json',
              *sorted(p for p in (repo / 'Packaging/skills').rglob('*') if p.is_file()),
              repo / 'Packaging/pilot-agent.md', repo / 'Packaging/pilot-agent-shell',
              repo / '.build/debug/PilotCLI', repo / '.build/debug/PilotMCP',
              repo / '.build/debug/PilotTests.xctest/Contents/MacOS/PilotTests']
    def hashes():
        return {str(p.relative_to(repo)): hashlib.sha256(p.read_bytes()).hexdigest() for p in inputs}
    manifest = dict(cases=list(CASES), inputs=hashes(), results=[])
    def record():
        (evidence / 'all.json').write_text(json.dumps(manifest, indent=2) + '\n')
    record()
    for case in CASES:
        target = evidence / case
        target.mkdir(exist_ok=True)
        command = [sys.executable, str(Path(__file__).resolve()), '--case', case]
        with (target / 'command.log').open('w') as log:
            result = subprocess.run(command, env=dict(os.environ, PILOT_THEME_PROOF_EVIDENCE=str(target)),
                                    cwd=repo, stdout=log, stderr=subprocess.STDOUT)
        manifest['results'].append(dict(case=case, command=command, exit=result.returncode, evidence=str(target)))
        record()
        print(f'{case}: exit {result.returncode}', flush=True)
    manifest['inputsUnchanged'] = hashes() == manifest['inputs']
    manifest['success'] = manifest['inputsUnchanged'] and all(r['exit'] == 0 for r in manifest['results'])
    record()
    sys.exit(0 if manifest['success'] else 1)
source = directory / (args.case + '.py')
spec = importlib.util.spec_from_file_location('theme_case', source)
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
module.run(seam_only=args.seam_only, fixes_only=args.fixes_only)
if not args.seam_only and not args.fixes_only:
    if args.case == 'custom':
        module.run_fixes()
    elif args.case == 'strip':
        module.preservation_fixes()
        module.final_preservation()
