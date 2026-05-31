#!/usr/bin/env bash
set -euo pipefail

CONF="${1:-debug}"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

[[ "${VERBOSE:-0}" == "1" || "${VERBOSE:-0}" == "true" ]] && set -x

START_TIME="$(date +%s)"
PHASE_START="$START_TIME"
phase(){
    local now elapsed total
    now="$(date +%s)"
    elapsed=$((now - PHASE_START))
    total=$((now - START_TIME))
    printf '\n==> [%s] %s (previous: %ss, total: %ss)\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" "$elapsed" "$total"
    PHASE_START="$now"
}
echo_cmd(){
    printf '+ '
    printf '%q ' "$@"
    printf '\n'
}
run(){
    echo_cmd "$@"
    "$@"
}
fail(){ echo "ERROR: $*" >&2; exit 1; }
finish(){
    local status=$? now total
    now="$(date +%s)"
    total=$((now - START_TIME))
    if (( status == 0 )); then
        printf '\n==> [%s] Completed packaging in %ss\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$total"
    else
        echo "ERROR: Packaging failed after ${total}s. Re-run with VERBOSE=1 $0 $CONF for shell tracing." >&2
    fi
    exit "$status"
}
trap finish EXIT

BUNDLE_ID_OVERRIDE="${BUNDLE_ID:-}"
set -a; source "$ROOT_DIR/version.env"; set +a
APP_NAME="${APP_NAME:-RepoPrompt}"; DISPLAY_NAME="${DISPLAY_NAME:-RepoPrompt CE}"; BASE_BUNDLE_ID="${BUNDLE_ID:-com.pvncher.repoprompt.ce}"; MARKETING_VERSION="${MARKETING_VERSION:-0.1.0}"; BUILD_NUMBER="${BUILD_NUMBER:-1}"; SIGNING_TEAM_ID="${SIGNING_TEAM_ID:-648A27MST5}"

IS_RELEASE=0
[[ "$CONF" == "release" ]] && IS_RELEASE=1
if (( IS_RELEASE )); then
    BUNDLE_ID="${BUNDLE_ID_OVERRIDE:-$BASE_BUNDLE_ID}"
else
    BUNDLE_ID="${BUNDLE_ID_OVERRIDE:-${DEBUG_BUNDLE_ID:-$BASE_BUNDLE_ID.debug}}"
fi

phase "Checking build environment"
run ./Scripts/doctor.sh --quiet
SIGN_IDENTITY_WAS_EXPLICIT=0
if [[ -n "${SIGN_IDENTITY:-}" ]]; then
    SIGN_IDENTITY_WAS_EXPLICIT=1
fi
SIGN_IDENTITY="${SIGN_IDENTITY:-}"
ALLOW_ADHOC_SIGNING="${ALLOW_ADHOC_SIGNING:-0}"
RELEASE_ALLOW_ADHOC_SIGNING="${RELEASE_ALLOW_ADHOC_SIGNING:-0}"
PREFER_STABLE_DEBUG_SIGNING="${PREFER_STABLE_DEBUG_SIGNING:-1}"
DEBUG_SECURE_STORAGE_BACKEND="${DEBUG_SECURE_STORAGE_BACKEND:-}"
REPOPROMPT_PROVISIONING_PROFILE="${REPOPROMPT_PROVISIONING_PROFILE:-}"
APP_ENTITLEMENTS_TEMPLATE="${APP_ENTITLEMENTS_TEMPLATE:-$ROOT_DIR/AppBundle/RepoPrompt.entitlements.template}"
USE_ADHOC_SIGNING=0
DEBUG_STORAGE_BACKEND_MARKER="alternate-in-memory"
warn_adhoc_signing(){
    echo "WARNING: Using explicit ad-hoc signing for a debug package."
    echo "WARNING: RepoPrompt debug runtime will use ephemeral in-memory secure storage instead of macOS Keychain for API keys and secure permission documents."
    echo "WARNING: Keychain consent prompts should be avoided, but secrets and secure permission changes saved in this run will not persist across app launches."
    echo "WARNING: Use explicit SIGN_IDENTITY=\"Apple Development: ...\" for real local Keychain persistence."
}
warn_release_candidate_signing(){
    echo "WARNING: Using explicit ad-hoc signing for a release-candidate package."
    echo "WARNING: This artifact exercises release packaging only. It is not notarizable, distributable, or suitable for GitHub Releases."
}
if [[ -z "$SIGN_IDENTITY" ]] && (( ! IS_RELEASE )) && [[ "$PREFER_STABLE_DEBUG_SIGNING" == "1" || "$PREFER_STABLE_DEBUG_SIGNING" == "true" ]]; then
    AUTO_SIGN_IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null | awk -F'"' '/"Apple Development: / { print $2; exit }')"
    if [[ -n "$AUTO_SIGN_IDENTITY" ]]; then
        SIGN_IDENTITY="$AUTO_SIGN_IDENTITY"
        echo "Using auto-detected debug signing identity: $SIGN_IDENTITY"
    fi
