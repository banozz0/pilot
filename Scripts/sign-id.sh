#!/bin/zsh
# The identity that signs Pilot, printed for build-app.sh, build-terminal-pack.sh and release.sh, so all three sign alike
# (Sven, 2026-11-14, Q225: test builds sign as releases do). SIGN_ID when set; else the keychain's one "Developer ID
# Application" identity, found by find-identity so no name is written in the repo; else the self-signed "Pilot Release".
# Several Developer ID identities stop it: SIGN_ID names the one that signs Pilot.
set -euo pipefail
if [[ -n ${SIGN_ID:-} ]]; then print -r -- "$SIGN_ID"; exit 0; fi
ids=(${(f)"$(security find-identity -v -p codesigning 2>/dev/null | sed -nE 's/.*"(Developer ID Application: [^"]+)".*/\1/p' | sort -u)"})
(( ${#ids} <= 1 )) || { echo "error: ${#ids} Developer ID Application identities in the keychain; set SIGN_ID to the one that signs Pilot" >&2; exit 1; }
print -r -- "${ids[1]:-Pilot Release}"
