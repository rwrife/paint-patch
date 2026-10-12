#!/usr/bin/env bash
set -Eeuo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

expected_sha="${1:-}"
if [[ -z "$expected_sha" ]]; then
  echo "usage: Scripts/ci.sh <expected-commit-sha>" >&2
  exit 2
fi

artifact_root="${PAINTPATCH_ARTIFACT_DIR:-$repo_root/build/ci-artifacts}"
mkdir -p "$artifact_root" "$repo_root/build"
artifact_dir="$(mktemp -d "$artifact_root/run.XXXXXX")"
derived_data="$(mktemp -d "$repo_root/build/DerivedData.XXXXXX")"
phase="initialization"

write_provenance() {
  local result=$?
  {
    echo "expected_sha=$expected_sha"
    echo "actual_sha=$(git rev-parse HEAD 2>/dev/null || echo unavailable)"
    echo "runner_os=${RUNNER_OS:-unknown}"
    echo "runner_arch=${RUNNER_ARCH:-unknown}"
    echo "developer_dir=${DEVELOPER_DIR:-unselected}"
    echo "simulator_udid=${simulator_udid:-unselected}"
    echo "phase=$phase"
    echo "exit_status=$result"
  } > "$artifact_dir/provenance.txt"
  if [[ -n "${DEVELOPER_DIR:-}" ]]; then
    python3 Scripts/boot_simulator.py capture \
      --timeout 15 --output "$artifact_dir/xcode-version.txt" \
      -- xcodebuild -version || true
    python3 Scripts/boot_simulator.py capture \
      --timeout 15 --output "$artifact_dir/iphoneos-sdk-version.txt" \
      -- xcrun --sdk iphoneos --show-sdk-version || true
  fi
}
trap write_provenance EXIT

actual_sha="$(git rev-parse HEAD)"
if [[ "$actual_sha" != "$expected_sha" ]]; then
  echo "Checked out SHA $actual_sha does not equal requested SHA $expected_sha" >&2
  exit 1
fi

phase="iphone_only_source_gate"
# iPhone-only is a product contract, not a default: every app configuration
# must pin TARGETED_DEVICE_FAMILY = 1 and the bundle id prefix.
if ! grep -q 'TARGETED_DEVICE_FAMILY = 1;' PaintPatch.xcodeproj/project.pbxproj; then
  echo "::error::PaintPatch.xcodeproj must set TARGETED_DEVICE_FAMILY = 1 in all configurations." >&2
  exit 1
fi
if grep -q 'TARGETED_DEVICE_FAMILY = "1,2"' PaintPatch.xcodeproj/project.pbxproj; then
  echo "::error::iPad device family (1,2) found; native iPad support is disabled." >&2
  exit 1
fi
if ! grep -q 'PRODUCT_BUNDLE_IDENTIFIER = com.infinityball.paintpatch' PaintPatch.xcodeproj/project.pbxproj; then
  echo "::error::Bundle identifier must stay under com.infinityball.paintpatch." >&2
  exit 1
fi

phase="helper_tests"
python3 -m unittest discover -s Scripts/tests -v 2>&1 | tee "$artifact_dir/helper-tests.log"

phase="toolchain_selection"
python3 Scripts/select_xcode.py \
  --toolchain toolchain.json \
  > "$artifact_dir/developer-dir.txt" \
  2> >(tee "$artifact_dir/toolchain-selection.log" >&2)
export DEVELOPER_DIR
DEVELOPER_DIR="$(<"$artifact_dir/developer-dir.txt")"

phase="simulator_selection"
sdk_version="$(python3 -c 'import json; print(json.load(open("toolchain.json", encoding="utf-8"))["iphoneos_sdk"])')"
simulator_udid="$(python3 Scripts/select_simulator.py \
  --sdk "$sdk_version" \
  --devices-json-out "$artifact_dir/simulator-devices.json")"
echo "platform=iOS Simulator,id=$simulator_udid" > "$artifact_dir/destination.txt"

phase="simulator_boot"
python3 Scripts/boot_simulator.py boot \
  --udid "$simulator_udid" \
  --devices-json "$artifact_dir/simulator-devices.json" \
  --log "$artifact_dir/simulator-boot.log" \
  --boot-timeout 120 \
  --bootstatus-timeout 180 \
  2> >(tee -a "$artifact_dir/simulator-boot.log" >&2)

phase="domain_tests"
xcrun swift test \
  --package-path Packages/PaintPatchKit \
  2>&1 | tee "$artifact_dir/domain-tests.log"

phase="app_build"
xcodebuild build \
  -project PaintPatch.xcodeproj \
  -scheme PaintPatch \
  -configuration Debug \
  -destination "platform=iOS Simulator,id=$simulator_udid" \
  -derivedDataPath "$derived_data" \
  -resultBundlePath "$artifact_dir/build.xcresult" \
  CODE_SIGNING_ALLOWED=NO \
  CODE_SIGNING_REQUIRED=NO \
  2>&1 | tee "$artifact_dir/xcodebuild-build.log"

phase="device_family_assert"
# The source gate above is a contract check; this reads the actual bytes of
# the built app: bundle id and iPhone-only device family.
built_plist="$derived_data/Build/Products/Debug-iphonesimulator/PaintPatch.app/Info.plist"
bundle_id="$(plutil -extract CFBundleIdentifier raw -o - "$built_plist")"
echo "CFBundleIdentifier= $bundle_id" | tee "$artifact_dir/bundle-id.txt"
if [[ "$bundle_id" != "com.infinityball.paintpatch" ]]; then
  echo "::error::Built app bundle id is $bundle_id." >&2
  exit 1
fi
plutil -convert json -o - "$built_plist" \
  | python3 -c 'import json,sys; v=json.load(sys.stdin).get("UIDeviceFamily"); print("UIDeviceFamily=", v); sys.exit(0 if v == [1] else 1)' \
  | tee "$artifact_dir/uidevicefamily.txt"

phase="ui_tests"
xcodebuild test \
  -project PaintPatch.xcodeproj \
  -scheme PaintPatch \
  -only-testing:PaintPatchUITests/PaintPatchLaunchTests \
  -destination "platform=iOS Simulator,id=$simulator_udid" \
  -derivedDataPath "$derived_data" \
  -resultBundlePath "$artifact_dir/tests-compact.xcresult" \
  CODE_SIGNING_ALLOWED=NO \
  CODE_SIGNING_REQUIRED=NO \
  2>&1 | tee "$artifact_dir/xcodebuild-test-compact.log"

phase="complete"
echo "Paint Patch CI complete."
