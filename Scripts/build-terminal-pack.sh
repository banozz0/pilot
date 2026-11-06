#!/bin/zsh
# The terminal pack (T76 TD1, plan pilot-terminal-download): libghostty as a signed dylib that Pilot downloads on the first
# Hyper+T and loads with dlopen once its pinned SHA-256 and its signature check out (TerminalPack). Pilot.app carries none.
#   Scripts/build-terminal-pack.sh      after build-ghosttykit.sh; build-app.sh runs both
# Output: .build/terminal-pack/{libghostty.dylib,PilotTerminal-<sha8>.zip}, its last line the cache folder holding them, and Sources/Pilot/Terminal/TerminalPackPin.swift
# rewritten with the zip's byte count and SHA-256 and the dylib's SHA-256 (<sha8> is the dylib's), which Pilot's own
# signature covers. Commit the pin when it changes: Scripts/release.sh refuses a tree it changed.
# The same inputs give the same bytes. codesign's signing time and the zip's dates make every link a new hash, and a new
# hash is a new download for everyone, so a pack is built once per input set into <the repo's git common dir>/terminal-pack/<key>
# and copied from there afterwards; the key covers libghostty.a, both headers, the recipe below and the signing
# certificate's SHA-1. A cached pack is trusted no more than a fresh one: every run checks its signature against that
# certificate, its exports, and that the zip holds exactly that dylib, before anything is pinned or copied (T76 review).
set -euo pipefail
ROOT=${0:a:h:h}
ID=${SIGN_ID:-Pilot Release}
LIB=$ROOT/.build/ghosttykit/libghostty.a
HEADER=$ROOT/Sources/CGhostty/ghostty.h
API=$ROOT/Sources/CGhostty/ghostty-api.h  # the calls Pilot makes, the one list the exports and GhosttyAPI's dlsym table read
OUT=$ROOT/.build/terminal-pack
PIN=$ROOT/Sources/Pilot/Terminal/TerminalPackPin.swift
[[ -f $LIB ]] || { echo "error: no $LIB; run Scripts/build-ghosttykit.sh first" >&2; exit 1; }
[[ $ID != - ]] || { echo "error: the pack needs a certificate: Pilot checks it is signed by the certificate that signed Pilot" >&2; exit 1; }
# The certificate $ID signs with, by the SHA-1 of its DER as a requirement's certificate leaf = H"…" names it: certificate 0
# of a fresh signature of a scratch copy of /usr/bin/true, never of the cached pack. Self-signed, Apple Development and
# Developer ID identities alike. Learned once per identity name and kept beside the packs, so later runs sign nothing
# extra (each signature can ask the Keychain); a pack signed by another certificate of that name then fails its check below.
PACKS=$(git -C $ROOT rev-parse --path-format=absolute --git-common-dir)/terminal-pack
LEARNED=$PACKS/leaf-$(print -rn -- "$ID" | shasum -a 1 | cut -c1-12)
LEAF=$(cat $LEARNED 2>/dev/null || true)
if [[ ! $LEAF =~ '^[0-9a-f]{40}$' ]]; then
  PROBE=$(mktemp -d "${TMPDIR:-/tmp}/terminal-pack.XXXXXX")
  trap 'rm -rf "$PROBE"' EXIT
  cp /usr/bin/true $PROBE/leaf
  codesign --force --sign "$ID" $PROBE/leaf 2>/dev/null || { echo "error: \"$ID\" cannot sign; set SIGN_ID to the identity that signs Pilot" >&2; exit 1; }
  codesign -d --extract-certificates=$PROBE/cert $PROBE/leaf 2>/dev/null
  [[ -f $PROBE/cert0 ]] || { echo "error: \"$ID\"'s signature carries no certificate" >&2; exit 1; }
  LEAF=$(shasum -a 1 $PROBE/cert0 | cut -c1-40)
  mkdir -p $PACKS && print -r -- $LEAF >$LEARNED
