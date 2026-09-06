#!/bin/bash
set -euo pipefail
project_dir="$(cd "$(dirname "$0")/.." && pwd)"
"$project_dir/scripts/build.sh"
result="$project_dir/build/Tests-$(date +%Y%m%d-%H%M%S).xcresult"
xcodebuild -project "$project_dir/Snow Globe.xcodeproj" -scheme 'Snow Globe' \
  -configuration Debug -destination 'platform=macOS' \
  -derivedDataPath "$project_dir/build" -resultBundlePath "$result" \
  CODE_SIGN_IDENTITY=- test
