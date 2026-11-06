#!/bin/zsh
# A release a stranger downloads (SH4, notes §9): the signed release build in a DMG, the DMG signed, and its checksum.
#   Scripts/release.sh <version>     e.g. 0.2.0; writes build/Pilot-<version>.dmg, its .sha256, a copy as build/Pilot.dmg, build/updates/appcast.xml
#                                    and the terminal pack, build/PilotTerminal-<sha8>.zip (T76)
# No notarization or staple (Q318): spctl rejects the DMG and the app, and the first launch goes through Open Anyway.
# It never publishes, uploads or tags anything: putting the files on a release page is Sven's call.
# Sparkle's public key (SH5, SH6) is Pilot's own, printed by generate_keys on 2026-10-19, kept in Packaging/sparkle-public-key.txt (the
# commit guard reads a key in a script line as a credential, Q545); SPARKLE_ED_KEY overrides it. Of build-app.sh's inputs, PILOT_DEV, SPARKLE_FEED and
# CONFIG are pinned, so an exported one never ships a placeholder key, a test feed or a debug build; the GhosttyKit build's
# (GHOSTTY_TAG, GHOSTTYKIT_WORK, ZIG, GHOSTTY_LIB_DIR) still pass through.
# RELEASE_ANY_BRANCH=1 skips the main-branch check, for testing this script in a detached worktree only.
set -euo pipefail
ROOT=${0:a:h:h}
VERSION=${1:?usage: Scripts/release.sh <version>}
OUT=$ROOT/build
DMG=$OUT/Pilot-$VERSION.dmg
ID=${SIGN_ID:-Pilot Release}
[[ $VERSION =~ '^[0-9]+\.[0-9]+(\.[0-9]+)?$' ]] || { echo "error: $VERSION is not a version like 0.2.0" >&2; exit 1; }
export SPARKLE_ED_KEY=${SPARKLE_ED_KEY:-$(<"$ROOT/Packaging/sparkle-public-key.txt")}
# Checked before minutes of building. Main and a clean tree: the DMG holds exactly a commit on main, and PilotCommit
# names it. Not shallow: CFBundleVersion is git rev-list --count HEAD, which a shallow clone counts from 1 (Moody, SH3).
if [[ ${RELEASE_ANY_BRANCH:-} != 1 && $(git -C "$ROOT" symbolic-ref --quiet --short HEAD) != main ]]; then
  echo "error: not on main; a release is built from main" >&2; exit 1
fi
if [[ -n $(git -C "$ROOT" status --porcelain) ]]; then
  echo "error: the tree has uncommitted changes; a release is built from a commit:" >&2; git -C "$ROOT" status --short >&2; exit 1
fi
if [[ $(git -C "$ROOT" rev-parse --is-shallow-repository) == true ]]; then
  echo "error: shallow clone; its build number would be wrong (git fetch --unshallow)" >&2; exit 1
fi
command -v dmgbuild >/dev/null || { echo "error: dmgbuild is missing; install it with: uv tool install dmgbuild" >&2; exit 1; }

