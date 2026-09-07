#!/bin/bash
set -euo pipefail
project_dir="$(cd "$(dirname "$0")/.." && pwd)"
cd "$project_dir"
xcodebuild -project 'Snow Globe.xcodeproj' -scheme 'Snow Globe' \
  -configuration Release -destination 'platform=macOS' -derivedDataPath "$project_dir/build" \
  -clonedSourcePackagesDirPath "$project_dir/build/SourcePackages" \
  build
app_path="$project_dir/build/Build/Products/Release/Snow Globe.app"
codesign --verify --deep --strict --verbose=2 "$app_path"
echo "Built: $app_path"
