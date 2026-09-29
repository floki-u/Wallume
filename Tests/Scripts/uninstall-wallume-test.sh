#!/bin/bash
set -euo pipefail

REPOSITORY_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/wallume-uninstall-test.XXXXXX")"
trap 'rm -rf "$TEST_ROOT"' EXIT

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

make_command_mocks() {
    local bin_directory="$1"
    mkdir -p "$bin_directory"

    for command_name in osascript pluginkit sleep xattr; do
        cat > "$bin_directory/$command_name" <<'EOF'
#!/bin/bash
exit 0
EOF
        chmod +x "$bin_directory/$command_name"
    done
}

make_cleanup_tool() {
    local tool_path="$1"
    local label="$2"
    mkdir -p "$(dirname "$tool_path")"
    cat > "$tool_path" <<EOF
#!/bin/bash
printf '%s %s\n' '$label' "\$1" >> "\$WALLUME_TEST_LOG"
EOF
    chmod +x "$tool_path"
}

run_uninstaller() {
    local package_directory="$1"
    local target_app="$2"
    local log_path="$3"
    local mock_bin="$4"

    WALLUME_TEST_LOG="$log_path" \
        PATH="$mock_bin:/usr/bin:/bin:/usr/sbin:/sbin" \
        bash -c "printf 'y\\n' | \"$package_directory/uninstall-wallume.sh\" \"$target_app\""
}

test_uses_target_app_helper_when_package_app_was_moved() {
    local case_root="$TEST_ROOT/target fallback"
    local package_directory="$case_root/Wallume-1.2.9"
    local target_app="$case_root/Applications Folder/Wallume.app"
    local log_path="$case_root/calls.log"
    local mock_bin="$case_root/bin"

    mkdir -p "$package_directory"
    cp "$REPOSITORY_ROOT/uninstall-wallume.sh" "$package_directory/uninstall-wallume.sh"
    chmod +x "$package_directory/uninstall-wallume.sh"
    make_cleanup_tool "$target_app/Contents/Resources/wallume-provider-cleanup" target
    make_command_mocks "$mock_bin"

    run_uninstaller "$package_directory" "$target_app" "$log_path" "$mock_bin"

    grep -Fx 'target confirm-system-reset' "$log_path" >/dev/null || fail "target helper did not confirm reset"
    grep -Fx 'target cleanup' "$log_path" >/dev/null || fail "target helper did not clean up"
}

test_prefers_standalone_package_helper() {
    local case_root="$TEST_ROOT/standalone helper"
    local package_directory="$case_root/Wallume Package"
    local target_app="$case_root/Applications/Wallume.app"
    local log_path="$case_root/calls.log"
    local mock_bin="$case_root/bin"

    mkdir -p "$package_directory"
    cp "$REPOSITORY_ROOT/uninstall-wallume.sh" "$package_directory/uninstall-wallume.sh"
    chmod +x "$package_directory/uninstall-wallume.sh"
    make_cleanup_tool "$package_directory/wallume-provider-cleanup" package
    make_cleanup_tool "$target_app/Contents/Resources/wallume-provider-cleanup" target
    make_command_mocks "$mock_bin"

    run_uninstaller "$package_directory" "$target_app" "$log_path" "$mock_bin"

    grep -Fx 'package confirm-system-reset' "$log_path" >/dev/null || fail "standalone package helper was not preferred"
    if grep -F 'target ' "$log_path" >/dev/null; then
        fail "target helper ran even though the standalone package helper exists"
    fi
}

test_release_package_contains_standalone_helper() {
    local case_root="$TEST_ROOT/release-package"
    local project_directory="$case_root/project"
    local build_directory="$case_root/build"
    local fake_bin="$case_root/bin"
    local version="9.9.9"
    local info_plist="$build_directory/Wallume.app/Contents/Info.plist"
    local output_zip="$project_directory/.artifacts/Wallume-$version.zip"

    mkdir -p "$project_directory" "$build_directory/Wallume.app/Contents/Resources" "$fake_bin"
    cp "$REPOSITORY_ROOT/package-experimental.sh" "$project_directory/package-experimental.sh"
    cp "$REPOSITORY_ROOT/uninstall-wallume.sh" "$build_directory/uninstall-wallume.sh"
    chmod +x "$project_directory/package-experimental.sh" "$build_directory/uninstall-wallume.sh"
    make_cleanup_tool "$build_directory/Wallume.app/Contents/Resources/wallume-provider-cleanup" package
    plutil -create xml1 "$info_plist"
    plutil -insert CFBundleShortVersionString -string "$version" "$info_plist"

    cat > "$fake_bin/swift" <<'EOF'
#!/bin/bash
printf '%s\n' "$WALLUME_FAKE_BUILD_DIRECTORY"
EOF
    chmod +x "$fake_bin/swift"

    (
        cd "$project_directory"
        WALLUME_FAKE_BUILD_DIRECTORY="$build_directory" \
            PATH="$fake_bin:/usr/bin:/bin:/usr/sbin:/sbin" \
            ./package-experimental.sh "$version" >/dev/null
    )

    unzip -Z1 "$output_zip" | grep -Fx "Wallume-$version/wallume-provider-cleanup" >/dev/null \
        || fail "release ZIP does not contain the standalone cleanup helper"
}

test_uses_target_app_helper_when_package_app_was_moved
test_prefers_standalone_package_helper
test_release_package_contains_standalone_helper
echo "PASS: uninstall-wallume helper selection"
