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

header_count=0
while IFS= read -r header; do
  ((header_count += 1))
  for retired in session_client_get_sessions session_client_get_session \
    session_client_open_chat_with_intent; do
    if grep -q "$retired" "$header"; then
      echo "$header still declares retired $retired" >&2
      exit 1
    fi
  done
  grep -q 'session_client_open_chat' "$header" || {
    echo "$header is missing session_client_open_chat" >&2
    exit 1
  }
  grep -q 'session_client_send_dtmf' "$header" || {
    echo "$header is missing session_client_send_dtmf" >&2
    exit 1
  }
done < <(find "$artifact" -type f -name session_bridge.h -print)
if (( header_count == 0 )); then
  echo "XCFramework has no session_bridge.h" >&2
  exit 2
fi

library_count=0
while IFS= read -r library; do
  ((library_count += 1))
  symbols="$(strings "$library")"
  grep -Eq '^_?session_client_open_chat$' <<<"$symbols" || {
    echo "$library is missing session_client_open_chat" >&2
    exit 1
  }
  grep -Eq '^_?session_client_send_dtmf$' <<<"$symbols" || {
    echo "$library is missing session_client_send_dtmf" >&2
    exit 1
  }
  for retired in session_client_get_sessions session_client_get_session \
    session_client_open_chat_with_intent; do
    ! grep -Eq "^_?${retired}$" <<<"$symbols" || {
      echo "$library still exports retired $retired" >&2
      exit 1
    }
  done
done < <(find "$artifact" -type f -name libsession.a -print)
if (( library_count == 0 )); then
  echo "XCFramework has no libsession.a slices" >&2
  exit 2
fi

wrapper="$repo_dir/Sources/OrigonSDK/OrigonClient.swift"
grep -q 'public func sendDtmf(id: String, digit: Character)' "$wrapper" || {
  echo "Swift wrapper is missing sendDtmf(id:digit:)" >&2
  exit 1
}
if grep -Eq 'public (func|var) (receiveDtmf|onDtmf|dtmfReceived)' "$wrapper"; then
  echo "Swift wrapper exposes an unsupported DTMF receive API" >&2
  exit 1
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

destination="${ORIGON_IOS_TEST_DESTINATION:-platform=iOS Simulator,name=iPhone 16}"
xcodebuild \
  -project "$scratch/repo/examples/origon-sdk-example-ios/OrigonSDKExample.xcodeproj" \
  -scheme OrigonSDKExample \
  -destination "$destination" \
  -derivedDataPath "$scratch/DerivedData" \
  CODE_SIGNING_ALLOWED=NO \
  test
