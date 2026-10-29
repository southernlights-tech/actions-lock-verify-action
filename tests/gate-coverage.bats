#!/usr/bin/env bats

# Behavioral tests for scripts/gate-coverage.sh.
# Every test builds a throwaway caller repo under the bats temp dir (a gate
# workflow, a lockfile and the workflow files those two reference) and drives
# the script with env overrides. No network, no docker, no gh.

SCRIPT="scripts/gate-coverage.sh"

setup() {
    WORKDIR="${BATS_TEST_TMPDIR:-${BATS_TMPDIR:-/tmp}}/repo"
    GATE="${WORKDIR}/.github/workflows/gate.yaml"
    LOCK="${WORKDIR}/.github/workflows/actions.lock"

    mkdir -p "${WORKDIR}/.github/workflows"
    # Default fixture HAS a composite action: assertion 8 then applies, and the
    # composite-drop test below exercises it. The new test removes the directory
    # again to prove the assertion is skipped for composite-free repos.
    mkdir -p "${WORKDIR}/.github/actions/example"
    cat > "${WORKDIR}/.github/actions/example/action.yml" <<'YAML'
name: Example composite
description: Stub composite action used only as a fixture.
runs:
  using: composite
  steps:
    - run: echo example
      shell: bash
YAML

    write_gate
    write_lockfile
    write_workflow ".github/workflows/a.yml"
    write_workflow ".github/workflows/b.yml"

    export GITHUB_WORKSPACE="${WORKDIR}"
    export GATE_WORKFLOW=".github/workflows/gate.yaml"
    export LOCKFILE=".github/workflows/actions.lock"
    export WORKFLOWS=".github/workflows/a.yml .github/workflows/b.yml"
    export EXCLUDED_WORKFLOWS=""
}

teardown() {
    unset GITHUB_WORKSPACE GATE_WORKFLOW LOCKFILE WORKFLOWS EXCLUDED_WORKFLOWS
    rm -rf "${WORKDIR:-}"
}

# A caller gate workflow. $1 overrides the action's workflows input.
write_gate() {
    local workflows="${1:-.github/workflows/a.yml .github/workflows/b.yml}"
    cat > "${GATE}" <<YAML
name: Actions lockfile verify

on:
  pull_request:
    paths:
      - '.github/workflows/actions.lock'
      - '.github/workflows/**'
      - '.github/actions/**'

jobs:
  verify:
    runs-on: ubuntu-latest
    timeout-minutes: 10
    steps:
      - uses: actions/checkout@v7
      - uses: southernlights-tech/actions-lock-verify-action@v1
        with:
          workflows: "${workflows}"
YAML
}

# A minimal lockfile in the shape gh-actions-lock writes.
write_lockfile() {
    cat > "${LOCK}" <<'LOCK'
version: '1'
workflows:
    '.github/workflows/a.yml':
        - actions/checkout@0123456789abcdef
    '.github/workflows/b.yml':
        - actions/checkout@0123456789abcdef
dependencies:
    actions/checkout@0123456789abcdef:
        - actions/checkout
LOCK
}

write_workflow() {
    local path="${1}"
    printf 'name: %s\non: pull_request\njobs:\n  noop:\n    runs-on: ubuntu-latest\n    steps:\n      - run: echo noop\n' "${path}" > "${WORKDIR}/${path}"
}

@test "passes when the gate, the action input and the lockfile agree" {
    run bash "$SCRIPT"
    [ "$status" -eq 0 ]
    [[ "$output" == *"gate-coverage: OK: 2 onboarded workflows"* ]]
}

@test "fails and names the lockfile when it does not exist" {
    rm -f "${LOCK}"
    run bash "$SCRIPT"
    [ "$status" -ne 0 ]
    [[ "$output" == *"actions.lock"* ]]
}

@test "fails with an actionable fix when the gate workflow does not exist" {
    rm -f "${GATE}"
    run bash "$SCRIPT"
    [ "$status" -ne 0 ]
    [[ "$output" == *"gate-workflow"* || "$output" == *"check-gate-coverage"* ]]
}

@test "fails naming the path when the gate lists a workflow the lockfile does not" {
    write_gate ".github/workflows/a.yml .github/workflows/b.yml .github/workflows/c.yml"
    write_workflow ".github/workflows/c.yml"
    export WORKFLOWS=".github/workflows/a.yml .github/workflows/b.yml .github/workflows/c.yml"
    run bash "$SCRIPT"
    [ "$status" -ne 0 ]
    [[ "$output" == *"c.yml"* ]]
}

