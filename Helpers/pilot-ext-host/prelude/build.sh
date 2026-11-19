#!/bin/zsh
# Builds ../pilot-ext-prelude.js (ADR 0017) at dev time, so building Pilot never needs Node: React and react-reconciler
# (MIT, Meta) in their production builds and Pilot's own clean-room shim in src/, one IIFE for a bare JSContext.
# Their licence comments stay in the file, and ../React-LICENSE.txt is React's own licence text, which build-app.sh
# copies into the app. Run after `npm ci --ignore-scripts` here; commit the two files it writes.
set -euo pipefail
HERE=${0:a:h}
cd "$HERE"
./node_modules/.bin/esbuild src/index.js --bundle --format=iife --platform=neutral --target=es2022 --minify \
  --legal-comments=inline --define:process.env.NODE_ENV='"production"' --main-fields=main,module \
  --outfile=../pilot-ext-prelude.js
cp node_modules/react/LICENSE ../React-LICENSE.txt
wc -c ../pilot-ext-prelude.js
