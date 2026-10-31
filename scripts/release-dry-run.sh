#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

WORK_DIR="${WORK_DIR:-$ROOT_DIR/.release-dry-run}"
TAG="${TAG:-v0.0.0-dryrun}"
VERSION="${TAG#v}"
FORMULA_NAME="${FORMULA_NAME:-axe}"
FORMULA_CLASS="$(echo "$FORMULA_NAME" | awk -F'[-_]' '{for(i=1;i<=NF;i++) $i=toupper(substr($i,1,1)) substr($i,2); print $0}' OFS="")"
HOMEPAGE="${HOMEPAGE:-https://github.com/cameroncooke/AXe}"
CANONICAL_FORMULA_PATH="${CANONICAL_FORMULA_PATH:-./scripts/fixtures/homebrew-formula.expected.rb}"

cleanup() {
  rm -rf "$WORK_DIR"
}
trap cleanup EXIT

STAGE_DIR="$WORK_DIR/stage"
PACKAGE_ROOT="$WORK_DIR/package-root/AXe-Final-dryrun"
OUT_DIR="$WORK_DIR/out"
UNIVERSAL_ARCHIVE="$OUT_DIR/AXe-macOS-${TAG}-universal.tar.gz"
HOMEBREW_ARCHIVE="$OUT_DIR/AXe-macOS-homebrew-${TAG}.tar.gz"
FORMULA_OUT="$OUT_DIR/${FORMULA_NAME}.rb"

mkdir -p \
  "$PACKAGE_ROOT/Resources" \
  "$PACKAGE_ROOT/AXe_AXe.bundle" \
  "$OUT_DIR"

echo "[release-dry-run] Preparing arm64 test binaries"
BIN_PATH="/usr/bin/file"
# Stands in for the simulator helper: any signed arm64 binary whose signature must survive.
BRIDGE_STAND_IN="/usr/bin/true"

for required_binary in "$BIN_PATH" "$BRIDGE_STAND_IN"; do
  if [[ ! -f "$required_binary" ]]; then
    echo "[release-dry-run] ERROR: required system binary missing at $required_binary"
    exit 1
  fi
  lipo -info "$required_binary" | grep -q "arm64"
done

cp "$BIN_PATH" "$PACKAGE_ROOT/axe"
cp "$BRIDGE_STAND_IN" "$PACKAGE_ROOT/Resources/SimulatorFrameworkBridge-iOS"
codesign --verify --strict "$PACKAGE_ROOT/Resources/SimulatorFrameworkBridge-iOS"
printf 'name: axe\n' > "$PACKAGE_ROOT/AXe_AXe.bundle/manifest.txt"

PACKAGE_ZIP="$WORK_DIR/AXe-Final-dryrun.zip"
ditto -c -k --norsrc --noextattr --noqtn --keepParent "$PACKAGE_ROOT" "$PACKAGE_ZIP"

./scripts/release-artifacts.sh extract-stage \
  --package-zip "$PACKAGE_ZIP" \
  --stage-dir "$STAGE_DIR"

./scripts/release-artifacts.sh verify-stage --stage-dir "$STAGE_DIR"

echo "[release-dry-run] Verifying AppleDouble sanitization"
CONTAMINATED_DIR="$WORK_DIR/contaminated-output"
CONTAMINATED_STAGE="$WORK_DIR/contaminated-stage"
cp -R "$PACKAGE_ROOT" "$CONTAMINATED_DIR"
touch "$CONTAMINATED_DIR/._axe" \
  "$CONTAMINATED_DIR/Resources/._SimulatorFrameworkBridge-iOS"
xattr -w com.example.axe-dry-run test "$CONTAMINATED_DIR/axe"
./scripts/release-artifacts.sh stage-build-output \
  --build-output-dir "$CONTAMINATED_DIR" \
  --stage-dir "$CONTAMINATED_STAGE"
./scripts/release-artifacts.sh verify-stage --stage-dir "$CONTAMINATED_STAGE"
[[ -z "$(xattr -p com.example.axe-dry-run "$CONTAMINATED_STAGE/axe" 2>/dev/null)" ]]
./scripts/release-artifacts.sh create-universal-archive --stage-dir "$STAGE_DIR" --archive "$UNIVERSAL_ARCHIVE"
./scripts/release-artifacts.sh create-homebrew-archive --stage-dir "$STAGE_DIR" --archive "$HOMEBREW_ARCHIVE"

