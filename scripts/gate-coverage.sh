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
#   * The gate's action input must appear exactly once, in the canonical form
#         workflows: "<space-separated list>"
#     Any leading indentation is allowed, but the double quotes are required.
#   * The lockfile's workflow keys live in the top-level `workflows:` map and
#     end at the top-level `dependencies:` map. A workflow with no remote
#     actions is written as `    'path': []`, so the key pattern accepts an
#     optional trailing ` []`; matching only `':` would silently drop those
#     keys and make every later comparison wrong.
#   * Set comparisons are order-insensitive: each list is split to one path
#     per line and `sort -u`d before `comm` runs in both directions.
#   * The `ignore[-_]local[-_]actions` assertion strips comments first
#     (`sed 's/#.*//'`), so a comment that merely mentions the flag does not
#     trip the guard, while both the CLI flag (`--ignore-local-actions`) and
#     the YAML input key (`ignore-local-actions: true`) do.
#   * The `.github/actions/**` path-filter assertion is conditional: it only
#     applies when the workspace has a `.github/actions` directory. A repo
#     with no composites cannot change a pin by editing one, so it is not
#     forced to carry a dead path filter; a repo with composites must trigger
#     on them. When the assertion does not apply it emits nothing.
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

# 3. The gate must declare exactly one workflow list, in the canonical form.
gate_input_count="$(grep -cE '^[[:space:]]*workflows:[[:space:]]*"' "${gate_stripped}" || true)"
case "${gate_input_count}" in
    0)
        fail "${GATE_WORKFLOW} declares no workflow list. Expected exactly one input in the form: workflows: \"<space-separated list>\" (double quotes required)."
        ;;
    1) ;;
    *)
        fail "${GATE_WORKFLOW} declares ${gate_input_count} 'workflows:' inputs; expected exactly one (the action input)."
        ;;
esac

gate_workflows_raw="$(grep -E '^[[:space:]]*workflows:[[:space:]]*"' "${gate_stripped}" \
    | sed -E 's/^[[:space:]]*workflows:[[:space:]]*"([^"]*)".*/\1/')"
printf '%s\n' "${gate_workflows_raw}" | split_list > "${gate_list}"

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
        if (indent <= paths_indent) { state = 0; next }
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
    if ! grep -Fxq -- '.github/actions/**' "${gate_pr_paths}"; then
        fail "${GATE_WORKFLOW} must list '.github/actions/**' under pull_request.paths: editing a composite action changes the pins recorded in ${LOCKFILE}, so the gate has to run on those edits."
    fi
fi

# 9. The gate must never silence the verifier outside a comment.
if grep -Eiq -- 'ignore[-_]local[-_]actions' "${gate_stripped}"; then
    fail "${GATE_WORKFLOW} turns the verifier off outside a comment ('--ignore-local-actions' / 'ignore-local-actions: true'). Remove it so the gate actually blocks unverifiable local composite actions."
fi

onboarded="$(wc -l < "${gate_list}" | tr -d ' ')"
echo "gate-coverage: OK: ${onboarded} onboarded workflows; gate, action input, and lockfile agree"
