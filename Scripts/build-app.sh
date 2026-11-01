#!/bin/zsh
# Builds Pilot.app into build/ and signs it. TCC trusts a signed bundle, never a bare binary (ADR 0001).
#   Scripts/build-app.sh            release build, signed with the self-signed "Pilot Release" certificate
#   SIGN_ID="<identity>" Scripts/build-app.sh   another identity; SIGN_ID=- signs ad hoc
#   CONFIG=debug Scripts/build-app.sh
#   SPARKLE_ED_KEY=<generate_keys -p> Scripts/build-app.sh   a release that updates through Sparkle (SH6), naming no checkout
#   SPARKLE_FEED=<appcast url>        another appcast than Info.plist's SUFeedURL, for a test feed
#   PILOT_DEV=1 Scripts/build-app.sh  a release with no key and no updates, Sven's own (run.sh sets it); only
#                                     CONFIG=debug counts the checkout's commits (Q331)
set -euo pipefail
ROOT=${0:a:h:h}
CONFIG=${CONFIG:-release}
APP="$ROOT/build/Pilot.app"
cd "$ROOT"
# One certificate signs every build, debug and release (SH3, notes §9): its designated requirement is the certificate's
# hash, so TCC keeps Pilot's grants from build to build and no name or email is in it. No fallback to another identity:
# a different signature would drop every grant. Checked first, before minutes of building.
ID=${SIGN_ID:-Pilot Release}
if [[ $ID != - ]] && ! security find-identity -v -p codesigning 2>/dev/null | grep -qF "\"$ID\""; then
  echo "no \"$ID\" code-signing identity in the keychain; set SIGN_ID to yours, or SIGN_ID=- for ad hoc (TCC asks again after every build)" >&2; exit 1
fi
# A release without Sparkle's key has no updates at all, so it needs the key or PILOT_DEV=1. The key is checked
# as PilotUpdates.isKey checks it (Foundation's base64 of 32 bytes), before anything builds.
if [[ -n ${SPARKLE_ED_KEY:-} ]]; then
  if [[ ! $SPARKLE_ED_KEY =~ '^[A-Za-z0-9+/]{43}=$' ]]; then echo "SPARKLE_ED_KEY is not generate_keys -p's public key (base64 of 32 bytes)" >&2; exit 1; fi
elif [[ $CONFIG == release && ${PILOT_DEV:-} != 1 ]]; then
  echo "a release build needs SPARKLE_ED_KEY (Sparkle updates) or PILOT_DEV=1 (a build of Sven's own, with no updates)" >&2; exit 1
