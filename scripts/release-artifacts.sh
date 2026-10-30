#!/usr/bin/env bash

set -euo pipefail

# Shared payload helper
# shellcheck source=./release-payload.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/release-payload.sh"

usage() {
  cat <<'EOF'
Usage:
  scripts/release-artifacts.sh extract-stage --package-zip ZIP --stage-dir DIR
  scripts/release-artifacts.sh stage-build-output --build-output-dir DIR --stage-dir DIR
  scripts/release-artifacts.sh verify-stage --stage-dir DIR
  scripts/release-artifacts.sh create-universal-archive --stage-dir DIR --archive PATH
  scripts/release-artifacts.sh create-homebrew-archive --stage-dir DIR --archive PATH
  scripts/release-artifacts.sh smoke-test-stage --stage-dir DIR
  scripts/release-artifacts.sh smoke-test-archive --archive PATH
EOF
}

fail() {
  echo "❌ $*" >&2
  exit 1
}

require_arg() {
  local name="$1"
  local value="$2"
  [[ -n "$value" ]] || fail "Missing required argument: $name"
}

verify_arch() {
  local binary_path="$1"
  local expected_arch="$2"

  [[ -f "$binary_path" ]] || fail "Binary not found: $binary_path"

  local arch_info
  arch_info="$(lipo -info "$binary_path" 2>/dev/null || true)"
  [[ "$arch_info" == *"$expected_arch"* ]] || fail "Missing architecture '$expected_arch' in $binary_path"
}

# The simulator helper keeps the signature it was built with: it runs inside the simulator and
# the Homebrew post_install never re-signs it, so stripping it would leave it unsigned.
strip_signatures() {
  local stage_dir="$1"
  local bridge_path="$stage_dir/$RELEASE_SIMULATOR_BRIDGE"

  while IFS= read -r -d '' file_path; do
    [[ "$file_path" != "$bridge_path" ]] || continue
    if file "$file_path" | grep -q "Mach-O"; then
      codesign --remove-signature "$file_path" 2>/dev/null || true
    fi
  done < <(find "$stage_dir" -type f -print0)

  while IFS= read -r -d '' bundle_path; do
    codesign --remove-signature "$bundle_path" 2>/dev/null || true
  done < <(find "$stage_dir" -type d -name "*.bundle" -print0)
}

extract_stage() {
  local package_zip="$1"
  local stage_dir="$2"
  local extract_root

  [[ -f "$package_zip" ]] || fail "Package zip not found: $package_zip"

  rm -rf "$stage_dir"
  mkdir -p "$stage_dir"

  extract_root="$(mktemp -d "${TMPDIR:-/tmp}/axe-release-stage.XXXXXX")"

  ditto -x -k "$package_zip" "$extract_root"

  local top_level_dir_count
  local top_level_file_count
  local package_root

  top_level_dir_count="$(find "$extract_root" -mindepth 1 -maxdepth 1 -type d | wc -l | tr -d ' ')"
  top_level_file_count="$(find "$extract_root" -mindepth 1 -maxdepth 1 -type f | wc -l | tr -d ' ')"

  if [[ "$top_level_dir_count" -eq 1 && "$top_level_file_count" -eq 0 ]]; then
    package_root="$(find "$extract_root" -mindepth 1 -maxdepth 1 -type d | head -1)"
  else
    package_root="$extract_root"
  fi

  copy_release_payload "$package_root" "$stage_dir"
  rm -rf "$extract_root"
  echo "✅ Extracted staged payload to $stage_dir"
}

stage_build_output() {
  local build_output_dir="$1"
  local stage_dir="$2"

  copy_release_payload "$build_output_dir" "$stage_dir"
  echo "✅ Materialized staged payload from build output to $stage_dir"
}

verify_stage() {
  local stage_dir="$1"
  local bridge_path="$stage_dir/$RELEASE_SIMULATOR_BRIDGE"

  [[ -d "$stage_dir" ]] || fail "Stage directory not found: $stage_dir"
  [[ -x "$stage_dir/axe" ]] || fail "Stage is missing executable axe"
  [[ -d "$stage_dir/AXe_AXe.bundle" ]] || fail "Stage is missing AXe_AXe.bundle"
  [[ ! -e "$stage_dir/Frameworks" ]] || fail "Stage has a Frameworks directory; IDB is linked statically"
  [[ -x "$bridge_path" ]] || fail "Stage is missing executable $RELEASE_SIMULATOR_BRIDGE"

  verify_arch "$stage_dir/axe" "arm64"
  verify_arch "$bridge_path" "arm64"
  # Every archive (including the unsigned Homebrew one) must carry the helper with its build
  # signature intact.
  codesign --verify --strict "$bridge_path" >/dev/null 2>&1 \
    || fail "$RELEASE_SIMULATOR_BRIDGE signature does not verify; it must never be stripped or re-signed"

  local appledouble_files
  appledouble_files="$(find "$stage_dir" -type f -name "._*" | head -5)"
  [[ -z "$appledouble_files" ]] || fail "AppleDouble metadata files in staged payload: ${appledouble_files}"

  echo "✅ Verified staged payload contract and architectures"
}