fi
names=(${(f)"$(sed -nE 's/^typedef __typeof__\((ghostty_[a-z_]+)\) \*ghostty_[a-z_]+_fn;$/\1/p' $API)"})
(( ${#names} > 0 )) || { echo "error: no calls listed in $API" >&2; exit 1; }
# A static libghostty autolinks nothing: these are the system libraries and frameworks it calls (Package.swift's ghosttyLinks
# before T76), and Foundation, which Pilot itself brought in before.
LINKS=(-lc++ -lz)
for f in Foundation Carbon Metal QuartzCore CoreText IOSurface UniformTypeIdentifiers Security IOKit; do LINKS+=(-framework $f); done
# Only Pilot's calls are kept and exported: -u pulls each one's archive members in, -dead_strip drops the rest
# (11.6 MB, against 14 MB stripped for all 93 ghostty_* symbols; T75).
RECIPE="pack 1: arm64 macOS 26.0, -u and -exported_symbols_list per call, -dead_strip, strip -x, $LINKS, identifier dev.banozz.pilot.terminal"
REQUIREMENT="identifier \"dev.banozz.pilot.terminal\" and certificate leaf = H\"$LEAF\""
key=$({ shasum -a 256 $LIB $HEADER $API | cut -d' ' -f1; print -r -- "$RECIPE|$LEAF"; } | shasum -a 256 | cut -c1-16)
CACHE=$PACKS/$key

if [[ ! -f $CACHE/libghostty.dylib || -z $(print $CACHE/PilotTerminal-*.zip(N)) ]]; then
  WORK=$CACHE.part
  rm -rf $WORK && mkdir -p $WORK
  print -l _${^names} >$WORK/exports.txt
  xcrun clang -dynamiclib -arch arm64 -mmacosx-version-min=26.0 -install_name @rpath/libghostty.dylib \
    -Wl,-u,_${^names} -Wl,-exported_symbols_list,$WORK/exports.txt -Wl,-dead_strip $LIB $LINKS -o $WORK/libghostty.dylib
  strip -x $WORK/libghostty.dylib
  codesign --force --sign "$ID" --identifier dev.banozz.pilot.terminal $WORK/libghostty.dylib
  sha=$(shasum -a 256 $WORK/libghostty.dylib | cut -d' ' -f1)
  # The dylib alone at the zip's top level; no extended attributes or resource forks ride along (its signature is in it).
  ditto -c -k --norsrc --noextattr --noqtn --noacl $WORK/libghostty.dylib $WORK/PilotTerminal-${sha[1,8]}.zip
  rm -rf $CACHE && mv $WORK $CACHE
fi

# Every run, cached or just built: the checks Pilot makes, and the zip holding that dylib and nothing else.
dylib=$CACHE/libghostty.dylib
zips=($CACHE/PilotTerminal-*.zip(N))
(( ${#zips} == 1 )) || { echo "error: $CACHE holds ${#zips} zips; delete that folder" >&2; exit 1; }
zip=$zips[1]
codesign --verify --strict -R="$REQUIREMENT" $dylib \
  || { echo "error: $dylib is not dev.banozz.pilot.terminal signed by $LEAF; delete $CACHE" >&2; exit 1; }
exported=$(nm -gU $dylib | grep -c ' T _ghostty_' || true)
(( exported == ${#names} )) || { echo "error: the pack exports $exported calls, Pilot makes ${#names}; delete $CACHE" >&2; exit 1; }
dylib_sha=$(shasum -a 256 $dylib | cut -d' ' -f1)
[[ ${zip:t} == PilotTerminal-${dylib_sha[1,8]}.zip ]] || { echo "error: $zip is not named for its dylib; delete $CACHE" >&2; exit 1; }
[[ $(zipinfo -1 $zip) == libghostty.dylib ]] || { echo "error: $zip holds more or other than libghostty.dylib; delete $CACHE" >&2; exit 1; }
[[ $(unzip -p $zip libghostty.dylib | shasum -a 256 | cut -d' ' -f1) == $dylib_sha ]] \
  || { echo "error: the dylib in $zip is not $dylib; delete $CACHE" >&2; exit 1; }
zip_sha=$(shasum -a 256 $zip | cut -d' ' -f1)
rm -rf $OUT && mkdir -p $OUT
cp -c $dylib $zip $OUT/
pin="// Generated by Scripts/build-terminal-pack.sh from libghostty $(sed -nE 's/^TAG=\$\{GHOSTTY_TAG:-([^}]+)\}.*/\1/p' $ROOT/Scripts/build-ghosttykit.sh); never edit it by hand.
// The terminal pack this build of Pilot loads and no other (TerminalPack): Pilot's own signature covers these numbers.
// leaf, the SHA-1 of the certificate that signed it, is the tests'; Pilot checks a pack against its own certificate.
extension TerminalPack {
    static let pin = Pin(file: \"${zip:t}\", bytes: $(stat -f %z $zip), sha256: \"$zip_sha\",
                         dylibSHA256: \"$dylib_sha\", leaf: \"$LEAF\")
}"
# Written only when it changes, so an unchanged pack rebuilds nothing.
[[ -f $PIN && $(<$PIN) == "$pin" ]] || print -r -- "$pin" >$PIN
# Only this key's pack is kept: another key's (an older libghostty, recipe or certificate) and any half-built one go.
for old in $PACKS/*(N/); do [[ ${old:t} == $key ]] || rm -rf $old; done
echo "terminal pack ${zip:t}: $(( $(stat -f %z $dylib) / 1000 )) kB, zipped $(( $(stat -f %z $zip) / 1000 )) kB, ${#names} calls, signed by $LEAF"
echo "terminal pack cache: $CACHE"
