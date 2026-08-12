#!/usr/bin/env bash
set -euo pipefail

repository_root="$(cd "$(dirname "$0")/.." && pwd)"

run_package_tests() {
    local package="$1"
    local package_path="$repository_root/Packages/$package"
    local log
    log="$(mktemp -t "burrow-${package}-test.XXXXXX")"
    if swift test --package-path "$package_path" 2>&1 | tee "$log"; then
        rm -f "$log"
        return 0
    fi
    local status="${PIPESTATUS[0]}"
    if rg -q 'unexpected signal code 4' "$log"; then
        echo "==> stale SwiftPM ABI cache detected for $package; clean rebuild once"
        swift package --package-path "$package_path" clean
        rm -f "$log"
        swift test --package-path "$package_path"
        return
    fi
    rm -f "$log"
    return "$status"
}

echo "==> swift build"
swift build --package-path "$repository_root"

for package in \
    Domain Protocol StateStore Host LocalTransport ClientCore Transport \
    TerminalRenderer TmuxRuntime Application DesignSystem Desktop \
    GhosttyAdapter SwiftTermAdapter Observation Mobile \
    SwiftTermMobileAdapter WebRelay; do
    echo "==> swift test $package"
    run_package_tests "$package"
done

echo "==> tmux integration test"
swift test --package-path "$repository_root" --filter ApplicationIntegrationTests

echo "==> process lifecycle contracts"
BURROW_APP_EXECUTABLE="$repository_root/.build/debug/BurrowNext" \
    swift test --package-path "$repository_root" --filter BurrowProcessTests

echo "==> non-visual semantic UI acceptance"
BURROW_ARTIFACT_DIR="${BURROW_ARTIFACT_DIR:-/tmp/burrow-observation/ui-probe}" \
    swift run --package-path "$repository_root" UIProbe

echo "==> headless terminal color semantics"
BURROW_ARTIFACT_DIR="${BURROW_TERMINAL_ARTIFACT_DIR:-/tmp/burrow-observation/terminal-probe}" \
    swift run --package-path "$repository_root" TerminalProbe

echo "==> build app"
bash "$repository_root/scripts/build-app.sh" debug

echo "All checks passed."
