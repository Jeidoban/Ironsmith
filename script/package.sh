#!/usr/bin/env bash

# Packaging is intentionally fail-fast. A missing tool, invalid credential set,
# or failed notarization must stop the script instead of producing a DMG that
# looks complete but is not safe to distribute.
set -euo pipefail

# Command-line state. Empty values mean the caller did not provide that option;
# the credential-selection helper below turns one complete credential set into
# the argument list passed to Apple's notarytool.
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

# Describe the accepted app path, output, signing, and notarization options.
# Notarization supports three credential styles, selected by the helper below.
usage() {
  cat <<USAGE
Usage: script/package.sh [path/to/App.app] [options]

Packages a .app into a DMG, submits the DMG for notarization, and staples it.
Defaults to dist/release-arm64/Ironsmith.app when no .app path is provided.

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

# Require a non-empty option value and reject a following option being consumed
# accidentally as that value.
require_value() {
  local option="$1"
  local value="${2:-}"
  if [[ -z "$value" || "$value" == --* ]]; then
    echo "$option requires a value" >&2
    exit 2
  fi
  printf '%s' "$value"
}

# Parse one optional app path plus the packaging and notarization options. The
# app path is positional; all other arguments are named to keep credential usage
# explicit and avoid accidentally sending the wrong identity or secret to
# Apple's tooling.
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

# Resolve paths relative to the repository rather than the caller's current
# directory. This makes the default release artifact location predictable.
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "$SCRIPT_DIR/.." && pwd)"

if [[ -z "$APP_URL" ]]; then
  # The default is the arm64 release artifact produced by build.sh. x86_64
  # callers should pass dist/release-x86_64/Ironsmith.app explicitly.
  APP_URL="$REPO_ROOT/dist/release-arm64/Ironsmith.app"
fi

# Fail early on an obviously wrong input before asking any external tool to
# inspect it.
if [[ "$APP_URL" != *.app ]]; then
  echo "App path must end in .app: $APP_URL" >&2
  exit 2
fi

# Require the staged app to exist. The tailored hint covers the common default
# path and reminds the caller that packaging expects a signed release build.
if [[ ! -d "$APP_URL" ]]; then
  echo "Missing app bundle at $APP_URL" >&2
  if [[ "$APP_URL" == "$REPO_ROOT/dist/release-arm64/Ironsmith.app" ]]; then
    echo "Build it first with: script/build.sh --release --arch arm64 --sign-identity \"Developer ID Application: Example (TEAMID)\"" >&2
  fi
  exit 1
fi

# Canonicalize the app path and derive the display name used for both the DMG
# filename and (unless overridden) the DMG volume title.
APP_PARENT_URL="$(cd -- "$(dirname -- "$APP_URL")" && pwd)"
APP_URL="$APP_PARENT_URL/$(basename -- "$APP_URL")"
APP_DISPLAY_NAME="$(basename -- "$APP_URL" .app)"
DMG_VOLUME_NAME="${DMG_VOLUME_NAME_OVERRIDE:-$APP_DISPLAY_NAME}"

if [[ -n "$OUTPUT_URL_OVERRIDE" ]]; then
  # Create the requested output directory before canonicalizing the destination
  # so --output can point to a directory that does not exist yet.
  OUTPUT_PARENT_URL="$(mkdir -p "$(dirname -- "$OUTPUT_URL_OVERRIDE")" && cd -- "$(dirname -- "$OUTPUT_URL_OVERRIDE")" && pwd)"
  DMG_URL="$OUTPUT_PARENT_URL/$(basename -- "$OUTPUT_URL_OVERRIDE")"
else
  DMG_URL="$APP_PARENT_URL/$APP_DISPLAY_NAME.dmg"
fi

# Be forgiving if the caller omitted the extension, while ensuring the final
# destination is always a DMG path.
if [[ "$DMG_URL" != *.dmg ]]; then
  DMG_URL="$DMG_URL.dmg"
fi

# notarytool receives its credential flags as an array. Arrays preserve argument
# boundaries safely, including spaces or shell-special characters in paths and
# profile names.
NOTARY_ARGS=()