fi
# Pilot and the PilotWebApp template. Release optimises for size (story 142): the main program is about a fifth smaller,
# and the launcher's fuzzy rank and the tap's layer decision timed the same as -O within a few nanoseconds a key. Passed
# here, not as Package.swift unsafeFlags: those left __text 3.4 MB bigger (25.3 against 21.9 MB, 2026-10-09). A release's
# programs export no symbols: nothing loads into them or looks one up by name (their dlsym calls are into system
# frameworks), and the export trie was 0.58 MB of the main program (2026-10-23).
SWIFTFLAGS=(); [[ $CONFIG == release ]] && SWIFTFLAGS=(-Xswiftc -Osize -Xlinker -no_exported_symbols)
# The terminal drop's libghostty, Sentry off (T11): seconds once built for this Mac, about 5 to 10 minutes the first time.
"$ROOT/Scripts/build-ghosttykit.sh"
swift build -c "$CONFIG" $SWIFTFLAGS
# The menu's file index (FileIndex), Cardinal's engine on stable Rust; release always, a debug walk is ten times slower.
cargo build --release --quiet --manifest-path "$ROOT/Helpers/pilot-files/Cargo.toml"
# Pilot's own dictation (story 194), WhisperKit and FluidAudio in a package of its own so Pilot's build never compiles them;
# FluidAudio's resource bundle stays behind, only its text to speech reads it. Release always,
# a debug decode is twice as slow. The Neural Engine keeps its compile of the model for one code signature: the same binary
# signed again kept it (2026-10-16), a changed one compiles again, which SpeechModel.prepareInBackground does a minute
# after launch.
DICTATE=$ROOT/Helpers/pilot-dictate
swift build -c release -Xswiftc -Osize -Xlinker -no_exported_symbols --package-path "$DICTATE" --product pilot-dictate
DICTATEBIN=$(swift build -c release --package-path "$DICTATE" --show-bin-path)
# Dictation's Pause media (MediaPause): a library /usr/bin/perl loads to pause and play what is playing; macOS 15.4 and
# later tell only Apple's own programs that (Helpers/pilot-media/pilot-media.m).
mkdir -p "$ROOT/.build/pilot-media"
xcrun clang -fobjc-arc -Os -dynamiclib -framework Foundation "$ROOT/Helpers/pilot-media/pilot-media.m" -o "$ROOT/.build/pilot-media/pilot-media.dylib"
BINDIR=$(swift build -c "$CONFIG" --show-bin-path)
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Helpers"
cp "$BINDIR/Pilot" "$APP/Contents/MacOS/Pilot"
cp "$BINDIR/PilotWebApp" "$APP/Contents/Helpers/PilotWebApp"  # the web-app template, stamped per site
cp "$BINDIR/PilotText" "$APP/Contents/Helpers/pilot-text"  # the clipboard's image text, Vision in a child (HelperText)
# The pilot command (ADR 0013), linked into ~/.local/bin from General. Helpers, not MacOS: on a case-insensitive disk
# Contents/MacOS/pilot is Pilot itself.
cp "$BINDIR/PilotCLI" "$APP/Contents/Helpers/pilot"
cp "$BINDIR/PilotUpscale" "$APP/Contents/Helpers/pilot-upscale"  # Real-ESRGAN on Core ML in a child (UpscaleJob), gone after each image
cp "$BINDIR/PilotMCP" "$APP/Contents/Helpers/pilot-mcp"  # Codex's one tool in Ask Pilot: one gated pilot call (AIChat.Agent.codexLock)
cp "$DICTATEBIN/pilot-dictate" "$APP/Contents/Helpers/pilot-dictate"  # Whisper while dictating (PilotDictation), Kokoro for Read aloud (KokoroSpeaker); the models are downloaded
cp "$ROOT/.build/pilot-media/pilot-media.dylib" "$APP/Contents/Helpers/"  # Pause media while dictating
cp "$ROOT/Helpers/pilot-media/pilot-media.pl" "$APP/Contents/Resources/"  # a script in Helpers is unsigned code: codesign refuses the bundle
cp "$ROOT/Packaging/pilot-agent-shell" "$APP/Contents/Helpers/pilot-agent-shell"  # the AI agents' shell gate: one plain pilot call (AIChat.Agent.environment)
# Sparkle 2 (SH6, PilotUpdates): its Autoupdate and Updater.app replace the app. The XPC services are for sandboxed apps
# only, the headers for building. SwiftPM's rpath to its own build folder goes, so the bundle loads the framework beside
# it, never a build's copy.
mkdir -p "$APP/Contents/Frameworks"
ditto "$BINDIR/Sparkle.framework" "$APP/Contents/Frameworks/Sparkle.framework"
for part in XPCServices Headers PrivateHeaders Modules; do
  rm -rf "$APP/Contents/Frameworks/Sparkle.framework/$part" "$APP/Contents/Frameworks/Sparkle.framework/Versions/B/$part"
done
if otool -l "$APP/Contents/MacOS/Pilot" | grep -qF "path $BINDIR/PackageFrameworks "; then
  install_name_tool -delete_rpath "$BINDIR/PackageFrameworks" "$APP/Contents/MacOS/Pilot"
