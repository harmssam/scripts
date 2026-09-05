#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "$0")" && pwd)"
app_name="Burrow"
app_bundle="$root/dist/$app_name.app"
engine_dir=""
atomic_replace_tool="$root/.build/burrow-atomic-replace"

usage() { echo "usage: $0 [--with-engine | --engine-dir PATH]" >&2; }

case "${1:-}" in
    "") (( $# == 0 )) || { usage; exit 2; } ;;
    --with-engine)
        (( $# == 1 )) || { usage; exit 2; }
        source "$root/ThirdParty/Mole/VERSION.env"
        engine_dir="$root/.artifacts/mole/$MOLE_TAG/$(uname -m)"
        if [[ ! -d "$engine_dir" ]]; then
            "$root/scripts/fetch-mole-engine.sh" "$engine_dir"
        fi
        "$root/scripts/verify-mole-engine.sh" "$engine_dir"
        ;;
    --engine-dir)
        (( $# == 2 )) || { usage; exit 2; }
        engine_dir="$2"
        "$root/scripts/verify-mole-engine.sh" "$engine_dir"
        ;;
    -h|--help)
        (( $# == 1 )) || { usage; exit 2; }
        usage
        exit 0
        ;;
    *) usage; exit 2 ;;
esac

cd "$root"
swift build -c release
build_dir="$(swift build -c release --show-bin-path)"

mkdir -p "$root/dist"
xcrun clang -Os -mmacosx-version-min=14.0 \
    "$root/Sources/BuildTools/atomic-replace.c" \
    -o "$atomic_replace_tool"
staging_bundle="$(mktemp -d "$root/dist/.$app_name.app.staging.XXXXXX")"
cleanup() {
    case "$staging_bundle" in
        "$root/dist/.$app_name.app.staging."*) rm -rf -- "$staging_bundle" ;;
        *) echo "Refusing to clean unexpected staging path: $staging_bundle" >&2 ;;
    esac
}
trap cleanup EXIT

mkdir -p "$staging_bundle/Contents/MacOS" "$staging_bundle/Contents/Resources"
cp "$root/Sources/Burrow/Info.plist" "$staging_bundle/Contents/Info.plist"
cp "$build_dir/$app_name" "$staging_bundle/Contents/MacOS/$app_name"
cp "$root/Assets/AppIcon.icns" "$staging_bundle/Contents/Resources/AppIcon.icns"
resource_bundle="$build_dir/${app_name}_${app_name}.bundle"
[[ -d "$resource_bundle" ]] || {
    echo "Missing SwiftPM resource bundle: $resource_bundle" >&2
    exit 1
}
cp -R "$resource_bundle" "$staging_bundle/Contents/Resources/${app_name}_${app_name}.bundle"
cp "$root/THIRD_PARTY_NOTICES.md" "$staging_bundle/Contents/Resources/THIRD_PARTY_NOTICES.md"
chmod 755 "$staging_bundle/Contents/MacOS/$app_name"

if [[ -n "$engine_dir" ]]; then
    mkdir -p "$staging_bundle/Contents/Resources/ThirdParty"
    cp -R "$engine_dir" "$staging_bundle/Contents/Resources/ThirdParty/Mole"
    xcrun clang -Os -mmacosx-version-min=14.0 \
        "$root/Sources/MoleLauncher/main.c" \
        -o "$staging_bundle/Contents/MacOS/mo"
    chmod 755 "$staging_bundle/Contents/MacOS/mo"
    # Verify upstream bytes before signing changes the Mach-O helper hashes.
    "$root/scripts/verify-mole-engine.sh" "$staging_bundle/Contents/Resources/ThirdParty/Mole"
fi

sign_identity="${BURROW_CODE_SIGN_IDENTITY:--}"
if [[ "$sign_identity" == "-" ]]; then
    sign_args=(--force --sign -)
    echo "Signing development bundle ad hoc"
else
    [[ -n "${BURROW_TEAM_ID:-}" ]] || {
        echo "BURROW_TEAM_ID is required for Developer ID signing" >&2
        exit 2
    }
    sign_args=(--force --sign "$sign_identity" --options runtime --timestamp)
    echo "Signing release bundle with Developer ID identity: $sign_identity"
fi

# Sign executable code from the innermost components outward. Deliberately do
# not use --deep for signing: every nested code object remains explicit.
if [[ -n "$engine_dir" ]]; then
    codesign "${sign_args[@]}" "$staging_bundle/Contents/Resources/ThirdParty/Mole/engine/bin/analyze-go"
    codesign "${sign_args[@]}" "$staging_bundle/Contents/Resources/ThirdParty/Mole/engine/bin/status-go"
    codesign "${sign_args[@]}" "$staging_bundle/Contents/MacOS/mo"
fi
codesign "${sign_args[@]}" "$staging_bundle/Contents/MacOS/$app_name"
codesign "${sign_args[@]}" "$staging_bundle"

require_runtime=0
if [[ "$sign_identity" != "-" ]]; then
    require_runtime=1
fi
env BURROW_REQUIRE_RUNTIME="$require_runtime" \
    BURROW_TEAM_ID="${BURROW_TEAM_ID:-}" \
    "$root/scripts/verify-app-bundle.sh" "$staging_bundle"

# renameatx_np(RENAME_SWAP) makes replacement of an existing bundle one atomic
# filesystem operation. The old bundle lands at the staging path for cleanup.
"$atomic_replace_tool" "$staging_bundle" "$app_bundle"

echo "Built and verified $app_bundle"
