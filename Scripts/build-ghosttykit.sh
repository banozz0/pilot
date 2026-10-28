#!/bin/zsh
# Bar drops T11: libghostty from Ghostty's own source at Sven's tag, Sentry and libintl off, where Package.swift links it.
#   Scripts/build-ghosttykit.sh      ~10 min the first time; afterwards any checkout copies the finished build in seconds
# Output, gitignored under .build/ghosttykit: libghostty.a (arm64), Ghostty-LICENSE.txt, and resources/{ghostty,terminfo},
# which build-app.sh copies to Pilot.app's Contents/Resources (libghostty finds them from its executable:
# terminfo/78/xterm-ghostty). build-app.sh runs this script first.
# Sources/CGhostty/ghostty.h is the tag's header; the script fails when they differ.
#
# Four workarounds keep the pinned tag building on this Mac (2026-10-15, Xcode 27, macOS 27 SDK), all inside $WORK:
#  1. Zig 0.15.2 (the tag's pin) links nothing against the macOS 26+ SDK, whose tbd files list arm64e-macos but not
#     arm64-macos: an APFS clone of the SDK gets arm64-macos added, and an xcrun shim names it.
#  2. Xcode 27 lacks its Metal toolchain (xcodebuild -downloadComponent MetalToolchain is Sven's call): the copy macOS
#     already cached for Xcode 26 is mounted read-only, and the shim runs metal and metallib from it.
#  3. Ghostty calls /usr/bin/xcrun for Metal by full path: patched to the shim.
#  4. Xcode 27's libtool drops Zig 0.15.2 archive members ("not 8-byte aligned"), libghostty's own among them: Ghostty's
#     libtool step runs pilot-libtool, which merges the archives with llvm-ar (zig ar) instead.
# And one choice: -Di18n=false keeps GNU gettext's libintl (LGPL) out of Pilot (coordinator, 2026-10-18). Ghostty links it on
# macOS whatever the flag says, so SharedDeps.zig is patched to link it only when i18n is on; the terminal's own words stay
# English, as Pilot's are.
set -euo pipefail
ROOT=${0:a:h:h}
TAG=${GHOSTTY_TAG:-v1.3.1}  # Ghostty.app's version on Sven's Mac
WORK=${GHOSTTYKIT_WORK:-$HOME/Library/Caches/Pilot/ghosttykit-$TAG}
OUT=$ROOT/.build/ghosttykit
SRC=$WORK/src
BUILT=$SRC/macos/GhosttyKit.xcframework/macos-arm64/libghostty-fat.a
FLAGS=(-Demit-xcframework=true -Dxcframework-target=native -Demit-macos-app=false -Doptimize=ReleaseFast -Dsentry=false -Di18n=false)
STAMP=$WORK/built-flags  # the flags $BUILT was built with: a change rebuilds it