fi
if [[ -z "$SIGN_IDENTITY" ]]; then
    if (( IS_RELEASE )); then
        if [[ "$RELEASE_ALLOW_ADHOC_SIGNING" != "1" && "$RELEASE_ALLOW_ADHOC_SIGNING" != "true" ]]; then
            fail "Release packaging requires SIGN_IDENTITY and will not produce an ad-hoc signed app by default. Set SIGN_IDENTITY to a stable Apple signing identity for team $SIGNING_TEAM_ID."
        fi
        USE_ADHOC_SIGNING=1
        SIGN_IDENTITY="-"
        warn_release_candidate_signing
    else
        if [[ "$ALLOW_ADHOC_SIGNING" != "1" && "$ALLOW_ADHOC_SIGNING" != "true" ]]; then
            fail "Debug ad-hoc signing is disabled by default. Set ALLOW_ADHOC_SIGNING=1 to build an ad-hoc package, or set SIGN_IDENTITY for stable signing."
        fi
        USE_ADHOC_SIGNING=1
        SIGN_IDENTITY="-"
        warn_adhoc_signing
    fi
else
    if (( ! IS_RELEASE )) && (( ! SIGN_IDENTITY_WAS_EXPLICIT )) && [[ -z "$DEBUG_SECURE_STORAGE_BACKEND" ]]; then
        echo "WARNING: Auto-detected debug signing will use ephemeral in-memory secure storage to avoid macOS Keychain prompts."
        echo "WARNING: Use explicit SIGN_IDENTITY=\"Apple Development: ...\" to opt in to persistent debug Keychain storage."
    fi
    echo "Using signing identity: $SIGN_IDENTITY"
    if ! security find-identity -v -p codesigning | grep -F -- "$SIGN_IDENTITY" >/dev/null 2>&1; then
        echo "WARNING: SIGN_IDENTITY was not found by exact text in 'security find-identity'; codesign will still attempt to use it."
    fi
fi

if (( IS_RELEASE )) && (( ! USE_ADHOC_SIGNING )); then
    DEBUG_STORAGE_BACKEND_MARKER="keychain"
elif [[ -n "$DEBUG_SECURE_STORAGE_BACKEND" ]]; then
    case "$DEBUG_SECURE_STORAGE_BACKEND" in
        keychain|alternate-in-memory) DEBUG_STORAGE_BACKEND_MARKER="$DEBUG_SECURE_STORAGE_BACKEND" ;;
        *) fail "DEBUG_SECURE_STORAGE_BACKEND must be 'keychain' or 'alternate-in-memory', got '$DEBUG_SECURE_STORAGE_BACKEND'." ;;
    esac
elif (( SIGN_IDENTITY_WAS_EXPLICIT )) && (( ! USE_ADHOC_SIGNING )); then
    DEBUG_STORAGE_BACKEND_MARKER="keychain"
fi
printf 'Debug secure storage backend marker: %s\n' "$DEBUG_STORAGE_BACKEND_MARKER"

phase "Building $APP_NAME ($CONF)"
run swift build -c "$CONF" --product "$APP_NAME"

phase "Building repoprompt-mcp ($CONF)"
run swift build -c "$CONF" --product repoprompt-mcp

phase "Resolving build artifact paths"
echo_cmd swift build -c "$CONF" --show-bin-path
BUILD_DIR="$(swift build -c "$CONF" --show-bin-path)"
if (( IS_RELEASE )); then
    APP_BUNDLE="$BUILD_DIR/$APP_NAME.app"
else
    APP_BUNDLE="${REPOPROMPT_DEBUG_APP_BUNDLE:-$HOME/Library/Application Support/RepoPrompt CE/DebugApps/$APP_NAME.app}"
fi
COMPAT_APP_BUNDLE="$ROOT_DIR/.build/$CONF/$APP_NAME.app"
CLI_PATH="$BUILD_DIR/repoprompt-mcp"
printf 'BUILD_DIR=%s\nAPP_BUNDLE=%s\nCOMPAT_APP_BUNDLE=%s\nCLI_PATH=%s\nAD_HOC_SIGNING=%s\n' "$BUILD_DIR" "$APP_BUNDLE" "$COMPAT_APP_BUNDLE" "$CLI_PATH" "$USE_ADHOC_SIGNING"

