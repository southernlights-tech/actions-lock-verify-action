#!/usr/bin/env bash
# scripts/gate-coverage.sh
#
# Pre-check that runs BEFORE any network call. It asserts that three lists
# agree: the workflow paths handed to the composite action (WORKFLOWS), the
# gate workflow that invokes the action (GATE_WORKFLOW), and the lockfile the
# verifier reads (LOCKFILE). A disagreement means the gate is green for a set
# of workflows nobody declared, which is worse than a red gate.
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
#
# Parsing contract (sed/grep/awk + coreutils only; no yq, jq or python):
#
#   * The gate's action input must appear exactly once, as a single-line YAML
#     scalar, quoted or unquoted:
#         workflows: "<space-separated list>"
#         workflows: <space-separated list>
#     Any leading indentation is allowed. A block or flow indicator in place of
#     a scalar ('|', '>', '[', '{', '|-', '>-') is rejected.
#   * The lockfile's workflow keys live in the top-level `workflows:` map and
#     end at the top-level `dependencies:` map. A workflow with no remote
#     actions is written as `    'path': []`, so the key pattern accepts an
#     optional trailing ` []`; matching only `':` would silently drop those
#     keys and make every later comparison wrong.
#   * Set comparisons are order-insensitive: each list is split to one path
#     per line and `sort -u`d before `comm` runs in both directions.
#   * The `ignore[-_]local[-_]actions` assertion strips comments first
#     (`sed 's/#.*//'`), so a comment that merely mentions the flag does not
#     trip the guard. Outside a comment the CLI flag
#     (`--ignore-local-actions`) fails, and so does the YAML input key when its
#     value is truthy (`ignore-local-actions: true|yes|on|1`, quoted or not);
#     an explicit `ignore-local-actions: false|no|off|0` passes because it
#     leaves verification on.
#   * The `.github/actions/**` path-filter assertion is conditional: it only
#     applies when the workspace has a `.github/actions` directory. A repo
#     with no composites cannot change a pin by editing one, so it is not
#     forced to carry a dead path filter; a repo with composites must trigger
#     on them. An ordered negation mentioning `.github/actions` (e.g.
#     `- '!.github/actions/**'`) fails even when the inclusion is present,
#     because it cancels that trigger. When the assertion does not apply it
#     emits nothing.
set -euo pipefail

WORKFLOWS="${WORKFLOWS:-}"
GATE_WORKFLOW="${GATE_WORKFLOW:-.github/workflows/actions-lock-verify.yaml}"
EXCLUDED_WORKFLOWS="${EXCLUDED_WORKFLOWS:-}"
LOCKFILE="${LOCKFILE:-.github/workflows/actions.lock}"
GITHUB_WORKSPACE="${GITHUB_WORKSPACE:-.}"

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
gate_list="${tmp_dir}/gate.txt"
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

# 3. The gate must declare exactly one workflow list, as a single-line scalar.
#    Both documented forms are accepted:
#        workflows: "<space-separated list>"   (double quoted)
#        workflows: <space-separated list>     (unquoted)
#    `grep -nE` keeps the line number so a multi-line value can still be told
#    apart from a block/flow indicator below.
gate_inputs="$(grep -nE '^[[:space:]]*workflows:[[:space:]]*[^[:space:]]' "${gate_stripped}" || true)"
gate_input_count="$(printf '%s\n' "${gate_inputs}" | grep -c . || true)"
case "${gate_input_count}" in
    0)
        fail "${GATE_WORKFLOW} declares no workflow list. Expected exactly one input listing the workflow paths space-separated, either quoted ('workflows: \"<paths>\"') or unquoted ('workflows: <paths>')."
        ;;
    1) ;;
    *)
        fail "${GATE_WORKFLOW} declares ${gate_input_count} 'workflows:' inputs; expected exactly one (the action input)."
        ;;
esac

# Everything after `workflows:`, with the `grep -n` prefix removed and the
# surrounding whitespace trimmed.
gate_workflows_value="$(printf '%s\n' "${gate_inputs}" \
    | sed -E 's/^[0-9]+:[[:space:]]*workflows:[[:space:]]*//' \
    | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//')"

case "${gate_workflows_value}" in
    '|'|'>'|'['|'{'|'|-'|'>-')
        fail "${GATE_WORKFLOW}'s 'workflows:' input must be a single-line scalar (quoted or unquoted) listing the workflow paths space-separated; it is a YAML block or flow indicator ('${gate_workflows_value}') instead."
        ;;
esac

