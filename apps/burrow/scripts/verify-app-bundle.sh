#!/usr/bin/env bash
set -euo pipefail

if (( $# > 1 )); then
    echo "usage: $0 [APP_BUNDLE]" >&2
    exit 2
fi

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
project_dir="$(cd "$script_dir/.." && pwd)"
source "$project_dir/ThirdParty/Mole/VERSION.env"

app_bundle="${1:-$project_dir/dist/Burrow.app}"
if [[ "$app_bundle" != /* ]]; then
    app_bundle="$(pwd)/$app_bundle"
fi

for path in \
    "$app_bundle/Contents/Info.plist" \
    "$app_bundle/Contents/MacOS/Burrow" \
    "$app_bundle/Contents/Resources/THIRD_PARTY_NOTICES.md"; do
    [[ -f "$path" ]] || { echo "Missing bundle file: $path" >&2; exit 1; }
done

verify_mode() {
    local expected="$1" path="$2" actual
    actual="$(stat -f '%Lp' "$path")"
    [[ "$actual" == "$expected" ]] || {
        echo "Unexpected mode for $path: expected $expected, got $actual" >&2
        exit 1
    }
}

verify_signature() {
    local path="$1" signature_details
    codesign --verify --strict --verbose=2 "$path"
    signature_details="$(codesign -d --verbose=4 "$path" 2>&1)"
    if [[ -n "${BURROW_TEAM_ID:-}" ]]; then
        grep -Fqx "TeamIdentifier=$BURROW_TEAM_ID" <<< "$signature_details" || {
            echo "Unexpected or missing Team ID for $path" >&2
            exit 1
        }
    fi
    if [[ "${BURROW_REQUIRE_RUNTIME:-0}" == "1" ]]; then
        grep -Eq '^CodeDirectory .*flags=.*\(.*runtime.*\)' <<< "$signature_details" || {
            echo "Hardened runtime is not enabled for $path" >&2
            exit 1
        }
    fi
}

verify_mode 755 "$app_bundle/Contents/MacOS/Burrow"
verify_signature "$app_bundle/Contents/MacOS/Burrow"

if [[ -e "$app_bundle/Contents/MacOS/mo" ]]; then
    verify_mode 755 "$app_bundle/Contents/MacOS/mo"
    verify_signature "$app_bundle/Contents/MacOS/mo"
    third_party="$app_bundle/Contents/Resources/ThirdParty/Mole"
    "$script_dir/verify-mole-engine.sh" "$third_party" --signed
    verify_signature "$third_party/engine/bin/analyze-go"
    verify_signature "$third_party/engine/bin/status-go"
    [[ -f "$third_party/engine/LICENSE" ]] || {
        echo "Mole GPL license is absent from the app bundle" >&2
        exit 1
    }
    [[ -f "$third_party/corresponding-source/Mole-$MOLE_REVISION.tar.gz" ]] || {
        echo "Mole corresponding source is absent from the app bundle" >&2
        exit 1
    }
fi

verify_signature "$app_bundle"

if [[ "${BURROW_REQUIRE_NOTARIZATION:-0}" == "1" ]]; then
    xcrun stapler validate "$app_bundle"
    spctl --assess --type execute --verbose=2 "$app_bundle"
fi

if [[ -e "$app_bundle/Contents/MacOS/mo" ]]; then
    echo "Verified signed Burrow bundle with Mole $MOLE_VERSION"
else
    echo "Verified signed Burrow bundle without an embedded Mole engine"
fi