fi
# A release ships its Swift programs stripped (card agent-bo-95423280): the symbol tables are half the main program and
# nothing reads them at run time. Their debug symbols stay beside the bundle, build/<name>.dSYM made from the very binary
# (same UUID, about 2 s), so a crash log still symbolicates (atos -o build/Pilot.dSYM/Contents/Resources/DWARF/Pilot).
if [[ $CONFIG == release ]]; then
  for name in Pilot PilotWebApp PilotText PilotCLI PilotMCP PilotUpscale; do rm -rf "$ROOT/build/$name.dSYM"; dsymutil "$BINDIR/$name" -o "$ROOT/build/$name.dSYM"; done
  rm -rf "$ROOT/build/pilot-dictate.dSYM"; dsymutil "$DICTATEBIN/pilot-dictate" -o "$ROOT/build/pilot-dictate.dSYM"
  strip -u -r -T "$APP/Contents/MacOS/Pilot" "$APP/Contents/Helpers/PilotWebApp" "$APP/Contents/Helpers/pilot-text" "$APP/Contents/Helpers/pilot" \
    "$APP/Contents/Helpers/pilot-mcp" "$APP/Contents/Helpers/pilot-dictate" "$APP/Contents/Helpers/pilot-upscale"
fi
cp "$ROOT/Helpers/pilot-files/target/release/pilot-files" "$APP/Contents/Helpers/pilot-files"
cp "$ROOT/Helpers/pilot-files/vendor/cardinal/LICENSE" "$APP/Contents/Resources/Cardinal-LICENSE.txt"  # MIT keeps its notice
cp "$ROOT/Helpers/pilot-files/vendor/cardinal/NOTICE" "$APP/Contents/Resources/Cardinal-NOTICE.txt"  # what was vendored and changed
# The file index's crates.io crates, each with its copyright lines and licence texts from the cargo registry (General ›
# About, Acknowledgements); a crate with no text found fails the build.
python3 -I "$ROOT/Scripts/rust-licenses.py" "$ROOT/Helpers/pilot-files/Cargo.toml" >"$APP/Contents/Resources/Rust-crates-LICENSES.txt"
cp "$DICTATE/WhisperKit-LICENSE.txt" "$APP/Contents/Resources/WhisperKit-LICENSE.txt"  # MIT keeps its notice (pilot-dictate)
cp "$DICTATE/FluidAudio-LICENSE.txt" "$APP/Contents/Resources/FluidAudio-LICENSE.txt"  # Apache 2.0 keeps its licence (pilot-dictate, Parakeet)
cp "$ROOT/Packaging/WhisperKit-NOTICES.txt" "$ROOT/Packaging/FluidAudio-NOTICES.txt" "$APP/Contents/Resources/"  # their third-party notices, at the pinned tags
# The models Pilot downloads on a click, never bundled: each one's credit and licence (Parakeet's CC BY 4.0 asks for it).
cp "$ROOT/Packaging/Whisper-LICENSE.txt" "$ROOT/Packaging/Parakeet-LICENSE.txt" "$ROOT/Packaging/Kokoro-LICENSE.txt" \
  "$ROOT/Packaging/RealESRGAN-CoreML-LICENSE.txt" "$APP/Contents/Resources/"
cp "$ROOT/Packaging/Info.plist" "$APP/Contents/Info.plist"
# The app icon (SH22, Sven's pick Q342): an Icon Composer document, compiled to Assets.car (the Liquid Glass renditions,
# light, dark, tinted and clear) and AppIcon.icns; Info.plist names both AppIcon.
xcrun actool --compile "$APP/Contents/Resources" --platform macosx --minimum-deployment-target 26.0 --app-icon AppIcon \
  --output-partial-info-plist "$ROOT/.build/AppIcon-partial.plist" --errors --warnings "$ROOT/Packaging/AppIcon.icon" >/dev/null
