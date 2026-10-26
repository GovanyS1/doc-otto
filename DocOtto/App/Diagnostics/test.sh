#!/usr/bin/env bash
set -euo pipefail
cd -- "$(dirname -- "${BASH_SOURCE[0]}")"

if command -v swift >/dev/null 2>&1; then
    exec swift test
fi

if command -v docker >/dev/null 2>&1 &&
   docker image inspect swift:6.0.3-jammy >/dev/null 2>&1; then
    exec docker run --rm --network none \
        --user "$(id -u):$(id -g)" -e HOME=/tmp \
        -v "$PWD:/package" -w /package \
        swift:6.0.3-jammy swift test
fi

printf '%s\n' 'Install Swift, or explicitly pull swift:6.0.3-jammy with Docker, then rerun this script.' >&2
exit 1
