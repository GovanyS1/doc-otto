#!/usr/bin/env bash
set -euo pipefail
cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.."
mkdir -p build
task_dir="$(mktemp -d "$PWD/build/verify.XXXXXX")"
trap 'rm -rf -- "$task_dir"' EXIT
mkdir -p "$task_dir/core" "$task_dir/tests"
find core/src/main/java -name "*.java" -print | sort > "$task_dir/core-sources.txt"
find core/src/test/java -name "*.java" -print | sort > "$task_dir/test-sources.txt"
javac --release 8 -Xlint:all -Werror -d "$task_dir/core" @"$task_dir/core-sources.txt"
javac --release 8 -Xlint:all -Werror -cp "$task_dir/core" -d "$task_dir/tests" @"$task_dir/test-sources.txt"
java -cp "$task_dir/core:$task_dir/tests" com.docotto.diagnostics.DiagnosticsTests

if [[ -n "${DOC_OTTO_ANDROID_JAR:-}" ]]; then
    test -f "$DOC_OTTO_ANDROID_JAR"
    mkdir -p "$task_dir/ble"
    find ble/src/main/java -name "*.java" -print | sort > "$task_dir/ble-sources.txt"
    javac --release 8 -Xlint:all -Werror -cp "$task_dir/core:$DOC_OTTO_ANDROID_JAR" \
        -d "$task_dir/ble" @"$task_dir/ble-sources.txt"
    printf "%s\n" "Android BLE source compiled against the supplied Android API jar."
else
    printf "%s\n" "Android BLE SDK compile skipped: supply DOC_OTTO_ANDROID_JAR to enable it."
fi
