#!/usr/bin/env bash
# scripts/gate-coverage.sh
#
# Pre-check that runs BEFORE any network call. It asserts that two lists
# agree: the workflow paths handed to the composite action (WORKFLOWS) and the
# lockfile the verifier reads (LOCKFILE). A disagreement means the gate is
# green for a set of workflows nobody declared, which is worse than a red gate.
# It also asserts that the caller's gate cannot silence the verifier and, when
# the repository has composites, that its `pull_request.paths` still triggers
# on them.
#
# Required env:
#   WORKFLOWS            space-separated list passed to the action (>= 1 path)
# Optional env:
#   GATE_WORKFLOW        caller's gate workflow file
#                        (default .github/workflows/actions-lock-verify.yaml)
#   EXCLUDED_WORKFLOWS   space-separated paths deliberately excluded
#                        (default empty)
#   LOCKFILE             default .github/workflows/actions.lock
#   GITHUB_WORKSPACE     root the paths above resolve against (default .)
#   IGNORE_LOCAL_ACTIONS resolved `ignore-local-actions` input, as the runner
#                        evaluated it (default false)
#
# Parsing contract (sed/grep/awk + coreutils only; no yq, jq or python):
#
#   * The workflow list is taken verbatim from the action input (the WORKFLOWS
#     env var), which is the resolved value the caller's step hands to the
#     composite action. It is NOT parsed out of the gate YAML: re-reading the
#     caller's file for a value the action already receives is redundant and
#     fragile, and a second `workflows:` key in that file (for example a
#     `workflow_run: workflows: [Build]` trigger) is not an input at all.
#     Only the gate's `pull_request.paths` list is read from the gate file, to
#     assert the composite trigger.
#   * The lockfile's workflow keys live in the top-level `workflows:` map and
#     end at the top-level `dependencies:` map. A workflow with no remote
#     actions is written as `    'path': []`, so the key pattern accepts an
#     optional trailing ` []`; matching only `':` would silently drop those
#     keys and make every later comparison wrong.
#   * Set comparisons are order-insensitive: each list is split to one path
#     per line and `sort -u`d before `comm` runs in both directions.
#   * The `ignore[-_]local[-_]actions` assertion strips comments first
#     (`sed 's/#.*//'`), so a comment that merely mentions the flag does not
#     trip the guard. It fails three ways: the RESOLVED input (env
#     IGNORE_LOCAL_ACTIONS) being truthy, the CLI flag
#     (`--ignore-local-actions`) appearing outside a comment, and the YAML
#     input key being set to a truthy literal
#     (`ignore-local-actions: true|yes|on|1`, quoted or not). The resolved
#     value is checked first because that is the only way to catch an
#     expression: `ignore-local-actions: ${{ true }}` or a variable evaluates
#     to a truthy input the literal pattern cannot see. An explicit
#     `ignore-local-actions: false|no|off|0` passes because it leaves
#     verification on.
#   * The `.github/actions/**` path-filter assertion is conditional: it only
#     applies when the workspace has a `.github/actions` directory. A repo
#     with no composites cannot change a pin by editing one, so it is not
#     forced to carry a dead path filter; a repo with composites must trigger
#     on them. Because `paths` is ordered, a negation that could cancel that
#     trigger fails even when the positive entry is present. Overlap is
#     decided conservatively by path prefix: an ancestor glob such as
#     `!.github/**`, a bare `!*`/`!**`, and a brace set (whose expansion cannot
#     be ruled out) all fail, while unrelated negations such as `!docs/**` or
#     `!.github/workflows/**` pass. When the assertion does not apply it emits
#     nothing.
set -euo pipefail

WORKFLOWS="${WORKFLOWS:-}"
GATE_WORKFLOW="${GATE_WORKFLOW:-.github/workflows/actions-lock-verify.yaml}"
EXCLUDED_WORKFLOWS="${EXCLUDED_WORKFLOWS:-}"
LOCKFILE="${LOCKFILE:-.github/workflows/actions.lock}"
GITHUB_WORKSPACE="${GITHUB_WORKSPACE:-.}"
IGNORE_LOCAL_ACTIONS="${IGNORE_LOCAL_ACTIONS:-false}"

fail() {
    echo "::error::gate-coverage: $*" >&2
    exit 1
}