UNIVERSAL_VERIFY_DIR="$WORK_DIR/verify-universal"
HOMEBREW_VERIFY_DIR="$WORK_DIR/verify-homebrew"
mkdir -p "$UNIVERSAL_VERIFY_DIR" "$HOMEBREW_VERIFY_DIR"
tar -xzf "$UNIVERSAL_ARCHIVE" -C "$UNIVERSAL_VERIFY_DIR"
tar -xzf "$HOMEBREW_ARCHIVE" -C "$HOMEBREW_VERIFY_DIR"
./scripts/release-artifacts.sh verify-stage --stage-dir "$UNIVERSAL_VERIFY_DIR"
./scripts/release-artifacts.sh verify-stage --stage-dir "$HOMEBREW_VERIFY_DIR"

echo "[release-dry-run] Verifying the stable-name archive and SHA256SUMS"
STABLE_ARCHIVE="$OUT_DIR/axe-aarch64-apple-darwin.tar.gz"
cp "$HOMEBREW_ARCHIVE" "$STABLE_ARCHIVE"
cmp "$HOMEBREW_ARCHIVE" "$STABLE_ARCHIVE"
(
  cd "$OUT_DIR"
  shasum -a 256 \
    "$(basename "$UNIVERSAL_ARCHIVE")" \
    "$(basename "$HOMEBREW_ARCHIVE")" \
    "$(basename "$STABLE_ARCHIVE")" \
    > SHA256SUMS
  shasum -a 256 -c SHA256SUMS
)
[[ "$(wc -l < "$OUT_DIR/SHA256SUMS" | tr -d ' ')" -eq 3 ]]
# Bare file names only, so the check passes in any download folder.
if grep -q '/' "$OUT_DIR/SHA256SUMS"; then
  echo "[release-dry-run] ERROR: SHA256SUMS must list bare file names"
  exit 1
fi

HOMEBREW_SHA="$(shasum -a 256 "$HOMEBREW_ARCHIVE" | awk '{print $1}')"

./scripts/generate-homebrew-formula.sh \
  --formula-class "$FORMULA_CLASS" \
  --homepage "$HOMEPAGE" \
  --version "$VERSION" \
  --url "${HOMEPAGE}/releases/download/${TAG}/$(basename "$HOMEBREW_ARCHIVE")" \
  --sha256 "$HOMEBREW_SHA" \
  > "$FORMULA_OUT"

grep -q 'depends_on arch: :arm64' "$FORMULA_OUT"
grep -q 'depends_on macos: :sequoia' "$FORMULA_OUT"
grep -q 'libexec.install "axe", "AXe_AXe.bundle", "Resources"' "$FORMULA_OUT"
grep -q 'bin.write_exec_script libexec/"axe"' "$FORMULA_OUT"
grep -q 'def post_install' "$FORMULA_OUT"
# post_install must re-sign axe only, never the simulator helper.
[[ "$(grep -c '"codesign"' "$FORMULA_OUT")" -eq 1 ]]
! grep -q 'Frameworks' "$FORMULA_OUT"

tmp_dir="$WORK_DIR/normalized-formulas"
mkdir -p "$tmp_dir"
normalize_formula() {
  local input_path="$1"
  perl \
    -pe 's/^  desc ".*"$/  desc "<normalized>"/;' \
    -pe 's/^  version ".*"$/  version "<normalized>"/;' \
    -pe 's/^  url ".*"$/  url "<normalized>"/;' \
    -pe 's/^  sha256 ".*"$/  sha256 "<normalized>"/;' \
    "$input_path"
}

normalize_formula "$FORMULA_OUT" > "$tmp_dir/generated.rb"
normalize_formula "$CANONICAL_FORMULA_PATH" > "$tmp_dir/canonical.rb"

cmp -s "$tmp_dir/generated.rb" "$tmp_dir/canonical.rb"

node <<'NODE'
const { execFileSync } = require('node:child_process');

function resolve(mode, ref, sha, runNumber, signing = 'available') {
  const output = execFileSync('node', ['scripts/release-context.mjs', '--mode', mode, '--requested-ref', ref, '--commit-sha', sha, '--run-number', runNumber, '--signing', signing], { encoding: 'utf8', stdio: ['ignore', 'pipe', 'pipe'] });
  return Object.fromEntries(output.trim().split('\n').map((line) => {
    const separator = line.indexOf('=');
    return [line.slice(0, separator), line.slice(separator + 1)];
  }));
}

