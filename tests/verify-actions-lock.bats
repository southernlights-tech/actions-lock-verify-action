#!/usr/bin/env bats

# Behavioral tests for scripts/verify-actions-lock.sh.
# Stubs `gh` on a temp PATH so no API calls are made.

SCRIPT="scripts/verify-actions-lock.sh"

setup() {
    FAKE_BIN="$(mktemp -d)"
    export PATH="$FAKE_BIN:$PATH"
    export ARGS_FILE="$FAKE_BIN/args"
    : > "$ARGS_FILE"
    cat > "$FAKE_BIN/gh" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$ARGS_FILE"
if [ "${1:-}" = "extension" ] && [ "${STUB_EXTENSION_FAIL:-0}" = "1" ]; then
    echo "boom" >&2
    exit 1
fi
exit 0
STUB
    chmod +x "$FAKE_BIN/gh"
}

teardown() {
    rm -rf "${FAKE_BIN:-}"
}

@test "installs the pinned extension then verifies the given paths" {
    export WORKFLOWS=".github/workflows/a.yml .github/workflows/b.yml"
    run bash "$SCRIPT"
    [ "$status" -eq 0 ]
    run grep -F "extension install github/gh-actions-lock --pin v0.2.0" "$ARGS_FILE"
    [ "$status" -eq 0 ]
    run grep -F "actions-lock --verify .github/workflows/a.yml .github/workflows/b.yml" "$ARGS_FILE"
    [ "$status" -eq 0 ]
}

@test "respects EXTENSION_PIN" {
    export WORKFLOWS=".github/workflows/a.yml"
    export EXTENSION_PIN="v0.3.0"
    run bash "$SCRIPT"
    [ "$status" -eq 0 ]
    run grep -F -- "--pin v0.3.0" "$ARGS_FILE"
    [ "$status" -eq 0 ]
}

@test "fails when WORKFLOWS is unset" {
    run bash "$SCRIPT"
    [ "$status" -ne 0 ]
}

@test "fails when the extension install fails" {
    export WORKFLOWS=".github/workflows/a.yml"
    export STUB_EXTENSION_FAIL="1"
    run bash "$SCRIPT"
    [ "$status" -ne 0 ]
}
