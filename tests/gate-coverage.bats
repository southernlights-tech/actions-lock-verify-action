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

# 24
@test "REGRESSION: rejects a descendant negation '!.github/actions/example/**'" {
    # The positive '.github/actions/**' entry is present, so a prefix check
    # passes; the filter must be evaluated to see the later exclusion.
    test -f "${WORKDIR}/.github/actions/example/action.yml"
    sed -i "s|^      - '\.github/actions/\*\*'\$|&\n      - '!.github/actions/example/**'|" "${GATE}"
    run bash "$SCRIPT"
    [ "$status" -ne 0 ]
    [[ "$output" == *".github/actions/example/action.yml"* ]]
    [[ "$output" == *"!.github/actions/example/**"* ]]
}

# 25
@test "REGRESSION: rejects a wildcard negation '!.github/*/**'" {
    sed -i "s|^      - '\.github/actions/\*\*'\$|&\n      - '!.github/*/**'|" "${GATE}"
    run bash "$SCRIPT"
    [ "$status" -ne 0 ]
    [[ "$output" == *".github/actions/example/action.yml"* ]]
    [[ "$output" == *"!.github/*/**"* ]]
}

# 26
@test "passes when a negation excludes an unrelated tree, e.g. '!/docs/**'" {
    # Leading-slash form: an unrelated pattern must not match a composite path
    # even after normalisation. ('!docs/**' is already test 21.)
    sed -i "s|^      - '\.github/actions/\*\*'\$|&\n      - '!/docs/**'|" "${GATE}"
    run bash "$SCRIPT"
    [ "$status" -eq 0 ]
    [[ "$output" == *"gate-coverage: OK: 2 onboarded workflows"* ]]
}

# 27
@test "supports a multiline WORKFLOWS value" {
    # A `workflows: |` block scalar hands one path per line to the step. Both
    # this script and verify-actions-lock.sh split on any whitespace.
    export WORKFLOWS=$'.github/workflows/a.yml\n.github/workflows/b.yml'
    run bash "$SCRIPT"
    [ "$status" -eq 0 ]
    [[ "$output" == *"gate-coverage: OK: 2 onboarded workflows"* ]]
}

# 28
@test "fails conservatively when a paths pattern cannot be evaluated (brace set)" {
    sed -i "s|^      - '\.github/actions/\*\*'\$|&\n      - '!{.github/actions}/**'|" "${GATE}"
    run bash "$SCRIPT"
    [ "$status" -ne 0 ]
    [[ "$output" == *"cannot be evaluated"* ]]
    [[ "$output" == *"{.github/actions}/**"* ]]
}

# 29
@test "REGRESSION: '?' is a quantifier on the preceding character, so a matching exclusion is caught" {
    # GitHub reads 'action.ymm?l' as 'action.ym' + 'm?' + 'l', which matches
    # 'action.yml' (zero-or-one 'm'). Modelling '?' as "one non-slash char"
    # made this exclusion invisible: a false green.
    sed -i "s|^      - '\.github/actions/\*\*'\$|&\n      - '!.github/actions/example/action.ymm?l'|" "${GATE}"
    run bash "$SCRIPT"
    [ "$status" -ne 0 ]
    [[ "$output" == *".github/actions/example/action.yml"* ]]
    [[ "$output" == *"!.github/actions/example/action.ymm?l"* ]]
}

# 30
@test "REGRESSION: '+' is a quantifier on the preceding character, so a matching exclusion is caught" {
    # 'action.ym+l' means one-or-more 'm', so it matches 'action.yml'.
    sed -i "s|^      - '\.github/actions/\*\*'\$|&\n      - '!.github/actions/example/action.ym+l'|" "${GATE}"
    run bash "$SCRIPT"
    [ "$status" -ne 0 ]
    [[ "$output" == *".github/actions/example/action.yml"* ]]
    [[ "$output" == *"!.github/actions/example/action.ym+l"* ]]
}