if [[ ! -f $BUILT || $(cat $STAMP 2>/dev/null) != "$FLAGS" ]]; then
  mkdir -p $WORK
  [[ -d $SRC ]] || git -c advice.detachedHead=false clone -q --depth 1 --branch $TAG https://github.com/ghostty-org/ghostty $SRC
  want=$(sed -nE 's/.*minimum_zig_version = "([^"]+)".*/\1/p' $SRC/build.zig.zon)
  ZIG=${ZIG:-}
  for z in "$ZIG" $HOME/code/_tools/zig-aarch64-macos-$want/zig /opt/homebrew/opt/zig@${want%.*}/bin/zig; do
    if [[ -n $z && -x $z && $($z version) == $want ]]; then ZIG=$z; break; fi
  done
  [[ -n $ZIG && $($ZIG version) == $want ]] || { echo "error: $TAG needs Zig $want" >&2; exit 1; }

  # 1. The SDK clone with arm64-macos in every tbd that lists arm64e-macos.
  # The 26 SDK is the one proved with Zig 0.15.2 (2026-10-15); the clone is named by the version it came from.
  real=/Library/Developer/CommandLineTools/SDKs/MacOSX26.sdk
  [[ -d $real ]] || real=$(xcrun --show-sdk-path)
  SDK=$WORK/MacOSX$(/usr/bin/plutil -extract Version raw ${real:A}/SDKSettings.plist)-arm64.sdk
  if [[ ! -d $SDK ]]; then
    rm -rf $SDK.part
    cp -Rc ${real:A} $SDK.part
    chmod -R u+w $SDK.part
    find $SDK.part -name '*.tbd' -type f -print0 \
      | xargs -0 perl -0777 -pi -e 's{\[([^\]]*)\]}{my $l = $1; $l =~ s/\barm64e-macos\b/arm64-macos, arm64e-macos/ if $l !~ /\barm64-macos\b/; "[$l]"}ge'
    mv $SDK.part $SDK
  fi

  # 2. Metal: Xcode's own toolchain when it runs, else the cached one, mounted for this build only.
  METAL=$(dirname $(xcrun -f metal))
  if ! echo 'kernel void k() {}' | xcrun metal -x metal -c - -o /dev/null 2>/dev/null; then
    dmg=$(ls -t /System/Library/AssetsV2/com_apple_MobileAsset_MetalToolchain/*/AssetData/Restore/*.dmg 2>/dev/null | head -1)
    [[ -n $dmg ]] || { echo "error: no Metal toolchain; Sven: xcodebuild -downloadComponent MetalToolchain" >&2; exit 1; }
    mounted=$(hdiutil info | awk -v img="$dmg" '$0 ~ "^image-path" { on = ($3 == img) } on && $NF ~ "^/" { print $NF; exit }')
    if [[ -z $mounted ]]; then
      mounted=$WORK/metal
      mkdir -p $mounted
      hdiutil attach -readonly -nobrowse -quiet -mountpoint $mounted $dmg
      trap "hdiutil detach -quiet $mounted" EXIT
    fi
    METAL=$mounted/Metal.xctoolchain/usr/bin
  fi

  mkdir -p $WORK/bin
  cat > $WORK/bin/xcrun <<EOF
#!/bin/bash
case "\$*" in
  *--show-sdk-path*) echo "$SDK"; exit 0;;
  *--show-sdk-version*) /usr/bin/plutil -extract Version raw "$SDK/SDKSettings.plist"; exit 0;;
esac
args=("\$@"); i=0
while [[ \$i -lt \${#args[@]} ]]; do
  case "\${args[\$i]}" in
    -sdk) i=\$((i + 2));;
    -*) i=\$((i + 1));;
    metal|metallib) exec "$METAL/\${args[\$i]}" "\${args[@]:\$((i + 1))}";;
    *) break;;
  esac
done
exec /usr/bin/xcrun "\$@"
EOF
  cat > $WORK/bin/pilot-libtool <<EOF
#!/bin/bash
[[ "\$1" == -static && "\$2" == -o ]] || exec /usr/bin/libtool "\$@"
out=\$3; shift 3
{ echo "create \$out"; for a in "\$@"; do echo "addlib \$a"; done; echo save; echo end; } | "$ZIG" ar -M && "$ZIG" ranlib "\$out"
EOF
  chmod +x $WORK/bin/xcrun $WORK/bin/pilot-libtool

  # 3, 4 and libintl.
  sed -i '' 's|"/usr/bin/xcrun", "-sdk"|"xcrun", "-sdk"|' $SRC/src/build/MetallibStep.zig
  sed -i '' 's|"libtool", "-static", "-o"|"pilot-libtool", "-static", "-o"|' $SRC/src/build/LibtoolStep.zig
  sed -i '' 's|^        if (b.lazyDependency("libintl", .{|        if (!self.config.i18n) {} else if (b.lazyDependency("libintl", .{|' $SRC/src/build/SharedDeps.zig
  grep -q '"xcrun", "-sdk"' $SRC/src/build/MetallibStep.zig && grep -q '"pilot-libtool"' $SRC/src/build/LibtoolStep.zig \
    && grep -q 'if (!self.config.i18n) {} else if (b.lazyDependency("libintl"' $SRC/src/build/SharedDeps.zig \
    || { echo "error: $TAG's MetallibStep.zig, LibtoolStep.zig or SharedDeps.zig changed; a patch did not apply" >&2; exit 1; }

  echo "building GhosttyKit $TAG with Zig $want (log: $WORK/build.log)"
  rm -rf $SRC/macos/GhosttyKit.xcframework  # xcodebuild -create-xcframework refuses to overwrite
  (cd $SRC && PATH="$WORK/bin:/opt/homebrew/opt/gettext/bin:$PATH" $ZIG build $FLAGS) > $WORK/build.log 2>&1 \
    || { tail -30 $WORK/build.log >&2; exit 1; }

  # The archive must hold libghostty itself, no Sentry SDK (only libc++'s ostream::sentry and Ghostty's compiled-out
  # crash module carry the word) and no libintl. Counted, not grep -q: under pipefail an early grep exit fails nm with SIGPIPE.
  symbols=$(nm $BUILT 2>/dev/null)
  [[ $(grep -c ' T _ghostty_surface_new$' <<< $symbols) -gt 0 ]] || { rm -f $BUILT; echo "error: libghostty missing from the archive" >&2; exit 1; }
  [[ $(grep -c ' _sentry_' <<< $symbols) -eq 0 ]] || { rm -f $BUILT; echo "error: Sentry in the archive" >&2; exit 1; }
  [[ $(grep -cE ' [TDS] _(libintl_|bindtextdomain$)' <<< $symbols) -eq 0 ]] || { rm -f $BUILT; echo "error: libintl in the archive" >&2; exit 1; }
  echo "$FLAGS" > $STAMP
fi

# Packaging/Ghostty-THIRD-PARTY.txt holds the licences of what this tag's libghostty links into Pilot: a new tag re-checks it.
grep -q "Ghostty $TAG as" $ROOT/Packaging/Ghostty-THIRD-PARTY.txt || { echo "error: Packaging/Ghostty-THIRD-PARTY.txt is not for $TAG" >&2; exit 1; }
cmp -s $SRC/include/ghostty.h $ROOT/Sources/CGhostty/ghostty.h || { echo "error: $TAG's ghostty.h differs from Sources/CGhostty" >&2; exit 1; }

rm -rf $OUT
mkdir -p $OUT/resources
cp -c $BUILT $OUT/libghostty.a  # an APFS clone, not 139 MB of writes
cp -R $SRC/zig-out/share/ghostty $SRC/zig-out/share/terminfo $OUT/resources/
cp $SRC/LICENSE $OUT/Ghostty-LICENSE.txt
ls -l $OUT/libghostty.a
du -sh $OUT/resources
