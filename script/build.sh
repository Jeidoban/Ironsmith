#!/usr/bin/env bash

# Fail fast and make shell mistakes visible:
#   - -e stops after an unhandled command failure.
#   - -u treats an unset variable as an error instead of silently expanding it.
#   - pipefail makes a pipeline fail when any command in it fails, not only the
#     last command.
set -euo pipefail

# These values define the identity of the app bundle and the deployment target
# used by SwiftPM, asset compilation, and the generated Info.plist.
APP_NAME="Ironsmith"
BUNDLE_IDENTIFIER="com.jeidoban.Ironsmith"
MINIMUM_MACOS_VERSION="26.0"

# Defaults for the command-line interface. The parser below can replace these
# values before any build work begins.
COMMAND="build"
RELEASE_BUILD=false
SIGN_IDENTITY_OVERRIDE=""
SUPABASE_URL_OVERRIDE=""
SUPABASE_PUBLISHABLE_KEY_OVERRIDE=""
API_BASE_URL_OVERRIDE=""
APP_VERSION_OVERRIDE=""
APP_BUILD_NUMBER_OVERRIDE=""
CODEX_VERSION_OVERRIDE=""
BUILD_ARCH="native"

# Print the complete command-line contract. Keeping this close to the parser
# makes it easier to update the documented behavior when an option changes.
usage() {
  cat <<USAGE
Usage: script/build.sh [build|run] [--release] [options]

Builds the SwiftPM executable and stages dist/debug/Ironsmith.app or dist/release-<arch>/Ironsmith.app.

Environment:
  Build-time backend values are read from Config/.env by default.
  IRONSMITH_CODEX_VERSION pins the bundled Codex version. Defaults to latest.

Options:
  --release                     Build with SwiftPM release configuration and Developer ID signing
  --arch <native|arm64|x86_64>  Build architecture. Release builds require arm64 or x86_64.
  --sign-identity               Override the signing identity selected for this build. Required for release builds.
  --supabase-url                Override IronsmithSupabaseURL in Info.plist
  --supabase-publishable-key    Override IronsmithSupabasePublishableKey in Info.plist
  --api-base-url                Override IronsmithAPIBaseURL in Info.plist
  --codex-version <version>     Override IRONSMITH_CODEX_VERSION for this build
  --version                     Override CFBundleShortVersionString in Info.plist
  --build-number                Override CFBundleVersion in Info.plist
  -h, --help                    Show this help
USAGE
}

# Read the value that follows an option such as --arch or --version. Treat a
# missing value, or another option accidentally supplied as the value, as a
# usage error rather than letting the later build fail in a confusing place.
require_value() {
  local option="$1"
  local value="${2:-}"
  if [[ -z "$value" || "$value" == --* ]]; then
    echo "$option requires a value" >&2
    exit 2
  fi
  printf '%s' "$value"
}

# Parse the command name and all optional overrides. The parser deliberately
# stores values first; validation and environment resolution happen afterward so
# every invocation follows the same order of operations.
while [[ $# -gt 0 ]]; do
  case "$1" in
    build|run)
      COMMAND="$1"
      shift
      ;;
    --release)
      RELEASE_BUILD=true
      shift
      ;;
    --arch)
      BUILD_ARCH="$(require_value "$1" "${2:-}")"
      shift 2
      ;;
    --sign-identity)
      SIGN_IDENTITY_OVERRIDE="$(require_value "$1" "${2:-}")"
      shift 2
      ;;
    --supabase-url)
      SUPABASE_URL_OVERRIDE="$(require_value "$1" "${2:-}")"
      shift 2
      ;;
    --supabase-publishable-key)
      SUPABASE_PUBLISHABLE_KEY_OVERRIDE="$(require_value "$1" "${2:-}")"
      shift 2
      ;;
    --api-base-url)
      API_BASE_URL_OVERRIDE="$(require_value "$1" "${2:-}")"
      shift 2
      ;;
    --codex-version)
      CODEX_VERSION_OVERRIDE="$(require_value "$1" "${2:-}")"
      shift 2
      ;;
    --version)
      APP_VERSION_OVERRIDE="$(require_value "$1" "${2:-}")"
      shift 2
      ;;
    --build-number)
      APP_BUILD_NUMBER_OVERRIDE="$(require_value "$1" "${2:-}")"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    --*)
      echo "Unknown argument: $1" >&2
      usage >&2
      exit 2
      ;;
    *)
      echo "Unknown command: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

