#!/usr/bin/env python3
"""Ask Pilot's skills, end to end, against a throwaway Pilot (a dev script, not a test target).

Each case runs the agent exactly as Ask Pilot does (AIChat.Agent.claudeArguments, AIChat.Agent.environment): claude -p
with the shell alone, allowed only for `pilot …`, through the app's own gate (Packaging/pilot-agent-shell), on the
bundle's prompt (Packaging/pilot-agent.md), skills and settings files off. A message that picks a skill carries its
steps as AISkill.message builds them; /extension runs the maker's profile (ExtensionMaker: the skill as the prompt, the
file tools, a fresh folder). A later turn resumes the session with the time first (AIChat.Request.text).

Where `pilot` points, never Sven's Pilot:
  sandbox  the SandboxHost on a private socket (Projects/Pilot/Sandbox E2E.md); each Allow is held and answered by
           this script (PILOT_SANDBOX_ALLOW_HOLD), yes unless the case says deny.
  theme    ThemeFixture (Scripts/theme-proof): Pilot's packs, fake screens, Ghostty, Zed, two Obsidian vaults and a
           home of detected apps, every effect recorded, never applied; its Allow answers from control.json.
The `pilot` first on the agent's PATH is a small wrapper round .build/debug/PilotCLI that logs each call with its
full size, and answers `not allowed` (as a Deny does) to verbs that would act on the real Mac in the sandbox.

  python3 Scripts/skills-test.py --list
  python3 Scripts/skills-test.py [--only id,id] [--skill theme] [--style blocks|plain|detailed|none] [--model <id>] [--out <dir>]

Needs `swift build --build-tests` first. Each case writes <out>/<case>/{stream.jsonl,calls.jsonl,allows.jsonl,
summary.json}; <out>/results.json collects them. Costs real usage on the signed-in Claude subscription.
"""
import argparse
import base64
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import threading
import time
import uuid

REPO = Path(__file__).resolve().parents[1]
PROMPT = REPO / 'Packaging/pilot-agent.md'  # --prompt replaces it (an older copy, for a before run)
CLI = REPO / '.build/debug/PilotCLI'
HOST = ['nice', '-n', '10', 'swift', 'test', '-j', '4', '--skip-build', '--filter', 'SandboxHost']

# Verbs that act on the Mac the sandbox runs on (AGENTS.md › Commands): answered as a Deny, never sent.
ACTING = [('run',), ('system',), ('wallpaper',), ('install',), ('files',), ('model',), ('permit',), ('ai',),
          ('wifi',), ('bluetooth',), ('bug',), ('open',), ('crash', '--reveal'), ('ext', 'run'), ('ext', 'publish'),
          ('theme', 'apply'), ('theme', 'restore'), ('clip', 'paste'), ('workspace', 'move'), ('workspace', 'rule'),
          ('snapshot', 'restore'), ('press',)]

WRAPPER = r'''#!/usr/bin/python3 -I
import json, os, subprocess, sys, time
words = sys.argv[1:]
log = os.environ['PILOT_SKILLS_LOG']
plain = [w for w in words if w != '--json']
blocked = os.environ.get('PILOT_SKILLS_BLOCK', '')
hit = None
for rule in json.loads(blocked or '[]'):
    if plain and plain[0] == rule[0] and all(word in plain[1:] for word in rule[1:]):
        hit = rule; break
env = dict(os.environ)
if os.environ.get('PILOT_SKILLS_SOCKET'): env['PILOT_SOCKET'] = os.environ['PILOT_SKILLS_SOCKET']
started = time.time()
if hit:
    out, err, code = '', 'not allowed: ' + ' '.join(['pilot'] + words) + '\n', 4
else:
    done = subprocess.run([os.environ['PILOT_SKILLS_CLI']] + words, env=env, capture_output=True, text=True)
    out, err, code = done.stdout, done.stderr, done.returncode
with open(log, 'a') as f:
    f.write(json.dumps(dict(argv=words, exit=code, stdout_bytes=len(out.encode()), stderr=err[-2000:], blocked=bool(hit),
                            seconds=round(time.time() - started, 2), stdout=out[:200000])) + '\n')
sys.stdout.write(out); sys.stderr.write(err); sys.exit(code)
'''