# 31
@test "passes when a '?' exclusion does not match the composite" {
    # 'action.ym?' means zero-or-one 'm' after 'action.y', so it matches
    # 'action.y' / 'action.ym' but never 'action.yml': the composite still
    # triggers the gate.
    sed -i "s|^      - '\.github/actions/\*\*'\$|&\n      - '!.github/actions/example/action.ym?'|" "${GATE}"
    run bash "$SCRIPT"
    [ "$status" -eq 0 ]
    [[ "$output" == *"gate-coverage: OK: 2 onboarded workflows"* ]]
}

# 32
@test "fails conservatively when '?' or '+' has no operand" {
    # A quantifier at the start of a pattern has nothing to repeat, so the
    # evaluator cannot decide whether it matches: fail, never assume.
    sed -i "s|^      - '\.github/actions/\*\*'\$|&\n      - '!?github/**'|" "${GATE}"
    run bash "$SCRIPT"
    [ "$status" -ne 0 ]
    [[ "$output" == *"cannot be evaluated"* ]]
    [[ "$output" == *"!?github/**"* ]]

    # Same for '+', and for a quantifier right after a segment boundary.
    sed -i "s|^      - '!?github/\*\*'\$|      - '!.github/+ctions/**'|" "${GATE}"
    run bash "$SCRIPT"
    [ "$status" -ne 0 ]
    [[ "$output" == *"cannot be evaluated"* ]]
    [[ "$output" == *"!.github/+ctions/**"* ]]
}

# 33
@test "REGRESSION: a backslash-escaped dot matches literally, so an escaped exclusion is caught" {
    # GitHub reads '\.' as a literal dot, so this exclusion DOES match the
    # composite. Emitting the backslash literally ('\\.') matched nothing,
    # which made the exclusion invisible and the check report OK: false green.
    cat > "${GATE}" <<'YAML'
name: Actions lockfile verify

on:
  pull_request:
    paths:
      - '.github/workflows/actions.lock'
      - '.github/workflows/**'
      - '.github/actions/**'
      - '!.github/actions/example/action\.yml'

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
    # The fixture must contain '.yml' preceded by ONE backslash.
    grep -qF 'action\.yml' "${GATE}"
    test -f "${WORKDIR}/.github/actions/example/action.yml"
    run bash "$SCRIPT"
    [ "$status" -ne 0 ]
    [[ "$output" == *".github/actions/example/action.yml"* ]]
    [[ "$output" == *'!.github/actions/example/action\.yml'* ]]
}

# 34
@test "REGRESSION: an escaped wildcard is a literal, not a wildcard" {
    # 'action\*.yml' is the literal name 'action*.yml', which does not match
    # 'action.yml', so the composite still triggers the gate and the check
    # passes. Treating '\*' as a wildcard would wrongly fail here.
    cat > "${GATE}" <<'YAML'
name: Actions lockfile verify

on:
  pull_request:
    paths:
      - '.github/workflows/actions.lock'
      - '.github/workflows/**'
      - '.github/actions/**'
      - '!.github/actions/example/action\*.yml'

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
    grep -qF 'action\*.yml' "${GATE}"
    test -f "${WORKDIR}/.github/actions/example/action.yml"
    run bash "$SCRIPT"
    [ "$status" -eq 0 ]
    [[ "$output" == *"gate-coverage: OK: 2 onboarded workflows"* ]]
}