# Validate the command and architecture before touching the filesystem or
# invoking SwiftPM. "native" means use the architecture of this Mac; an
# explicit architecture is primarily useful for reproducible release builds.
case "$COMMAND" in
  build|run) ;;
  *)
    echo "Command must be build or run" >&2
    exit 2
    ;;
esac

case "$BUILD_ARCH" in
  native|arm64|x86_64) ;;
  *)
    echo "--arch must be native, arm64, or x86_64" >&2
    exit 2
    ;;
esac

# Release payloads must name an architecture because they bundle an
# architecture-specific Codex executable and are staged under a stable
# release-<arch> directory.
if [[ "$RELEASE_BUILD" == true && "$BUILD_ARCH" == "native" ]]; then
  echo "Release builds require an explicit architecture: --arch arm64 or --arch x86_64" >&2
  exit 2
fi

native_arch() {
  case "$(uname -m)" in
    arm64)
      printf '%s' "arm64"
      ;;
    x86_64)
      printf '%s' "x86_64"
      ;;
    *)
      echo "Unsupported native architecture: $(uname -m)" >&2
      exit 1
      ;;
  esac
}

# Resolve the architecture that will be used for bundled third-party payloads.
# BUILD_ARCH remains "native" for display/path behavior, while
# EFFECTIVE_ARCH is always a concrete arm64 or x86_64 value.
if [[ "$BUILD_ARCH" == "native" ]]; then
  EFFECTIVE_ARCH="$(native_arch)"
else
  EFFECTIVE_ARCH="$BUILD_ARCH"
fi

# SwiftPM's configuration and the output directory are kept in step. Debug
# builds are staged at dist/debug; architecture-specific release builds are
# staged at dist/release-arm64 or dist/release-x86_64.
if [[ "$RELEASE_BUILD" == true ]]; then
  SWIFT_CONFIGURATION="release"
  DIST_LABEL="release-$BUILD_ARCH"
else
  SWIFT_CONFIGURATION="debug"
  DIST_LABEL="debug"
fi

# Resolve all paths from the script location, not from the caller's current
# directory. This lets contributors invoke the script from anywhere in the
# repository (or by absolute path) and still get the same result.
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "$SCRIPT_DIR/.." && pwd)"
CONFIG_DIR="$REPO_ROOT/Config"
DIST_DIR="$REPO_ROOT/dist/$DIST_LABEL"
APP_URL="$DIST_DIR/$APP_NAME.app"
CONTENTS_URL="$APP_URL/Contents"
MACOS_URL="$CONTENTS_URL/MacOS"
RESOURCES_URL="$CONTENTS_URL/Resources"
INFO_PLIST_URL="$CONTENTS_URL/Info.plist"
ASSET_INFO_PLIST_URL="$RESOURCES_URL/asset-info.plist"
APP_RESOURCES_SOURCE_URL="$REPO_ROOT/Ironsmith/Resources"
CODEX_CACHE_ROOT="$REPO_ROOT/.build/ironsmith-codex"
CODEX_VENDOR_RESOURCE_URL="$RESOURCES_URL/Codex/vendor"
CODEX_ARM64_TRIPLE="aarch64-apple-darwin"
CODEX_X64_TRIPLE="x86_64-apple-darwin"

# Source an optional dotenv-style configuration file. `set -a` exports values
# defined by the file while it is sourced so child commands such as npm and
# SwiftPM can see them. Missing Config/.env is allowed for local builds.
source_env_file() {
  local file="$1"
  [[ -f "$file" ]] || return 0

  set -a
  # shellcheck disable=SC1090
  source "$file"
  set +a
}

# Remember which relevant values were already present in the caller's
# environment before Config/.env is sourced. The later restore step gives
# explicit process environment variables precedence over values from the file,
# while still allowing the file to provide values that were not set externally.
HAS_ENV_IRONSMITH_SUPABASE_URL=false
HAS_ENV_IRONSMITH_SUPABASE_PUBLISHABLE_KEY=false
HAS_ENV_IRONSMITH_API_BASE_URL=false
HAS_ENV_IRONSMITH_DEV_SIGN_IDENTITY=false
HAS_ENV_IRONSMITH_CODEX_VERSION=false