env -u PILOT_DEV -u SPARKLE_FEED CONFIG=release PILOT_VERSION=$VERSION SIGN_ID=$ID "$ROOT/Scripts/build-app.sh"
APP=$OUT/Pilot.app
[[ $(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$APP/Contents/Info.plist") == $VERSION ]] \
  || { echo "error: build-app.sh did not set version $VERSION" >&2; exit 1; }

# The terminal pack (T76), checked before the DMG: each Pilot fetches releases/download/v<its version>/<its pin's file>,
# never latest, so every release carries the pack its Pilot pins, an unchanged one copied forward with its hash
# (build-terminal-pack.sh's cache). A pin the build had to rewrite is not in the commit this release names: commit it and
# release again. Only the pin is checked: the lean ratchet may lower a budget in this same build (Scripts/lean-budgets.json).
# A release fetches from its release page alone: the build-folder URL a build of Sven's own carries must be absent.
PIN=$ROOT/Sources/Pilot/Terminal/TerminalPackPin.swift
git -C "$ROOT" diff --quiet HEAD -- "$PIN" || { echo "error: the build wrote a new terminal pack pin; commit $PIN and release again" >&2; exit 1; }
PACK=$OUT/$(sed -nE 's/.*file: "([^"]+)".*/\1/p' "$PIN")
[[ -f $PACK && $(shasum -a 256 "$PACK" | cut -d' ' -f1) == $(sed -nE 's/.* sha256: "([0-9a-f]+)".*/\1/p' "$PIN") ]] \
  || { echo "error: $PACK is missing or does not match the pin Pilot was built with" >&2; exit 1; }
if /usr/libexec/PlistBuddy -c "Print :PilotTerminalURL" "$APP/Contents/Info.plist" >/dev/null 2>&1; then
  echo "error: the bundle names a PilotTerminalURL; a release fetches its terminal from its release page" >&2; exit 1
fi

# The DMG: the app and a link to Applications to drag it onto, in the install window drawn in Packaging/dmg (SH24).
# dmgbuild lays that window out without Finder (Scripts/dmg-settings.py) and copies the app with ditto, which keeps the
# extended attributes that hold pilot-agent-shell's signature (a script signs into xattrs, notes §1).
STAGE=$(mktemp -d "${TMPDIR:-/tmp}/pilot-release.XXXXXX")
MNT=$STAGE/mnt
trap '[[ -d $MNT ]] && hdiutil detach -quiet "$MNT" 2>/dev/null; rm -rf "$STAGE"' EXIT
dmgbuild -s "$ROOT/Scripts/dmg-settings.py" -D app="$APP" -D root="$ROOT" Pilot "$DMG" >"$STAGE/dmgbuild.log" 2>&1 \
  || { cat "$STAGE/dmgbuild.log" >&2; exit 1; }
codesign --force --sign "$ID" --identifier dev.banozz.pilot.dmg "$DMG"

# Checked as a stranger gets it: the image is whole, and the app inside still verifies with every helper's signature.
hdiutil verify -quiet "$DMG"
codesign --verify --strict "$DMG"
mkdir "$MNT"
hdiutil attach -quiet -readonly -nobrowse -noautoopen -mountpoint "$MNT" "$DMG"
codesign --verify --strict --deep "$MNT/Pilot.app"
hdiutil detach -quiet "$MNT" && rmdir "$MNT"

# shasum -a 256 -c Pilot-<version>.dmg.sha256, run beside the download, checks it.
(cd "$OUT" && shasum -a 256 "${DMG:t}" >"${DMG:t}.sha256")
echo "released $DMG ($(du -h "$DMG" | cut -f1), signed: $ID, build $(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" "$APP/Contents/Info.plist"))"
echo "checksum $DMG.sha256"
# The site's Download button asks for releases/latest/download/Pilot.dmg (SH13): attach this copy and its checksum too.
cp "$DMG" "$OUT/Pilot.dmg"
(cd "$OUT" && shasum -a 256 Pilot.dmg >Pilot.dmg.sha256)
echo "unversioned $OUT/Pilot.dmg and Pilot.dmg.sha256"

# The appcast (SH7): generate_appcast signs the DMG with Sparkle's private key from the login Keychain (SH5) and writes
# its item, sparkle:version from CFBundleVersion and sparkle:minimumSystemVersion from LSMinimumSystemVersion (27.0).
# The feed is releases/latest's appcast.xml (Q431), so it lists this release alone: build/updates starts empty each
# time, since an earlier DMG or appcast.xml there would become an item under this tag's URL, and the unversioned
# Pilot.dmg would be a second archive of one build, which generate_appcast refuses.
UPDATES=$OUT/updates
rm -rf "$UPDATES" && mkdir "$UPDATES"
cp "$DMG" "$UPDATES/"
"$ROOT/.build/artifacts/sparkle/Sparkle/bin/generate_appcast" \
  --download-url-prefix "https://github.com/banozz0/pilot/releases/download/v$VERSION/" "$UPDATES"
# A Keychain key that is not SUPublicEDKey's only warns and leaves the item unsigned, which every Pilot refuses.
grep -q 'sparkle:edSignature=' "$UPDATES/appcast.xml" \
  || { echo "error: the appcast item is unsigned; the Keychain's Sparkle key does not match SPARKLE_ED_KEY" >&2; exit 1; }
echo "appcast $UPDATES/appcast.xml (attach it to the v$VERSION release with the DMG)"

echo "terminal pack $PACK (attach it to the v$VERSION release with the DMG)"
