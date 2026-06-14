#!/usr/bin/env bash
set -euo pipefail

APP_NAME="Ironsmith"
BUNDLE_IDENTIFIER="com.jeidoban.Ironsmith"
MINIMUM_MACOS_VERSION="26.0"

COMMAND="build"
RELEASE_BUILD=false
SIGN_IDENTITY_OVERRIDE=""
SUPABASE_URL_OVERRIDE=""
SUPABASE_PUBLISHABLE_KEY_OVERRIDE=""
API_BASE_URL_OVERRIDE=""
APP_VERSION_OVERRIDE=""
APP_BUILD_NUMBER_OVERRIDE=""

usage() {
  cat <<USAGE
Usage: script/build.sh [build|run] [--release] [options]

Builds the SwiftPM executable and stages dist/debug/Ironsmith.app or dist/release/Ironsmith.app.

Environment:
  Build-time backend values are read from Config/.env by default.

Options:
  --release                     Build with SwiftPM release configuration and Developer ID signing
  --sign-identity               Override the signing identity selected for this build. Required for release builds.
  --supabase-url                Override IronsmithSupabaseURL in Info.plist
  --supabase-publishable-key    Override IronsmithSupabasePublishableKey in Info.plist
  --api-base-url                Override IronsmithAPIBaseURL in Info.plist
  --version                     Override CFBundleShortVersionString in Info.plist
  --build-number                Override CFBundleVersion in Info.plist
  -h, --help                    Show this help
USAGE
}

require_value() {
  local option="$1"
  local value="${2:-}"
  if [[ -z "$value" || "$value" == --* ]]; then
    echo "$option requires a value" >&2
    exit 2
  fi
  printf '%s' "$value"
}

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

case "$COMMAND" in
  build|run) ;;
  *)
    echo "Command must be build or run" >&2
    exit 2
    ;;
esac

if [[ "$RELEASE_BUILD" == true ]]; then
  SWIFT_CONFIGURATION="release"
  DIST_LABEL="release"
else
  SWIFT_CONFIGURATION="debug"
  DIST_LABEL="debug"
fi

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

source_env_file() {
  local file="$1"
  [[ -f "$file" ]] || return 0

  set -a
  # shellcheck disable=SC1090
  source "$file"
  set +a
}

HAS_ENV_IRONSMITH_SUPABASE_URL=false
HAS_ENV_IRONSMITH_SUPABASE_PUBLISHABLE_KEY=false
HAS_ENV_IRONSMITH_API_BASE_URL=false
HAS_ENV_IRONSMITH_DEV_SIGN_IDENTITY=false

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

source_env_file "$CONFIG_DIR/.env"

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

IRONSMITH_SUPABASE_URL="${IRONSMITH_SUPABASE_URL:-}"
IRONSMITH_SUPABASE_PUBLISHABLE_KEY="${IRONSMITH_SUPABASE_PUBLISHABLE_KEY:-}"
IRONSMITH_API_BASE_URL="${IRONSMITH_API_BASE_URL:-}"
IRONSMITH_DEV_SIGN_IDENTITY="${IRONSMITH_DEV_SIGN_IDENTITY:--}"

if [[ -n "$SUPABASE_URL_OVERRIDE" ]]; then
  IRONSMITH_SUPABASE_URL="$SUPABASE_URL_OVERRIDE"
fi

if [[ -n "$SUPABASE_PUBLISHABLE_KEY_OVERRIDE" ]]; then
  IRONSMITH_SUPABASE_PUBLISHABLE_KEY="$SUPABASE_PUBLISHABLE_KEY_OVERRIDE"
fi

if [[ -n "$API_BASE_URL_OVERRIDE" ]]; then
  IRONSMITH_API_BASE_URL="$API_BASE_URL_OVERRIDE"
fi