if [[ "${IRONSMITH_SUPABASE_URL+x}" == x ]]; then
  HAS_ENV_IRONSMITH_SUPABASE_URL=true
  ENV_IRONSMITH_SUPABASE_URL="$IRONSMITH_SUPABASE_URL"
fi

if [[ "${IRONSMITH_SUPABASE_PUBLISHABLE_KEY+x}" == x ]]; then
  HAS_ENV_IRONSMITH_SUPABASE_PUBLISHABLE_KEY=true
  ENV_IRONSMITH_SUPABASE_PUBLISHABLE_KEY="$IRONSMITH_SUPABASE_PUBLISHABLE_KEY"
fi

if [[ "${IRONSMITH_API_BASE_URL+x}" == x ]]; then
  HAS_ENV_IRONSMITH_API_BASE_URL=true
  ENV_IRONSMITH_API_BASE_URL="$IRONSMITH_API_BASE_URL"
fi

if [[ "${IRONSMITH_DEV_SIGN_IDENTITY+x}" == x ]]; then
  HAS_ENV_IRONSMITH_DEV_SIGN_IDENTITY=true
  ENV_IRONSMITH_DEV_SIGN_IDENTITY="$IRONSMITH_DEV_SIGN_IDENTITY"
fi

if [[ "${IRONSMITH_CODEX_VERSION+x}" == x ]]; then
  HAS_ENV_IRONSMITH_CODEX_VERSION=true
  ENV_IRONSMITH_CODEX_VERSION="$IRONSMITH_CODEX_VERSION"
fi

source_env_file "$CONFIG_DIR/.env"

# Restore values that were explicitly supplied by the invoking shell. This is
# necessary because `source_env_file` intentionally lets the dotenv file assign
# variables while it is being read.
if [[ "$HAS_ENV_IRONSMITH_SUPABASE_URL" == true ]]; then
  IRONSMITH_SUPABASE_URL="$ENV_IRONSMITH_SUPABASE_URL"
fi

if [[ "$HAS_ENV_IRONSMITH_SUPABASE_PUBLISHABLE_KEY" == true ]]; then
  IRONSMITH_SUPABASE_PUBLISHABLE_KEY="$ENV_IRONSMITH_SUPABASE_PUBLISHABLE_KEY"
fi

if [[ "$HAS_ENV_IRONSMITH_API_BASE_URL" == true ]]; then
  IRONSMITH_API_BASE_URL="$ENV_IRONSMITH_API_BASE_URL"
fi

if [[ "$HAS_ENV_IRONSMITH_DEV_SIGN_IDENTITY" == true ]]; then
  IRONSMITH_DEV_SIGN_IDENTITY="$ENV_IRONSMITH_DEV_SIGN_IDENTITY"
fi

if [[ "$HAS_ENV_IRONSMITH_CODEX_VERSION" == true ]]; then
  IRONSMITH_CODEX_VERSION="$ENV_IRONSMITH_CODEX_VERSION"
fi

# Normalize optional configuration to non-errored shell values and establish
# defaults. Empty backend values are passed into Info.plist as-is; Codex uses
# the npm "latest" tag unless pinned by configuration or an option.
IRONSMITH_SUPABASE_URL="${IRONSMITH_SUPABASE_URL:-}"
IRONSMITH_SUPABASE_PUBLISHABLE_KEY="${IRONSMITH_SUPABASE_PUBLISHABLE_KEY:-}"
IRONSMITH_API_BASE_URL="${IRONSMITH_API_BASE_URL:-}"
IRONSMITH_DEV_SIGN_IDENTITY="${IRONSMITH_DEV_SIGN_IDENTITY:--}"
IRONSMITH_CODEX_VERSION="${IRONSMITH_CODEX_VERSION:-latest}"

# Command-line overrides have the highest precedence and are applied after both
# the process environment and Config/.env have been resolved.
if [[ -n "$SUPABASE_URL_OVERRIDE" ]]; then
  IRONSMITH_SUPABASE_URL="$SUPABASE_URL_OVERRIDE"
fi

if [[ -n "$SUPABASE_PUBLISHABLE_KEY_OVERRIDE" ]]; then
  IRONSMITH_SUPABASE_PUBLISHABLE_KEY="$SUPABASE_PUBLISHABLE_KEY_OVERRIDE"
fi