# Check for a command before using it, and provide the installation/repair hint
# supplied by the caller of this helper.
require_command() {
  local command_name="$1"
  local install_hint="$2"
  if ! command -v "$command_name" >/dev/null 2>&1; then
    echo "Missing required command: $command_name" >&2
    echo "$install_hint" >&2
    exit 1
  fi
}

# `create-dmg` is a third-party executable with several similarly named tools in
# the ecosystem. Inspect its help output so a different executable does not
# silently receive incompatible flags and generate an invalid image.
require_sindresorhus_create_dmg() {
  local help_output
  help_output="$(create-dmg --help 2>&1 || true)"
  if [[ "$help_output" != *"--dmg-title"* || "$help_output" != *"--identity"* || "$help_output" != *"--no-code-sign"* ]]; then
    echo "The installed create-dmg does not look like sindresorhus/create-dmg." >&2
    echo "Install the expected tool with: npm install --global create-dmg" >&2
    exit 1
  fi
}

# Translate exactly one complete notarization credential style into notarytool
# flags. The order establishes precedence when more than one style is supplied:
# keychain profile, then App Store Connect API key, then Apple ID credentials.
# Partial groups fail explicitly because notarytool would otherwise fail later
# with a less useful authentication error.
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

# Resolve credentials and verify every external dependency before modifying the
# output path or creating temporary packaging state.
configure_notary_args
require_command create-dmg "Install sindresorhus/create-dmg with: npm install --global create-dmg"
require_sindresorhus_create_dmg
xcrun -find notarytool >/dev/null
xcrun -find stapler >/dev/null

# create-dmg writes into a temporary directory so a failed or differently named
# intermediate file cannot partially overwrite the requested final DMG. The
# EXIT trap removes that directory on success, failure, or interruption.
DMG_OUTPUT_DIR="$(mktemp -d)"
trap 'rm -rf "$DMG_OUTPUT_DIR"' EXIT

# Replace an existing DMG at the exact destination. This is intentionally done
# only after all preflight checks have passed.
rm -f "$DMG_URL"

# Build the create-dmg arguments. A supplied identity asks create-dmg to sign
# the image; otherwise --no-code-sign leaves DMG signing to the explicit
# notarization/stapling workflow and avoids inventing a signing identity.
CREATE_DMG_ARGS=(--overwrite --dmg-title="$DMG_VOLUME_NAME")
if [[ -n "$SIGN_IDENTITY" ]]; then
  CREATE_DMG_ARGS+=(--identity="$SIGN_IDENTITY")
else
  CREATE_DMG_ARGS+=(--no-code-sign)
fi

# Create the DMG from the already-built app. The tool may choose the generated
# filename, so locate the DMG it produced instead of assuming a name.
create-dmg "${CREATE_DMG_ARGS[@]}" "$APP_URL" "$DMG_OUTPUT_DIR"

# Confirm that creation produced a real file before moving it to the requested
# destination. A missing file is a packaging failure, not a notarization issue.
CREATED_DMG_URL="$(find "$DMG_OUTPUT_DIR" -maxdepth 1 -type f -name "*.dmg" -print -quit)"
if [[ -z "$CREATED_DMG_URL" || ! -f "$CREATED_DMG_URL" ]]; then
  echo "create-dmg did not produce a DMG in $DMG_OUTPUT_DIR" >&2
  exit 1
fi

# Move the completed image into its final stable location. From here onward the
# remaining steps operate on the artifact the caller will distribute.
mv "$CREATED_DMG_URL" "$DMG_URL"

# Submit the DMG and wait synchronously for Apple's verdict. With --wait, a
# rejection or submission failure exits non-zero and prevents stapling.
xcrun notarytool submit "$DMG_URL" --wait "${NOTARY_ARGS[@]}"

# Attach Apple's notarization ticket to the DMG and then verify that the ticket
# can be read back successfully. Both steps are required for a complete
# distributable artifact.
xcrun stapler staple "$DMG_URL"
xcrun stapler validate "$DMG_URL"

# Report the final artifact only after creation, notarization, stapling, and
# validation have all succeeded.
echo "Packaged notarized DMG $DMG_URL"
