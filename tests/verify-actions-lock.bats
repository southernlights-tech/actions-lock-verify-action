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
    run grep -F "extension install github/gh-actions-lock --pin v0.4.0" "$ARGS_FILE"
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

@test "does not pass --ignore-local-actions by default" {
    export WORKFLOWS=".github/workflows/a.yml"
    run bash "$SCRIPT"
    [ "$status" -eq 0 ]
    run grep -F -- "--ignore-local-actions" "$ARGS_FILE"
    [ "$status" -ne 0 ]
}

@test "passes --ignore-local-actions when IGNORE_LOCAL_ACTIONS=true" {
    export WORKFLOWS=".github/workflows/a.yml"
    export IGNORE_LOCAL_ACTIONS="true"
    run bash "$SCRIPT"
    [ "$status" -eq 0 ]
    run grep -F -- "actions-lock --verify --ignore-local-actions .github/workflows/a.yml" "$ARGS_FILE"
    [ "$status" -eq 0 ]
}

@test "passes every path when WORKFLOWS contains newlines" {
    # REGRESSION: `read -a <<< "$WORKFLOWS"` used to read only the first line,
    # so the remaining paths in a `workflows: |` block scalar were silently
    # left unverified.
    export WORKFLOWS=$'.github/workflows/a.yml\n.github/workflows/b.yml'
    run bash "$SCRIPT"
    [ "$status" -eq 0 ]
    run grep -F "actions-lock --verify .github/workflows/a.yml .github/workflows/b.yml" "$ARGS_FILE"
    [ "$status" -eq 0 ]
}