function resolveFails(mode, ref, signing, expectedMessage) {
  try {
    resolve(mode, ref, 'abcdef0123456789', '42', signing);
  } catch (error) {
    const stderr = String(error.stderr ?? '');
    if (!stderr.includes(expectedMessage)) {
      throw new Error(`${mode} with signing ${signing} failed with an unexpected message: ${stderr}`);
    }
    return;
  }
  throw new Error(`${mode} with signing ${signing} must fail`);
}

const productionShipping = resolve('production-shipping', 'refs/tags/v1.5.2', 'abcdef0123456789', '42');
if (productionShipping.publishRelease !== 'true' || productionShipping.updateTapTarget !== 'production' || productionShipping.stageSource !== 'notarized-package' || productionShipping.signed !== 'true') {
  throw new Error('production-shipping context is invalid');
}

const productionVerify = resolve('production-verify', 'refs/tags/v1.5.2-beta.1', 'abcdef0123456789', '42');
if (productionVerify.publishRelease !== 'false' || productionVerify.uploadArtifacts !== 'true' || productionVerify.updateTapTarget !== 'none' || productionVerify.signed !== 'true') {
  throw new Error('production-verify context is invalid');
}

if (productionShipping.releaseTitle !== 'Release v1.5.2') {
  throw new Error('signed production-shipping title must not carry the unsigned marker');
}

const productionShippingUnsigned = resolve('production-shipping', 'refs/tags/v1.5.2', 'abcdef0123456789', '42', 'unavailable');
if (productionShippingUnsigned.publishRelease !== 'true' || productionShippingUnsigned.prerelease !== 'false' || productionShippingUnsigned.updateTapTarget !== 'production' || productionShippingUnsigned.notesMode !== 'changelog' || productionShippingUnsigned.stageSource !== 'build-output' || productionShippingUnsigned.signed !== 'false' || productionShippingUnsigned.releaseTitle !== 'Release v1.5.2 (unsigned)' || productionShippingUnsigned.releaseTag !== 'v1.5.2') {
  throw new Error('unsigned production-shipping context is invalid');
}

const productionShippingUnsignedPrerelease = resolve('production-shipping', 'refs/tags/v1.5.2-fork.1', 'abcdef0123456789', '42', 'unavailable');
if (productionShippingUnsignedPrerelease.prerelease !== 'true' || productionShippingUnsignedPrerelease.updateTapTarget !== 'staging' || productionShippingUnsignedPrerelease.releaseTitle !== 'Release v1.5.2-fork.1 (unsigned)') {
  throw new Error('unsigned production-shipping prerelease context is invalid');
}

const productionVerifyUnsigned = resolve('production-verify', 'refs/tags/v1.5.2-beta.1', 'abcdef0123456789', '42', 'unavailable');
if (productionVerifyUnsigned.publishRelease !== 'false' || productionVerifyUnsigned.uploadArtifacts !== 'true' || productionVerifyUnsigned.updateTapTarget !== 'none' || productionVerifyUnsigned.notesMode !== 'none' || productionVerifyUnsigned.stageSource !== 'build-output' || productionVerifyUnsigned.signed !== 'false') {
  throw new Error('unsigned production-verify context is invalid');
}

resolveFails('staging-publish', 'refs/heads/main', 'maybe', 'Invalid --signing value');

const stagingPublish = resolve('staging-publish', 'refs/heads/main', 'abcdef0123456789', '42');
if (stagingPublish.publishRelease !== 'true' || stagingPublish.uploadArtifacts !== 'false' || stagingPublish.updateTapTarget !== 'staging' || stagingPublish.stageSource !== 'notarized-package' || stagingPublish.signed !== 'true' || stagingPublish.releaseTitle.includes('(unsigned)')) {
  throw new Error('staging-publish context is invalid');
}

const stagingPublishUnsigned = resolve('staging-publish', 'refs/heads/main', 'abcdef0123456789', '42', 'unavailable');
if (stagingPublishUnsigned.publishRelease !== 'true' || stagingPublishUnsigned.uploadArtifacts !== 'false' || stagingPublishUnsigned.prerelease !== 'true' || stagingPublishUnsigned.updateTapTarget !== 'staging' || stagingPublishUnsigned.notesMode !== 'staging' || stagingPublishUnsigned.stageSource !== 'build-output' || stagingPublishUnsigned.signed !== 'false' || !stagingPublishUnsigned.releaseTitle.endsWith('(unsigned)') || stagingPublishUnsigned.releaseTag !== stagingPublish.releaseTag) {
  throw new Error('unsigned staging-publish context is invalid');
}

