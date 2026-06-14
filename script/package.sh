#!/usr/bin/env bash
set -euo pipefail

APP_URL=""
OUTPUT_URL_OVERRIDE=""
DMG_VOLUME_NAME_OVERRIDE=""
SIGN_IDENTITY=""
NOTARY_KEYCHAIN_PROFILE=""
NOTARY_APPLE_ID=""
NOTARY_PASSWORD=""
NOTARY_TEAM_ID=""
NOTARY_KEY=""
NOTARY_KEY_ID=""
NOTARY_ISSUER_ID=""

usage() {
  cat <<USAGE
Usage: script/package.sh [path/to/App.app] [options]

Packages a .app into a DMG, submits the DMG for notarization, and staples it.
Defaults to dist/release/Ironsmith.app when no .app path is provided.

General options:
  --output                      Output DMG path. Default: next to the app, named after the app
  --volume-name                 DMG volume title. Default: app name
  --sign-identity               Optional Developer ID Application identity for signing the DMG

Notarization credentials, option 1:
  --notary-keychain-profile     Keychain profile created with xcrun notarytool store-credentials

Notarization credentials, option 2:
  --notary-key                  App Store Connect API key path or key ID recognized by notarytool
  --notary-key-id               App Store Connect API key ID
  --notary-issuer-id            App Store Connect issuer ID

Notarization credentials, option 3:
  --notary-apple-id             Apple ID email
  --notary-password             Apple ID app-specific password
  --notary-team-id              Apple Developer team ID

Other:
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
    --output)
      OUTPUT_URL_OVERRIDE="$(require_value "$1" "${2:-}")"
      shift 2
      ;;
    --volume-name)
      DMG_VOLUME_NAME_OVERRIDE="$(require_value "$1" "${2:-}")"
      shift 2
      ;;
    --sign-identity)
      SIGN_IDENTITY="$(require_value "$1" "${2:-}")"
      shift 2
      ;;
    --notary-keychain-profile)
      NOTARY_KEYCHAIN_PROFILE="$(require_value "$1" "${2:-}")"
      shift 2
      ;;
    --notary-apple-id)
      NOTARY_APPLE_ID="$(require_value "$1" "${2:-}")"
      shift 2
      ;;
    --notary-password)
      NOTARY_PASSWORD="$(require_value "$1" "${2:-}")"
      shift 2
      ;;
    --notary-team-id)
      NOTARY_TEAM_ID="$(require_value "$1" "${2:-}")"
      shift 2
      ;;
    --notary-key)
      NOTARY_KEY="$(require_value "$1" "${2:-}")"
      shift 2
      ;;
    --notary-key-id)
      NOTARY_KEY_ID="$(require_value "$1" "${2:-}")"
      shift 2
      ;;
    --notary-issuer-id)
      NOTARY_ISSUER_ID="$(require_value "$1" "${2:-}")"
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
      if [[ -n "$APP_URL" ]]; then
        echo "Only one .app path can be provided" >&2
        exit 2
      fi
      APP_URL="$1"
      shift
      ;;
  esac
done

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "$SCRIPT_DIR/.." && pwd)"

if [[ -z "$APP_URL" ]]; then
  APP_URL="$REPO_ROOT/dist/release/Ironsmith.app"
fi

if [[ "$APP_URL" != *.app ]]; then
  echo "App path must end in .app: $APP_URL" >&2
  exit 2
fi

if [[ ! -d "$APP_URL" ]]; then
  echo "Missing app bundle at $APP_URL" >&2
  if [[ "$APP_URL" == "$REPO_ROOT/dist/release/Ironsmith.app" ]]; then
    echo "Build it first with: script/build.sh --release --sign-identity \"Developer ID Application: Example (TEAMID)\"" >&2
  fi
  exit 1
fi

APP_PARENT_URL="$(cd -- "$(dirname -- "$APP_URL")" && pwd)"
APP_URL="$APP_PARENT_URL/$(basename -- "$APP_URL")"
APP_DISPLAY_NAME="$(basename -- "$APP_URL" .app)"
DMG_VOLUME_NAME="${DMG_VOLUME_NAME_OVERRIDE:-$APP_DISPLAY_NAME}"

if [[ -n "$OUTPUT_URL_OVERRIDE" ]]; then
  OUTPUT_PARENT_URL="$(mkdir -p "$(dirname -- "$OUTPUT_URL_OVERRIDE")" && cd -- "$(dirname -- "$OUTPUT_URL_OVERRIDE")" && pwd)"
  DMG_URL="$OUTPUT_PARENT_URL/$(basename -- "$OUTPUT_URL_OVERRIDE")"