if [[ -n "$API_BASE_URL_OVERRIDE" ]]; then
  IRONSMITH_API_BASE_URL="$API_BASE_URL_OVERRIDE"
fi

if [[ -n "$CODEX_VERSION_OVERRIDE" ]]; then
  IRONSMITH_CODEX_VERSION="$CODEX_VERSION_OVERRIDE"
fi

# Choose the code-signing identity. Release builds require either a Developer
# ID Application identity or the explicit ad hoc marker "-" for local signing
# verification. Debug builds may use the configured development identity and
# otherwise fall back to ad hoc signing.
resolve_sign_identity() {
  if [[ "$RELEASE_BUILD" == true ]]; then
    SIGN_IDENTITY="$SIGN_IDENTITY_OVERRIDE"

    if [[ -z "$SIGN_IDENTITY" ]]; then
      echo "Release builds require a Developer ID Application signing identity." >&2
      echo "Pass --sign-identity, or --sign-identity - for local ad hoc verification." >&2
      exit 1
    fi

    if [[ "$SIGN_IDENTITY" != "-" && "$SIGN_IDENTITY" != *"Developer ID Application"* ]]; then
      echo "Release builds must be signed with a Developer ID Application identity." >&2
      echo "Received: $SIGN_IDENTITY" >&2
      exit 1
    fi
  else
    SIGN_IDENTITY="${SIGN_IDENTITY_OVERRIDE:-$IRONSMITH_DEV_SIGN_IDENTITY}"
    if [[ -z "$SIGN_IDENTITY" ]]; then
      SIGN_IDENTITY="-"
    fi
  fi
}

resolve_sign_identity

# Make the signing mode visible in the log without exposing any credentials or
# other configuration values.
if [[ "$SIGN_IDENTITY" == "-" ]]; then
  echo "Signing $APP_NAME ($DIST_LABEL) ad hoc"
else
  echo "Signing $APP_NAME ($DIST_LABEL) with $SIGN_IDENTITY"
fi

# All subsequent relative paths and SwiftPM commands should run from the repo
# root, regardless of where the caller launched this script.
cd "$REPO_ROOT"

# These two variables are populated by the selected SwiftPM build helper and
# then reused while assembling the app bundle.
BUILD_ARCH_EXECUTABLE_URL=""
BUILD_ARCH_BIN_DIR=""

# Fail with a focused message when a build or downloaded payload is missing its
# expected executable.
require_executable() {
  local executable_url="$1"
  if [[ ! -x "$executable_url" ]]; then
    echo "Missing executable at $executable_url" >&2
    exit 1
  fi
}

# Check for external tools before invoking them in a later helper. This keeps
# missing-tool failures actionable and avoids partially staging an app.
require_command() {
  local command_name="$1"
  if ! command -v "$command_name" >/dev/null 2>&1; then
    echo "Missing required command: $command_name" >&2
    exit 1
  fi
}

# Ask npm which concrete Codex version a tag/range resolves to. We use the
# concrete version in the cache path and in the bundle's version.txt so the
# payload is reproducible for the remainder of this build.
resolve_codex_version() {
  require_command npm

  local resolved_version
  resolved_version="$(npm view "@openai/codex@$IRONSMITH_CODEX_VERSION" version --silent)"
  if [[ -z "$resolved_version" ]]; then
    echo "Could not resolve @openai/codex@$IRONSMITH_CODEX_VERSION." >&2
    exit 1
  fi

  printf '%s' "$resolved_version"
}

codex_vendor_has_binary() {
  # Codex packages have used both a top-level `codex` path and a `bin/codex`
  # path. Accept either layout so the rest of the pipeline can treat the
  # vendor directory as valid without depending on one package detail.
  local vendor_dir="$1"
  [[ -x "$vendor_dir/codex" || -x "$vendor_dir/bin/codex" ]]
}

# Convert the app architecture into the suffix used by the platform-specific
# @openai/codex npm package.
codex_platform_suffix_for_arch() {
  case "$1" in
    arm64)
      printf '%s' "darwin-arm64"
      ;;
    x86_64)
      printf '%s' "darwin-x64"
      ;;
    *)
      echo "Unsupported Codex architecture: $1" >&2
      exit 1
      ;;
  esac
}

