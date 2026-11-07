#!/bin/sh
# Xcode Cloud runs this after cloning, once per action, from inside ci_scripts/.
# See docs/Releasing.md, "Xcode Cloud".

set -e

# project.yml, Config/ and the generated project all live at the repository root.
cd "${CI_PRIMARY_REPOSITORY_PATH:-$(dirname "$0")/..}"

# The project is gitignored and generated from project.yml, so it has to exist before
# Xcode Cloud looks for the workflow's scheme.
export HOMEBREW_NO_AUTO_UPDATE=1
export HOMEBREW_NO_INSTALL_CLEANUP=1
brew install xcodegen
xcodegen generate

# Last.fm credentials and SharePlay's relay come from the workflow's secret environment
# variables. The committed xcconfig leaves them empty and includes Config/Secrets.xcconfig if
# it exists, the same file a local release build uses. ci_pre_xcodebuild.sh stops an archive
# without them.
: > Config/Secrets.xcconfig
for name in TRACKS_LASTFM_API_KEY TRACKS_LASTFM_SECRET TRACKS_RELAY_HOST TRACKS_RELAY_KEY; do
  value=$(printenv "$name" || true)
  if [ -n "$value" ]; then
    printf '%s = %s\n' "$name" "$value" >> Config/Secrets.xcconfig
  else
    echo "$name not set; the build leaves it empty."
  fi
done
echo "Wrote Config/Secrets.xcconfig"
