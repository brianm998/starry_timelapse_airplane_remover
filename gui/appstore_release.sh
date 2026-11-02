#!/bin/bash

set -e

# Build the sandboxed Mac App Store variant of the star gui and upload it to App Store Connect (TestFlight).
# gui/release.sh is the Developer ID + notarized build and is not touched by this one.
#
#   ./appstore_release.sh                 archive, check entitlements, export, validate, upload
#   ./appstore_release.sh --export-only   the same without the upload (destination=export), then altool --validate-app
#   ./appstore_release.sh --archive-only  stop after the archive and the entitlement checks (no installer identity needed)
#   ./appstore_release.sh --print-build-number
#
# What the variant is: appstore.xcconfig (Info.plist keys, universal), the version and build number on the xcodebuild
# command line, and, after the archive, star/star-appstore.entitlements and the bundle id. project.pbxproj is never edited.
#
# Environment (all optional locally, set by the macos-testflight job in CI):
#   APPSTORE_PROFILE_PATH   a Mac App Store .provisionprofile. Setting it means manual signing (a runner has no Apple ID
#                           in Xcode); without it signing is automatic with -allowProvisioningUpdates (this Mac).
#   APPSTORE_SIGNING        manual or automatic, to override that choice.
#   APPSTORE_TEAM_ID        the team of the Apple Distribution identity; else read from the one in the keychain.
#                           Not APPLE_TEAM_ID: that is the Developer ID team, which can be another team.
#   APPSTORE_BUNDLE_ID      the store's bundle id; default com.star. Developer ID builds keep com.star.
#   APPSTORE_BUILD_NUMBER   CFBundleVersion; default ${GITHUB_RUN_NUMBER}.${GITHUB_RUN_ATTEMPT} in CI (see below).
#   APPLE_API_KEY_PATH, APPLE_API_KEY_ID, APPLE_API_ISSUER_ID
#                           an App Store Connect API key (role App Manager or Admin) for the upload and the validation.
#                           Without it xcodebuild uses the account signed in to Xcode, and validation is skipped.

BUILD_DIR=.build/appstore
APP_NAME=Star
APP_ENTITLEMENTS=star/star-appstore.entitlements
TOOL_ENTITLEMENTS=ffmpeg-appstore.entitlements.plist
SIGN_APP_NAME="Apple Distribution"
SIGN_PKG_NAME="Mac Installer Distribution"

MODE=upload
for arg in "$@"; do
    case "$arg" in
        --export-only) MODE="export" ;;
        --archive-only) MODE=archive ;;
        --print-build-number) MODE=print-build-number ;;
        -h|--help) sed -n '3,/^$/p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "unknown argument: $arg (try --help)" >&2; exit 2 ;;
    esac
done

# ── build number ─────────────────────────────────────────────────────────────
# App Store Connect rejects an upload whose CFBundleVersion is not higher than every earlier one of the same marketing
# version. A CFBundleVersion is dot-separated integers, compared numerically part by part, so in CI
#   <run number>.<run attempt>
# rises for a re-run of the same run (57.1 -> 57.2) and for the next run (57.2 -> 58.1).
# A local upload gets 1.<minutes since the epoch>: it rises with every local upload, and is below every CI number
# (run numbers are far past 1), so a local upload never makes the next CI upload fail. The reverse is not true: once CI
# has uploaded a marketing version, a local upload of the same version is refused. Set APPSTORE_BUILD_NUMBER to choose.
build_number() {
    if [ -n "$APPSTORE_BUILD_NUMBER" ]; then
        echo "$APPSTORE_BUILD_NUMBER"
    elif [ -n "$GITHUB_RUN_NUMBER" ]; then
        echo "${GITHUB_RUN_NUMBER}.${GITHUB_RUN_ATTEMPT:-1}"
    else
        echo "1.$(( $(date -u +%s) / 60 ))"
    fi
}

if [ "$MODE" = print-build-number ]; then
    build_number
    exit 0
fi

# The app bundles ffmpeg and ffprobe, and this build is universal, so they have to be too.
source "$(dirname "$0")/../preflight.sh"
preflight_ffmpeg universal
preflight_finish

