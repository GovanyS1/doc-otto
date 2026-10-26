#!/usr/bin/env bash
set -euo pipefail
cd -- "$(dirname -- "${BASH_SOURCE[0]}")"
android_jar="${DOC_OTTO_ANDROID_JAR:-}"
if [[ -z "$android_jar" && -n "${ANDROID_HOME:-}" && -f "$ANDROID_HOME/platforms/android-35/android.jar" ]]; then
    android_jar="$ANDROID_HOME/platforms/android-35/android.jar"
fi
if [[ -z "$android_jar" && -n "${ANDROID_SDK_ROOT:-}" && -f "$ANDROID_SDK_ROOT/platforms/android-35/android.jar" ]]; then
    android_jar="$ANDROID_SDK_ROOT/platforms/android-35/android.jar"
fi
if [[ -z "$android_jar" && -f "../../../.ai/out/android-api35.jar" ]]; then
    android_jar="$PWD/../../../.ai/out/android-api35.jar"
fi
if [[ -n "$android_jar" ]]; then
    if [[ ! -f "$android_jar" ]]; then
        printf "%s\n" "The supplied Android API jar does not exist." >&2
        exit 1
    fi
    android_jar="$(cd -- "$(dirname -- "$android_jar")" && pwd)/$(basename -- "$android_jar")"
fi

if command -v javac >/dev/null 2>&1 && command -v java >/dev/null 2>&1; then
    export DOC_OTTO_ANDROID_JAR="$android_jar"
    exec bash scripts/run-tests.sh
fi

if command -v docker >/dev/null 2>&1 &&
   docker image inspect eclipse-temurin:17-jdk-jammy >/dev/null 2>&1; then
    args=(run --rm --network none --user "$(id -u):$(id -g)" -v "$PWD:/package" -w /package)
    if [[ -n "$android_jar" ]]; then
        args+=(-v "$android_jar:/android.jar:ro" -e DOC_OTTO_ANDROID_JAR=/android.jar)
    fi
    exec docker "${args[@]}" eclipse-temurin:17-jdk-jammy bash scripts/run-tests.sh
fi

printf "%s\n" "Install JDK 17, or explicitly pull eclipse-temurin:17-jdk-jammy with Docker, then rerun." >&2
exit 1
