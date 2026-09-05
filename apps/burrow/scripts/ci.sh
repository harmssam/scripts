#!/usr/bin/env bash
set -euo pipefail

if (( $# != 0 )); then
    echo "usage: $0" >&2
    exit 2
fi

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
project_dir="$(cd "$script_dir/.." && pwd)"

cd "$project_dir"
sw_vers
xcodebuild -version
swift --version
swift test
"$project_dir/build-app.sh" --with-engine
"$project_dir/scripts/verify-app-bundle.sh" "$project_dir/dist/Burrow.app"