create_archive() {
  local stage_dir="$1"
  local archive_path="$2"
  local strip_before_archive="$3"
  local archive_root

  verify_stage "$stage_dir"

  archive_root="$(mktemp -d "${TMPDIR:-/tmp}/axe-release-archive.XXXXXX")"

  cp -R "$stage_dir"/. "$archive_root"/

  if [[ "$strip_before_archive" == "true" ]]; then
    strip_signatures "$archive_root"
  fi

  rm -f "$archive_path"
  mkdir -p "$(dirname "$archive_path")"
  COPYFILE_DISABLE=1 tar -czf "$archive_path" -C "$archive_root" .
  rm -rf "$archive_root"
  echo "✅ Created archive: $archive_path"
}

smoke_test_stage() {
  local stage_dir="$1"

  verify_stage "$stage_dir"
  "$stage_dir/axe" --version >/dev/null
  "$stage_dir/axe" init --print | grep -q "name: axe"
  echo "✅ Smoke-tested staged payload"
}

# The Homebrew archive's axe is unsigned by design (create-homebrew-archive strips its
# signature) and the formula's post_install re-signs it ad hoc on install. Running it
# raw fails on Apple silicon, which refuses unsigned code. Mirror post_install on the
# extracted copy only: axe alone, same flags; the simulator helper is never re-signed.
# Archives whose axe already verifies (the universal archive) are left untouched.
adhoc_sign_unsigned_stage() {
  local stage_dir="$1"

  if codesign --verify --strict "$stage_dir/axe" >/dev/null 2>&1; then
    return 0
  fi

  codesign --force --sign - --timestamp=none "$stage_dir/axe"
  echo "Archive is unsigned; ad-hoc signed the extracted copy for the smoke test"
}

smoke_test_archive() {
  local archive_path="$1"
  local stage_dir

  [[ -f "$archive_path" ]] || fail "Archive not found: $archive_path"

  stage_dir="$(mktemp -d "${TMPDIR:-/tmp}/axe-release-smoke.XXXXXX")"

  tar -xzf "$archive_path" -C "$stage_dir"
  adhoc_sign_unsigned_stage "$stage_dir"
  smoke_test_stage "$stage_dir"
  rm -rf "$stage_dir"
  echo "✅ Smoke-tested archive: $archive_path"
}

command_name="${1:-}"
shift || true

package_zip=""
build_output_dir=""
stage_dir=""
archive_path=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --package-zip)
      package_zip="${2:-}"
      shift 2
      ;;
    --build-output-dir)
      build_output_dir="${2:-}"
      shift 2
      ;;
    --stage-dir)
      stage_dir="${2:-}"
      shift 2
      ;;
    --archive)
      archive_path="${2:-}"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      fail "Unknown argument: $1"
      ;;
  esac
done

case "$command_name" in
  extract-stage)
    require_arg --package-zip "$package_zip"
    require_arg --stage-dir "$stage_dir"
    extract_stage "$package_zip" "$stage_dir"
    ;;
  stage-build-output)
    require_arg --build-output-dir "$build_output_dir"
    require_arg --stage-dir "$stage_dir"
    stage_build_output "$build_output_dir" "$stage_dir"
    ;;
  verify-stage)
    require_arg --stage-dir "$stage_dir"
    verify_stage "$stage_dir"
    ;;
  create-universal-archive)
    require_arg --stage-dir "$stage_dir"
    require_arg --archive "$archive_path"
    create_archive "$stage_dir" "$archive_path" false
    ;;
  create-homebrew-archive)
    require_arg --stage-dir "$stage_dir"
    require_arg --archive "$archive_path"
    create_archive "$stage_dir" "$archive_path" true
    ;;
  smoke-test-stage)
    require_arg --stage-dir "$stage_dir"
    smoke_test_stage "$stage_dir"
    ;;
  smoke-test-archive)
    require_arg --archive "$archive_path"
    smoke_test_archive "$archive_path"
    ;;
  ''|-h|--help|help)
    usage
    ;;
  *)
    fail "Unknown command: $command_name"
    ;;
esac