# Convert the app architecture into the Darwin triple used inside the Codex
# package and used as the cache key.
codex_triple_for_arch() {
  case "$1" in
    arm64)
      printf '%s' "$CODEX_ARM64_TRIPLE"
      ;;
    x86_64)
      printf '%s' "$CODEX_X64_TRIPLE"
      ;;
    *)
      echo "Unsupported Codex architecture: $1" >&2
      exit 1
      ;;
  esac
}

PRESERVED_CODEX_RESOURCE_URL=""

# A debug rebuild normally deletes the existing app bundle below. If that app
# already contains a valid Codex payload, preserve it first so an offline or
# temporarily unavailable npm registry does not unnecessarily break a local
# rebuild. Release builds always resolve/stage their requested payload afresh.
preserve_debug_codex_resources_if_available() {
  if [[ "$RELEASE_BUILD" == true ]]; then
    return 0
  fi

  if [[ ! -f "$RESOURCES_URL/Codex/version.txt" ]]; then
    return 0
  fi

  if ! codex_vendor_has_binary "$CODEX_VENDOR_RESOURCE_URL"; then
    return 0
  fi

  PRESERVED_CODEX_RESOURCE_URL="$CODEX_CACHE_ROOT/.preserved-debug-codex-$$"
  rm -rf "$PRESERVED_CODEX_RESOURCE_URL"
  mkdir -p "$(dirname -- "$PRESERVED_CODEX_RESOURCE_URL")"
  cp -R "$RESOURCES_URL/Codex" "$PRESERVED_CODEX_RESOURCE_URL"
  echo "Reusing staged Codex resources from existing debug app"
}

# Put a previously preserved debug payload back into the newly-created app
# bundle. Returning 1 means no payload was preserved, which tells the caller to
# perform the normal download/cache path.
restore_preserved_debug_codex_resources() {
  if [[ -z "$PRESERVED_CODEX_RESOURCE_URL" || ! -d "$PRESERVED_CODEX_RESOURCE_URL" ]]; then
    return 1
  fi

  rm -rf "$RESOURCES_URL/Codex"
  mkdir -p "$RESOURCES_URL"
  cp -R "$PRESERVED_CODEX_RESOURCE_URL" "$RESOURCES_URL/Codex"
  rm -rf "$PRESERVED_CODEX_RESOURCE_URL"
  PRESERVED_CODEX_RESOURCE_URL=""
  return 0
}

# The EXIT trap covers failures and interrupts after a preserved payload has
# been created, preventing temporary files from accumulating in the Codex cache.
cleanup_preserved_debug_codex_resources() {
  if [[ -n "$PRESERVED_CODEX_RESOURCE_URL" ]]; then
    rm -rf "$PRESERVED_CODEX_RESOURCE_URL"
  fi
}

trap cleanup_preserved_debug_codex_resources EXIT

download_codex_vendor() {
  # Cache each resolved Codex version and architecture separately. This avoids
  # re-downloading the same platform binary while ensuring arm64 and x86_64
  # payloads can never be mixed.
  local resolved_version="$1"
  local platform_suffix="$2"
  local triple="$3"
  local cache_dir="$CODEX_CACHE_ROOT/$resolved_version/$triple"

  if codex_vendor_has_binary "$cache_dir"; then
    echo "Using cached Codex $resolved_version ($triple)"
    return 0
  fi

  # npm pack downloads the platform-specific package as a tarball without
  # installing it into the repository. The temporary extraction directory is
  # intentionally unique to this process so concurrent builds do not collide.
  local package_spec="@openai/codex@${resolved_version}-${platform_suffix}"
  local tmp_dir="$CODEX_CACHE_ROOT/.tmp-$resolved_version-$platform_suffix-$$"
  local tarball=""
  local vendor_dir=""

  echo "Downloading $package_spec"
  rm -rf "$tmp_dir"
  mkdir -p "$tmp_dir"
  tarball="$(cd "$tmp_dir" && npm pack "$package_spec" --silent)"
  tar -xzf "$tmp_dir/$tarball" -C "$tmp_dir"
  vendor_dir="$(find "$tmp_dir/package" -type d -path "*/vendor/$triple" -print -quit)"

  # Validate both the expected directory layout and the executable before
  # copying anything into the persistent cache.
  if [[ -z "$vendor_dir" || ! -d "$vendor_dir" ]]; then
    echo "Package $package_spec did not contain vendor/$triple." >&2
    exit 1
  fi

  if ! codex_vendor_has_binary "$vendor_dir"; then
    echo "Package $package_spec did not contain an executable Codex binary." >&2
    exit 1
  fi

  # Replace only this version/triple cache entry. The cache is local build
  # state, while the staged app receives a copy of the payload below.
  mkdir -p "$CODEX_CACHE_ROOT/$resolved_version"
  rm -rf "$cache_dir"
  cp -R "$vendor_dir" "$cache_dir"
  rm -rf "$tmp_dir"
}