STAR_VERSION=`cd ../StarCore ; perl version.pl`
BUILD_NUMBER="$(build_number)"
BUNDLE_ID="${APPSTORE_BUNDLE_ID:-com.star}"
echo "App Store build: ${STAR_VERSION} (${BUILD_NUMBER}), bundle id ${BUNDLE_ID}"

die() { echo "error: $*" >&2; exit 1; }

# ── team and signing ─────────────────────────────────────────────────────────
if [ -z "$APPSTORE_TEAM_ID" ]; then
    # "Apple Distribution: Preffect, Inc. (ZPZ92MX278)" -> ZPZ92MX278
    TEAMS="$(security find-identity -v | sed -n "s/.*\"${SIGN_APP_NAME}: .*(\([A-Z0-9]*\))\".*/\1/p" | sort -u)"
    [ -n "$TEAMS" ] || die "no \"${SIGN_APP_NAME}\" identity in the keychain, and APPSTORE_TEAM_ID is not set"
    [ "$(echo "$TEAMS" | wc -l)" -eq 1 ] || die "several teams have an \"${SIGN_APP_NAME}\" identity ($(echo $TEAMS)); set APPSTORE_TEAM_ID"
    APPSTORE_TEAM_ID="$TEAMS"
fi
echo "team ${APPSTORE_TEAM_ID}"

SIGNING="${APPSTORE_SIGNING:-}"
if [ -z "$SIGNING" ]; then
    if [ -n "$APPSTORE_PROFILE_PATH" ]; then SIGNING=manual; else SIGNING=automatic; fi
fi

XCODEBUILD_SIGNING_ARGS=("DEVELOPMENT_TEAM=${APPSTORE_TEAM_ID}")
EXPORT_PROFILES=""
if [ "$SIGNING" = manual ]; then
    # The archive is signed with the distribution identity and no profile: a sandboxed Mac app with these entitlements
    # needs none to build (the Developer ID build is the same). The export embeds the profile and signs with it.
    # A profile specifier on the archive command line would also reach the Swift package targets, which refuse one.
    XCODEBUILD_SIGNING_ARGS+=(
        "CODE_SIGN_STYLE=Manual"
        "CODE_SIGN_IDENTITY=${SIGN_APP_NAME}"
        "PROVISIONING_PROFILE_SPECIFIER="
        "OTHER_CODE_SIGN_FLAGS=--timestamp"
    )
else
    XCODEBUILD_SIGNING_ARGS+=("CODE_SIGN_STYLE=Automatic")
fi
XCODEBUILD_AUTH_ARGS=()
if [ -n "$APPLE_API_KEY_PATH" ]; then
    XCODEBUILD_AUTH_ARGS=(
        -authenticationKeyPath "$APPLE_API_KEY_PATH"
        -authenticationKeyID "$APPLE_API_KEY_ID"
        -authenticationKeyIssuerID "$APPLE_API_ISSUER_ID"
    )
fi
ALLOW_PROVISIONING=()
[ "$SIGNING" = automatic ] && ALLOW_PROVISIONING=(-allowProvisioningUpdates)

rm -rf "${BUILD_DIR}"
mkdir -p "${BUILD_DIR}"

INSTALLED_PROFILE=""
cleanup() { [ -z "$INSTALLED_PROFILE" ] || rm -f "$INSTALLED_PROFILE"; }
trap cleanup EXIT

if [ "$SIGNING" = manual ] && [ "$MODE" != archive ]; then
    [ -f "$APPSTORE_PROFILE_PATH" ] || die "manual signing needs APPSTORE_PROFILE_PATH, a Mac App Store .provisionprofile (it is '${APPSTORE_PROFILE_PATH}')"
    security cms -D -i "$APPSTORE_PROFILE_PATH" > "$BUILD_DIR/profile.plist"
    PROFILE_NAME="$(/usr/libexec/PlistBuddy -c 'Print :Name' "$BUILD_DIR/profile.plist")"
    PROFILE_UUID="$(/usr/libexec/PlistBuddy -c 'Print :UUID' "$BUILD_DIR/profile.plist")"
    PROFILE_APPID="$(/usr/libexec/PlistBuddy -c 'Print :Entitlements:com.apple.application-identifier' "$BUILD_DIR/profile.plist")"
    # Said here, not left to an export error twenty minutes in.
    [ "$PROFILE_APPID" = "${APPSTORE_TEAM_ID}.${BUNDLE_ID}" ] ||
        die "the provisioning profile '${PROFILE_NAME}' is for ${PROFILE_APPID}, not ${APPSTORE_TEAM_ID}.${BUNDLE_ID}"
    /usr/libexec/PlistBuddy -c 'Print :ProvisionedDevices' "$BUILD_DIR/profile.plist" >/dev/null 2>&1 &&
        die "the provisioning profile '${PROFILE_NAME}' lists devices: it is a development profile, not a Mac App Store one"
    PROFILE_DIR="$HOME/Library/MobileDevice/Provisioning Profiles"
    mkdir -p "$PROFILE_DIR"
    INSTALLED_PROFILE="$PROFILE_DIR/${PROFILE_UUID}.provisionprofile"
    cp "$APPSTORE_PROFILE_PATH" "$INSTALLED_PROFILE"
    EXPORT_PROFILES="<key>provisioningProfiles</key><dict><key>${BUNDLE_ID}</key><string>${PROFILE_NAME}</string></dict>"
    echo "provisioning profile '${PROFILE_NAME}' (${PROFILE_UUID})"