else
  DMG_URL="$APP_PARENT_URL/$APP_DISPLAY_NAME.dmg"
fi

if [[ "$DMG_URL" != *.dmg ]]; then
  DMG_URL="$DMG_URL.dmg"
fi

NOTARY_ARGS=()

require_command() {
  local command_name="$1"
  local install_hint="$2"
  if ! command -v "$command_name" >/dev/null 2>&1; then
    echo "Missing required command: $command_name" >&2
    echo "$install_hint" >&2
    exit 1
  fi
}

require_sindresorhus_create_dmg() {
  local help_output
  help_output="$(create-dmg --help 2>&1 || true)"
  if [[ "$help_output" != *"--dmg-title"* || "$help_output" != *"--identity"* || "$help_output" != *"--no-code-sign"* ]]; then
    echo "The installed create-dmg does not look like sindresorhus/create-dmg." >&2
    echo "Install the expected tool with: npm install --global create-dmg" >&2
    exit 1
  fi
}

configure_notary_args() {
  if [[ -n "$NOTARY_KEYCHAIN_PROFILE" ]]; then
    NOTARY_ARGS=(--keychain-profile "$NOTARY_KEYCHAIN_PROFILE")
    return
  fi

  if [[ -n "$NOTARY_KEY" || -n "$NOTARY_KEY_ID" || -n "$NOTARY_ISSUER_ID" ]]; then
    if [[ -z "$NOTARY_KEY" || -z "$NOTARY_KEY_ID" || -z "$NOTARY_ISSUER_ID" ]]; then
      echo "App Store Connect API-key notarization requires --notary-key, --notary-key-id, and --notary-issuer-id." >&2
      exit 1
    fi
    NOTARY_ARGS=(--key "$NOTARY_KEY" --key-id "$NOTARY_KEY_ID" --issuer "$NOTARY_ISSUER_ID")
    return
  fi

  if [[ -n "$NOTARY_APPLE_ID" || -n "$NOTARY_PASSWORD" || -n "$NOTARY_TEAM_ID" ]]; then
    if [[ -z "$NOTARY_APPLE_ID" || -z "$NOTARY_PASSWORD" || -z "$NOTARY_TEAM_ID" ]]; then
      echo "Apple ID notarization requires --notary-apple-id, --notary-password, and --notary-team-id." >&2
      exit 1
    fi
    NOTARY_ARGS=(--apple-id "$NOTARY_APPLE_ID" --password "$NOTARY_PASSWORD" --team-id "$NOTARY_TEAM_ID")
    return
  fi

  echo "Notarization credentials are required." >&2
  echo "Pass --notary-keychain-profile, or the complete App Store Connect API key group, or the complete Apple ID group." >&2
  exit 1
}

configure_notary_args
require_command create-dmg "Install sindresorhus/create-dmg with: npm install --global create-dmg"
require_sindresorhus_create_dmg
xcrun -find notarytool >/dev/null
xcrun -find stapler >/dev/null

DMG_OUTPUT_DIR="$(mktemp -d)"
trap 'rm -rf "$DMG_OUTPUT_DIR"' EXIT

rm -f "$DMG_URL"

CREATE_DMG_ARGS=(--overwrite --dmg-title="$DMG_VOLUME_NAME")
if [[ -n "$SIGN_IDENTITY" ]]; then
  CREATE_DMG_ARGS+=(--identity="$SIGN_IDENTITY")
else
  CREATE_DMG_ARGS+=(--no-code-sign)
fi

create-dmg "${CREATE_DMG_ARGS[@]}" "$APP_URL" "$DMG_OUTPUT_DIR"

CREATED_DMG_URL="$(find "$DMG_OUTPUT_DIR" -maxdepth 1 -type f -name "*.dmg" -print -quit)"
if [[ -z "$CREATED_DMG_URL" || ! -f "$CREATED_DMG_URL" ]]; then
  echo "create-dmg did not produce a DMG in $DMG_OUTPUT_DIR" >&2
  exit 1
fi

mv "$CREATED_DMG_URL" "$DMG_URL"

xcrun notarytool submit "$DMG_URL" --wait "${NOTARY_ARGS[@]}"
xcrun stapler staple "$DMG_URL"
xcrun stapler validate "$DMG_URL"

echo "Packaged notarized DMG $DMG_URL"