# Strip one pair of surrounding double or single quotes if present.
if [[ "${gate_workflows_value}" == \"*\" && ${#gate_workflows_value} -ge 2 ]]; then
    gate_workflows_value="${gate_workflows_value:1:${#gate_workflows_value}-2}"
elif [[ "${gate_workflows_value}" == \'*\' && ${#gate_workflows_value} -ge 2 ]]; then
    gate_workflows_value="${gate_workflows_value:1:${#gate_workflows_value}-2}"
fi

printf '%s\n' "${gate_workflows_value}" | split_list > "${gate_list}"

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

# 4. The gate's list must equal WORKFLOWS as a set, both directions.
report_diff "${action_list}" "${gate_list}" \
    "passed to the action but absent from ${GATE_WORKFLOW}" \
    "${GATE_WORKFLOW} lists it but it was not passed to the action"

# 5. The gate's list must equal the lockfile keys as a set, both directions.
report_diff "${lock_list}" "${gate_list}" \
    "${LOCKFILE} lists it but ${GATE_WORKFLOW} does not" \
    "${GATE_WORKFLOW} lists it but it is absent from ${LOCKFILE}"

if (( diff_found )); then
    exit 1
fi

# 6. Every gate path must exist on disk.
while IFS= read -r path; do
    if [ ! -f "${GITHUB_WORKSPACE%/}/${path}" ]; then
        fail "workflow '${path}' is listed in ${GATE_WORKFLOW} but does not exist under '${GITHUB_WORKSPACE}'."
    fi
done < "${gate_list}"

# 7. Excluded workflows must not appear anywhere. The length check keeps the
#    expansion safe under `set -u` when EXCLUDED_WORKFLOWS is empty.
excluded=()
if [ -n "${EXCLUDED_WORKFLOWS}" ]; then
    read -r -a excluded <<< "${EXCLUDED_WORKFLOWS}"
fi
if (( ${#excluded[@]} > 0 )); then
    for entry in "${excluded[@]}"; do
        if grep -Fxq -- "${entry}" "${gate_list}"; then
            fail "excluded workflow '${entry}' must not be listed in ${GATE_WORKFLOW}."
        fi
        if grep -Fxq -- "${entry}" "${lock_list}"; then
            fail "excluded workflow '${entry}' must not appear in the lockfile ${LOCKFILE}."
        fi
        if grep -Fxq -- "${entry}" "${action_list}"; then
            fail "excluded workflow '${entry}' must not be passed to the action."
        fi
    done
fi

# 8. The gate must re-run when a composite action changes: composite edits
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

if [ -d "${GITHUB_WORKSPACE%/}/.github/actions" ]; then
    # A later, ordered negation cancels an earlier inclusion, so the mere
    # presence of '.github/actions/**' is not enough: with a negation such as
    # `- '!.github/actions/**'` composite-only edits would no longer run the
    # gate while the positive-entry check still passed. Unrelated negations
    # (e.g. '!docs/**') are left alone.
    negated_composite_paths="$(grep -E '^!' "${gate_pr_paths}" | grep -F -- '.github/actions' || true)"
    if [ -n "${negated_composite_paths}" ]; then
        fail "${GATE_WORKFLOW} negates '.github/actions' under pull_request.paths ('${negated_composite_paths}'). That negation cancels the required trigger, so editing a composite action would no longer run the gate; remove the negated entry."
    fi
    if ! grep -Fxq -- '.github/actions/**' "${gate_pr_paths}"; then
        fail "${GATE_WORKFLOW} must list '.github/actions/**' under pull_request.paths: editing a composite action changes the pins recorded in ${LOCKFILE}, so the gate has to run on those edits."
    fi
fi

# 9. The gate must never silence the verifier outside a comment.
if grep -Eq -- '--ignore[-_]local[-_]actions' "${gate_stripped}"; then
    fail "${GATE_WORKFLOW} enables silencing the verifier outside a comment with the '--ignore-local-actions' CLI flag. Remove it so the gate actually blocks unverifiable local composite actions."
fi

# Quoted values are unwrapped so that `ignore-local-actions: 'true'` and
# `ignore-local-actions: "yes"` are caught, while false/no/off/0 pass.
gate_unquoted="${tmp_dir}/gate.unquoted"
sed -E "s/[\"']//g" "${gate_stripped}" > "${gate_unquoted}"
if grep -Eiq -- 'ignore[-_]local[-_]actions:[[:space:]]*(true|yes|on|1)([[:space:]]|$)' "${gate_unquoted}"; then
    fail "${GATE_WORKFLOW} enables silencing the verifier by setting the 'ignore-local-actions' input to a truthy value. Set it to false or remove it so the gate blocks unverifiable local composite actions."
fi

onboarded="$(wc -l < "${gate_list}" | tr -d ' ')"
echo "gate-coverage: OK: ${onboarded} onboarded workflows; gate, action input, and lockfile agree"