fi

# ── entitlement checks ───────────────────────────────────────────────────────
# check_entitlements <path> <label> <expected keys, space separated> [extra keys allowed]
# Dumps what codesign says the code carries and fails unless the keys are exactly the expected ones (plus the allowed
# extras, which Xcode adds from the provisioning profile) and none is false.
check_entitlements() {
    local path="$1" label="$2" expected="$3" extras="$4" xml keys key
    echo "--- entitlements: ${label}"
    xml="$(codesign -d --entitlements - --xml "$path" 2>/dev/null)"
    [ -n "$xml" ] || die "${label} carries no entitlements at all (${path})"
    echo "$xml" | plutil -p -
    keys="$(echo "$xml" | plutil -convert json -o - - | perl -MJSON::PP -e '
        my $h = decode_json(join "", <STDIN>);
        for my $k (sort keys %$h) { print "$k\n" if $h->{$k} }
        print "FALSE:$_\n" for grep { !$h->{$_} } sort keys %$h;')"
    for key in $keys; do
        case "$key" in
            FALSE:*) die "${label}: ${key#FALSE:} is false" ;;
        esac
        case " $expected $extras " in
            *" $key "*) ;;
            *) die "${label} has the entitlement ${key}, which is not wanted here (wanted exactly: ${expected}${extras:+, plus $extras from the profile})" ;;
        esac
    done
    for key in $expected; do
        case " $(echo $keys) " in
            *" $key "*) ;;
            *) die "${label} lacks the entitlement ${key}" ;;
        esac
    done
}

APP_KEYS="com.apple.security.app-sandbox com.apple.security.files.user-selected.read-write com.apple.security.files.bookmarks.app-scope"
TOOL_KEYS="com.apple.security.app-sandbox com.apple.security.inherit"
# what Xcode adds to the app from the provisioning profile (and, for TestFlight, a crash-report flag)
PROFILE_KEYS="com.apple.application-identifier com.apple.developer.team-identifier beta-reports-active"

check_app_bundle() {
    local app="$1" where="$2" tool
    check_entitlements "$app" "${where} ${APP_NAME}.app" "$APP_KEYS" "$PROFILE_KEYS"
    for tool in ffmpeg ffprobe; do
        [ -f "$app/Contents/MacOS/$tool" ] || die "${where}: $app/Contents/MacOS/$tool is missing"
        check_entitlements "$app/Contents/MacOS/$tool" "${where} Contents/MacOS/$tool" "$TOOL_KEYS" ""
    done
}

# ── archive ──────────────────────────────────────────────────────────────────
xcodebuild \
    -project "star.xcodeproj" \
    -scheme "Star Release" \
    -configuration "Release" \
    -xcconfig appstore.xcconfig \
    -archivePath "${BUILD_DIR}/star.xcarchive" \
    "MARKETING_VERSION=${STAR_VERSION}" \
    "CURRENT_PROJECT_VERSION=${BUILD_NUMBER}" \
    "${XCODEBUILD_SIGNING_ARGS[@]}" \
    "${XCODEBUILD_AUTH_ARGS[@]}" \
    "${ALLOW_PROVISIONING[@]}" \
    archive