@test "fails naming the path when the lockfile locks a workflow the gate does not list" {
    sed -i "s|^dependencies:|    '.github/workflows/d.yml': []\ndependencies:|" "${LOCK}"
    run bash "$SCRIPT"
    [ "$status" -ne 0 ]
    [[ "$output" == *"d.yml"* ]]
}

@test "fails naming the path when the action input differs from the gate list" {
    export WORKFLOWS=".github/workflows/a.yml"
    run bash "$SCRIPT"
    [ "$status" -ne 0 ]
    [[ "$output" == *"b.yml"* ]]
}

@test "fails when a workflow listed in the gate does not exist on disk" {
    rm -f "${WORKDIR}/.github/workflows/b.yml"
    run bash "$SCRIPT"
    [ "$status" -ne 0 ]
    [[ "$output" == *"b.yml"* ]]
}

@test "fails when an excluded workflow is still listed in the gate" {
    export EXCLUDED_WORKFLOWS=".github/workflows/b.yml"
    run bash "$SCRIPT"
    [ "$status" -ne 0 ]
    [[ "$output" == *"excluded workflow '.github/workflows/b.yml'"* ]]
}

@test "passes when EXCLUDED_WORKFLOWS names a workflow absent from every list" {
    export EXCLUDED_WORKFLOWS=".github/workflows/z.yml"
    run bash "$SCRIPT"
    [ "$status" -eq 0 ]
}

@test "fails explaining composite edits when the gate drops '.github/actions/**'" {
    sed -i "/\\.github\\/actions\\/\\*\\*/d" "${GATE}"
    run bash "$SCRIPT"
    [ "$status" -ne 0 ]
    [[ "$output" == *"composite"* ]]
}

@test "passes when the repo has no .github/actions directory, even without the paths entry" {
    rm -rf "${WORKDIR}/.github/actions"
    sed -i "/\\.github\\/actions\\/\\*\\*/d" "${GATE}"
    run bash "$SCRIPT"
    [ "$status" -eq 0 ]
    [[ "$output" == *"gate-coverage: OK: 2 onboarded workflows"* ]]
}

@test "fails when the gate passes the --ignore-local-actions CLI flag" {
    printf '      - name: verify locally\n        run: gh actions-lock --verify --ignore-local-actions\n' >> "${GATE}"
    run bash "$SCRIPT"
    [ "$status" -ne 0 ]
    [[ "$output" == *"ignore-local-actions"* ]]
}

@test "REGRESSION: fails when the gate sets the ignore-local-actions YAML input key" {
    sed -i 's|^\([[:space:]]*workflows: "\)|          ignore-local-actions: true\n\1|' "${GATE}"
    run bash "$SCRIPT"
    [ "$status" -ne 0 ]
    [[ "$output" == *"ignore-local-actions"* ]]
}

@test "passes when a comment merely mentions ignore-local-actions" {
    printf '# NOTE: never pass --ignore-local-actions or set ignore-local-actions: true here\n' >> "${GATE}"
    run bash "$SCRIPT"
    [ "$status" -eq 0 ]
    [[ "$output" == *"gate-coverage: OK: 2 onboarded workflows"* ]]
}

@test "fails when WORKFLOWS is unset or empty" {
    unset WORKFLOWS
    run bash "$SCRIPT"
    [ "$status" -ne 0 ]

    export WORKFLOWS=""
    run bash "$SCRIPT"
    [ "$status" -ne 0 ]
}

@test "fails when the gate declares two workflows inputs" {
    cat >> "${GATE}" <<'YAML'
      - uses: southernlights-tech/actions-lock-verify-action@v1
        with:
          workflows: ".github/workflows/a.yml"
YAML
    run bash "$SCRIPT"
    [ "$status" -ne 0 ]
    [[ "$output" == *"expected exactly one"* ]]
}

@test "REGRESSION: compares a lockfile entry written as 'path': [] correctly" {
    cat > "${LOCK}" <<'LOCK'
version: '1'
workflows:
    '.github/workflows/a.yml':
        - actions/checkout@0123456789abcdef
    '.github/workflows/b.yml': []
dependencies:
    actions/checkout@0123456789abcdef:
        - actions/checkout
LOCK
    run bash "$SCRIPT"
    [ "$status" -eq 0 ]
    [[ "$output" == *"gate-coverage: OK: 2 onboarded workflows"* ]]
}