# Resolve a path against GITHUB_WORKSPACE; absolute paths are used as-is.
resolve_path() {
    case "${1}" in
        /*) printf '%s\n' "${1}" ;;
        *) printf '%s/%s\n' "${GITHUB_WORKSPACE%/}" "${1}" ;;
    esac
}

# stdin -> one path per line, sorted, de-duplicated.
split_list() {
    tr -s '[:space:]' '\n' | sed -e '/^$/d' | LC_ALL=C sort -u
}

tmp_dir="$(mktemp -d)"
trap 'rm -rf "${tmp_dir}"' EXIT

action_list="${tmp_dir}/action.txt"
lock_list="${tmp_dir}/lock.txt"

printf '%s\n' "${WORKFLOWS}" | split_list > "${action_list}"
if [ ! -s "${action_list}" ]; then
    fail "WORKFLOWS is empty; pass the space-separated list of onboarded workflow paths."
fi

lock_path="$(resolve_path "${LOCKFILE}")"
gate_path="$(resolve_path "${GATE_WORKFLOW}")"

# 1. The lockfile must exist: there is nothing to compare against otherwise.
if [ ! -f "${lock_path}" ]; then
    fail "lockfile not found at '${LOCKFILE}' (resolved: '${lock_path}'). Generate it with 'gh actions-lock' before enabling this gate."
fi

# 2. The gate workflow must exist, and the message must say how to fix it.
if [ ! -f "${gate_path}" ]; then
    fail "gate workflow not found at '${GATE_WORKFLOW}' (resolved: '${gate_path}'). Set the action's 'gate-workflow:' input to your gate workflow's path, or set 'check-gate-coverage: false' to opt out."
fi

# Comments are stripped for every structural assertion below.
gate_stripped="${tmp_dir}/gate.no-comments"
sed 's/#.*//' "${gate_path}" > "${gate_stripped}"

# Lockfile workflow keys: top-level `workflows:` map up to `dependencies:`.
# The trailing `.*` accepts both `'path':` and `'path': []`.
sed -n '/^workflows:[[:space:]]*$/,/^dependencies:[[:space:]]*$/p' "${lock_path}" \
    | grep -E "^[[:space:]]+'" \
    | sed -E "s/^[[:space:]]+'([^']+)'.*/\1/" \
    | LC_ALL=C sort -u > "${lock_list}" || true

diff_found=0

# Report every path that differs between two sorted lists, in both directions.
report_diff() {
    local list_a="${1}"
    local list_b="${2}"
    local only_a="${3}"
    local only_b="${4}"
    local found=0
    local path
    while IFS= read -r path; do
        echo "::error::gate-coverage: '${path}' ${only_a}" >&2
        found=1
    done < <(comm -23 "${list_a}" "${list_b}")
    while IFS= read -r path; do
        echo "::error::gate-coverage: '${path}' ${only_b}" >&2
        found=1
    done < <(comm -13 "${list_a}" "${list_b}")
    if (( found )); then
        diff_found=1
    fi
}

# 3. The list the action receives must equal the lockfile keys as a set, both
#    directions. The gate YAML is not consulted: the action input is the
#    resolved value the caller's step already handed over.
report_diff "${action_list}" "${lock_list}" \
    "passed to the action but absent from ${LOCKFILE}" \
    "${LOCKFILE} lists it but it was not passed to the action"

if (( diff_found )); then
    exit 1
fi

# 4. Every path passed to the action must exist on disk.
while IFS= read -r path; do
    if [ ! -f "${GITHUB_WORKSPACE%/}/${path}" ]; then
        fail "workflow '${path}' is passed to the action but does not exist under '${GITHUB_WORKSPACE}'."
    fi
done < "${action_list}"

# 5. Excluded workflows must not appear anywhere. The length check keeps the
#    expansion safe under `set -u` when EXCLUDED_WORKFLOWS is empty.
excluded=()
if [ -n "${EXCLUDED_WORKFLOWS}" ]; then
    read -r -a excluded <<< "${EXCLUDED_WORKFLOWS}"
fi
if (( ${#excluded[@]} > 0 )); then
    for entry in "${excluded[@]}"; do
        if grep -Fxq -- "${entry}" "${lock_list}"; then
            fail "excluded workflow '${entry}' must not appear in the lockfile ${LOCKFILE}."
        fi
        if grep -Fxq -- "${entry}" "${action_list}"; then
            fail "excluded workflow '${entry}' must not be passed to the action."
        fi
    done
fi

# 6. The gate must re-run when a composite action changes: composite edits
#    change the pins recorded in the lockfile. This is only true for repos that
#    actually have composites, so the requirement is conditional on the
#    workspace having a .github/actions directory: repos with composites must
#    trigger on them, and repos without composites are not forced to add a
#    dead path filter. Skipping the assertion emits no output.
gate_pr_paths="${tmp_dir}/gate.pr-paths"
awk '
    {
        line = $0
        indent = 0
        while (substr(line, indent + 1, 1) == " ") indent++
        trimmed = substr(line, indent + 1)
    }
    state == 0 {
        if (trimmed ~ /^pull_request:[[:space:]]*$/) { pr_indent = indent; state = 1; next }
    }
    state == 1 {
        if (trimmed == "") next
        if (indent <= pr_indent) { state = 0; next }
        if (trimmed ~ /^paths:[[:space:]]*$/) { paths_indent = indent; state = 2; next }
    }
    state == 2 {
        if (trimmed == "") next
        if (indent < paths_indent) { state = 0; next }
        if (indent == paths_indent && substr(trimmed, 1, 1) != "-") { state = 0; next }
        if (trimmed ~ /^-/) {
            value = trimmed
            sub(/^-[[:space:]]*/, "", value)
            sub(/[[:space:]]+$/, "", value)
            print value
        }
    }
' "${gate_stripped}" \
    | sed -E "s/^'(.*)'$/\1/; s/^\"(.*)\"$/\1/" > "${gate_pr_paths}"

# Does a negated path filter overlap the '.github/actions' directory? Overlap
# is decided by path prefix, conservatively: a negated entry that cannot be
# proven disjoint is treated as conflicting. Returns 0 (conflicting) or 1.
negation_overlaps_composite_paths() {
    local pattern="${1#!}"
    local composite_dir='.github/actions'
    pattern="${pattern#/}"
    pattern="${pattern%/**}"
    pattern="${pattern%/}"
    # An empty remainder, a bare wildcard, or a brace set matches unknown
    # paths, so overlap with '.github/actions' cannot be ruled out.
    case "${pattern}" in
        '' | '*' | '**' | *'{'*) return 0 ;;
    esac
    # '<remainder>' or '<remainder>/*' is a prefix of '.github/actions/...'
    # when the remainder equals '.github' or '.github/actions'.
    case "${composite_dir}" in
        "${pattern}" | "${pattern}"/*) return 0 ;;
    esac
    return 1
}

if [ -d "${GITHUB_WORKSPACE%/}/.github/actions" ]; then
    # A later, ordered negation cancels an earlier inclusion, so the mere
    # presence of '.github/actions/**' is not enough: with a negation such as
    # `- '!.github/actions/**'`, or an ancestor glob such as
    # `- '!.github/**'`, composite-only edits would no longer run the gate
    # while the positive-entry check still passed. Negations that cannot
    # overlap (e.g. '!docs/**') are left alone.
    while IFS= read -r negated; do
        if [ -z "${negated}" ]; then
            continue
        fi
        if negation_overlaps_composite_paths "${negated}"; then
            fail "${GATE_WORKFLOW} negates '${negated}' under pull_request.paths. That negation can cancel the required '.github/actions/**' trigger (an ancestor glob such as '!.github/**' or a brace set whose overlap cannot be ruled out counts too), so editing a composite action would no longer run the gate; remove the negated entry."
        fi
    done < <(grep -E '^!' "${gate_pr_paths}" || true)
    if ! grep -Fxq -- '.github/actions/**' "${gate_pr_paths}"; then
        fail "${GATE_WORKFLOW} must list '.github/actions/**' under pull_request.paths: editing a composite action changes the pins recorded in ${LOCKFILE}, so the gate has to run on those edits."
    fi
fi

# 7. The gate must never silence the verifier.
#
# (a) The RESOLVED input is what the runner and the action actually see, so an
#     expression such as `${{ true }}` or a variable that evaluates truthy is
#     caught here even though no literal in the file is truthy.
resolved_ignore_local_actions="$(printf '%s' "${IGNORE_LOCAL_ACTIONS}" | tr '[:upper:]' '[:lower:]')"
case "${resolved_ignore_local_actions}" in
    true | yes | on | 1)
        fail "the action's resolved 'ignore-local-actions' input is truthy ('${IGNORE_LOCAL_ACTIONS}'). That makes the verifier pass while the GitHub Actions runner still enforces the lockfile, so jobs fail with 'lockfile missing pin for <action>'. Remove the input; if your gate genuinely cannot follow the standard shape, set 'check-gate-coverage: false' instead."
        ;;
esac

# (b) The CLI flag, outside a comment.
if grep -Eq -- '--ignore[-_]local[-_]actions' "${gate_stripped}"; then
    fail "${GATE_WORKFLOW} enables silencing the verifier outside a comment with the '--ignore-local-actions' CLI flag. Remove it so the gate actually blocks unverifiable local composite actions."
fi

# (c) The literal YAML input. Quoted values are unwrapped so that
#     `ignore-local-actions: 'true'` and `ignore-local-actions: "yes"` are
#     caught, while false/no/off/0 pass.
gate_unquoted="${tmp_dir}/gate.unquoted"
sed -E "s/[\"']//g" "${gate_stripped}" > "${gate_unquoted}"
if grep -Eiq -- 'ignore[-_]local[-_]actions:[[:space:]]*(true|yes|on|1)([[:space:]]|$)' "${gate_unquoted}"; then
    fail "${GATE_WORKFLOW} enables silencing the verifier by setting the 'ignore-local-actions' input to a truthy value. Set it to false or remove it so the gate blocks unverifiable local composite actions."
fi

onboarded="$(wc -l < "${action_list}" | tr -d ' ')"
echo "gate-coverage: OK: ${onboarded} onboarded workflows; action input and lockfile agree"