APP="${BUILD_DIR}/star.xcarchive/Products/Applications/${APP_NAME}.app"
[ -d "$APP" ] || die "the archive has no ${APP}"
PLIST="$APP/Contents/Info.plist"

# ── Info.plist ───────────────────────────────────────────────────────────────
# appstore.xcconfig asks for these; make sure they landed, and set them here if Xcode left them out.
plist_set() { # key type value
    local current
    current="$(/usr/libexec/PlistBuddy -c "Print :$1" "$PLIST" 2>/dev/null || true)"
    [ "$current" = "$3" ] && return 0
    echo "Info.plist: $1 was '${current}', setting '$3'"
    /usr/libexec/PlistBuddy -c "Delete :$1" "$PLIST" 2>/dev/null || true
    /usr/libexec/PlistBuddy -c "Add :$1 $2 $3" "$PLIST"
}
plist_set LSApplicationCategoryType string public.app-category.photography
plist_set ITSAppUsesNonExemptEncryption bool false
plist_set CFBundleShortVersionString string "$STAR_VERSION"
plist_set CFBundleVersion string "$BUILD_NUMBER"
# The project's own id is com.star. Another one for the store is set here, after the archive, and not as a
# PRODUCT_BUNDLE_IDENTIFIER on the xcodebuild command line, which would reach every target and give the Swift
# package resource bundle inside the app the app's id too. xcodebuild -exportArchive reads it from the archive's own
# Info.plist as well.
plist_set CFBundleIdentifier string "$BUNDLE_ID"
ARCHIVE_PLIST="${BUILD_DIR}/star.xcarchive/Info.plist"
[ "$(/usr/libexec/PlistBuddy -c "Print :ApplicationProperties:CFBundleIdentifier" "$ARCHIVE_PLIST")" = "$BUNDLE_ID" ] ||
    /usr/libexec/PlistBuddy -c "Set :ApplicationProperties:CFBundleIdentifier $BUNDLE_ID" "$ARCHIVE_PLIST"
plutil -p "$PLIST" | grep -E 'CFBundle(Short)?Version|CFBundleIdentifier|LSApplicationCategoryType|ITSAppUses'

# Another bundle inside the app with the app's own id is a validation error in App Store Connect.
while IFS= read -r nested; do
    id="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$nested" 2>/dev/null || true)"
    [ "$id" != "$BUNDLE_ID" ] || die "$nested has the same bundle id as the app (${BUNDLE_ID})"
done < <(find "$APP/Contents" -name Info.plist \( -path "*.bundle/*" -o -path "*.framework/*" \))

# ── re-sign ffmpeg and ffprobe, then the app ─────────────────────────────────
# The project copies them with CodeSignOnCopy, which signs them with no entitlements, and a sandboxed app cannot run
# a child that is not sandboxed. Xcode has no per-file entitlements for that, so they are signed again here with
# exactly app-sandbox + inherit (not ffmpeg.entitlements.plist, which App Review rejects), then the app, whose seal
# covers them, with star/star-appstore.entitlements (the project itself builds with the empty star.entitlements, and an
# entitlements build setting would reach the Swift package targets) and the flags Xcode gave it.
IDENTITY="$(codesign -d --verbose=2 "$APP" 2>&1 | sed -n 's/^Authority=//p' | head -1)"
[ -n "$IDENTITY" ] || die "cannot tell which identity signed ${APP}"
echo "re-signing ffmpeg and ffprobe with ${TOOL_ENTITLEMENTS} as ${IDENTITY}"
for tool in ffmpeg ffprobe; do
    codesign --force --timestamp --sign "$IDENTITY" --entitlements "$TOOL_ENTITLEMENTS" "$APP/Contents/MacOS/$tool"
done
codesign --force --timestamp --sign "$IDENTITY" --entitlements "$APP_ENTITLEMENTS" --preserve-metadata=requirements,flags,runtime "$APP"
codesign --verify --deep --strict "$APP"

check_app_bundle "$APP" "archive"
# universal: the app and both tools carry both slices (preflight_archs, not `lipo -archs`: see preflight.sh)
for bin in "$APP/Contents/MacOS/${APP_NAME}" "$APP/Contents/MacOS/ffmpeg" "$APP/Contents/MacOS/ffprobe"; do
    archs="$(preflight_archs "$bin")"
    echo "$bin: $archs"
    for arch in arm64 x86_64; do
        case " $archs " in *" $arch "*) ;; *) die "$bin has no $arch slice ($archs)" ;; esac
    done