phase "Creating app bundle layout"
run rm -rf "$APP_BUNDLE"
if [[ "$(python3 - <<PY
from pathlib import Path
import os
print(Path('$APP_BUNDLE').resolve(strict=False) == Path('$COMPAT_APP_BUNDLE').resolve(strict=False))
PY
)" != "True" ]]; then
    run rm -rf "$COMPAT_APP_BUNDLE"
fi
run mkdir -p "$APP_BUNDLE/Contents/MacOS" "$APP_BUNDLE/Contents/Resources/bin" "$APP_BUNDLE/Contents/Frameworks"
for exe in "$APP_NAME" repoprompt-mcp; do
    [[ -x "$BUILD_DIR/$exe" ]] || fail "Missing built executable: $BUILD_DIR/$exe"
    run cp "$BUILD_DIR/$exe" "$APP_BUNDLE/Contents/MacOS/$exe"
    run chmod +x "$APP_BUNDLE/Contents/MacOS/$exe"
done
run ln -sf ../MacOS/repoprompt-mcp "$APP_BUNDLE/Contents/Resources/repoprompt-mcp"
run ln -sf ../../MacOS/repoprompt-mcp "$APP_BUNDLE/Contents/Resources/bin/repoprompt-mcp"
run mkdir -p "$APP_BUNDLE/Contents/Resources/Legal"
run cp "$ROOT_DIR/LICENSE" "$ROOT_DIR/THIRD_PARTY_NOTICES.md" "$APP_BUNDLE/Contents/Resources/Legal/"
run cp -R "$ROOT_DIR/ThirdPartyLicenses" "$APP_BUNDLE/Contents/Resources/Legal/"
[[ ! -d AppResources ]] || run rsync -a AppResources/ "$APP_BUNDLE/Contents/Resources/"
shopt -s nullglob
for bundle in "$BUILD_DIR"/*.bundle; do run cp -R "$bundle" "$APP_BUNDLE/Contents/Resources/"; done
shopt -u nullglob

phase "Writing Info.plist"
run python3 - <<PY
from pathlib import Path
s=Path('AppBundle/Info.plist.template').read_text()
for k,v in {'__APP_NAME__':'$APP_NAME','__DISPLAY_NAME__':'$DISPLAY_NAME','__BUNDLE_ID__':'$BUNDLE_ID','__MARKETING_VERSION__':'$MARKETING_VERSION','__BUILD_NUMBER__':'$BUILD_NUMBER','__DEBUG_SECURE_STORAGE_BACKEND__':'$DEBUG_STORAGE_BACKEND_MARKER'}.items(): s=s.replace(k,v)
Path('$APP_BUNDLE/Contents/Info.plist').write_text(s)
PY
run plutil -lint "$APP_BUNDLE/Contents/Info.plist"

if (( IS_RELEASE )) && (( ! USE_ADHOC_SIGNING )); then
    phase "Embedding release provisioning profile and entitlements"
    [[ -f "$REPOPROMPT_PROVISIONING_PROFILE" ]] || fail "Signed release packaging requires REPOPROMPT_PROVISIONING_PROFILE pointing to the RepoPrompt CE Developer ID provisioning profile."
    [[ -f "$APP_ENTITLEMENTS_TEMPLATE" ]] || fail "Missing release entitlements template: $APP_ENTITLEMENTS_TEMPLATE"
    PROFILE_PLIST="$(mktemp)"
    run security cms -D -i "$REPOPROMPT_PROVISIONING_PROFILE" -o "$PROFILE_PLIST"
    PROFILE_APP_IDENTIFIER="$(/usr/libexec/PlistBuddy -c 'Print :Entitlements:com.apple.application-identifier' "$PROFILE_PLIST" 2>/dev/null || true)"
    run rm -f "$PROFILE_PLIST"
    [[ "$PROFILE_APP_IDENTIFIER" == "$SIGNING_TEAM_ID.$BUNDLE_ID" ]] || fail "Provisioning profile app identifier mismatch: expected $SIGNING_TEAM_ID.$BUNDLE_ID, got ${PROFILE_APP_IDENTIFIER:-<missing>}."
    run cp "$REPOPROMPT_PROVISIONING_PROFILE" "$APP_BUNDLE/Contents/embedded.provisionprofile"
    run python3 - <<PY
from pathlib import Path
s=Path('$APP_ENTITLEMENTS_TEMPLATE').read_text()
for k,v in {'__BUNDLE_ID__':'$BUNDLE_ID','__SIGNING_TEAM_ID__':'$SIGNING_TEAM_ID'}.items(): s=s.replace(k,v)
Path('$APP_BUNDLE/Contents/RepoPrompt.entitlements').write_text(s)
PY
    run plutil -lint "$APP_BUNDLE/Contents/RepoPrompt.entitlements"
fi

phase "Copying dynamic frameworks"
printf 'Framework destination: %s\n' "$APP_BUNDLE/Contents/Frameworks"
echo_cmd find "$ROOT_DIR/.build" -path '*/Sparkle.framework' -type d -prune -print -exec cp -R {} "$APP_BUNDLE/Contents/Frameworks/" ';'
find "$ROOT_DIR/.build" -path '*/Sparkle.framework' -type d -prune -print -exec cp -R {} "$APP_BUNDLE/Contents/Frameworks/" \; 2>/dev/null || true
run install_name_tool -add_rpath @executable_path/../Frameworks "$APP_BUNDLE/Contents/MacOS/$APP_NAME" 2>/dev/null || true

phase "Signing app bundle"
sign_path(){
    local path="$1"
    shift || true
    local args=(--force --sign "$SIGN_IDENTITY")
    if (( USE_ADHOC_SIGNING )); then
        args+=(--timestamp=none)
    elif (( IS_RELEASE )); then
        args+=(--timestamp --options runtime)
    else
        args+=(--timestamp=none)
    fi
    run codesign "${args[@]}" "$@" "$path"
}
verify_signed_app_identity(){
    local details identifier team authorities
    details="$(codesign -dv "$APP_BUNDLE" 2>&1 || true)"
    identifier="$(printf '%s\n' "$details" | awk -F= '/^Identifier=/{print $2; exit}')"
    team="$(printf '%s\n' "$details" | awk -F= '/^TeamIdentifier=/{print $2; exit}')"
    authorities="$(printf '%s\n' "$details" | awk -F= '/^Authority=/{print $2}' | paste -sd ', ' -)"
    printf 'Signed app path: %s\n' "$APP_BUNDLE"
    printf 'Signed app identifier: %s\n' "${identifier:-<missing>}"
    printf 'Signed app team: %s\n' "${team:-<missing>}"
    printf 'Signing authorities: %s\n' "${authorities:-<none/ad-hoc>}"
    printf 'Ad-hoc signing active: %s\n' "$USE_ADHOC_SIGNING"
    printf 'Debug secure storage backend marker: %s\n' "$DEBUG_STORAGE_BACKEND_MARKER"
    [[ "$identifier" == "$BUNDLE_ID" ]] || fail "Signed app identifier mismatch: expected $BUNDLE_ID, got ${identifier:-<missing>}"
    if (( USE_ADHOC_SIGNING )); then
        [[ -z "$team" || "$team" == "not set" ]] || echo "WARNING: Expected ad-hoc signing without a team identifier, but found team '$team'."
        echo "WARNING: Ad-hoc package created explicitly; do not use this artifact for release."
    elif (( IS_RELEASE )); then
        [[ "$team" == "$SIGNING_TEAM_ID" ]] || fail "Signed app team mismatch: expected $SIGNING_TEAM_ID, got ${team:-<missing>}"
    else
        [[ -n "$team" && "$team" != "not set" ]] || fail "Debug app was expected to be signed with a stable identity, but no team identifier was found."
    fi
}
if [[ -d "$APP_BUNDLE/Contents/Frameworks/Sparkle.framework" ]]; then sign_path "$APP_BUNDLE/Contents/Frameworks/Sparkle.framework"; fi
sign_path "$APP_BUNDLE/Contents/MacOS/repoprompt-mcp"
sign_path "$APP_BUNDLE/Contents/MacOS/$APP_NAME"
APP_SIGN_ARGS=(--deep)
if (( IS_RELEASE )) && (( ! USE_ADHOC_SIGNING )); then
    APP_SIGN_ARGS+=(--entitlements "$APP_BUNDLE/Contents/RepoPrompt.entitlements")
fi
sign_path "$APP_BUNDLE" "${APP_SIGN_ARGS[@]}"
run codesign --verify --deep --strict --verbose=2 "$APP_BUNDLE"
verify_signed_app_identity
if [[ "$(python3 - <<PY
from pathlib import Path
print(Path('$APP_BUNDLE').resolve(strict=False) == Path('$COMPAT_APP_BUNDLE').resolve(strict=False))
PY
)" != "True" ]]; then
    phase "Updating compatibility app bundle link"
    run mkdir -p "$(dirname "$COMPAT_APP_BUNDLE")"
    if (( USE_ADHOC_SIGNING )); then
        if (( IS_RELEASE )); then
            warn_release_candidate_signing
        else
            warn_adhoc_signing
        fi
    fi
    run ln -sfn "$APP_BUNDLE" "$COMPAT_APP_BUNDLE"
    printf 'Compatibility link: %s -> %s\n' "$COMPAT_APP_BUNDLE" "$APP_BUNDLE"
fi
printf 'Created: %s\n' "$APP_BUNDLE"
