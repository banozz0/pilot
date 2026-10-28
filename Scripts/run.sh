#!/bin/zsh
# Builds and (re)launches Pilot.app, streaming its log. Ctrl+C stops the stream, not the app.
set -euo pipefail
ROOT=${0:a:h:h}
PILOT_DEV=1 "$ROOT/Scripts/build-app.sh"  # Sven's own release, no update feed; CONFIG=debug counts the checkout's commits
pkill -x Pilot 2>/dev/null && sleep 0.5 || true
open -n "$ROOT/build/Pilot.app"
echo "Pilot launched. Log follows (also: log stream --predicate 'subsystem == \"dev.banozz.pilot\"')."
exec log stream --level info --predicate 'subsystem == "dev.banozz.pilot"' --style compact
