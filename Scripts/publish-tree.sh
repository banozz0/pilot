#!/bin/zsh
# The public tree (SH9; Sven, Q321: a new public repo, one commit, from the code of the day): every file of HEAD but the
# private ones, written into a new folder and checked there: gitleaks over the folder, then a grep for Sven's address,
# his home folder and links to the private repo. It never creates a repository, adds a remote or pushes: publishing the
# folder is Sven's call.
#   Scripts/publish-tree.sh <new or empty folder> [<commit or tree>]    (HEAD when left out)
set -euo pipefail
ROOT=${0:a:h:h}
OUT=${1:?usage: Scripts/publish-tree.sh <new or empty folder> [<commit or tree>]}
REV=${2:-HEAD}
# Private: the agent brief and its CLAUDE.md symlink (vault paths, board ids, thread rules), Claude Code's project settings
# and its Xcode MCP bridge.
PRIVATE=(AGENTS.md CLAUDE.md .claude .mcp.json)
# Lines the grep lets through, path and text: Pilot's Send feedback opens the public repo's issue form, and the site's
# pages link the repo, its releases and its issues, and Sparkle's feed and release.sh's download links name its releases (Q431); the public repo is banozz0/pilot once today's is renamed (Q324).
# They are printed on every run.
ALLOWED=('Sources/PilotCore/Feedback.swift:.*github.com/banozz0/pilot/issues/new'
         'Tests/PilotCoreTests/FeedbackTests.swift:.*banozz0/pilot'
         'site/[a-z]+\.html:.*github.com/banozz0/pilot'
         'Packaging/Info.plist:.*github.com/banozz0/pilot/releases/'
         'Scripts/release.sh:.*github.com/banozz0/pilot/releases/')
PATTERN='svenmedina|/Users/sven([^[:alnum:]_]|$)|banozz0/pilot([^-[:alnum:]_]|$)'

git -C "$ROOT" rev-parse --verify --quiet "$REV^{tree}" >/dev/null || { echo "error: $REV is no commit or tree" >&2; exit 1; }
if [[ -e $OUT && -n $(ls -A "$OUT") ]]; then echo "error: $OUT is not empty" >&2; exit 1; fi
command -v gitleaks >/dev/null || { echo "error: gitleaks is not installed (brew install gitleaks)" >&2; exit 1; }
mkdir -p "$OUT"
OUT=${OUT:A}
git -C "$ROOT" archive --format=tar "$REV" -- . ${PRIVATE/#/:(exclude)} | tar -x -C "$OUT"
for p in $PRIVATE; do [[ ! -e $OUT/$p && ! -L $OUT/$p ]] || { echo "error: $p is in the tree" >&2; exit 1; }; done
# README's file map lists the private files too: their rows, and .claude/'s one child, leave with them.
[[ -f $OUT/README.md ]] && perl -0pi -e 's/^├── \.claude\/[^\n]*\n(?:│   [^\n]*\n)*//m; s/^├── (?:\.mcp\.json|AGENTS\.md|CLAUDE\.md)\b[^\n]*\n//mg' "$OUT/README.md"

echo "public tree: $OUT"
echo "  from: $REV ($(git -C "$ROOT" rev-parse --short "$REV"))"
echo "  files: $(find "$OUT" -type f -o -type l | wc -l | tr -d ' '), $(du -sh "$OUT" | cut -f1)"
echo "  left out: ${(j:, :)PRIVATE}"
failed=0

report=$(mktemp -t publish-tree-gitleaks)
if (cd "$OUT" && gitleaks dir . --no-banner --redact --log-level error --report-format json --report-path "$report"); then
  echo "  gitleaks $(gitleaks version) dir mode: no leaks"
else
  echo "  gitleaks $(gitleaks version) dir mode: LEAKS"
  python3 -I -c 'import json,sys; [print("    %s:%s %s" % (f["File"], f["StartLine"], f["RuleID"])) for f in json.load(open(sys.argv[1]))]' "$report"
  failed=1
fi
rm -f "$report"

# This script names what it looks for, so it is left out of its own grep.
hits=$(cd "$OUT" && grep -rInE --exclude=publish-tree.sh "$PATTERN" . | sed 's|^\./||' || true)
allowed=$(print -r -- "$hits" | grep -E "^(${(j:|:)ALLOWED})" || true)
bad=$(print -r -- "$hits" | grep -vE "^(${(j:|:)ALLOWED})" | grep . || true)
if [[ -n $bad ]]; then
  echo "  grep (svenmedina, /Users/sven, banozz0/pilot): $(print -r -- "$bad" | wc -l | tr -d ' ') hits"
  print -r -- "$bad" | cut -c1-160 | sed 's/^/    /'
  failed=1
else
  echo "  grep (svenmedina, /Users/sven, banozz0/pilot): no hits"
fi
[[ -z $allowed ]] || { echo "  allowed:"; print -r -- "$allowed" | cut -c1-160 | sed 's/^/    /'; }

if (( failed )); then echo "NOT CLEAN"; exit 1; fi
echo "clean: no repository, remote or push was made"