const stagingValidate = resolve('staging-validate', 'refs/heads/feature/release-work', 'abcdef0123456789', '42');
if (stagingValidate.publishRelease !== 'false' || stagingValidate.uploadArtifacts !== 'true' || stagingValidate.updateTapTarget !== 'none' || stagingValidate.notesMode !== 'none' || stagingValidate.stageSource !== 'build-output' || stagingValidate.signed !== 'true') {
  throw new Error('staging-validate context is invalid');
}

const stagingValidateUnsigned = resolve('staging-validate', 'refs/heads/feature/release-work', 'abcdef0123456789', '42', 'unavailable');
if (stagingValidateUnsigned.stageSource !== 'build-output' || stagingValidateUnsigned.signed !== 'false' || stagingValidateUnsigned.releaseTitle !== stagingValidate.releaseTitle) {
  throw new Error('unsigned staging-validate context is invalid');
}

const unsignedNotes = execFileSync('node', ['scripts/generate-github-release-notes.mjs', '--channel', 'staging', '--version', '0.0.0-staging.42', '--ref', 'refs/heads/main', '--commit-sha', 'abcdef0123456789', '--unsigned'], { encoding: 'utf8' });
if (!unsignedNotes.includes('## Unsigned build') || !unsignedNotes.includes('xattr -dr com.apple.quarantine')) {
  throw new Error('unsigned release notes are missing the unsigned build notice');
}

const signedNotes = execFileSync('node', ['scripts/generate-github-release-notes.mjs', '--channel', 'staging', '--version', '0.0.0-staging.42', '--ref', 'refs/heads/main', '--commit-sha', 'abcdef0123456789'], { encoding: 'utf8' });
if (signedNotes.includes('## Unsigned build')) {
  throw new Error('signed release notes must not carry the unsigned build notice');
}
if (!signedNotes.includes('brew tap cameroncooke/axe-staging') || !signedNotes.includes('brew install cameroncooke/axe-staging/axe')) {
  throw new Error('staging release notes must default to the cameroncooke staging tap');
}

const forkNotes = execFileSync('node', ['scripts/generate-github-release-notes.mjs', '--channel', 'staging', '--version', '0.0.0-staging.42', '--ref', 'refs/heads/main', '--commit-sha', 'abcdef0123456789', '--tap-owner', 'example-fork'], { encoding: 'utf8' });
if (!forkNotes.includes('brew tap example-fork/axe-staging') || !forkNotes.includes('brew install example-fork/axe-staging/axe') || forkNotes.includes('cameroncooke')) {
  throw new Error('staging release notes must use the --tap-owner tap');
}

const forkProductionNotes = execFileSync('node', ['scripts/generate-github-release-notes.mjs', '--version', '999.0.0', '--fallback', 'newest-older', '--tap-owner', 'example-fork'], { encoding: 'utf8' });
if (!forkProductionNotes.includes('brew tap example-fork/axe') || forkProductionNotes.includes('brew tap cameroncooke/axe')) {
  throw new Error('production release notes must use the --tap-owner tap');
}
for (const asset of ['AXe-macOS-v999.0.0-universal.tar.gz', 'AXe-macOS-homebrew-v999.0.0.tar.gz', 'axe-aarch64-apple-darwin.tar.gz', 'SHA256SUMS']) {
  if (!forkProductionNotes.includes(`\`${asset}\``)) {
    throw new Error(`production release notes must list the ${asset} asset`);
  }
}

const unsignedProductionNotes = execFileSync('node', ['scripts/generate-github-release-notes.mjs', '--channel', 'production', '--version', '999.0.0', '--fallback', 'newest-older', '--unsigned'], { encoding: 'utf8' });
if (!unsignedProductionNotes.includes('## Unsigned build') || !unsignedProductionNotes.includes("## What's Changed")) {
  throw new Error('unsigned production release notes must carry the unsigned build notice');
}
if (forkProductionNotes.includes('## Unsigned build')) {
  throw new Error('signed production release notes must not carry the unsigned build notice');
}
NODE

# The tap script requires the tap owner; without arguments it prints the usage and fails.
if TAP_USAGE="$(./scripts/update-homebrew-tap.sh 2>&1)"; then
  echo "[release-dry-run] ERROR: update-homebrew-tap.sh must fail without arguments"
  exit 1
fi
grep -q -- '--tap-owner OWNER' <<<"$TAP_USAGE"
grep -q 'OWNER/homebrew-axe-staging' <<<"$TAP_USAGE"
if grep -q 'cameroncooke' scripts/update-homebrew-tap.sh; then
  echo "[release-dry-run] ERROR: update-homebrew-tap.sh must not hard-code the tap owner"
  exit 1
