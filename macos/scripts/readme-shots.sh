#!/bin/sh
# Redraws the README's pictures in docs/images from the app's own views (ReadmeShotTests): a
# fresh setup and sample states, never this Mac's data or the hosted relay's address.
set -eu
cd "$(dirname "$0")/.."
out=$(cd .. && pwd)/docs/images
mkdir -p "$out"
make project >/dev/null
TEST_RUNNER_README_SHOTS_DIR=$out xcodebuild -project Latchkey.xcodeproj -scheme Latchkey \
  -destination 'platform=macOS' -derivedDataPath build/DerivedData test \
  -only-testing:LatchkeyTests/ReadmeShotTests >/dev/null 2>&1
ls "$out"