# Resolve, download/cache, and copy the architecture-matched Codex payload into
# Contents/Resources/Codex. The small version.txt file lets diagnostics and
# future debug builds identify what was bundled.
stage_codex_resources() {
  if restore_preserved_debug_codex_resources; then
    return 0
  fi

  local resolved_version
  local platform_suffix
  local triple

  resolved_version="$(resolve_codex_version)"
  platform_suffix="$(codex_platform_suffix_for_arch "$EFFECTIVE_ARCH")"
  triple="$(codex_triple_for_arch "$EFFECTIVE_ARCH")"

  echo "Bundling Codex $resolved_version ($EFFECTIVE_ARCH)"
  download_codex_vendor "$resolved_version" "$platform_suffix" "$triple"

  mkdir -p "$RESOURCES_URL/Codex"
  printf '%s\n' "$resolved_version" > "$RESOURCES_URL/Codex/version.txt"
  rm -rf "$CODEX_VENDOR_RESOURCE_URL"
  mkdir -p "$CODEX_VENDOR_RESOURCE_URL"
  cp -R "$CODEX_CACHE_ROOT/$resolved_version/$triple/." "$CODEX_VENDOR_RESOURCE_URL"
}

# Sign one file using the policy for this build:
#   - ad hoc signing has no timestamp/runtime options;
#   - release signing enables the hardened runtime and timestamp required for
#     distribution/notarization;
#   - debug Developer ID signing keeps the normal debug metadata behavior.
codesign_file() {
  local file_url="$1"
  if [[ "$SIGN_IDENTITY" == "-" ]]; then
    /usr/bin/codesign \
      --force \
      --sign "$SIGN_IDENTITY" \
      --preserve-metadata=entitlements \
      "$file_url" >/dev/null
  elif [[ "$RELEASE_BUILD" == true ]]; then
    /usr/bin/codesign \
      --force \
      --sign "$SIGN_IDENTITY" \
      --options runtime \
      --timestamp \
      --preserve-metadata=entitlements \
      "$file_url" >/dev/null
  else
    /usr/bin/codesign \
      --force \
      --sign "$SIGN_IDENTITY" \
      --preserve-metadata=entitlements \
      "$file_url" >/dev/null
  fi
}

# Sign every executable shipped inside Codex before signing the containing app.
# Nested code must be signed before its parent bundle is signed, otherwise the
# parent's signature will not describe the final contents.
sign_codex_vendor_executables() {
  if [[ ! -d "$CODEX_VENDOR_RESOURCE_URL" ]]; then
    return 0
  fi

  local executable_url
  while IFS= read -r executable_url; do
    echo "Signing Codex executable $executable_url"
    codesign_file "$executable_url"
  done < <(find "$CODEX_VENDOR_RESOURCE_URL" -type f -perm -u+x)
}

# Codex's code-mode host uses JIT and unsigned executable memory. Verify that
# both expected executables carry both entitlements after signing; fail before
# the app is declared built if either nested binary is unsuitable.
verify_codex_jit_entitlements() {
  local executable_name
  local executable_url
  local entitlements
  local entitlement

  for executable_name in codex codex-code-mode-host; do
    executable_url="$(find "$CODEX_VENDOR_RESOURCE_URL" -type f -name "$executable_name" -perm -u+x -print -quit)"
    if [[ -z "$executable_url" ]]; then
      echo "Bundled Codex is missing required executable $executable_name." >&2
      exit 1
    fi

    entitlements="$(/usr/bin/codesign -d --entitlements - "$executable_url" 2>/dev/null)"
    for entitlement in \
      com.apple.security.cs.allow-jit \
      com.apple.security.cs.allow-unsigned-executable-memory; do
      if [[ "$entitlements" != *"$entitlement"* ]]; then
        echo "Bundled $executable_name is missing required entitlement $entitlement." >&2
        exit 1
      fi
    done
  done
}

