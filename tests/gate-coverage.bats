#!/usr/bin/env bats

# Behavioral tests for scripts/gate-coverage.sh.
# Every test builds a throwaway caller repo under the bats temp dir (a gate
# workflow, a lockfile and the workflow files those two reference) and drives
# the script with env overrides. No network, no docker, no gh.
#
# The script takes the workflow list from the action's `workflows:` input
# (WORKFLOWS), never from the gate YAML, so the fixtures keep the gate's input
# in sync with WORKFLOWS unless a test deliberately changes one of them.

SCRIPT="scripts/gate-coverage.sh"

setup() {
    WORKDIR="${BATS_TEST_TMPDIR:-${BATS_TMPDIR:-/tmp}}/repo"
    GATE="${WORKDIR}/.github/workflows/gate.yaml"
    LOCK="${WORKDIR}/.github/workflows/actions.lock"

    mkdir -p "${WORKDIR}/.github/workflows"
    # Default fixture HAS a composite action: assertion 6 then applies, and the
    # composite-drop test below exercises it. The final test removes the
    # directory again to prove the assertion is skipped for composite-free
    # repos.
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
    unset IGNORE_LOCAL_ACTIONS
}

teardown() {
    unset GITHUB_WORKSPACE GATE_WORKFLOW LOCKFILE WORKFLOWS EXCLUDED_WORKFLOWS IGNORE_LOCAL_ACTIONS
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

# 1
@test "passes when the action input and the lockfile agree" {
    run bash "$SCRIPT"
    [ "$status" -eq 0 ]
    [[ "$output" == *"gate-coverage: OK: 2 onboarded workflows"* ]]
}

# 2
@test "fails and names the lockfile when it does not exist" {
    rm -f "${LOCK}"
    run bash "$SCRIPT"
    [ "$status" -ne 0 ]
    [[ "$output" == *"actions.lock"* ]]
}

# 3
@test "fails with an actionable fix when the gate workflow does not exist" {
    rm -f "${GATE}"
    run bash "$SCRIPT"
    [ "$status" -ne 0 ]
    [[ "$output" == *"gate-workflow"* || "$output" == *"check-gate-coverage"* ]]
}

# 4
@test "fails naming the path when the action input lists a workflow the lockfile does not" {
    write_workflow ".github/workflows/c.yml"
    export WORKFLOWS=".github/workflows/a.yml .github/workflows/b.yml .github/workflows/c.yml"
    run bash "$SCRIPT"
    [ "$status" -ne 0 ]
    [[ "$output" == *"c.yml"* ]]
}

# 5
@test "fails naming the path when the lockfile locks a workflow not passed to the action" {
    sed -i "s|^dependencies:|    '.github/workflows/d.yml': []\ndependencies:|" "${LOCK}"
    run bash "$SCRIPT"
    [ "$status" -ne 0 ]
    [[ "$output" == *"d.yml"* ]]
}

# 6
@test "fails when a workflow passed to the action does not exist on disk" {
    rm -f "${WORKDIR}/.github/workflows/b.yml"
    run bash "$SCRIPT"
    [ "$status" -ne 0 ]
    [[ "$output" == *"b.yml"* ]]
}

# 7
@test "fails when an excluded workflow is still passed to the action" {
    export EXCLUDED_WORKFLOWS=".github/workflows/b.yml"
    run bash "$SCRIPT"
    [ "$status" -ne 0 ]
    [[ "$output" == *"excluded workflow '.github/workflows/b.yml'"* ]]
}

# 8
@test "passes when EXCLUDED_WORKFLOWS names a workflow absent from every list" {
    export EXCLUDED_WORKFLOWS=".github/workflows/z.yml"
    run bash "$SCRIPT"
    [ "$status" -eq 0 ]
}

# 9
@test "fails explaining composite edits when the gate drops '.github/actions/**'" {
    sed -i "/\\.github\\/actions\\/\\*\\*/d" "${GATE}"
    run bash "$SCRIPT"
    [ "$status" -ne 0 ]
    [[ "$output" == *"composite"* ]]
}

# 10
@test "passes when the repo has no .github/actions directory, even without the paths entry" {
    rm -rf "${WORKDIR}/.github/actions"
    sed -i "/\\.github\\/actions\\/\\*\\*/d" "${GATE}"
    run bash "$SCRIPT"
    [ "$status" -eq 0 ]
    [[ "$output" == *"gate-coverage: OK: 2 onboarded workflows"* ]]
}

# 11
@test "fails when the gate passes the --ignore-local-actions CLI flag" {
    printf '      - name: verify locally\n        run: gh actions-lock --verify --ignore-local-actions\n' >> "${GATE}"
    run bash "$SCRIPT"
    [ "$status" -ne 0 ]
    [[ "$output" == *"ignore-local-actions"* ]]
}

# 12
@test "fails when the gate sets the literal unquoted ignore-local-actions: true" {
    sed -i 's|^\([[:space:]]*workflows: "\)|          ignore-local-actions: true\n\1|' "${GATE}"
    run bash "$SCRIPT"
    [ "$status" -ne 0 ]
    [[ "$output" == *"ignore-local-actions"* ]]
}

# 13
@test "REGRESSION: fails when the gate sets ignore-local-actions: 'true' quoted" {
    sed -i "s|^\([[:space:]]*workflows: \"\)|          ignore-local-actions: 'true'\n\1|" "${GATE}"
    run bash "$SCRIPT"
    [ "$status" -ne 0 ]
    [[ "$output" == *"ignore-local-actions"* ]]
}

# 14
@test "passes when the gate explicitly sets ignore-local-actions: false" {
    sed -i 's|^\([[:space:]]*workflows: "\)|          ignore-local-actions: false\n\1|' "${GATE}"
    run bash "$SCRIPT"
    [ "$status" -eq 0 ]
    [[ "$output" == *"gate-coverage: OK: 2 onboarded workflows"* ]]
}

# 15
@test "REGRESSION: fails when the RESOLVED ignore-local-actions input is truthy" {
    # Simulates `ignore-local-actions: \${{ true }}` or a variable: the file
    # contains no truthy literal, only the resolved value the action receives.
    export IGNORE_LOCAL_ACTIONS="TRUE"
    run bash "$SCRIPT"
    [ "$status" -ne 0 ]
    [[ "$output" == *"resolved"* ]]
}

# 16
@test "passes when a comment merely mentions ignore-local-actions" {
    printf '# NOTE: never pass --ignore-local-actions or set ignore-local-actions: true here\n' >> "${GATE}"
    run bash "$SCRIPT"
    [ "$status" -eq 0 ]
    [[ "$output" == *"gate-coverage: OK: 2 onboarded workflows"* ]]
}

# 17
@test "fails when WORKFLOWS is unset or empty" {
    unset WORKFLOWS
    run bash "$SCRIPT"
    [ "$status" -ne 0 ]

    export WORKFLOWS=""
    run bash "$SCRIPT"
    [ "$status" -ne 0 ]
}

# 18
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

# 19
@test "REGRESSION: rejects an exact negation of '.github/actions/**'" {
    sed -i "s|^      - '\.github/actions/\*\*'\$|&\n      - '!.github/actions/**'|" "${GATE}"
    run bash "$SCRIPT"
    [ "$status" -ne 0 ]
    [[ "$output" == *"negat"* && "$output" == *"cancel"* ]]
}

# 20
@test "REGRESSION: rejects an ancestor negation '!.github/**' that cancels the composite trigger" {
    sed -i "s|^      - '\.github/actions/\*\*'\$|&\n      - '!.github/**'|" "${GATE}"
    run bash "$SCRIPT"
    [ "$status" -ne 0 ]
    [[ "$output" == *"!.github/**"* && "$output" == *"cancel"* ]]
}

# 21
@test "REGRESSION: passes when the negation is unrelated, e.g. '!docs/**'" {
    sed -i "s|^      - '\.github/actions/\*\*'\$|&\n      - '!docs/**'|" "${GATE}"
    run bash "$SCRIPT"
    [ "$status" -eq 0 ]
    [[ "$output" == *"gate-coverage: OK: 2 onboarded workflows"* ]]
}

# 22
@test "passes when paths items sit at the same indentation as the key" {
    sed -i "/^      - '\.github\//s/^  //" "${GATE}"
    # Sanity: the sequence items now align with `paths:`.
    grep -q "^    - '\.github/actions/\*\*'" "${GATE}"
    run bash "$SCRIPT"
    [ "$status" -eq 0 ]
    [[ "$output" == *"gate-coverage: OK: 2 onboarded workflows"* ]]
}

# 23
@test "REGRESSION: an unrelated workflow_run 'workflows:' trigger is not a second action input" {
    cat > "${GATE}" <<'YAML'
name: Actions lockfile verify

on:
  workflow_run:
    workflows: [Build]
    types: [completed]
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
          workflows: ".github/workflows/a.yml .github/workflows/b.yml"
YAML
    run bash "$SCRIPT"
    [ "$status" -eq 0 ]
    [[ "$output" == *"gate-coverage: OK: 2 onboarded workflows"* ]]
}
