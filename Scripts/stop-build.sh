#!/bin/zsh
# Claude Code's Stop hook (.claude/settings.json): swift build only when a build input changed since the last good build.
# Inputs are every non-test target's files: Package.swift, Package.resolved, Sources/, Tests/Fixtures/ (HungAppFixture).
# A failed build writes no stamp, so it is built and reported again next turn. Each run logs one line to .build/stop-build.log.
cd "$CLAUDE_PROJECT_DIR" && [[ -d .build/ghosttykit ]] || exit 0
setopt pipe_fail
export LC_ALL=C
stamp=.build/stop-build.stamp
note() { print -r -- "$(/bin/date '+%Y-%m-%dT%H:%M:%S') $1 ${sum:0:12}" >> .build/stop-build.log }

# Any doubt builds: a hash that fails or comes out empty never matches the stamp.
sum=$(/usr/bin/find Package.swift Package.resolved Sources Tests/Fixtures -type f -print0 | /usr/bin/sort -z \
  | /usr/bin/xargs -0 /usr/bin/shasum -a 256 | /usr/bin/shasum -a 256) || sum=
sum=${sum%% *}
if [[ -n $sum && -r $stamp && "$(<$stamp)" == "$sum" ]]; then note skip; exit 0; fi

start=$SECONDS
if out=$(NO_COLOR=1 /usr/bin/nice -n 10 swift build -j 4 2>&1); then
  [[ -n $sum ]] && print -r -- $sum > $stamp.tmp && /bin/mv -f $stamp.tmp $stamp
  note "build ok $((SECONDS - start))s"
  exit 0
fi
note "build FAILED $((SECONDS - start))s"
{ echo 'Stop check: swift build failed. Fix it before the turn ends.'; printf '%s\n' "$out" | /usr/bin/grep -m 20 ': error:' || printf '%s\n' "$out" | /usr/bin/tail -20; } >&2
exit 2