# Build for the current machine architecture. SwiftPM chooses the native
# compiler target and returns the bin directory where the executable was placed.
build_native_executable() {
  echo "Building $APP_NAME ($DIST_LABEL, native)"
  swift build --configuration "$SWIFT_CONFIGURATION"
  BUILD_ARCH_BIN_DIR="$(swift build --configuration "$SWIFT_CONFIGURATION" --show-bin-path)"
  BUILD_ARCH_EXECUTABLE_URL="$BUILD_ARCH_BIN_DIR/$APP_NAME"
  require_executable "$BUILD_ARCH_EXECUTABLE_URL"
}

# Build for an explicit architecture using a macOS deployment-target triple.
# This is the path used by release builds so the resulting app and bundled
# Codex payload are reproducibly arm64 or x86_64.
build_arch_executable() {
  local configuration="$1"
  local arch="$2"
  local triple="$arch-apple-macosx$MINIMUM_MACOS_VERSION"

  echo "Building $APP_NAME ($DIST_LABEL, $arch)"
  swift build --configuration "$configuration" --triple "$triple"
  BUILD_ARCH_BIN_DIR="$(swift build --configuration "$configuration" --triple "$triple" --show-bin-path)"
  BUILD_ARCH_EXECUTABLE_URL="$BUILD_ARCH_BIN_DIR/$APP_NAME"
  require_executable "$BUILD_ARCH_EXECUTABLE_URL"
}

if [[ "$BUILD_ARCH" == "native" ]]; then
  # Select the appropriate SwiftPM helper. Both helpers populate the same output
  # variables so the app-staging code below does not need to know how the binary
  # was built.
  build_native_executable
else
  build_arch_executable "$SWIFT_CONFIGURATION" "$BUILD_ARCH"
fi

EXECUTABLE_URL="$BUILD_ARCH_EXECUTABLE_URL"
RESOURCE_BUNDLE_BIN_DIR="$BUILD_ARCH_BIN_DIR"

# Preserve a usable debug Codex payload before removing the old app bundle.
preserve_debug_codex_resources_if_available

# Recreate the minimal .app directory structure. The executable, Info.plist,
# assets, SwiftPM resource bundles, Package.resolved, and Codex payload are all
# copied into this fresh staging directory in the following steps.
rm -rf "$APP_URL"
mkdir -p "$MACOS_URL" "$RESOURCES_URL"

# Copy the SwiftPM executable into the conventional app-bundle location and
# restore executable permissions in case the source artifact did not retain
# them through a prior copy.
cp "$EXECUTABLE_URL" "$MACOS_URL/$APP_NAME"
chmod 755 "$MACOS_URL/$APP_NAME"

# Start from the repository's checked-in template plist, then inject values that
# are known only at build time (bundle identity, deployment target, backend
# endpoints, and optional version overrides).
cp "$REPO_ROOT/Ironsmith/Info.plist" "$INFO_PLIST_URL"
/usr/libexec/PlistBuddy -c "Set :CFBundleExecutable $APP_NAME" "$INFO_PLIST_URL"
/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $BUNDLE_IDENTIFIER" "$INFO_PLIST_URL"
/usr/libexec/PlistBuddy -c "Set :LSMinimumSystemVersion $MINIMUM_MACOS_VERSION" "$INFO_PLIST_URL"
/usr/libexec/PlistBuddy -c "Set :IronsmithSupabaseURL $IRONSMITH_SUPABASE_URL" "$INFO_PLIST_URL"
/usr/libexec/PlistBuddy -c "Set :IronsmithSupabasePublishableKey $IRONSMITH_SUPABASE_PUBLISHABLE_KEY" "$INFO_PLIST_URL"
/usr/libexec/PlistBuddy -c "Set :IronsmithAPIBaseURL $IRONSMITH_API_BASE_URL" "$INFO_PLIST_URL"

if [[ -n "$APP_VERSION_OVERRIDE" ]]; then
  /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $APP_VERSION_OVERRIDE" "$INFO_PLIST_URL"
fi

if [[ -n "$APP_BUILD_NUMBER_OVERRIDE" ]]; then
  /usr/libexec/PlistBuddy -c "Set :CFBundleVersion $APP_BUILD_NUMBER_OVERRIDE" "$INFO_PLIST_URL"
fi

