#!/usr/bin/env bash
set -euo pipefail

if (( $# > 2 )); then
    echo "usage: $0 [ENGINE_DIRECTORY] [--signed]" >&2
    exit 2
fi

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
project_dir="$(cd "$script_dir/.." && pwd)"
# shellcheck source=../ThirdParty/Mole/VERSION.env
source "$project_dir/ThirdParty/Mole/VERSION.env"

engine_dir="${1:-$project_dir/.artifacts/mole/$MOLE_TAG/$(uname -m)}"
signed_helpers=false
if [[ "${2:-}" == "--signed" ]]; then
    signed_helpers=true
elif [[ -n "${2:-}" ]]; then
    echo "usage: $0 [ENGINE_DIRECTORY] [--signed]" >&2
    exit 2
fi
if [[ "$engine_dir" != /* ]]; then
    engine_dir="$(pwd)/$engine_dir"
fi

require_file() {
    local path="$1"
    if [[ ! -f "$path" ]]; then
        echo "Missing required engine file: $path" >&2
        exit 1
    fi
}

for relative_path in \
    engine/mo \
    engine/mole \
    engine/LICENSE \
    engine/bin/analyze-go \
    engine/bin/status-go \
    corresponding-source/SHA256SUMS \
    corresponding-source/Mole-$MOLE_REVISION.tar.gz \
    ENGINE_SHA256SUMS \
    PROVENANCE.txt \
    VERSION.env; do
    require_file "$engine_dir/$relative_path"
done

actual_source_sha="$(shasum -a 256 "$engine_dir/corresponding-source/Mole-$MOLE_REVISION.tar.gz" | awk '{print $1}')"
[[ "$actual_source_sha" == "$MOLE_SOURCE_SHA256" ]] || {
    echo "Corresponding-source checksum mismatch" >&2
    exit 1
}

actual_release_sums_sha="$(shasum -a 256 "$engine_dir/corresponding-source/SHA256SUMS" | awk '{print $1}')"
[[ "$actual_release_sums_sha" == "$MOLE_RELEASE_SUMS_SHA256" ]] || {
    echo "Upstream SHA256SUMS checksum mismatch" >&2
    exit 1
}

cmp -s "$project_dir/ThirdParty/Mole/VERSION.env" "$engine_dir/VERSION.env" || {
    echo "Staged engine metadata differs from the repository pin" >&2
    exit 1
}

grep -Fqx "revision=$MOLE_REVISION" "$engine_dir/PROVENANCE.txt" || {
    echo "Staged engine provenance has the wrong revision" >&2
    exit 1
}
grep -Fqx "VERSION=\"$MOLE_VERSION\"" "$engine_dir/engine/mole" || {
    echo "Staged Mole entrypoint does not report version $MOLE_VERSION" >&2
    exit 1
}

case "$(uname -m)" in
    arm64)
        expected_binary_sha="$MOLE_BINARIES_ARM64_SHA256"
        expected_analyze_sha="$MOLE_ANALYZE_ARM64_SHA256"
        expected_status_sha="$MOLE_STATUS_ARM64_SHA256"
        ;;
    x86_64)
        expected_binary_sha="$MOLE_BINARIES_AMD64_SHA256"
        expected_analyze_sha="$MOLE_ANALYZE_AMD64_SHA256"
        expected_status_sha="$MOLE_STATUS_AMD64_SHA256"
        ;;
    *) echo "Unsupported verification architecture: $(uname -m)" >&2; exit 2 ;;
esac

actual_archive_sha="$(grep '^binary_sha256=' "$engine_dir/PROVENANCE.txt" | cut -d= -f2)"
[[ "$actual_archive_sha" == "$expected_binary_sha" ]] || {
    echo "Staged helper archive provenance has the wrong checksum" >&2
    exit 1
}

release_arch="arm64"
[[ "$(uname -m)" == "x86_64" ]] && release_arch="amd64"
archive_name="binaries-darwin-$release_arch.tar.gz"
published_digest="$(awk -v name="$archive_name" '$2 == name {print $1}' "$engine_dir/corresponding-source/SHA256SUMS")"
[[ "$published_digest" == "$expected_binary_sha" ]] || {
    echo "Bundled upstream SHA256SUMS does not match the pinned digest for $archive_name" >&2
    exit 1
}

verify_mode() {
    local expected="$1"
    local path="$2"
    local actual
    actual="$(stat -f '%Lp' "$path")"
    [[ "$actual" == "$expected" ]] || {
        echo "Unexpected mode for $path: expected $expected, got $actual" >&2
        exit 1
    }
}

verify_mode 755 "$engine_dir/engine/mo"
verify_mode 755 "$engine_dir/engine/mole"
verify_mode 755 "$engine_dir/engine/bin/analyze-go"
verify_mode 755 "$engine_dir/engine/bin/status-go"

if [[ "$signed_helpers" == false ]]; then
    actual_analyze_sha="$(shasum -a 256 "$engine_dir/engine/bin/analyze-go" | awk '{print $1}')"
    actual_status_sha="$(shasum -a 256 "$engine_dir/engine/bin/status-go" | awk '{print $1}')"
    [[ "$actual_analyze_sha" == "$expected_analyze_sha" ]] || {
        echo "Staged analyze helper checksum mismatch" >&2
        exit 1
    }
    [[ "$actual_status_sha" == "$expected_status_sha" ]] || {
        echo "Staged status helper checksum mismatch" >&2
        exit 1
    }
fi

# Reconstruct the trusted source tree from the repository-pinned source archive.
# This deliberately does not trust ENGINE_SHA256SUMS, which is co-located with
# and could otherwise be changed alongside a compromised staged tree.
work_dir="$(mktemp -d "${TMPDIR:-/tmp}/burrow-verify-mole.XXXXXX")"
cleanup() {
    local temp_root="${TMPDIR:-/tmp}"
    case "$work_dir" in
        "$temp_root"/burrow-verify-mole.*) rm -rf -- "$work_dir" ;;
        *) echo "Refusing to clean unexpected temporary path: $work_dir" >&2 ;;
    esac
}
trap cleanup EXIT
mkdir -p "$work_dir/source"
tar -xzf "$engine_dir/corresponding-source/Mole-$MOLE_REVISION.tar.gz" \
    -C "$work_dir/source" --strip-components=1

source_manifest="$work_dir/source.manifest"
engine_manifest="$work_dir/engine.manifest"
(
    cd "$work_dir/source"
    find . -type f -print | LC_ALL=C sort | while IFS= read -r path; do
        printf '%s  %s  %s\n' "$(shasum -a 256 "$path" | awk '{print $1}')" "$(stat -f '%Lp' "$path")" "$path"
    done
) > "$source_manifest"
(
    cd "$engine_dir/engine"
    find . -type f ! -path './bin/analyze-go' ! -path './bin/status-go' -print | LC_ALL=C sort | while IFS= read -r path; do
        printf '%s  %s  %s\n' "$(shasum -a 256 "$path" | awk '{print $1}')" "$(stat -f '%Lp' "$path")" "$path"
    done
) > "$engine_manifest"
cmp -s "$source_manifest" "$engine_manifest" || {
    echo "Staged Mole source tree differs from the pinned source archive" >&2
    diff -u "$source_manifest" "$engine_manifest" >&2 || true
    exit 1
}

if [[ "$signed_helpers" == true ]]; then
    codesign --verify --strict --verbose=2 "$engine_dir/engine/bin/analyze-go"
    codesign --verify --strict --verbose=2 "$engine_dir/engine/bin/status-go"
else
    (
        cd "$engine_dir/engine"
        shasum -a 256 -c "$engine_dir/ENGINE_SHA256SUMS" >/dev/null
    ) || {
        echo "Staged Mole source tree checksum mismatch" >&2
        exit 1
    }
fi

echo "Verified Mole $MOLE_VERSION engine staging at $engine_dir"