/usr/libexec/PlistBuddy -c "Add :PilotBuildConfiguration string $CONFIG" "$APP/Contents/Info.plist"  # LeanBudgetTests judges only release
# The build number counts up with every commit on main (Sparkle compares it); two builds of one commit share it.
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $(git -C "$ROOT" rev-list --count HEAD)" "$APP/Contents/Info.plist"
# The version people read (About, the DMG's name): Scripts/release.sh sets PILOT_VERSION, other builds keep Info.plist's.
[[ -n ${PILOT_VERSION:-} ]] && /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $PILOT_VERSION" "$APP/Contents/Info.plist"
# General's update state (PilotUpdates): the commit this bundle is built from, then its route. SPARKLE_ED_KEY (checked at
# the top) replaces Info.plist's placeholder key: Sparkle's route. A debug build alone names the checkout its Check for
# updates counts from (Q331; a release has no such route): the main checkout that owns the git dir, never a linked
# worktree, since a build from a scratch worktree in /tmp would record a folder a reboot wipes.
PLIST=(-c "Add :PilotCommit string $(git -C "$ROOT" rev-parse HEAD)")
[[ -n ${SPARKLE_FEED:-} ]] && PLIST+=(-c "Set :SUFeedURL $SPARKLE_FEED")
[[ -n ${SPARKLE_ED_KEY:-} ]] && PLIST+=(-c "Set :SUPublicEDKey $SPARKLE_ED_KEY")
[[ $CONFIG == debug ]] && PLIST+=(-c "Add :PilotSource string $(dirname "$(git -C "$ROOT" rev-parse --path-format=absolute --git-common-dir)")")
/usr/libexec/PlistBuddy "${PLIST[@]}" "$APP/Contents/Info.plist"
cp "$ROOT/Packaging/drive-catalogue.json" "$APP/Contents/Resources/"  # the drive catalogue (DriveModule.catalogue)
cp "$ROOT/Packaging/install-catalogue.json" "$APP/Contents/Resources/"  # Install's catalogue (SPEC.md, Install catalogue)
cp "$ROOT/Packaging/themes.json" "$APP/Contents/Resources/"  # Omarchy's theme palettes (OmarchyThemes)
cp "$ROOT/Packaging/Omarchy-LICENSE.txt" "$APP/Contents/Resources/Omarchy-LICENSE.txt"  # MIT keeps its notice
cp "$ROOT/Packaging/emoji.json" "$APP/Contents/Resources/"  # gemoji's emoji names and keywords (EmojiSearch)
cp "$ROOT/Packaging/gemoji-LICENSE.txt" "$APP/Contents/Resources/gemoji-LICENSE.txt"  # MIT keeps its notice
cp "$ROOT/Packaging/CodexBar-LICENSE.txt" "$APP/Contents/Resources/CodexBar-LICENSE.txt"  # MIT keeps its notice (ExtensionGaugeIcon's Claude mark)
cp "$ROOT/Packaging/Sparkle-LICENSE.txt" "$APP/Contents/Resources/Sparkle-LICENSE.txt"  # MIT, with bsdiff's and sais-lite's notices (updates)
# The upscaler's built-in model (UpscaleModels), Real-ESRGAN's realesr-general-x4v3 as Core ML fp16, compiled here so the
# helper loads it at once; Scripts/convert-upscaler.py made the package from the pinned checkpoint.
mkdir -p "$APP/Contents/Resources/Upscale"
xcrun coremlcompiler compile "$ROOT/Packaging/Upscale/realesr-general-x4v3.mlpackage" "$APP/Contents/Resources/Upscale" >/dev/null
cp "$ROOT/Packaging/Real-ESRGAN-LICENSE.txt" "$APP/Contents/Resources/Real-ESRGAN-LICENSE.txt"  # BSD-3 keeps its notice (pilot-upscale's models)
cp "$ROOT/Packaging/AeroSpace-LICENSE.txt" "$APP/Contents/Resources/AeroSpace-LICENSE.txt"  # MIT keeps its notice (PilotTiler, the lifted engine)
cp "$ROOT/Packaging/Snapzy-LICENSE.txt" "$APP/Contents/Resources/Snapzy-LICENSE.txt"  # BSD-3 keeps its notice (the capture backdrop's blurs and ratio math)
# The terminal drop's Ghostty resources: terminfo for TERM=xterm-ghostty, shell integration and themes. libghostty finds them
# from its executable (Contents/Resources/terminfo/78/xterm-ghostty), so Pilot needs no Ghostty.app.
cp -R "$ROOT/.build/ghosttykit/resources/ghostty" "$ROOT/.build/ghosttykit/resources/terminfo" "$APP/Contents/Resources/"
cp "$ROOT/.build/ghosttykit/Ghostty-LICENSE.txt" "$APP/Contents/Resources/Ghostty-LICENSE.txt"  # MIT keeps its notice (libghostty)
cp "$ROOT/Packaging/Ghostty-THIRD-PARTY.txt" "$APP/Contents/Resources/"  # the libraries and fonts libghostty links, each one's licence
cp -R "$ROOT/Packaging/Fonts" "$APP/Contents/Resources/Fonts"  # the themes' display faces, OFL, each licence beside it (DisplayFaces)
cp -R "$ROOT/Packaging/catalogue-icons" "$APP/Contents/Resources/catalogue-icons"  # Install's catalogue pictures, 64 px (CatalogueIcons, Scripts/catalogue-icons.swift)
cp -R "$ROOT/Packaging/webapp-icons" "$APP/Contents/Resources/webapp-icons"  # the recommended web apps' own icons, 128 px (WebAppIdea, Scripts/webapp-icons.swift)
cp -R "$ROOT/Packaging/folder-designs" "$APP/Contents/Resources/folder-designs"  # the folder designs Pilot draws: 1024 px HEIC, 256 px and 64 px PNG each (FolderDesigns, P54)
cp -R "$ROOT/Packaging/ext-template" "$APP/Contents/Resources/ext-template"  # pilot ext new's templates, one folder per mode (ExtensionTemplate)
cp "$ROOT/Packaging/pilot-agent.md" "$APP/Contents/Resources/"  # the AI helper's system prompt (AIChat.Agent, AISettings.agent)
cp -R "$ROOT/Packaging/skills" "$APP/Contents/Resources/skills"  # the AI's skills: the Skills list, pilot guide <topic>, /extension's prompt (AISkills)
cp -R "$ROOT/Packaging/widgets" "$APP/Contents/Resources/widgets"  # the desk widgets' look kit (kit/) and the six desk-* widget folders, each with its own copy of the kit (ADR 0016)
echo -n 'APPL????' > "$APP/Contents/PkgInfo"
codesign --force --sign "$ID" --identifier dev.banozz.pilot.webapp "$APP/Contents/Helpers/PilotWebApp"
codesign --force --sign "$ID" --identifier dev.banozz.pilot.files "$APP/Contents/Helpers/pilot-files"
codesign --force --sign "$ID" --identifier dev.banozz.pilot.text "$APP/Contents/Helpers/pilot-text"
codesign --force --sign "$ID" --identifier dev.banozz.pilot.dictate "$APP/Contents/Helpers/pilot-dictate"
codesign --force --sign "$ID" --identifier dev.banozz.pilot.cli "$APP/Contents/Helpers/pilot"
codesign --force --sign "$ID" --identifier dev.banozz.pilot.mcp "$APP/Contents/Helpers/pilot-mcp"
codesign --force --sign "$ID" --identifier dev.banozz.pilot.upscale "$APP/Contents/Helpers/pilot-upscale"
codesign --force --sign "$ID" --identifier dev.banozz.pilot.agent-shell "$APP/Contents/Helpers/pilot-agent-shell"
codesign --force --sign "$ID" --identifier dev.banozz.pilot.media "$APP/Contents/Helpers/pilot-media.dylib"
# Sparkle inside out, in its own documented order: the installer, its progress app, then the framework.
SPARKLE="$APP/Contents/Frameworks/Sparkle.framework"
codesign --force --sign "$ID" "$SPARKLE/Versions/B/Autoupdate"
codesign --force --sign "$ID" "$SPARKLE/Versions/B/Updater.app"
codesign --force --sign "$ID" "$SPARKLE"
codesign --force --sign "$ID" --identifier dev.banozz.pilot "$APP"
codesign --verify --strict --deep "$APP"  # a broken signature fails the build
/System/Library/Frameworks/CoreServices.framework/Versions/A/Frameworks/LaunchServices.framework/Versions/A/Support/lsregister -f "$APP" >/dev/null 2>&1 || true
echo "built $APP (signed: $ID)"
# The lean budgets (SPEC story 142): a release bundle over its size budget fails the build, after it is built.
if [[ $CONFIG == release ]]; then "$ROOT/Scripts/lean-check.py" size --app "$APP"; fi
