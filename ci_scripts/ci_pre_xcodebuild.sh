#!/bin/sh
# Xcode Cloud runs this before each xcodebuild command. See docs/Releasing.md, "Xcode Cloud".

set -e

# An archive is what reaches TestFlight. Without the Last.fm credentials it still builds
# and uploads, and every tester gets "This build has no Last.fm API key". Without the relay,
# the App Clip can never reach the host's iPhone. So stop here. Build and test actions don't
# need them.
if [ "$CI_XCODEBUILD_ACTION" = "archive" ]; then
  missing=""
  for name in TRACKS_LASTFM_API_KEY TRACKS_LASTFM_SECRET TRACKS_RELAY_HOST TRACKS_RELAY_KEY; do
    if [ -z "$(printenv "$name" || true)" ]; then
      missing="$missing $name"
    fi
  done
  if [ -n "$missing" ]; then
    echo "error: set$missing as secret environment variables in this workflow's"
    echo "Environment settings to archive."
    exit 1
  fi
fi