fi
grep -q -- '--tap-owner "${{ github.repository_owner }}" \\$' .github/workflows/release-shared.yml
grep -q -- '--tap-owner "${{ github.repository_owner }}"$' .github/workflows/release-shared.yml

# Every release carries the stable-name archive and SHA256SUMS, also as validate/verify artifacts.
grep -q '^          STABLE_ARCHIVE_NAME="axe-aarch64-apple-darwin.tar.gz"$' .github/workflows/release-shared.yml
grep -q '^          shasum -a 256 -c SHA256SUMS$' .github/workflows/release-shared.yml
grep -q -- '--asset "${{ steps.create_checksums.outputs.stable_archive_name }}"' .github/workflows/release-shared.yml
grep -q -- '--asset "${{ steps.create_checksums.outputs.checksums_name }}"' .github/workflows/release-shared.yml
grep -q '^            ${{ steps.create_checksums.outputs.stable_archive_name }}$' .github/workflows/release-shared.yml
grep -q '^            ${{ steps.create_checksums.outputs.checksums_name }}$' .github/workflows/release-shared.yml
[[ "$(grep -n 'name: Create Homebrew archive' .github/workflows/release-shared.yml | cut -d: -f1)" -lt \
  "$(grep -n 'name: Create stable-name archive and checksums' .github/workflows/release-shared.yml | cut -d: -f1)" ]]

grep -q '^  pull_request:$' .github/workflows/release-staging.yml
grep -q "description: 'Exact ref to build for staging (branch, tag, or SHA)'" .github/workflows/release-staging.yml
grep -q '^        required: true$' .github/workflows/release-staging.yml
grep -q '^        default: validate$' .github/workflows/release-staging.yml
grep -q '^  staging-validate:$' .github/workflows/release-staging.yml
grep -q '^  staging-publish:$' .github/workflows/release-staging.yml
grep -q "mode: staging-validate" .github/workflows/release-staging.yml
grep -q "mode: staging-publish" .github/workflows/release-staging.yml
grep -q "github.event_name == 'pull_request' && github.sha" .github/workflows/release-staging.yml
! grep -q 'defaults to main' .github/workflows/release-staging.yml
! grep -q "github.event_name == 'pull_request' && github.event.pull_request.head.sha" .github/workflows/release-staging.yml
grep -q "^      - 'staging/\*\*'$" .github/workflows/release-staging.yml
grep -q '^    types: \[opened, synchronize, reopened, labeled\]$' .github/workflows/release-staging.yml
grep -q "contains(github.event.pull_request.labels.\*.name, 'publish-staging')" .github/workflows/release-staging.yml
grep -q "github.event.pull_request.head.repo.full_name == github.repository" .github/workflows/release-staging.yml
grep -q "github.event_name == 'pull_request' && github.event.pull_request.head.ref" .github/workflows/release-staging.yml
# contents: write belongs to the publish job only.
[[ "$(grep -c 'contents: write' .github/workflows/release-staging.yml)" -eq 1 ]]

grep -q '^      - name: Resolve signing availability$' .github/workflows/release-shared.yml
grep -q -- '--signing "${{ steps.signing_availability.outputs.signing }}"' .github/workflows/release-shared.yml
grep -q 'if \[ "${{ steps.context.outputs.stageSource }}" = "notarized-package" \]; then' .github/workflows/release-shared.yml
grep -q 'NOTES_ARGS+=(--unsigned)' .github/workflows/release-shared.yml
grep -q 'skipping the staging tap update' .github/workflows/release-shared.yml
if grep -q 'if \[ "${{ steps.context.outputs.publishRelease }}" = "true" \]; then' .github/workflows/release-shared.yml; then
  echo "[release-dry-run] ERROR: the certificate check must key off stageSource, not publishRelease"
  exit 1
fi
# The signing step must run before the context step that consumes its output.
[[ "$(grep -n 'name: Resolve signing availability' .github/workflows/release-shared.yml | cut -d: -f1)" -lt \
  "$(grep -n 'name: Resolve release context' .github/workflows/release-shared.yml | cut -d: -f1)" ]]

echo "[release-dry-run] OK"
echo "[release-dry-run] universal archive: $UNIVERSAL_ARCHIVE"
echo "[release-dry-run] homebrew archive: $HOMEBREW_ARCHIVE"
echo "[release-dry-run] formula: $FORMULA_OUT"
