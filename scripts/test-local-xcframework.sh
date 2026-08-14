#!/usr/bin/env bash
set -euo pipefail

repo_dir="$(cd "$(dirname "$0")/.." && pwd)"
artifact="${ORIGON_XCFRAMEWORK:-}"
if [[ -z "$artifact" ]]; then
  echo "ORIGON_XCFRAMEWORK must name COrigonSDK.xcframework" >&2
  exit 2
fi
if [[ "$artifact" != /* ]]; then
  artifact="$repo_dir/$artifact"
fi
if [[ ! -d "$artifact" ]]; then
  echo "XCFramework not found: $artifact" >&2
  exit 2
fi

scratch="$(mktemp -d)"
trap 'rm -rf "$scratch"' EXIT
mkdir -p "$scratch/repo"
rsync -a --exclude .git --exclude .build --exclude DerivedData \
  "$repo_dir/" "$scratch/repo/"
local_artifact="$scratch/repo/Frameworks/COrigonSDK.xcframework"
mkdir -p "$(dirname "$local_artifact")"
if [[ "$artifact" != "$repo_dir/Frameworks/COrigonSDK.xcframework" ]]; then
  rsync -a "$artifact/" "$local_artifact/"
fi

perl -0pi -e '
  s{\.binaryTarget\(\s*name:\s*"COrigonSDK",\s*url:\s*"[^"]+",\s*checksum:\s*"[^"]+"\s*\)}
   {.binaryTarget(name: "COrigonSDK", path: "Frameworks/COrigonSDK.xcframework")}sx
' "$scratch/repo/Package.swift"

swift test --package-path "$scratch/repo"

project="$scratch/repo/examples/origon-sdk-example-ios/OrigonSDKExample.xcodeproj/project.pbxproj"
perl -0pi -e '
  s{isa = XCRemoteSwiftPackageReference;\s*repositoryURL = "https://github\.com/Origon/apple-sdk";\s*requirement = \{.*?\};}
   {isa = XCLocalSwiftPackageReference;\n\t\t\trelativePath = ../..;}s
' "$project"

xcodebuild \
  -project "$scratch/repo/examples/origon-sdk-example-ios/OrigonSDKExample.xcodeproj" \
  -scheme OrigonSDKExample \
  -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath "$scratch/DerivedData" \
  CODE_SIGNING_ALLOWED=NO \
  ARCHS=arm64 \
  ONLY_ACTIVE_ARCH=YES \
  build