resolve_sign_identity() {
  if [[ "$RELEASE_BUILD" == true ]]; then
    SIGN_IDENTITY="$SIGN_IDENTITY_OVERRIDE"

    if [[ -z "$SIGN_IDENTITY" || "$SIGN_IDENTITY" == "-" ]]; then
      echo "Release builds require a Developer ID Application signing identity." >&2
      echo "Pass --sign-identity." >&2
      exit 1
    fi

    if [[ "$SIGN_IDENTITY" != *"Developer ID Application"* ]]; then
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

if [[ "$SIGN_IDENTITY" == "-" ]]; then
  echo "Signing $APP_NAME ($DIST_LABEL) ad hoc"
else
  echo "Signing $APP_NAME ($DIST_LABEL) with $SIGN_IDENTITY"
fi

cd "$REPO_ROOT"

BUILD_ARCH_EXECUTABLE_URL=""
BUILD_ARCH_BIN_DIR=""

require_executable() {
  local executable_url="$1"
  if [[ ! -x "$executable_url" ]]; then
    echo "Missing executable at $executable_url" >&2
    exit 1
  fi
}

build_native_executable() {
  echo "Building $APP_NAME ($DIST_LABEL)"
  swift build --configuration "$SWIFT_CONFIGURATION"
  BUILD_ARCH_BIN_DIR="$(swift build --configuration "$SWIFT_CONFIGURATION" --show-bin-path)"
  BUILD_ARCH_EXECUTABLE_URL="$BUILD_ARCH_BIN_DIR/$APP_NAME"
  require_executable "$BUILD_ARCH_EXECUTABLE_URL"
}

build_release_arch() {
  local arch="$1"
  local triple="$arch-apple-macosx$MINIMUM_MACOS_VERSION"

  echo "Building $APP_NAME (release, $arch)"
  swift build --configuration release --triple "$triple"
  BUILD_ARCH_BIN_DIR="$(swift build --configuration release --triple "$triple" --show-bin-path)"
  BUILD_ARCH_EXECUTABLE_URL="$BUILD_ARCH_BIN_DIR/$APP_NAME"
  require_executable "$BUILD_ARCH_EXECUTABLE_URL"
}

if [[ "$RELEASE_BUILD" == true ]]; then
  build_release_arch arm64
  ARM64_EXECUTABLE_URL="$BUILD_ARCH_EXECUTABLE_URL"
  RESOURCE_BUNDLE_BIN_DIR="$BUILD_ARCH_BIN_DIR"

  build_release_arch x86_64
  X86_64_EXECUTABLE_URL="$BUILD_ARCH_EXECUTABLE_URL"
else
  build_native_executable
  EXECUTABLE_URL="$BUILD_ARCH_EXECUTABLE_URL"
  RESOURCE_BUNDLE_BIN_DIR="$BUILD_ARCH_BIN_DIR"
fi

rm -rf "$APP_URL"
mkdir -p "$MACOS_URL" "$RESOURCES_URL"

if [[ "$RELEASE_BUILD" == true ]]; then
  /usr/bin/lipo \
    -create \
    "$ARM64_EXECUTABLE_URL" \
    "$X86_64_EXECUTABLE_URL" \
    -output "$MACOS_URL/$APP_NAME"
  /usr/bin/lipo "$MACOS_URL/$APP_NAME" -verify_arch arm64 x86_64
else
  cp "$EXECUTABLE_URL" "$MACOS_URL/$APP_NAME"
fi
chmod 755 "$MACOS_URL/$APP_NAME"

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

xcrun actool "$APP_RESOURCES_SOURCE_URL/Assets.xcassets" \
  --compile "$RESOURCES_URL" \
  --platform macosx \
  --minimum-deployment-target "$MINIMUM_MACOS_VERSION" \
  --app-icon AppIcon \
  --accent-color AccentColor \
  --output-partial-info-plist "$ASSET_INFO_PLIST_URL" >/dev/null

if [[ -f "$ASSET_INFO_PLIST_URL" ]]; then
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

find "$APP_RESOURCES_SOURCE_URL" \
  -mindepth 1 \
  -maxdepth 1 \
  ! -name "*.xcassets" \
  ! -name ".DS_Store" \
  -exec cp -R {} "$RESOURCES_URL" \;

if [[ -f "$REPO_ROOT/Package.resolved" ]]; then
  cp "$REPO_ROOT/Package.resolved" "$RESOURCES_URL/Package.resolved"
fi

find "$RESOURCE_BUNDLE_BIN_DIR" \
  -maxdepth 1 \
  -type d \
  -name "*.bundle" \
  ! -name "${APP_NAME}_${APP_NAME}.bundle" \
  -exec cp -R {} "$RESOURCES_URL" \;

if [[ "$RELEASE_BUILD" == true ]]; then
  /usr/bin/codesign \
    --force \
    --sign "$SIGN_IDENTITY" \
    --options runtime \
    --timestamp \
    "$APP_URL" >/dev/null
else
  /usr/bin/codesign --force --sign "$SIGN_IDENTITY" "$APP_URL" >/dev/null
fi
/usr/bin/codesign --verify --deep --strict "$APP_URL"

echo "Built $APP_URL"

if [[ "$COMMAND" == "run" ]]; then
  pkill -x "$APP_NAME" 2>/dev/null || true
  /usr/bin/open -n "$APP_URL"
fi