def answer_style(name):
    """AIChat.AnswerStyle.instructions, read from its Swift source so the harness never drifts from the app."""
    import re
    source = (REPO / 'Sources/PilotCore/AIChat.swift').read_text()
    body = source[source.index('public enum AnswerStyle'):]
    shared = re.search(r'let shared = (.*?)\n\s*switch self', body, re.S).group(1)
    shared = ''.join(re.findall(r'"((?:[^"\\]|\\.)*)"', shared))
    block = re.search(r'case \.%s:\n\s*return \"\"\"\n(.*?)\n\s*\"\"\"' % name, body, re.S).group(1)
    lines = [line[16:] if line.startswith(' ' * 16) else line.lstrip() for line in block.split('\n')]
    text = '\n'.join(lines).replace('\\\n', '').replace('\\(shared)', shared)
    return text.replace('\\"', '"')


def skill(name):
    """AISkill(text): the header's fields and the body."""
    text = (REPO / 'Packaging/skills' / name / 'SKILL.md').read_text()
    lines = text.split('\n')
    end = lines[1:].index('---') + 1
    fields = {}
    for line in lines[1:end]:
        if ':' in line:
            k, v = line.split(':', 1); v = v.strip()
            if len(v) >= 2 and v[0] == v[-1] == '"': v = v[1:-1]
            fields[k] = v
    return fields, '\n'.join(lines[end + 1:]).strip()


def skilled(message):
    """AIChat.Request.skilled: a message starting /<name> carries that skill's steps (not /extension, /widget)."""
    text = message.strip()
    for name in ['binds', 'preset', 'layouts', 'settings', 'explain', 'troubleshoot', 'catalogue', 'theme', 'publish']:
        command = '/' + name
        if text.lower().startswith(command) and (len(text) == len(command) or text[len(command)].isspace()):
            words = text[len(command):].strip()
            return (f"The user picked Pilot's {command} skill for this message. Follow its steps:\n\n{skill(name)[1]}\n\n"
                    f"The user's message:\n\n{words if words else '(none: start the job)'}")
    return message