done

if [ "$MODE" = archive ]; then
    echo "archive in ${BUILD_DIR}/star.xcarchive, entitlements as wanted (--archive-only: not exported)"
    exit 0
fi

# ── export ───────────────────────────────────────────────────────────────────
# A method=app-store-connect export signs the app and the installer pkg for the store.
# Under manual signing the profile is named for the bundle id; the identities are named explicitly, and are ignored
# under automatic signing.
write_export_options() { # destination
    cat > "${BUILD_DIR}/ExportOptions-$1.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>method</key>
    <string>app-store-connect</string>
    <key>destination</key>
    <string>$1</string>
    <key>signingStyle</key>
    <string>${SIGNING}</string>
    <key>signingCertificate</key>
    <string>${SIGN_APP_NAME}</string>
    <key>installerSigningCertificate</key>
    <string>${SIGN_PKG_NAME}</string>
    <key>teamID</key>
    <string>${APPSTORE_TEAM_ID}</string>
    ${EXPORT_PROFILES}
    <key>uploadSymbols</key>
    <true/>
    <key>manageAppVersionAndBuildNumber</key>
    <false/>
</dict>
</plist>
EOF
}

# Always export to a local pkg first and look inside it: a destination=upload export leaves nothing to look at, and
# Xcode's export re-signs the app, which could have dropped what was just put on ffmpeg and ffprobe.
write_export_options export
echo "exporting archive"
xcodebuild \
    -exportArchive \
    -archivePath "${BUILD_DIR}/star.xcarchive" \
    -exportOptionsPlist "${BUILD_DIR}/ExportOptions-export.plist" \
    -exportPath "${BUILD_DIR}/export" \
    "${XCODEBUILD_AUTH_ARGS[@]}" \
    "${ALLOW_PROVISIONING[@]}"

PKG="${BUILD_DIR}/export/${APP_NAME}.pkg"
[ -f "$PKG" ] || die "the export produced no ${PKG}"
rm -rf "${BUILD_DIR}/expanded"
pkgutil --expand-full "$PKG" "${BUILD_DIR}/expanded"
EXPORTED_APP="$(find "${BUILD_DIR}/expanded" -name "${APP_NAME}.app" -maxdepth 4 | head -1)"
[ -n "$EXPORTED_APP" ] || die "no ${APP_NAME}.app in ${PKG}"
check_app_bundle "$EXPORTED_APP" "exported"
rm -rf "${BUILD_DIR}/expanded"

# altool finds the key as AuthKey_<id>.p8 in this directory.
ALTOOL_AUTH=()
if [ -n "$APPLE_API_KEY_PATH" ]; then
    API_PRIVATE_KEYS_DIR="$(cd "$(dirname "$APPLE_API_KEY_PATH")" && pwd)"
    export API_PRIVATE_KEYS_DIR
    ALTOOL_AUTH=(--apiKey "$APPLE_API_KEY_ID" --apiIssuer "$APPLE_API_ISSUER_ID")
fi

if [ "$MODE" = export ]; then
    if [ -n "$APPLE_API_KEY_PATH" ]; then
        xcrun altool --validate-app -f "$PKG" -t macos "${ALTOOL_AUTH[@]}"
    else
        echo "validation skipped: altool needs an API key (APPLE_API_KEY_PATH, APPLE_API_KEY_ID, APPLE_API_ISSUER_ID)"
    fi
    echo "exported ${PKG} (--export-only: not uploaded)"
    exit 0
fi

# ── upload ───────────────────────────────────────────────────────────────────
write_export_options upload
echo "uploading ${STAR_VERSION} (${BUILD_NUMBER}) to App Store Connect"
xcodebuild \
    -exportArchive \
    -archivePath "${BUILD_DIR}/star.xcarchive" \
    -exportOptionsPlist "${BUILD_DIR}/ExportOptions-upload.plist" \
    -exportPath "${BUILD_DIR}/upload" \
    "${XCODEBUILD_AUTH_ARGS[@]}" \
    "${ALLOW_PROVISIONING[@]}"

echo "uploaded ${STAR_VERSION} (${BUILD_NUMBER}); it shows in App Store Connect -> TestFlight once processing is done"
