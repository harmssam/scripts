#!/usr/bin/env bash
set -euo pipefail

if (( $# > 1 )); then
    echo "usage: $0 [OUTPUT_DIRECTORY]" >&2
    exit 2
fi

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
project_dir="$(cd "$script_dir/.." && pwd)"
# shellcheck source=../ThirdParty/Mole/VERSION.env
source "$project_dir/ThirdParty/Mole/VERSION.env"

case "${1:-}" in
    "") output_dir="$project_dir/.artifacts/mole/$MOLE_TAG/$(uname -m)" ;;
    -h|--help)
        echo "usage: $0 [OUTPUT_DIRECTORY]"
        exit 0
        ;;
    *) output_dir="$1" ;;
esac

case "$(uname -m)" in
    arm64)
        release_arch="arm64"
        binary_sha256="$MOLE_BINARIES_ARM64_SHA256"
        analyze_sha256="$MOLE_ANALYZE_ARM64_SHA256"
        status_sha256="$MOLE_STATUS_ARM64_SHA256"
        ;;
    x86_64)
        release_arch="amd64"
        binary_sha256="$MOLE_BINARIES_AMD64_SHA256"
        analyze_sha256="$MOLE_ANALYZE_AMD64_SHA256"
        status_sha256="$MOLE_STATUS_AMD64_SHA256"
        ;;
    *)
        echo "Unsupported build architecture: $(uname -m)" >&2
        exit 2
        ;;
esac

if [[ "$output_dir" != /* ]]; then
    output_dir="$(pwd)/$output_dir"
fi
if [[ -e "$output_dir" ]]; then
    echo "Refusing to overwrite existing engine directory: $output_dir" >&2
    exit 2
fi

parent_dir="$(dirname "$output_dir")"
mkdir -p "$parent_dir"
work_dir="$(mktemp -d "${TMPDIR:-/tmp}/burrow-mole.XXXXXX")"
cleanup() {
    local temp_root="${TMPDIR:-/tmp}"
    case "$work_dir" in
        "$temp_root"/burrow-mole.*) rm -rf -- "$work_dir" ;; # SAFE: exact mktemp directory above
        *) echo "Refusing to clean unexpected temporary path: $work_dir" >&2 ;;
    esac
}
trap cleanup EXIT
source_archive="$work_dir/mole-source.tar.gz"
binary_archive="$work_dir/mole-binaries.tar.gz"
release_sums="$work_dir/SHA256SUMS"
expanded_source="$work_dir/source"
staged_dir="$work_dir/staged"

source_url="https://github.com/tw93/Mole/archive/$MOLE_REVISION.tar.gz"
release_url="https://github.com/tw93/Mole/releases/download/$MOLE_TAG"

curl --fail --location --silent --show-error --retry 4 --retry-delay 2 \
    --retry-all-errors --proto '=https' --tlsv1.2 \
    --output "$source_archive" "$source_url"
curl --fail --location --silent --show-error --retry 4 --retry-delay 2 \
    --retry-all-errors --proto '=https' --tlsv1.2 \
    --output "$release_sums" "$release_url/SHA256SUMS"
curl --fail --location --silent --show-error --retry 4 --retry-delay 2 \
    --retry-all-errors --proto '=https' --tlsv1.2 \
    --output "$binary_archive" "$release_url/binaries-darwin-$release_arch.tar.gz"

verify_digest() {
    local expected="$1"
    local path="$2"
    local actual
    actual="$(shasum -a 256 "$path" | awk '{print $1}')"
    if [[ "$actual" != "$expected" ]]; then
        echo "Checksum mismatch for $path" >&2
        echo "expected $expected" >&2
        echo "actual   $actual" >&2
        exit 1
    fi
}

verify_digest "$MOLE_SOURCE_SHA256" "$source_archive"
verify_digest "$MOLE_RELEASE_SUMS_SHA256" "$release_sums"
verify_digest "$binary_sha256" "$binary_archive"

archive_name="binaries-darwin-$release_arch.tar.gz"
published_digest="$(awk -v name="$archive_name" '$2 == name {print $1}' "$release_sums")"
if [[ "$published_digest" != "$binary_sha256" ]]; then
    echo "Pinned digest does not match upstream SHA256SUMS for $archive_name" >&2
    exit 1
fi

mkdir -p "$expanded_source" "$staged_dir/engine/bin" "$staged_dir/corresponding-source"
tar -xzf "$source_archive" -C "$expanded_source" --strip-components=1
tar -xzf "$binary_archive" -C "$work_dir"
verify_digest "$analyze_sha256" "$work_dir/analyze-darwin-$release_arch"
verify_digest "$status_sha256" "$work_dir/status-darwin-$release_arch"

cp -R "$expanded_source/." "$staged_dir/engine/"
cp "$work_dir/analyze-darwin-$release_arch" "$staged_dir/engine/bin/analyze-go"
cp "$work_dir/status-darwin-$release_arch" "$staged_dir/engine/bin/status-go"
chmod 755 "$staged_dir/engine/mo" "$staged_dir/engine/mole"
chmod 755 "$staged_dir/engine/bin/analyze-go" "$staged_dir/engine/bin/status-go"
cp "$source_archive" "$staged_dir/corresponding-source/Mole-$MOLE_REVISION.tar.gz"
cp "$release_sums" "$staged_dir/corresponding-source/SHA256SUMS"
cp "$project_dir/ThirdParty/Mole/VERSION.env" "$staged_dir/VERSION.env"

(
    cd "$staged_dir/engine"
    find . -type f -print | LC_ALL=C sort | while IFS= read -r path; do
        shasum -a 256 "$path"
    done
) > "$staged_dir/ENGINE_SHA256SUMS"

{
    echo "component=Mole"
    echo "version=$MOLE_VERSION"
    echo "tag=$MOLE_TAG"
    echo "revision=$MOLE_REVISION"
    echo "architecture=$(uname -m)"
    echo "helper_origin=official-release-artifacts"
    echo "source_url=$source_url"
    echo "binary_url=$release_url/$archive_name"
    echo "source_sha256=$MOLE_SOURCE_SHA256"
    echo "binary_sha256=$binary_sha256"
    echo "analyze_sha256=$analyze_sha256"
    echo "status_sha256=$status_sha256"
} > "$staged_dir/PROVENANCE.txt"

mv "$staged_dir" "$output_dir"
echo "Prepared verified Mole engine at $output_dir"