def now_line():
    t = time.localtime()
    off = t.tm_gmtoff // 60
    return time.strftime('%A %-d %B %Y, %H:%M', t) + ' UTC%s%02d:%02d' % ('+' if off >= 0 else '-', abs(off) // 60, abs(off) % 60)


def claude_arguments(prompt, session, model, effort, files, style=None):
    """AIChat.Agent.claudeArguments, word for word."""
    tools = ['Bash'] + (['Read', 'Write', 'Edit'] if files else [])
    return (['-p', '--output-format', 'stream-json', '--verbose', '--include-partial-messages', '--tools', ','.join(tools),
             '--allowedTools', 'Bash(pilot *)'] + tools[1:] + ['--permission-mode', 'dontAsk', '--strict-mcp-config', '--restricted',
             '--safe-mode', '--append-system-prompt-file', str(prompt), '--effort', effort]
            + (['--append-system-prompt', style] if style else [])
            + (['--resume', session] if session else []) + (['--model', model] if model else []))


class Host:
    """A throwaway Pilot on a private socket."""

    def __init__(self, case, root):
        self.case, self.root = case, root
        self.allows = root / 'allows.jsonl'
        self.process = None
        self.env = {}
        self.block = ACTING

    def start(self, extra):
        env = {k: v for k, v in os.environ.items() if not k.startswith(('PILOT_', 'CFFIXED_'))}
        env.update(extra)
        self.log = (self.root / 'host.log').open('w')
        self.process = subprocess.Popen(HOST, cwd=REPO, env=env, stdout=self.log, stderr=subprocess.STDOUT)
        deadline = time.monotonic() + 240  # two hosts starting at once wait on SwiftPM's build lock
        while time.monotonic() < deadline:
            if Path(str(self.socket) + '.hold').exists(): return
            if self.process.poll() is not None: raise SystemExit(f'host exited {self.process.returncode}: {(self.root / "host.log").read_text()[-3000:]}')
            time.sleep(.2)
        raise SystemExit('host not ready')

    def stop(self):
        if self.process is None: return
        Path(str(self.socket) + '.hold').unlink(missing_ok=True)
        try: self.process.wait(timeout=40)
        except subprocess.TimeoutExpired: self.process.kill(); self.process.wait()
        self.log.close(); self.process = None

    def cli(self, *words):
        env = dict(self.agent_env(), PILOT_SKILLS_LOG=str(self.root / 'setup-calls.jsonl'))
        env.pop('PILOT_AGENT')
        return subprocess.run([str(self.helpers / 'pilot'), *words], env=env, capture_output=True, text=True, timeout=90)


class Sandbox(Host):
    def __init__(self, case, root):
        super().__init__(case, root)
        self.socket = root / 's'
        self.hold = root / 'allow'
        self.deny = case.get('allow') == 'deny'

    def start(self):
        super().start({'PILOT_SANDBOX': str(self.socket), 'PILOT_SANDBOX_ALLOW_HOLD': str(self.hold), **self.case.get('host', {})})
        self.answering = True
        threading.Thread(target=self.answer, daemon=True).start()

    def answer(self):
        n = 1
        while self.answering:
            asked = Path(f'{self.hold}.asked.{n}')
            if asked.exists():
                text = asked.read_text()
                with self.allows.open('a') as f: f.write(json.dumps(dict(n=n, asked=text, allowed=not self.deny)) + '\n')
                if not self.deny: Path(f'{self.hold}.go.{n}').write_text('')
                n += 1
            time.sleep(.2)

    def stop(self):
        self.answering = False
        super().stop()

    def agent_env(self):
        return {'PILOT_SKILLS_SOCKET': str(self.socket)}


class Theme(Host):
    """editor.Fixture (Pilot's own packs, fake screens and native appearance, cursors, Zed, two Obsidian vaults) plus a
    home of detected apps and a local catalogue copy."""

    def __init__(self, case, root):
        super().__init__(case, root)
        os.environ['PILOT_THEME_PROOF_EVIDENCE'] = str(root)
        sys.path.insert(0, str(REPO / 'Scripts/theme-proof'))
        import importlib.util
        spec = importlib.util.spec_from_file_location('theme_editor', REPO / 'Scripts/theme-proof/editor.py')
        editor = importlib.util.module_from_spec(spec); spec.loader.exec_module(editor)
        editor.life.EVIDENCE = root
        self.f = f = editor.Fixture('t')
        home = f.root / 'home'
        support = home / 'Library/Application Support'
        for folder, name, text in [(support / 'Code/User', 'settings.json', '{\n  "editor.fontSize": 14\n}\n'),
                                   (home / '.config/kitty', 'kitty.conf', '# mine\nfont_size 13\n'),
                                   (home / '.config/btop', 'btop.conf', 'color_theme = "Default"\n'),
                                   (home / '.config/ghostex', 'settings.json', '{}\n')]:
            folder.mkdir(parents=True, exist_ok=True); (folder / name).write_text(text)
        f.settings['detectHome'] = str(home)
        (f.root / 'catalogue/themes').mkdir(parents=True)
        shutil.copy2(REPO / 'catalogue/index.json', f.root / 'catalogue/index.json')
        for name in ['akane', 'tokyo-night']:
            if (REPO / 'catalogue/themes' / name).is_dir(): shutil.copytree(REPO / 'catalogue/themes' / name, f.root / 'catalogue/themes' / name)
        f.settings['catalogue'] = str(f.root / 'catalogue')
        f.manifest.write_text(json.dumps(f.settings))
        f.controls(allow='no' if case.get('allow') == 'deny' else 'yes', reloadAllow='yes')
        self.socket = f.socket
        self.block = [r for r in ACTING if r not in [('theme', 'apply'), ('theme', 'restore')]]

    def start(self):
        super().start({'PILOT_THEME_FIXTURE': str(self.f.manifest)})

    def stop(self):
        super().stop()
        asked = [line[len('THEME Allow asked: '):] for line in (self.root / 'host.log').read_text().splitlines() if line.startswith('THEME Allow asked: ')]
        with self.allows.open('a') as f:
            for n, text in enumerate(asked, 1): f.write(json.dumps(dict(n=n, asked=text, allowed=self.case.get('allow') != 'deny')) + '\n')

    def agent_env(self):
        return {'PILOT_THEME_FIXTURE': str(self.f.manifest), 'PILOT_SOCKET': str(self.f.socket)}


def run_case(case, out, model, effort, style):
    root = out / case['id']
    shutil.rmtree(root, ignore_errors=True); root.mkdir(parents=True)
    host = (Theme if case['mode'] == 'theme' else Sandbox)(case, root)
    helpers = root / 'helpers'; helpers.mkdir()
    shutil.copy2(REPO / 'Packaging/pilot-agent-shell', helpers / 'pilot-agent-shell')
    (helpers / 'pilot').write_text(WRAPPER); (helpers / 'pilot').chmod(0o755)
    host.helpers = helpers
    claude = shutil.which('claude')
    maker = case['turns'][0].startswith('/extension')
    prompt = REPO / 'Packaging/skills/extension/SKILL.md' if maker else Path(PROMPT)
    work = root / ('ext-folder' if maker else 'cli'); work.mkdir()
    base = {k: v for k, v in os.environ.items() if k in ['HOME', 'USER', 'TMPDIR', 'LANG']}
    env = dict(base, PILOT_AGENT='1', PATH=f'{helpers}:{Path(claude).parent}:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin',
               SHELL='/bin/zsh', ZDOTDIR=str(helpers), CLAUDE_CODE_SHELL_PREFIX=str(helpers / 'pilot-agent-shell'),
               PILOT_SKILLS_LOG=str(root / 'calls.jsonl'), PILOT_SKILLS_CLI=str(CLI), PILOT_SKILLS_BLOCK=json.dumps([list(r) for r in host.block]))
    host.agent_env_full = env
    host.agent_env = (lambda inner: (lambda: dict(env, **inner())))(host.agent_env)
    env = host.agent_env()
    # {root}: the folder the case's own files go in (the theme fixture's root, which every theme path must be inside).
    place = host.f.root if case['mode'] == 'theme' else root
    fill = lambda text: text.replace('{root}', str(place))
    png = base64.b64decode('iVBORw0KGgoAAAANSUhEUgAAAAIAAAABCAIAAAB7QOjdAAAADUlEQVR42mOQdEwBIgAEowF9QIvmEgAAAABJRU5ErkJggg==')
    for name in case.get('pictures', []):
        (place / 'pictures').mkdir(exist_ok=True); (place / 'pictures' / name).write_bytes(png)
    prep = [[fill(w) for w in words] for words in case.get('prep', [])]
    if case.get('catalogue'):
        shutil.copytree(REPO / 'catalogue', root / 'catalogue')
        prep.insert(0, ['set', 'catalogue.source', str(root / 'catalogue')])
    if case['id'].startswith('publish-ext'):
        subprocess.run(['git', 'clone', '-q', '--local', str(REPO), str(root / 'clone')], check=True)
    try: host.start()
    except BaseException: host.stop(); raise
    summary = dict(id=case['id'], skill=case['skill'], mode=case['mode'], turns=[], style=style[:60] if style else None)
    try:
        for words in prep:
            done = host.cli(*words)
            with (root / 'prep.log').open('a') as f: f.write(f'$ pilot {" ".join(words)}\n{done.returncode} {done.stdout}{done.stderr}\n')
        session = None
        for i, message in enumerate(fill(t) for t in case['turns']):
            text = message if maker else skilled(message)
            if session: text = f'({now_line()})\n\n{text}'
            args = [claude] + claude_arguments(prompt, None if maker else session, model, effort, maker, style)
            started = time.time()
            with (root / f'stream-{i}.jsonl').open('w') as stream:
                done = subprocess.run(args, input=text, env=env, cwd=work, stdout=stream, stderr=subprocess.PIPE, text=True, timeout=900)
            turn = dict(message=message, seconds=round(time.time() - started), exit=done.returncode, stderr=done.stderr[-2000:], calls=[], answer=None)
            for line in (root / f'stream-{i}.jsonl').read_text().splitlines():
                try: o = json.loads(line)
                except json.JSONDecodeError: continue
                if o.get('type') == 'system' and o.get('subtype') == 'init': turn['model'] = o.get('model')
                if o.get('type') == 'assistant':
                    for b in o['message'].get('content', []):
                        if b.get('type') == 'tool_use': turn['calls'].append(dict(id=b['id'], command=b['input'].get('command') or b['name'] + ' ' + str(b['input'].get('file_path', ''))))
                if o.get('type') == 'user':
                    for b in (o.get('message') or {}).get('content', []) if isinstance((o.get('message') or {}).get('content'), list) else []:
                        if b.get('type') == 'tool_result':
                            c = b.get('content'); c = c if isinstance(c, str) else '\n'.join(x.get('text', '') for x in c or [])
                            for call in turn['calls']:
                                if call['id'] == b['tool_use_id']: call.update(shown_chars=len(c), error=b.get('is_error', False), shown=c[:600])
                if o.get('type') == 'result':
                    turn.update(answer=o.get('result'), cost=o.get('total_cost_usd'), num_turns=o.get('num_turns'), is_error=o.get('is_error'))
                    session = o.get('session_id') or session
            summary['turns'].append(turn)
            print(f"  turn {i}: {turn['seconds']}s, {len(turn['calls'])} calls, ${turn.get('cost') or 0:.3f}", flush=True)
    finally:
        host.stop()
    calls = [json.loads(l) for l in (root / 'calls.jsonl').read_text().splitlines()] if (root / 'calls.jsonl').exists() else []
    summary['pilot_calls'] = [dict(argv=c['argv'], exit=c['exit'], bytes=c['stdout_bytes'], blocked=c['blocked'], stderr=c['stderr'][:300]) for c in calls]
    summary['allows'] = [json.loads(l) for l in host.allows.read_text().splitlines()] if host.allows.exists() else []
    summary['cost'] = round(sum(t.get('cost') or 0 for t in summary['turns']), 4)
    summary['model'] = next((t.get('model') for t in summary['turns'] if t.get('model')), None)
    (root / 'summary.json').write_text(json.dumps(summary, indent=2))
    return summary


def main():
    p = argparse.ArgumentParser()
    p.add_argument('--cases', default=str(Path(__file__).with_name('skills-test-cases.json')))
    p.add_argument('--only'); p.add_argument('--skill'); p.add_argument('--list', action='store_true')
    p.add_argument('--model'); p.add_argument('--effort', default='low')
    p.add_argument('--style', choices=['blocks', 'plain', 'detailed', 'none'], default='blocks',
                   help="the Answer style the app passes (ai.answerStyle); none is the app before the setting")
    p.add_argument('--out', default=str(REPO / '.build/sb/skills'))
    p.add_argument('--prompt', help="the agent's prompt in place of Packaging/pilot-agent.md (git show origin/main:… for a before run)")
    a = p.parse_args()
    cases = json.loads(Path(a.cases).read_text())
    if a.list:
        for c in cases: print(f"{c['id']:24} {c['mode']:8} {c['turns'][0][:90]}")
        return
    if a.only: cases = [c for c in cases if c['id'] in a.only.split(',')]
    if a.skill: cases = [c for c in cases if c['skill'] == a.skill]
    assert CLI.exists(), 'swift build --build-tests first'
    out = Path(a.out).resolve(); out.mkdir(parents=True, exist_ok=True)
    style = None if a.style == 'none' else answer_style(a.style)
    global PROMPT
    if a.prompt: PROMPT = Path(a.prompt).resolve()
    results_file = out / 'results.json'
    results = json.loads(results_file.read_text()) if results_file.exists() else {}
    for case in cases:
        print(f"{case['id']}: {case['turns'][0]}", flush=True)
        results[case['id']] = run_case(case, out, a.model, a.effort, style)
        results_file.write_text(json.dumps(results, indent=2))
    print(f"total ${sum(r['cost'] for r in results.values()):.3f} over {len(results)} cases; {results_file}")


if __name__ == '__main__':
    main()
