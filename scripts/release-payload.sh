#!/usr/bin/env bash

# Release payload layout. IDB is linked statically into `axe`; the only IDB file shipped beside it
# is the in-simulator helper, in `Resources/` where upstream's BundledResources looks for it next to
# a standalone executable. The helper is signed for the simulator and must never be re-signed.
RELEASE_SIMULATOR_BRIDGE="Resources/SimulatorFrameworkBridge-iOS"

# AppleDouble (._*) files and extended attributes are dropped from the payload. Signatures are
# embedded in the Mach-O binaries, so dropping xattrs is safe post-signing.
sanitize_release_payload() {
  local payload_dir="$1"

  find "$payload_dir" -type f \( -name "._*" -o -name ".DS_Store" \) -delete
  xattr -cr "$payload_dir"
}

copy_release_payload() {
  local source_dir="$1"
  local destination_dir="$2"

  if [[ ! -f "${source_dir}/axe" ]]; then
    echo "❌ Error: AXe executable missing from ${source_dir}" >&2
    exit 1
  fi

  if [[ ! -d "${source_dir}/AXe_AXe.bundle" ]]; then
    echo "❌ Error: AXe resource bundle missing from ${source_dir}" >&2
    exit 1
  fi

  if [[ ! -f "${source_dir}/${RELEASE_SIMULATOR_BRIDGE}" ]]; then
    echo "❌ Error: ${RELEASE_SIMULATOR_BRIDGE} missing from ${source_dir}" >&2
    exit 1
  fi

  rm -rf "$destination_dir"
  mkdir -p "$destination_dir"
  cp "$source_dir/axe" "$destination_dir/"
  cp -R "$source_dir/AXe_AXe.bundle" "$destination_dir/"
  cp -R "$source_dir/Resources" "$destination_dir/"
  sanitize_release_payload "$destination_dir"
}
