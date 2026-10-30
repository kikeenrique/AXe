#!/bin/bash
# Builds the IDB static libraries AXe links, then the AXe executable and its release payload.

set -e
set -o pipefail

# On a TTY, git eagerly spawns an interactive pager for diff/log commands —
# even with empty output — blocking the build until 'q' is pressed. Force
# plain output for this script and any child scripts.
export GIT_PAGER=cat

# Resolve paths relative to this script so the build works from any CWD.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

# --- Local environment overrides (.env) ---
# Load KEY=VALUE pairs from a local, git-ignored .env file (repo root by
# default; override with AXE_ENV_FILE). This is where per-machine constants
# such as the code-signing identity live. Values already present in the
# environment win over the file, so `AXE_CODESIGN_IDENTITY=... ./build.sh`
# still works. See .env.example for the supported keys.
ENV_FILE="${AXE_ENV_FILE:-${REPO_ROOT}/.env}"

function load_env_file() {
  local file="$1"
  [[ -f "$file" ]] || return 0
  local line key value
  while IFS= read -r line || [[ -n "$line" ]]; do
    # Trim leading whitespace and an optional `export ` prefix.
    line="${line#"${line%%[![:space:]]*}"}"
    line="${line#export }"
    # Skip blank lines and comments.
    [[ -z "$line" || "$line" == \#* ]] && continue
    # Require a KEY=VALUE shape.
    [[ "$line" == *=* ]] || continue
    key="${line%%=*}"
    value="${line#*=}"
    # Normalise the key and strip one optional pair of surrounding quotes.
    key="${key//[[:space:]]/}"
    [[ -z "$key" ]] && continue
    if [[ "$value" == \"*\" || "$value" == \'*\' ]]; then
      value="${value:1:${#value}-2}"
    fi
    # Only fill values that are not already set in the environment.
    if [[ -z "${!key+x}" ]]; then
      export "${key}=${value}"
    fi
  done < "$file"
  return 0
}

load_env_file "${ENV_FILE}"

# Environment and Configuration
DEFAULT_IDB_CHECKOUT_DIR="${REPO_ROOT}/idb_checkout"
IDB_CHECKOUT_DIR="${IDB_CHECKOUT_DIR:-${DEFAULT_IDB_CHECKOUT_DIR}}"
IDB_CHECKOUT_DIR="$(cd "$(dirname "$IDB_CHECKOUT_DIR")" && pwd)/$(basename "$IDB_CHECKOUT_DIR")"
# Upstream facebook/idb, pinned to the immutable commit of tag v1.7.7. IDB_GIT_URL/IDB_GIT_REF
# overrides are for local development only: refuse_idb_override_in_release_mode rejects them in
# release commands and on CI. (release-shared.yml parses the two lines below; keep their shape.)
DEFAULT_IDB_GIT_URL="https://github.com/facebook/idb.git"
IDB_GIT_URL="${IDB_GIT_URL:-https://github.com/facebook/idb.git}"
DEFAULT_IDB_GIT_REF="1de1629a8e5e9838d841689e122d0bd0085a92b6"
IDB_GIT_REF="${IDB_GIT_REF:-${DEFAULT_IDB_GIT_REF}}"
BUILD_OUTPUT_DIR="${BUILD_OUTPUT_DIR:-./build_products}"
DERIVED_DATA_PATH="${DERIVED_DATA_PATH:-./build_derived_data}"
# Static archives, Swift modules and the simulator helper AXe consumes. Package.swift reads
# build_products/idb/lib, so a non-default BUILD_OUTPUT_DIR only suits the release steps.
IDB_PRODUCTS_DIR="${BUILD_OUTPUT_DIR}/idb"
IDB_LIBRARY_DIR="${IDB_PRODUCTS_DIR}/lib"
IDB_BRIDGE_DIR="${IDB_PRODUCTS_DIR}/bridge"
FBSIMCONTROL_PROJECT="${IDB_CHECKOUT_DIR}/FBSimulatorControl.xcodeproj"
SIMULATOR_BRIDGE_PROJECT="${IDB_CHECKOUT_DIR}/SimulatorFrameworkBridge/SimulatorFrameworkBridge.xcodeproj"
TEMP_DIR="${TEMP_DIR:-$(mktemp -d)}"
IDB_REPLACEMENT_ROOT=""

# The IDB libraries AXe links, in link order. Keep in sync with `idbArchives` in Package.swift.
# Every one except FBControlCoreObjC (Objective-C, module map in the checkout) has a Swift module.
IDB_LIBRARIES=(
  "FBSimulatorAX"
  "FBSimulatorServices"
  "FBSimulatorVideo"
  "FBVideoCore"
  "FBSimulatorControl"
  "FBSimulatorBridgeProtocol"
  "SimulatorIPC"
  "FBControlCore"
  "FBControlCoreObjC"
  "IDBConcurrency"
)

# The in-simulator helper FBSimulatorServices/FBSimulatorAX spawn in the guest (accessibility on
# multi-display simulators, services). Upstream's BundledResources.directoryPath() finds it, for a
# standalone binary, in a `Resources/` directory beside the resolved executable path; a host may
# instead set BundledResources.hostDirectoryPath. The release payload therefore ships it as
# `Resources/SimulatorFrameworkBridge-iOS` next to `axe` (see release-payload.sh). It is built for
# the iOS Simulator and ad-hoc signed with its entitlements by its own project: never re-sign it.
SIMULATOR_BRIDGE_NAME="SimulatorFrameworkBridge-iOS"

# Shared payload helper
# shellcheck source=./release-payload.sh
source "${SCRIPT_DIR}/release-payload.sh"

LIBRARY_CONFIGURATION="Release"
# Upstream builds arm64 only (ARCHS=arm64 in its build.sh); AXe ships Apple silicon only.
TARGET_ARCH="arm64"

# Codesigning configuration.
# Provided via AXE_CODESIGN_IDENTITY (from .env locally, or the environment / CI
# secrets) — there is intentionally no baked-in default. Must be a
# "Developer ID Application" identity for notarizable release builds; an
# "Apple Development" identity is fine for local `dev` builds only.
CODESIGN_IDENTITY="${AXE_CODESIGN_IDENTITY:-}"

# Notarization configuration (provided via the environment / .env / CI secrets).
NOTARIZATION_API_KEY_PATH="${NOTARIZATION_API_KEY_PATH:-}"
NOTARIZATION_KEY_ID="${NOTARIZATION_KEY_ID:-}"
NOTARIZATION_ISSUER_ID="${NOTARIZATION_ISSUER_ID:-}"

# Fail fast with an actionable message when a required value is missing, rather
# than letting codesign/notarytool fail obscurely later.
function require_config() {
  local name="$1" value="$2"
  if [[ -z "${value}" ]]; then
    echo "❌ Error: ${name} is not set. Set it in ${ENV_FILE} (copy .env.example) or export it in the environment." >&2
    exit 1
  fi
}

# --- Helper Functions ---

# Function to print a section header with emoji
function print_section() {
  local emoji="$1"
  local title="$2"
  echo ""
  echo ""
  echo "${emoji} ${title}"
  echo "$(printf '·%.0s' {1..60})"
}

# Function to print a subsection header
function print_subsection() {
  local emoji="$1"
  local title="$2"
  echo ""
  echo "${emoji} ${title}"
}

# Function to print success message
function print_success() {
  local message="$1"
  echo "✅ ${message}"
}

# Function to print info message
function print_info() {
  local message="$1"
  echo "ℹ️  ${message}"
}

# Function to print warning message
function print_warning() {
  local message="$1"
  echo "⚠️  ${message}"
}

# Absolute form of a directory path (relative paths resolve against the current directory).
function absolute_dir() {
  local dir="$1"
  mkdir -p "$dir"
  (cd "$dir" && pwd)
}

function remove_idb_replacement() {
  local replacement_root="$1"
  local checkout_parent
  checkout_parent="$(dirname "$IDB_CHECKOUT_DIR")"

  if [[ -L "$replacement_root" || ! -d "$replacement_root" ||
        "$(dirname "$replacement_root")" != "$checkout_parent" ||
        "$(basename "$replacement_root")" != .axe-idb-replacement.* ]]; then
    print_warning "Refusing unsafe IDB replacement cleanup: $replacement_root"
    return 0
  fi

  rm -r "$replacement_root"
}

function cleanup_current_idb_replacement() {
  [[ -n "$IDB_REPLACEMENT_ROOT" ]] || return 0
  remove_idb_replacement "$IDB_REPLACEMENT_ROOT"
  IDB_REPLACEMENT_ROOT=""
}

function cleanup_stale_idb_replacements() {
  local checkout_parent candidate owner_pid
  checkout_parent="$(dirname "$IDB_CHECKOUT_DIR")"

  for candidate in "$checkout_parent"/.axe-idb-replacement.*; do
    [[ ! -L "$candidate" && -d "$candidate" ]] || continue
    [[ ! -L "$candidate/.axe-owner-pid" && -f "$candidate/.axe-owner-pid" ]] || continue
    owner_pid="$(< "$candidate/.axe-owner-pid")"
    if [[ "$owner_pid" =~ ^[0-9]+$ ]] && kill -0 "$owner_pid" 2>/dev/null; then
      continue
    fi
    print_info "Removing stale managed IDB replacement directory: $candidate"
    remove_idb_replacement "$candidate"
  done
}

trap cleanup_current_idb_replacement EXIT

function codesign_with_retry() {
  local max_attempts=5
  local delay=10
  local attempt=1
  while [ $attempt -le $max_attempts ]; do
    if codesign "$@" 2>&1; then
      return 0
    fi
    local exit_code=$?
    if [ $attempt -lt $max_attempts ]; then
      print_warning "codesign failed (attempt $attempt/$max_attempts), retrying in ${delay}s..."
      sleep $delay
      delay=$((delay * 2))
    fi
    attempt=$((attempt + 1))
  done
  echo "❌ Error: codesign failed after $max_attempts attempts"
  return 1
}

function verify_macho_has_arch() {
  local binary_path="$1"
  local expected_arch="$2"

  if [[ ! -f "$binary_path" ]]; then
    echo "❌ Error: Binary not found for architecture verification: $binary_path"
    exit 1
  fi

  local arch_info
  arch_info=$(lipo -info "$binary_path" 2>/dev/null || true)
  if [[ "$arch_info" != *"$expected_arch"* ]]; then
    echo "❌ Error: Missing architecture '${expected_arch}' in $binary_path"
    echo "   lipo output: ${arch_info:-<empty>}"
    exit 1
  fi
}

# Exactly the given architectures, nothing else (the release is Apple silicon only).
function verify_macho_archs_exactly() {
  local binary_path="$1"
  local expected_archs="$2"

  if [[ ! -f "$binary_path" ]]; then
    echo "❌ Error: Binary not found for architecture verification: $binary_path"
    exit 1
  fi

  local archs
  archs=$(lipo -archs "$binary_path" 2>/dev/null || true)
  if [[ "$archs" != "$expected_archs" ]]; then
    echo "❌ Error: Expected only '${expected_archs}' in $binary_path, found '${archs:-<none>}'"
    exit 1
  fi
}

# The simulator helper must be an iOS Simulator arm64 binary whose own signature still verifies.
function verify_simulator_bridge() {
  local bridge_path="$1"

  if [[ ! -f "$bridge_path" || ! -x "$bridge_path" ]]; then
    echo "❌ Error: ${SIMULATOR_BRIDGE_NAME} missing or not executable: $bridge_path"
    exit 1
  fi
  verify_macho_has_arch "$bridge_path" "$TARGET_ARCH"
  if ! xcrun vtool -show-build "$bridge_path" 2>/dev/null | grep -q "IOSSIMULATOR"; then
    echo "❌ Error: ${SIMULATOR_BRIDGE_NAME} is not built for the iOS Simulator: $bridge_path"
    exit 1
  fi
  if ! codesign --verify --strict "$bridge_path" >/dev/null 2>&1; then
    echo "❌ Error: ${SIMULATOR_BRIDGE_NAME} signature does not verify (it must never be re-signed): $bridge_path"
    exit 1
  fi
}

# Function to invoke xcodebuild with upstream IDB's common settings
# (scripts `invoke_xcodebuild` in facebook/idb build.sh).
function invoke_xcodebuild() {
  local xcodebuild_root
  xcodebuild_root="$(absolute_dir "${DERIVED_DATA_PATH}")"
  local arguments=(
    -skipMacroValidation
    ENABLE_USER_SCRIPT_SANDBOXING=NO
    CLANG_ENABLE_EXPLICIT_MODULES=NO
    ARCHS="${TARGET_ARCH}"
    ONLY_ACTIVE_ARCH=NO
    SYMROOT="${xcodebuild_root}/Products"
    OBJROOT="${xcodebuild_root}/Intermediates"
    -derivedDataPath "${xcodebuild_root}"
    "$@"
  )
  print_info "Executing: xcodebuild ${arguments[*]}"
  xcodebuild "${arguments[@]}" 2>&1
}

function swift_build_bin_path() {
  local build_config="$1"
  local target_arch="$2"
  swift build --configuration "$build_config" --arch "$target_arch" --show-bin-path
}

function copy_resource_bundle() {
  local output_base_dir="$1"
  local bundle_name="AXe_AXe.bundle"
  local bundle_dest="${output_base_dir}/${bundle_name}"
  local bundle_source
  bundle_source="$(swift_build_bin_path "release" "${TARGET_ARCH}")/${bundle_name}"

  if [[ ! -d "$bundle_source" ]]; then
    echo "❌ Error: AXe resource bundle not found in Swift build outputs: ${bundle_source}"
    exit 1
  fi

  rm -rf "$bundle_dest"
  cp -R "$bundle_source" "$bundle_dest"
  print_success "AXe resource bundle installed to ${bundle_dest}"
}

# Copies the simulator helper into the payload's `Resources/` beside `axe`, keeping its signature.
function install_simulator_bridge() {
  local output_base_dir="$1"
  local bridge_source="${IDB_BRIDGE_DIR}/${SIMULATOR_BRIDGE_NAME}"
  local resources_dir="${output_base_dir}/Resources"

  verify_simulator_bridge "$bridge_source"
  rm -rf "$resources_dir"
  mkdir -p "$resources_dir"
  ditto "$bridge_source" "${resources_dir}/${SIMULATOR_BRIDGE_NAME}"
  verify_simulator_bridge "${resources_dir}/${SIMULATOR_BRIDGE_NAME}"
  print_success "${SIMULATOR_BRIDGE_NAME} installed to ${resources_dir}"
}

function fresh_clone_idb_repo() {
  if [[ -e "$IDB_CHECKOUT_DIR" ]]; then
    local existing_remote
    existing_remote="$(git -C "$IDB_CHECKOUT_DIR" remote get-url origin 2>/dev/null || true)"
    if [[ ! -f "$IDB_CHECKOUT_DIR/.git/axe-managed-checkout" &&
          ( "$IDB_CHECKOUT_DIR" != "$DEFAULT_IDB_CHECKOUT_DIR" || "$existing_remote" != "$IDB_GIT_URL" ) ]]; then
      echo "❌ Error: Refusing to replace an unmanaged IDB checkout: $IDB_CHECKOUT_DIR" >&2
      echo "   Remove or repair that checkout manually, then retry." >&2
      return 1
    fi
  fi

  IDB_REPLACEMENT_ROOT="$(mktemp -d "$(dirname "$IDB_CHECKOUT_DIR")/.axe-idb-replacement.XXXXXX")"
  printf '%s\n' "$$" > "$IDB_REPLACEMENT_ROOT/.axe-owner-pid"
  local replacement_checkout
  replacement_checkout="${IDB_REPLACEMENT_ROOT}/checkout"
  print_info "Cloning IDB into $IDB_CHECKOUT_DIR..."
  if ! git clone --no-checkout "$IDB_GIT_URL" "$replacement_checkout" ||
     ! git -C "$replacement_checkout" checkout --detach "$IDB_GIT_REF"; then
    cleanup_current_idb_replacement
    return 1
  fi
  touch "$replacement_checkout/.git/axe-managed-checkout"
  if [[ -e "$IDB_CHECKOUT_DIR" ]]; then
    rm -r "$IDB_CHECKOUT_DIR"
  fi
  mv "$replacement_checkout" "$IDB_CHECKOUT_DIR"
  cleanup_current_idb_replacement
  print_success "IDB cloned at $IDB_GIT_REF."
}

function clone_idb_repo() {
  cleanup_stale_idb_replacements
  if [[ ! -d "$IDB_CHECKOUT_DIR/.git" ]]; then
    fresh_clone_idb_repo
  else
    local actual_ref actual_remote
    actual_ref="$(git -C "$IDB_CHECKOUT_DIR" rev-parse HEAD 2>/dev/null || true)"
    actual_remote="$(git -C "$IDB_CHECKOUT_DIR" remote get-url origin 2>/dev/null || true)"
    if [[ "$actual_ref" == "$IDB_GIT_REF" && "$actual_remote" == "$IDB_GIT_URL" ]] &&
       git -C "$IDB_CHECKOUT_DIR" cat-file -e "${IDB_GIT_REF}^{tree}" 2>/dev/null; then
      if [[ -n "$(git -C "$IDB_CHECKOUT_DIR" status --porcelain)" ]]; then
        if [[ "$IDB_CHECKOUT_DIR" != "$DEFAULT_IDB_CHECKOUT_DIR" &&
              ! -f "$IDB_CHECKOUT_DIR/.git/axe-managed-checkout" ]]; then
          echo "Error: Refusing to repair an unmanaged IDB checkout: $IDB_CHECKOUT_DIR" >&2
          echo "   Clean or repair that checkout manually, then retry." >&2
          return 1
        fi
        print_warning "The pinned IDB checkout is dirty; repairing the managed checkout locally."
        if ! git -C "$IDB_CHECKOUT_DIR" restore --source=HEAD --staged --worktree -- . ||
           ! git -C "$IDB_CHECKOUT_DIR" clean -fd; then
          if [[ "$IDB_CHECKOUT_DIR" == "$DEFAULT_IDB_CHECKOUT_DIR" ]]; then
            fresh_clone_idb_repo
          else
            echo "Error: Unable to repair managed IDB checkout: $IDB_CHECKOUT_DIR" >&2
            return 1
          fi
        fi
      fi
      touch "$IDB_CHECKOUT_DIR/.git/axe-managed-checkout"
      print_info "Reusing pinned IDB checkout at $IDB_GIT_REF."
      verify_idb_source_state
      return 0
    fi

    print_info "Updating IDB checkout to $IDB_GIT_URL@$IDB_GIT_REF..."
    git -C "$IDB_CHECKOUT_DIR" remote set-url origin "$IDB_GIT_URL"
    if ! (cd "$IDB_CHECKOUT_DIR" && git fetch origin --tags --prune && git checkout -- . && git clean -fd && git checkout --detach "$IDB_GIT_REF"); then
      print_warning "The cached IDB checkout is incomplete; replacing it with a clean clone."
      fresh_clone_idb_repo
    else
      print_success "IDB checkout updated to $IDB_GIT_REF."
    fi
  fi
  verify_idb_source_state
}

function verify_idb_source_state() {
  local actual_ref
  actual_ref=$(git -C "$IDB_CHECKOUT_DIR" rev-parse HEAD)
  if [[ "$actual_ref" != "$IDB_GIT_REF" ]]; then
    echo "❌ Error: IDB checkout SHA mismatch"
    echo "   Expected: $IDB_GIT_REF"
    echo "   Actual:   $actual_ref"
    exit 1
  fi

  local actual_remote
  actual_remote=$(git -C "$IDB_CHECKOUT_DIR" remote get-url origin)
  if [[ "$actual_remote" != "$IDB_GIT_URL" ]]; then
    echo "❌ Error: IDB checkout remote mismatch"
    echo "   Expected: $IDB_GIT_URL"
    echo "   Actual:   $actual_remote"
    exit 1
  fi

  # Content markers for the upstream API AXe builds on, so a wrong or rewritten pin fails here
  # rather than as Swift errors later.
  local source_checks=(
    "FBSimulatorControl/Management/SimulatorControlBootstrap.swift|public final class SimulatorControlBootstrap"
    "FBSimulatorControl/Commands/SimulatorHIDCommands.swift|public func connect() async throws -> SimulatorHID"
    "FBSimulatorControl/Commands/SimulatorDisplayCommands.swift|public enum SimulatorDisplayRotation"
    "FBSimulatorControl/Commands/SimulatorHingeCommands.swift|public struct SimulatorHingeCommands"
    "FBSimulatorControl/Commands/SimulatorScreenshotCommands.swift|public func take(configuration: ScreenshotConfiguration)"
    "FBSimulatorAX/Commands/Simulator+UIAutomation.swift|public func uiAutomation(backend: UIAutomationBackend"
    "FBControlCore/Utility/BundledResources.swift|public static var hostDirectoryPath"
    "FBSimulatorServices/SimulatorFrameworkBridge/SimulatorFrameworkBridgeSelection.swift|\"${SIMULATOR_BRIDGE_NAME}\""
  )
  local check source_file source_marker
  for check in "${source_checks[@]}"; do
    source_file="${check%%|*}"
    source_marker="${check#*|}"
    if ! grep -Fq "$source_marker" "${IDB_CHECKOUT_DIR}/${source_file}"; then
      echo "❌ Error: Pinned IDB verification failed"
      echo "   Missing '${source_marker}' in ${source_file}"
      echo "   Revision: ${IDB_GIT_URL}@${IDB_GIT_REF}"
      exit 1
    fi
  done

  if ! git -C "$IDB_CHECKOUT_DIR" diff --check; then
    echo "❌ Error: Pinned IDB checkout contains uncommitted whitespace errors"
    exit 1
  fi
  if [[ -n "$(git -C "$IDB_CHECKOUT_DIR" status --porcelain)" ]]; then
    echo "❌ Error: Pinned IDB checkout is not clean"
    exit 1
  fi

  print_success "Verified IDB ${IDB_GIT_URL}@${actual_ref}"
}

# Generates the two upstream projects AXe builds from: FBSimulatorControl.xcodeproj (the
# `Libraries` scheme) and SimulatorFrameworkBridge.xcodeproj. Upstream's own `build.sh generate`
# also generates the companion projects, which AXe does not need. The generated projects are
# ignored by the checkout's .gitignore, so it stays clean.
function generate_idb_projects() {
  if ! command -v xcodegen >/dev/null 2>&1; then
    echo "❌ Error: XcodeGen is required to generate the pinned IDB projects."
    echo "   Install XcodeGen or make an existing installation available in PATH."
    exit 1
  fi

  verify_idb_source_state
  print_info "Generating pinned IDB projects with $(xcodegen --version)..."
  xcodegen generate --spec "${IDB_CHECKOUT_DIR}/project.yml" --project "${IDB_CHECKOUT_DIR}"
  xcodegen generate \
    --spec "${IDB_CHECKOUT_DIR}/SimulatorFrameworkBridge/project.yml" \
    --project "${IDB_CHECKOUT_DIR}/SimulatorFrameworkBridge"
  local project
  for project in "${FBSIMCONTROL_PROJECT}" "${SIMULATOR_BRIDGE_PROJECT}"; do
    if [[ ! -f "${project}/project.pbxproj" ]]; then
      echo "❌ Error: IDB project generation did not produce ${project}/project.pbxproj"
      exit 1
    fi
  done
  print_success "Generated pinned IDB projects"
}

function write_idb_build_evidence() {
  local evidence_path="${IDB_PRODUCTS_DIR}/IDB_BUILD_EVIDENCE.txt"
  mkdir -p "$IDB_PRODUCTS_DIR"
  {
    echo "IDB_SHA=${IDB_GIT_REF}"
    echo "IDB_GIT_URL=${IDB_GIT_URL}"
    echo "IDB_CONFIGURATION=${LIBRARY_CONFIGURATION}"
    echo "IDB_ARCHS=${TARGET_ARCH}"
    echo "DEVELOPER_DIR=${DEVELOPER_DIR:-<not set>}"
    echo "XCODE_VERSION=$(xcodebuild -version | tr '\n' ' ')"
    echo "SWIFT_VERSION=$(swiftc --version 2>&1 | head -1)"
    echo "XCODEGEN_VERSION=$(xcodegen --version)"
  } > "$evidence_path"
  print_success "Recorded IDB build evidence at ${evidence_path}"
}

# Builds every upstream library (the generated `Libraries` scheme) for macOS, then the
# SimulatorFrameworkBridge-iOS guest for the iOS Simulator.
function build_idb_libraries() {
  print_subsection "🔨" "Building IDB scheme: Libraries (${LIBRARY_CONFIGURATION}, ${TARGET_ARCH})"
  if ! invoke_xcodebuild \
    -project "${FBSIMCONTROL_PROJECT}" \
    -scheme Libraries \
    -sdk macosx \
    -destination "generic/platform=macOS" \
    -configuration "${LIBRARY_CONFIGURATION}" \
    build; then
    echo "❌ Error: IDB Libraries build failed"
    exit 1
  fi
  print_success "IDB libraries built"

  print_subsection "🔨" "Building IDB helper: ${SIMULATOR_BRIDGE_NAME}"
  if ! invoke_xcodebuild \
    -project "${SIMULATOR_BRIDGE_PROJECT}" \
    -scheme "${SIMULATOR_BRIDGE_NAME}" \
    -sdk iphonesimulator \
    -destination "generic/platform=iOS Simulator" \
    -configuration Release \
    build; then
    echo "❌ Error: ${SIMULATOR_BRIDGE_NAME} build failed"
    exit 1
  fi
  print_success "${SIMULATOR_BRIDGE_NAME} built"
}

# Copies what AXe links into build_products/idb:
#   lib/lib<Name>.a and lib/<Name>.swiftmodule/ side by side (-L and -I of Package.swift)
#   bridge/SimulatorFrameworkBridge-iOS (copied as built, signature intact)
#   IDB_BUILD_EVIDENCE.txt
function install_idb_libraries() {
  local xcodebuild_root
  xcodebuild_root="$(absolute_dir "${DERIVED_DATA_PATH}")"
  local macos_products="${xcodebuild_root}/Products/${LIBRARY_CONFIGURATION}"
  local simulator_products="${xcodebuild_root}/Products/Release-iphonesimulator"

  print_subsection "📦" "Installing IDB libraries to ${IDB_PRODUCTS_DIR}"
  rm -rf "${IDB_PRODUCTS_DIR}"
  mkdir -p "${IDB_LIBRARY_DIR}" "${IDB_BRIDGE_DIR}"

  local library archive module
  for library in "${IDB_LIBRARIES[@]}"; do
    archive="${macos_products}/lib${library}.a"
    if [[ ! -f "$archive" ]]; then
      echo "❌ Error: Built archive not found: ${archive}"
      exit 1
    fi
    cp "$archive" "${IDB_LIBRARY_DIR}/"
    module="${macos_products}/${library}.swiftmodule"
    if [[ -d "$module" ]]; then
      cp -R "$module" "${IDB_LIBRARY_DIR}/"
    fi
  done

  local bridge="${simulator_products}/${SIMULATOR_BRIDGE_NAME}"
  if [[ ! -f "$bridge" ]]; then
    echo "❌ Error: Built ${SIMULATOR_BRIDGE_NAME} not found: ${bridge}"
    exit 1
  fi
  ditto "$bridge" "${IDB_BRIDGE_DIR}/${SIMULATOR_BRIDGE_NAME}"

  write_idb_build_evidence
  verify_idb_libraries
}

function verify_idb_libraries() {
  print_subsection "🧪" "Validating IDB library inputs"

  local evidence_path="${IDB_PRODUCTS_DIR}/IDB_BUILD_EVIDENCE.txt"
  if ! grep -Fxq "IDB_SHA=${IDB_GIT_REF}" "$evidence_path" 2>/dev/null; then
    echo "❌ Error: ${evidence_path} missing or not built from ${IDB_GIT_REF}"
    exit 1
  fi

  local library archive
  for library in "${IDB_LIBRARIES[@]}"; do
    archive="${IDB_LIBRARY_DIR}/lib${library}.a"
    if [[ ! -f "$archive" ]]; then
      echo "❌ Error: Expected IDB archive missing: ${archive}"
      exit 1
    fi
    verify_macho_archs_exactly "$archive" "${TARGET_ARCH}"
    if [[ "$library" != "FBControlCoreObjC" &&
          ! -f "${IDB_LIBRARY_DIR}/${library}.swiftmodule/${TARGET_ARCH}-apple-macos.swiftmodule" ]]; then
      echo "❌ Error: Swift module missing for ${library} in ${IDB_LIBRARY_DIR}"
      exit 1
    fi
  done

  verify_simulator_bridge "${IDB_BRIDGE_DIR}/${SIMULATOR_BRIDGE_NAME}"
  print_success "IDB libraries are ${TARGET_ARCH} static archives with Swift modules, plus ${SIMULATOR_BRIDGE_NAME}"
}

function remove_xcode_rpaths() {
  local target="$1"
  if [[ ! -f "$target" ]]; then
    return
  fi

  local rpaths
  rpaths=$(otool -l "$target" 2>/dev/null | awk 'BEGIN{r=0} /LC_RPATH/{r=1} r==1 && /path/{print $2; r=0}' | grep "/Applications/Xcode" || true)
  if [[ -n "$rpaths" ]]; then
    while IFS= read -r path; do
      install_name_tool -delete_rpath "$path" "$target" || true
    done <<< "$rpaths"
  fi
}

# Function to build the AXe executable using Swift Package Manager
# $1: Base output directory
function build_axe_executable() {
  local output_base_dir="$1"
  local build_config="release"
  local executable_dest="${output_base_dir}/axe"
  local bin_path

  print_subsection "⚡" "Building AXe executable"
  print_info "Using Swift Package Manager to build AXe..."

  # Clean any existing build products to ensure fresh build
  print_info "Cleaning previous build products..."
  swift package clean

  print_info "Building ${TARGET_ARCH} executable..."
  swift build --configuration "${build_config}" --arch "${TARGET_ARCH}"
  bin_path="$(swift_build_bin_path "$build_config" "${TARGET_ARCH}")/axe"
  if [[ ! -f "${bin_path}" ]]; then
    echo "❌ Error: AXe executable not found at ${bin_path}"
    exit 1
  fi
  cp "${bin_path}" "${executable_dest}"

  copy_resource_bundle "${output_base_dir}"
  install_simulator_bridge "${output_base_dir}"

  # IDB is linked statically: nothing is embedded, so no Frameworks/ rpath is needed. Strip any
  # Xcode toolchain rpaths that can trigger Homebrew relocation.
  remove_xcode_rpaths "${executable_dest}"

  verify_macho_archs_exactly "${executable_dest}" "${TARGET_ARCH}"
  print_success "AXe executable installed to ${executable_dest}"
}

function verify_release_architectures() {
  local output_base_dir="$1"
  local executable_path="${output_base_dir}/axe"

  print_subsection "🧪" "Validating release artifact architectures"
  verify_macho_archs_exactly "${executable_path}" "${TARGET_ARCH}"

  # Self-contained: IDB is linked statically, so axe must not load anything through @rpath.
  if otool -L "${executable_path}" | grep -q "@rpath/"; then
    echo "❌ Error: ${executable_path} links libraries through @rpath; IDB must be linked statically"
    otool -L "${executable_path}" | grep "@rpath/"
    exit 1
  fi

  if [[ ! -d "${output_base_dir}/AXe_AXe.bundle" ]]; then
    echo "❌ Error: AXe resource bundle missing from ${output_base_dir}"
    exit 1
  fi
  verify_simulator_bridge "${output_base_dir}/Resources/${SIMULATOR_BRIDGE_NAME}"

  print_success "Release artifacts are ${TARGET_ARCH}-only, self-contained, and carry ${SIMULATOR_BRIDGE_NAME}"
}

# Function to sign the AXe executable with Developer ID
# $1: Base output directory
function sign_axe_executable() {
  local output_base_dir="$1"
  local executable_path="${output_base_dir}/axe"

  if [ -f "$executable_path" ]; then
    print_info "Signing AXe executable: ${executable_path}"

    # Sign with Developer ID and runtime hardening
    codesign_with_retry --force \
      --sign "${CODESIGN_IDENTITY}" \
      --options runtime \
      --entitlements entitlements.plist \
      --timestamp \
      "$executable_path"

    if [ $? -eq 0 ]; then
      print_success "AXe executable signed successfully"

      # Verify the signature with strictest verification
      print_info "Performing strict verification for AXe executable..."
      codesign -vvv "$executable_path"

      if [ $? -eq 0 ]; then
        print_success "AXe executable signature verification passed"

        # Display signature details
        print_info "AXe executable signature details:"
        codesign -dv "$executable_path" 2>&1 | grep -E "(Identifier|TeamIdentifier|Authority)" || true
      else
        echo "❌ Error: AXe executable signature verification failed"
        exit 1
      fi
    else
      echo "❌ Error: Failed to sign AXe executable"
      exit 1
    fi
  else
    print_warning "AXe executable not found: $executable_path"
  fi
}

# Function to create a package for notarization
# $1: Base output directory
function package_for_notarization() {
  local output_base_dir="$1"
  local package_name="AXe-$(date +%Y%m%d-%H%M%S)"
  local package_dir="${output_base_dir}/${package_name}"
  local package_zip="${output_base_dir}/${package_name}.zip"

  print_subsection "📦" "Creating notarization package" >&2
  print_info "Package name: ${package_name}" >&2

  # Create temporary package directory
  rm -rf "${package_dir}" "${package_zip}"
  mkdir -p "${package_dir}"

  print_info "Copying staged release payload to package..." >&2
  copy_release_payload "${output_base_dir}" "${package_dir}"
  # Only host code is submitted. The simulator helper runs inside the simulator, is signed for
  # it, and must keep that signature; the final package takes it from the build output instead.
  #
  # TODO(idb-upstream) RELEASE-BLOCKING, UNVERIFIED: the shipped archive therefore contains an
  # ad-hoc-signed, NOT notarized Mach-O (Resources/SimulatorFrameworkBridge-iOS). Nobody has yet
  # checked that a browser-downloaded (quarantined) release still runs it: CoreSimulator spawns it
  # for describe-ui and every other accessibility path, and Gatekeeper may block it. Homebrew
  # downloads with curl (no quarantine), so it would not catch this. Before the first release on
  # upstream idb: download the GitHub release archive with a browser, unzip it, and run
  # `axe describe-ui --udid <booted simulator>`. If it is blocked, find a signing/notarization route
  # that keeps the helper's simulator entitlements, or document removing the quarantine attribute.
  print_warning "Release payload: ${SIMULATOR_BRIDGE_NAME} is excluded from notarization (ad-hoc signed); quarantined-download behaviour is UNVERIFIED and release-blocking (see TODO in scripts/build.sh)." >&2
  rm -r "${package_dir:?}/Resources"

  # Create zip package excluding AppleDouble metadata
  print_info "Creating zip package: ${package_zip}" >&2
  ditto -c -k --norsrc --noextattr --noqtn --keepParent "${package_dir}" "${package_zip}" >&2

  # Clean up temporary directory
  rm -rf "${package_dir}"

  if [ -f "${package_zip}" ]; then
    print_success "Notarization package created: ${package_zip}" >&2
    # Store the clean absolute path
    local clean_path="$(cd "$(dirname "${package_zip}")" && pwd)/$(basename "${package_zip}")"
    # Only echo the path to stdout for capture
    echo "${clean_path}"
  else
    echo "❌ Error: Failed to create notarization package" >&2
    exit 1
  fi
}

# Function to submit package for notarization
# $1: Package zip path
function notarize_package() {
  local package_zip="$1"

  print_subsection "🍎" "Submitting for Apple notarization"

  # Ensure the notarization credentials are configured
  require_config "NOTARIZATION_API_KEY_PATH" "${NOTARIZATION_API_KEY_PATH}"
  require_config "NOTARIZATION_KEY_ID" "${NOTARIZATION_KEY_ID}"
  require_config "NOTARIZATION_ISSUER_ID" "${NOTARIZATION_ISSUER_ID}"

  # Check if API key exists
  if [ ! -f "${NOTARIZATION_API_KEY_PATH}" ]; then
    echo "❌ Error: Notarization API key not found at ${NOTARIZATION_API_KEY_PATH}"
    print_info "Please ensure the API key file exists or set NOTARIZATION_API_KEY_PATH environment variable"
    exit 1
  fi

  print_info "API Key: ${NOTARIZATION_API_KEY_PATH}"
  print_info "Key ID: ${NOTARIZATION_KEY_ID}"
  print_info "Issuer ID: ${NOTARIZATION_ISSUER_ID}"
  print_info "Package: ${package_zip}"
  print_info "Temporary directory: ${TEMP_DIR}"

  # Submit for notarization
  print_info "Submitting package for notarization..."
  local submit_output=$(xcrun notarytool submit "${package_zip}" \
    --key "${NOTARIZATION_API_KEY_PATH}" \
    --key-id "${NOTARIZATION_KEY_ID}" \
    --issuer "${NOTARIZATION_ISSUER_ID}" \
    --wait 2>&1)
  local submit_exit_code=$?

  echo "${submit_output}"

  if [ $submit_exit_code -eq 0 ] && echo "${submit_output}" | grep -q "status: Accepted"; then
    # Extract submission ID from output
    local submission_id=$(echo "${submit_output}" | grep "id:" | head -1 | awk '{print $2}')
    print_success "Notarization completed successfully!"
    print_info "Submission ID: ${submission_id}"

    # Extract notarized package and replace original distribution payload
    print_info "Extracting notarized package to replace original distribution payload..."
    local temp_extract_dir="${BUILD_OUTPUT_DIR}/temp_notarized"
    rm -rf "${temp_extract_dir}"
    mkdir -p "${temp_extract_dir}"

    ditto -x -k "${package_zip}" "${temp_extract_dir}"

    local extracted_package_dir
    extracted_package_dir="$(find "${temp_extract_dir}" -mindepth 1 -maxdepth 1 -type d | head -1)"

    if [ -n "${extracted_package_dir}" ] && [ -f "${extracted_package_dir}/axe" ]; then
      cp "${extracted_package_dir}/axe" "${BUILD_OUTPUT_DIR}/axe"
      print_success "Original executable replaced with notarized version"

      rm -rf "${BUILD_OUTPUT_DIR}/AXe_AXe.bundle"
      if [ -d "${extracted_package_dir}/AXe_AXe.bundle" ]; then
        cp -R "${extracted_package_dir}/AXe_AXe.bundle" "${BUILD_OUTPUT_DIR}/"
        print_success "Original AXe resource bundle replaced with notarized version"
      else
        echo "❌ Error: Notarized package missing AXe resource bundle"
        exit 1
      fi

      # Verify notarization status using spctl
      print_info "Verifying notarization with spctl assessment..."
      spctl -a -v "${BUILD_OUTPUT_DIR}/axe" 2>&1 | grep -q "accepted" || {
        print_info "Note: spctl shows 'not an app' for command-line tools - this is expected"
        print_info "Notarized command-line tools are validated differently by macOS"
      }

      # Check if the executable has the notarization signature
      print_info "Checking code signature details..."
      local sig_info=$(codesign -dv "${BUILD_OUTPUT_DIR}/axe" 2>&1)
      if echo "$sig_info" | grep -q "runtime"; then
        print_success "Executable has runtime hardening enabled (required for notarization)"
      else
        print_warning "Runtime hardening not detected in signature"
      fi

      print_success "Notarized executable is ready for distribution"

      # Create final deployment package in temporary directory
      print_info "Creating final deployment package..."
      local final_package_name="AXe-Final-$(date +%Y%m%d-%H%M%S)"
      local final_package_dir="${TEMP_DIR}/${final_package_name}"
      local final_package_zip="${TEMP_DIR}/${final_package_name}.zip"

      # Create final package directory
      mkdir -p "${final_package_dir}"

      # Notarized executable and resource bundle, plus Resources/ (the simulator helper) from
      # the build output, signature untouched.
      copy_release_payload "${BUILD_OUTPUT_DIR}" "${final_package_dir}"
      print_info "Included staged AXe payload in final package"

      # Create final zip package
      print_info "Creating final package: ${final_package_zip}"
      ditto -c -k --keepParent "${final_package_dir}" "${final_package_zip}"

      # Clean up temporary package directory
      rm -rf "${final_package_dir}"

      if [ -f "${final_package_zip}" ]; then
        print_success "Final deployment package created: ${final_package_zip}"

        # Clean up build artifacts (axe executable and payload, keep the IDB libraries)
        print_info "Cleaning up build artifacts..."
        rm -f "${BUILD_OUTPUT_DIR}/axe"
        rm -rf "${BUILD_OUTPUT_DIR}/AXe_AXe.bundle"
        rm -rf "${BUILD_OUTPUT_DIR}/Resources"
        print_success "Cleaned up axe executable, resource bundle, and Resources directory"
        print_info "Preserved ${IDB_PRODUCTS_DIR} for Swift package builds"

        # Output the final package path
        echo ""
        echo "📦 Final Package Location:"
        echo "${final_package_zip}"
        echo ""

        # Update the global PACKAGE_ZIP variable
        PACKAGE_ZIP="${final_package_zip}"
      else
        echo "❌ Error: Failed to create final deployment package"
        exit 1
      fi

      # Clean up temporary extraction directory and original notarization package
      rm -rf "${temp_extract_dir}"
      rm -f "${package_zip}"
      print_info "Cleaned up temporary notarization files"
    else
      echo "❌ Error: Could not find notarized executable in package"
      exit 1
    fi
  else
    echo "❌ Error: Notarization failed"

    # Extract submission ID for log fetching
    local submission_id=$(echo "${submit_output}" | grep "id:" | head -1 | awk '{print $2}')

    if [ -n "${submission_id}" ]; then
      print_info "Submission ID: ${submission_id}"
      print_info "Fetching notarization log for detailed error information..."

      # Fetch the notary log using notarytool
      echo ""
      echo "📋 Notarization Log:"
      echo "$(printf '·%.0s' {1..60})"
      xcrun notarytool log \
        --key "${NOTARIZATION_API_KEY_PATH}" \
        --key-id "${NOTARIZATION_KEY_ID}" \
        --issuer "${NOTARIZATION_ISSUER_ID}" \
        "${submission_id}"
      echo "$(printf '·%.0s' {1..60})"
    else
      print_info "Could not extract submission ID from notarization output"
    fi

    exit 1
  fi
}

# Function to print usage information
function print_usage() {
cat <<EOF
./build.sh usage:
  ./build.sh [<command>] [<options>]*

Commands:
  help
    Print this usage information.

  setup
    Clone the pinned upstream IDB revision into the checkout directory and verify it.

  clean
    Clean previous build products and derived data.

  generate
    Verify the pinned IDB revision, then generate its FBSimulatorControl and
    SimulatorFrameworkBridge projects with XcodeGen.

  libraries
    Generate the projects, build the IDB 'Libraries' scheme (Release, arm64) and the
    ${SIMULATOR_BRIDGE_NAME} helper, and install the static archives, Swift modules and
    helper into ${IDB_PRODUCTS_DIR} (lib/, bridge/).

  verify-libraries
    Verify ${IDB_PRODUCTS_DIR} holds arm64 archives and Swift modules built from the pinned
    revision, and a correctly signed ${SIMULATOR_BRIDGE_NAME}.

  executable
    Build the arm64 AXe executable with Swift Package Manager and stage the release payload
    (axe, AXe_AXe.bundle, Resources/${SIMULATOR_BRIDGE_NAME}) in the build output directory.

  sign-executable
    Code sign the AXe executable with Developer ID (the simulator helper is never re-signed).

  verify-arches
    Verify the executable is arm64-only and self-contained, and the payload carries the
    simulator helper with its signature intact.

  package
    Create a notarization package (zip file).

  notarize
    Submit package for Apple notarization and replace original executable.

  dev
    Run setup, clean, and libraries.

  build (default)
    Run all steps from setup through notarization.

Environment Variables (set inline, exported, or via a git-ignored .env file):
  AXE_ENV_FILE           Path to the .env file to load (default: <repo-root>/.env)
  AXE_CODESIGN_IDENTITY  Code-signing identity (required for signing; no default)
  IDB_CHECKOUT_DIR       Directory for IDB repository (default: ./idb_checkout)
  IDB_GIT_URL            IDB repository URL (default: ${DEFAULT_IDB_GIT_URL}); development only
  IDB_GIT_REF            Exact IDB revision (default: ${DEFAULT_IDB_GIT_REF}, tag v1.7.7);
                         development only. Both overrides are refused by build, sign-executable,
                         package and notarize, and by every command on CI.
  BUILD_OUTPUT_DIR       Directory for build outputs (default: ./build_products)
  DERIVED_DATA_PATH      Directory for derived data (default: ./build_derived_data)
  TEMP_DIR               Temporary directory for final packages (default: system temp)
  NOTARIZATION_API_KEY_PATH  Path to notarization API key (required to notarize; no default)
  NOTARIZATION_KEY_ID    Notarization key ID (required to notarize; no default)
  NOTARIZATION_ISSUER_ID Notarization issuer ID (required to notarize; no default)

  Values already set in the environment take precedence over .env.
  Copy .env.example to .env and fill in the values for your machine.

Examples:
  ./build.sh                    # Build everything (default)
  ./build.sh help               # Show this help
  ./build.sh dev                # Clone, clean, and build the IDB libraries
  ./build.sh libraries          # Only build the IDB libraries
  ./build.sh notarize           # Only run notarization step
EOF
}

# Individual command functions
function cmd_setup() {
  print_section "📥" "Repository Setup"
  clone_idb_repo
}

function cmd_clean() {
  print_section "🧹" "Cleaning Previous Build Products"
  print_info "Cleaning previous build products and derived data..."
  rm -rf "${BUILD_OUTPUT_DIR}"
  rm -rf "${DERIVED_DATA_PATH}"
  mkdir -p "${BUILD_OUTPUT_DIR}"
  mkdir -p "${DERIVED_DATA_PATH}"
  print_success "Build directories cleaned and recreated"
}

function cmd_generate() {
  print_section "🧬" "Generating IDB Projects"
  generate_idb_projects
}

function cmd_libraries() {
  print_section "🔧" "Building IDB Libraries"
  generate_idb_projects
  build_idb_libraries
  install_idb_libraries
}

function cmd_verify_libraries() {
  print_section "🧪" "Verifying IDB Library Inputs"
  verify_idb_libraries
}

function cmd_executable() {
  print_section "⚡" "Building AXe Executable"
  build_axe_executable "${BUILD_OUTPUT_DIR}"
}

function cmd_sign_executable() {
  print_section "🔒" "Signing AXe Executable"
  require_config "AXE_CODESIGN_IDENTITY" "${CODESIGN_IDENTITY}"
  sign_axe_executable "${BUILD_OUTPUT_DIR}"
}

function cmd_package() {
  print_section "📦" "Packaging for Notarization"
  PACKAGE_ZIP=$(package_for_notarization "${BUILD_OUTPUT_DIR}")
  print_info "Package created: ${PACKAGE_ZIP}"
}

function cmd_notarize() {
  print_section "🍎" "Apple Notarization"
  if [ -z "${PACKAGE_ZIP}" ]; then
    # Find the most recent package if PACKAGE_ZIP isn't set
    PACKAGE_ZIP=$(ls -t "${BUILD_OUTPUT_DIR}"/AXe-*.zip 2>/dev/null | head -1)
    if [ -z "${PACKAGE_ZIP}" ]; then
      echo "❌ Error: No package found. Run 'package' command first."
      exit 1
    fi
    print_info "Using package: ${PACKAGE_ZIP}"
  fi
  notarize_package "${PACKAGE_ZIP}"
}

function cmd_verify_arches() {
  print_section "🧪" "Verifying Architecture Slices"
  verify_release_architectures "${BUILD_OUTPUT_DIR}"
}

function cmd_build() {
  print_section "🚀" "IDB Library Builder for AXe Project"

  print_info "IDB Checkout Directory: ${IDB_CHECKOUT_DIR}"
  print_info "Build Output Directory: ${BUILD_OUTPUT_DIR}"
  print_info "Derived Data Path: ${DERIVED_DATA_PATH}"
  print_info "IDB Products Directory: ${IDB_PRODUCTS_DIR}"
  print_info "Temporary Directory: ${TEMP_DIR}"
  print_info "IDB Project: ${FBSIMCONTROL_PROJECT}"
  print_info "Notarization API Key: ${NOTARIZATION_API_KEY_PATH}"
  print_info "Notarization Key ID: ${NOTARIZATION_KEY_ID}"

  # Run all steps
  cmd_setup
  cmd_clean
  cmd_libraries
  cmd_executable
  cmd_sign_executable
  cmd_verify_arches
  cmd_package
  cmd_notarize

  print_section "🎉" "Build Complete!"
  print_success "IDB libraries, AXe executable, and notarization completed."
  print_info "📦 IDB libraries are located in ${IDB_PRODUCTS_DIR}"
  print_info "📁 Final deployment package is located at ${PACKAGE_ZIP}"
  print_info "🧹 Build artifacts (axe executable and payload) have been cleaned up"
  echo ""
  echo "🏁 Build process finished successfully!"
  echo ""
}

# A release must be built from the pinned upstream revision: a stray IDB_GIT_REF or IDB_GIT_URL
# (environment or .env) is refused for the release commands and on CI, and kept for local
# development commands (setup, libraries, dev, ...).
function refuse_idb_override_in_release_mode() {
  local command="$1"
  local reason=""
  case "$command" in
    build|sign-executable|package|notarize)
      reason="the '${command}' release command";;
  esac
  if [[ -z "$reason" && ( "${CI:-}" == "true" || "${GITHUB_ACTIONS:-}" == "true" ) ]]; then
    reason="CI (CI or GITHUB_ACTIONS is true)"
  fi
  [[ -n "$reason" ]] || return 0
  if [[ "$IDB_GIT_REF" != "$DEFAULT_IDB_GIT_REF" || "$IDB_GIT_URL" != "$DEFAULT_IDB_GIT_URL" ]]; then
    echo "❌ Error: IDB_GIT_REF/IDB_GIT_URL overrides are not allowed for ${reason}." >&2
    echo "   Pinned: ${DEFAULT_IDB_GIT_URL}@${DEFAULT_IDB_GIT_REF}" >&2
    echo "   Got:    ${IDB_GIT_URL}@${IDB_GIT_REF}" >&2
    echo "   Unset them (check ${ENV_FILE}), or change the pin in scripts/build.sh." >&2
    exit 1
  fi
}

# Parse command line arguments
COMMAND="${1:-build}"

case $COMMAND in
  help|-h|--help) ;;
  *) refuse_idb_override_in_release_mode "$COMMAND";;
esac

case $COMMAND in
  help|-h|--help)
    print_usage
    exit 0;;
  setup)
    cmd_setup;;
  generate)
    cmd_generate;;
  clean)
    cmd_clean;;
  libraries)
    cmd_libraries;;
  verify-libraries)
    cmd_verify_libraries;;
  dev)
    cmd_setup
    cmd_clean
    cmd_libraries;;
  executable)
    cmd_executable;;
  sign-executable)
    cmd_sign_executable;;
  package)
    cmd_package;;
  notarize)
    cmd_notarize;;
  verify-arches)
    cmd_verify_arches;;
  build)
    cmd_build;;
  *)
    echo "Unknown command: $COMMAND"
    echo ""
    print_usage
    exit 1;;
esac

exit 0