# 35
@test "fails conservatively on a trailing backslash" {
    # A trailing '\' escapes nothing, so the pattern has no defined meaning:
    # fail rather than guess. Written with a quoted heredoc so the file really
    # holds ONE trailing backslash.
    cat > "${GATE}" <<'YAML'
name: Actions lockfile verify

on:
  pull_request:
    paths:
      - '.github/workflows/actions.lock'
      - '.github/workflows/**'
      - '.github/actions/**'
      - '!.github/actions/example/**\'

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
    # One backslash before the closing quote, not two.
    grep -qF 'example/**\' "${GATE}"
    run bash "$SCRIPT"
    [ "$status" -ne 0 ]
    [[ "$output" == *"cannot be evaluated"* ]]
    [[ "$output" == *'!.github/actions/example/**\'* ]]
}

# 36
@test "REGRESSION: a backslash-escaped bracket is a literal, not an invalid regex" {
    # '\[1\]' means the literal text '[1]', so the emitted ERE must be
    # 'action\[1\]\.yml'. Before the escape-set fix a bare '[' was emitted,
    # which either turned the pattern into a character class ('[1]' means the
    # character '1' - the wrong meaning) or, when unterminated, produced an
    # INVALID ERE that `[[ =~ ]]` reports as 2 and the caller read as "no
    # match". Either way the exclusion stops meaning what the gate says.
    # Here the literal '[1]' does not match 'action.yml', so the composite is
    # still covered and the check must PASS - and must not report an
    # invalid-regex/unevaluable error.
    cat > "${GATE}" <<'YAML'
name: Actions lockfile verify

on:
  pull_request:
    paths:
      - '.github/workflows/actions.lock'
      - '.github/workflows/**'
      - '.github/actions/**'
      - '!.github/actions/example/action\[1\].yml'

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
    grep -qF 'action\[1\].yml' "${GATE}"
    test -f "${WORKDIR}/.github/actions/example/action.yml"
    run bash "$SCRIPT"
    [ "$status" -eq 0 ]
    [[ "$output" == *"gate-coverage: OK: 2 onboarded workflows"* ]]
    [[ "$output" != *"cannot be evaluated"* ]]
}

# 37
@test "REGRESSION: an invalid generated regex fails closed" {
    # After the escape-set fix above, no legitimate paths pattern can translate
    # to an invalid ERE, so the defence-in-depth guard is exercised directly
    # against the REAL code: the helper and the shared failure message are
    # extracted from the script under test (not retyped) and driven with a
    # regex that `[[ =~ ]]` rejects with status 2. The probe first proves that
    # this platform really returns 2, so the test cannot pass vacuously, and
    # then proves the guard fails the run instead of reporting "no match".
    helper="${BATS_TEST_TMPDIR}/gate-coverage-helpers.sh"
    {
        sed -n '/^fail()/,/^}$/p' "$SCRIPT"
        sed -n '/^fail_unevaluable()/,/^}$/p' "$SCRIPT"
        sed -n '/^path_matches_regex()/,/^}$/p' "$SCRIPT"
    } > "${helper}"
    # Sanity: the extraction really captured the code under test.
    grep -q '^fail()' "${helper}"
    grep -q '^fail_unevaluable()' "${helper}"
    grep -q '^path_matches_regex()' "${helper}"

    driver="${BATS_TEST_TMPDIR}/drive-invalid-regex.sh"
    cat > "${driver}" <<'SH'
#!/usr/bin/env bash
# $1: file defining fail, fail_unevaluable and path_matches_regex.
# shellcheck source=/dev/null
. "$1"
GATE_WORKFLOW=".github/workflows/gate.yaml"
probe_rc=0
[[ "x" =~ [abc ]] || probe_rc=$?
echo "invalid-ere-rc=${probe_rc}"
if [ "${probe_rc}" -ne 2 ]; then
    echo "PROBE-UNAVAILABLE"
    exit 3
fi
echo "before-guard"
# An unclosed bracket expression: regcomp fails, so `[[ =~ ]]` returns 2.
path_matches_regex "x" "[abc" '!.github/actions/[abc'
echo "AFTER-GUARD"
SH

    run bash "${driver}" "${helper}"
    [[ "$output" == *"invalid-ere-rc=2"* ]]
    [[ "$output" != *"PROBE-UNAVAILABLE"* ]]
    [ "$status" -ne 0 ]
    [[ "$output" == *"cannot be evaluated"* ]]
    [[ "$output" == *'!.github/actions/[abc'* ]]
    [[ "$output" != *"AFTER-GUARD"* ]]
}

# 38
@test "REGRESSION: a '#' inside a quoted paths entry is data, not a comment" {
    # `sed 's/#.*//'` cut the entry at the '#', so the exclusion never matched
    # and the check reported OK while GitHub really excluded that composite:
    # a false green. YAML only starts a comment at a '#' that is outside a
    # quoted scalar and at line start or after whitespace; here it is inside
    # single quotes and preceded by a path character, so it is data.
    mkdir -p "${WORKDIR}/.github/actions/foo#bar"
    cat > "${WORKDIR}/.github/actions/foo#bar/action.yml" <<'YAML'
name: Hash composite
description: Composite under a directory whose name contains '#'.
runs:
  using: composite
  steps:
    - run: echo hash
      shell: bash
YAML
    sed -i "s|^      - '\.github/actions/\*\*'\$|&\n      - '!.github/actions/foo#bar/**'|" "${GATE}"
    # The fixture really holds the '#' inside the quoted entry.
    grep -qF "'!.github/actions/foo#bar/**'" "${GATE}"
    run bash "$SCRIPT"
    [ "$status" -ne 0 ]
    [[ "$output" == *".github/actions/foo#bar/action.yml"* ]]
    [[ "$output" == *"!.github/actions/foo#bar/**"* ]]
}

# 39
@test "REGRESSION: a double-quoted escaped dot is decoded, so the exclusion is caught" {
    # The YAML source carries a DOUBLE backslash, so YAML's double-quoted
    # decoding yields `action\.yml` - the same pattern as single-quoted test 33.
    # Without decoding the evaluator saw a literal backslash-backslash and the
    # exclusion never matched: another false green.
    cat > "${GATE}" <<'YAML'
name: Actions lockfile verify

on:
  pull_request:
    paths:
      - '.github/workflows/actions.lock'
      - '.github/workflows/**'
      - '.github/actions/**'
      - "!.github/actions/example/action\\.yml"

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
    # Two backslashes in the source (the decoded scalar has one).
    grep -qF 'action\\.yml' "${GATE}"
    test -f "${WORKDIR}/.github/actions/example/action.yml"
    run bash "$SCRIPT"
    [ "$status" -ne 0 ]
    [[ "$output" == *".github/actions/example/action.yml"* ]]
    [[ "$output" == *'!.github/actions/example/action\.yml'* ]]
}

# 40
@test "REGRESSION: an unsupported escape in a double-quoted entry fails closed" {
    # `\t` is not one of the escapes a GitHub path pattern can carry, so the
    # decoded value cannot be reproduced reliably: fail closed rather than
    # evaluate a pattern that may never match (a false green).
    cat > "${GATE}" <<'YAML'
name: Actions lockfile verify

on:
  pull_request:
    paths:
      - '.github/workflows/actions.lock'
      - '.github/workflows/**'
      - '.github/actions/**'
      - "!.github/actions/example/action\tyml"

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
    grep -qF 'action\tyml' "${GATE}"
    run bash "$SCRIPT"
    [ "$status" -ne 0 ]
    [[ "$output" == *"cannot be evaluated"* ]]
    [[ "$output" == *'action\tyml'* ]]
}

# 41
@test "REGRESSION: every entry of a multiline EXCLUDED_WORKFLOWS is checked" {
    # `read -r -a excluded <<< "$EXCLUDED_WORKFLOWS"` only reads the FIRST
    # line, so an `excluded-workflows: |` block scalar silently dropped every
    # entry after it - an onboarded workflow that WAS excluded went unnoticed.
    export EXCLUDED_WORKFLOWS=$'.github/workflows/z.yml\n.github/workflows/b.yml'
    run bash "$SCRIPT"
    [ "$status" -ne 0 ]
    [[ "$output" == *"excluded workflow '.github/workflows/b.yml'"* ]]

    # Reverse order: the onboarded path is now the FIRST line and the absent
    # one the second. The result must be identical - order does not matter,
    # which proves the first-line truncation was the bug.
    export EXCLUDED_WORKFLOWS=$'.github/workflows/b.yml\n.github/workflows/z.yml'
    run bash "$SCRIPT"
    [ "$status" -ne 0 ]
    [[ "$output" == *"excluded workflow '.github/workflows/b.yml'"* ]]
}