# Compile the asset catalog into the app's Resources directory. actool writes a
# temporary partial plist containing the icon keys that must be merged into the
# main Info.plist, so the resulting app uses the catalog's generated icon data.
xcrun actool "$APP_RESOURCES_SOURCE_URL/Assets.xcassets" \
  --compile "$RESOURCES_URL" \
  --platform macosx \
  --minimum-deployment-target "$MINIMUM_MACOS_VERSION" \
  --app-icon AppIcon \
  --accent-color AccentColor \
  --output-partial-info-plist "$ASSET_INFO_PLIST_URL" >/dev/null

if [[ -f "$ASSET_INFO_PLIST_URL" ]]; then
  # The partial plist may contain either or both of these keys depending on the
  # asset catalog/platform. Copy only values that actool actually emitted, then
  # remove the temporary plist from the final app.
  CF_BUNDLE_ICON_FILE="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIconFile' "$ASSET_INFO_PLIST_URL" 2>/dev/null || true)"
  CF_BUNDLE_ICON_NAME="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIconName' "$ASSET_INFO_PLIST_URL" 2>/dev/null || true)"
  if [[ -n "$CF_BUNDLE_ICON_FILE" ]]; then
    /usr/libexec/PlistBuddy -c "Set :CFBundleIconFile $CF_BUNDLE_ICON_FILE" "$INFO_PLIST_URL"
  fi
  if [[ -n "$CF_BUNDLE_ICON_NAME" ]]; then
    /usr/libexec/PlistBuddy -c "Set :CFBundleIconName $CF_BUNDLE_ICON_NAME" "$INFO_PLIST_URL"
  fi
  rm -f "$ASSET_INFO_PLIST_URL"
fi

# Copy non-asset resources from the source Resources directory. The asset
# catalog was compiled separately above, and .DS_Store is never a useful app
# resource.
find "$APP_RESOURCES_SOURCE_URL" \
  -mindepth 1 \
  -maxdepth 1 \
  ! -name "*.xcassets" \
  ! -name ".DS_Store" \
  -exec cp -R {} "$RESOURCES_URL" \;

if [[ -f "$REPO_ROOT/Package.resolved" ]]; then
  # Keep the exact dependency lockfile beside the built app for diagnostics and
  # for identifying which package graph produced a release artifact.
  cp "$REPO_ROOT/Package.resolved" "$RESOURCES_URL/Package.resolved"
fi

# SwiftPM places target resource bundles beside the executable. Copy those
# bundles into the app unless they are the executable target's own generated
# bundle, which is not meant to be nested as a second app resource here.
find "$RESOURCE_BUNDLE_BIN_DIR" \
  -maxdepth 1 \
  -type d \
  -name "*.bundle" \
  ! -name "${APP_NAME}_${APP_NAME}.bundle" \
  -exec cp -R {} "$RESOURCES_URL" \;

# Stage and validate the nested Codex payload before signing the outer app.
stage_codex_resources
sign_codex_vendor_executables
verify_codex_jit_entitlements

# Sign the completed app bundle. Nested Codex executables were signed first;
# signing the parent last records the final bundle contents. Release signing
# repeats the hardened-runtime/timestamp policy used for nested files.
if [[ "$SIGN_IDENTITY" == "-" ]]; then
  /usr/bin/codesign --force --sign "$SIGN_IDENTITY" "$APP_URL" >/dev/null
elif [[ "$RELEASE_BUILD" == true ]]; then
  /usr/bin/codesign \
    --force \
    --sign "$SIGN_IDENTITY" \
    --options runtime \
    --timestamp \
    "$APP_URL" >/dev/null
else
  /usr/bin/codesign --force --sign "$SIGN_IDENTITY" "$APP_URL" >/dev/null
fi

# Verify the final bundle recursively and strictly. This catches missing,
# modified, or incorrectly signed nested code before the artifact is reported
# as usable (and before it can be handed to the packaging script).
/usr/bin/codesign --verify --deep --strict "$APP_URL"

# At this point the staged app is complete. `run` is an optional convenience
# mode that terminates an existing Ironsmith process and opens this exact
# bundle, while the default `build` mode stops after staging and verification.
echo "Built $APP_URL"

if [[ "$COMMAND" == "run" ]]; then
  pkill -x "$APP_NAME" 2>/dev/null || true
  /usr/bin/open -n "$APP_URL"
fi
