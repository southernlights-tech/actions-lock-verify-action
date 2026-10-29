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
#   * Composite coverage is decided by EVALUATING the gate's ordered
#     `pull_request.paths` filter, not by pattern-matching it. Every composite
#     action file in the workspace (`action.yml` / `action.yaml` under
#     `.github/actions`) is run through the filter the way GitHub applies it:
#     entries in order, the last matching entry wins, and a leading `!`
#     re-excludes. Coverage fails if any composite file would be excluded, so
#     a descendant (`!.github/actions/example/**`) or wildcard
#     (`!.github/*/**`) exclusion is caught exactly like an ancestor one
#     (`!.github/**`). Patterns are read with GitHub's documented path-pattern
#     semantics, which means `*` is "any characters except `/`", `**` is "any
#     characters including `/`", and `?` / `+` are regex QUANTIFIERS on the
#     preceding character (zero-or-one and one-or-more respectively) rather than
#     character classes. Patterns the evaluator cannot model (`{`, `[`, `]`,
#     i.e. brace sets and character classes, or a `?`/`+` with no single
#     preceding character) fail conservatively. The assertion is conditional: a
#     repo with no `.github/actions` directory is not forced to carry a dead
#     path filter, and emits nothing.
#   * WORKFLOWS is split on ANY whitespace here. A multi-line `workflows: |`
#     block scalar is therefore fully honoured. `scripts/verify-actions-lock.sh`
#     normalises the same variable identically (collapse whitespace, then
#     split) on purpose: the two steps must never disagree about which paths
#     were declared, and neither may silently truncate a block scalar to its
#     first line.
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
#
#    Coverage is decided by EVALUATING the ordered filter (see
#    filter_includes_path), not by pattern-matching entries: only that catches
#    descendant and wildcard negations, where a positive '.github/actions/**'
#    is present but a later, narrower exclusion removes the composites.
gate_pr_paths="${tmp_dir}/gate.pr-paths"
# Sequence collection below is unchanged; the state-2 exit condition only has
# to terminate the `paths:` block (dedent, or a non-'-' key at the same
# indentation), which is why same-indent `- ` items are also accepted.
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

# Sentinel printed by gha_path_pattern_to_regex for a pattern whose GitHub
# semantics the evaluator cannot reproduce. Every caller MUST treat it as
# "cannot be evaluated" and fail conservatively: an unevaluable pattern that is
# silently accepted is a false green, the one direction this check must never
# fail in.
UNEVALUABLE='UNEVALUABLE'

# Translate one GitHub Actions path-filter glob into an anchored bash ERE.
# Semantics modelled (GitHub's documented path-pattern semantics):
#   `**/`  zero or more characters, including '/' (a whole directory prefix)
#   `**`   zero or more of any character, including '/'
#   `*`    zero or more characters, but not '/'
#   `?`    zero or ONE of the preceding character
#   `+`    one or more of the preceding character
#   `\X`   the character X taken literally ('\.' is a dot, '\*' a literal '*')
# `?` and `+` are therefore regex QUANTIFIERS applied to the previous
# character, not character classes. A quantifier with no well-defined operand
# (start of pattern, after a '/', or after a `*`/`**` token whose expansion is
# not a single character) cannot be modelled, and neither can brace sets
# (`{`/`}`) or character classes (`[`/`]`): all of them print UNEVALUABLE so the
# caller fails conservatively through one shared message. Every other regex
# metacharacter is escaped.
gha_path_pattern_to_regex() {
    local pattern="${1}"
    # A leading './' is redundant in a repo-relative path filter.
    pattern="${pattern#./}"
    local out='' i=0 c next next2
    while (( i < ${#pattern} )); do
        c="${pattern:i:1}"
        next="${pattern:i+1:1}"
        if [ "${c}" = '*' ]; then
            if [ "${next}" = '*' ]; then
                next2="${pattern:i+2:1}"
                if [ "${next2}" = '/' ]; then
                    out+='(.*/)?'
                    i=$(( i + 3 ))
                else
                    out+='.*'
                    i=$(( i + 2 ))
                fi
            else
                out+='[^/]*'
                i=$(( i + 1 ))
            fi
        elif [ "${c}" = '?' ] || [ "${c}" = '+' ]; then
            # A quantifier needs exactly one preceding character to repeat.
            # Anything else (nothing emitted yet, a segment boundary, a
            # wildcard token, or a quantifier stacked on a quantifier) leaves
            # the operand undefined, so the pattern is not evaluable.
            case "${out}" in
                '' | *'/' | *'[^/]*' | *'.*' | *'(.*/)?' | *'?' | *'+')
                    printf '%s\n' "${UNEVALUABLE}"
                    return 0
                    ;;
            esac
            out+="${c}"
            i=$(( i + 1 ))
        else
            if [ "${c}" = "\\" ]; then
                # GitHub reads '\' as escaping the NEXT character, which then
                # stands for itself rather than its special meaning: '\.' is a
                # literal dot (not a backslash plus any char) and '\*' is a
                # literal asterisk (not a wildcard). Emitting a raw '\\' here
                # made every escaped-character exclusion unmatchable, so an
                # escaped exclusion was invisible and the check reported OK:
                # a false green. The escape set therefore covers every ERE
                # metacharacter, including '[', ']', '{' and '}': emitting a
                # BARE '[' or '{' produced an INVALID ERE, `[[ =~ ]]` returned
                # 2, and the caller read that as "does not match" - another
                # false green. A trailing backslash escapes nothing, so the
                # pattern has no defined meaning; that case also fails
                # conservatively through the shared unevaluable path.
                if [ -z "${next}" ]; then
                    printf '%s\n' "${UNEVALUABLE}"
                    return 0
                fi
                if [ "${next}" = "\\" ]; then
                    # A literal backslash in the matched text.
                    out+="\\\\"
                else
                    case "${next}" in
                        '.' | '^' | '$' | '+' | '(' | ')' | '|' | '*' | '?' | '[' | ']' | '{' | '}')
                            out+="\\${next}"
                            ;;
                        *)
                            out+="${next}"
                            ;;
                    esac
                fi
                i=$(( i + 2 ))
                continue
            fi
            case "${c}" in
                '{' | '}' | '[' | ']')
                    printf '%s\n' "${UNEVALUABLE}"
                    return 0
                    ;;
                '.' | '^' | '$' | '(' | ')' | '|')
                    out+="\\${c}"
                    ;;
                *)
                    out+="${c}"
                    ;;
            esac
            i=$(( i + 1 ))
        fi
    done
    printf '^%s$\n' "${out}"
}

# The single failure message for every pattern the evaluator cannot model, so
# brace sets, character classes and operand-less (or operand-ambiguous)
# `?`/`+` quantifiers all fail identically.
fail_unevaluable() {
    local entry="${1}"
    fail "${GATE_WORKFLOW} has a pull_request.paths pattern that cannot be evaluated: '${entry}'. Brace sets ('{', '}'), character classes ('[', ']'), and a '?' or '+' quantifier without a single preceding character to quantify are not modelled by the coverage check, so it cannot prove that composite actions still trigger the gate; rewrite the filter using only '**', '*', literal paths, and '?'/'+' placed directly after a literal character."
}

# Returns 0 on match, 1 on no match, and fails the run on an invalid regex
# rather than silently treating it as "no match" (a false green). `[[ =~ ]]`
# exits 2 when the generated ERE does not compile, which an `if` would read as
# ordinary false, so the exit status is captured explicitly.
path_matches_regex() {
    local path="${1}" regex="${2}" entry="${3}" rc=0
    # The condition's own exit status is exactly what we need here: 0 match,
    # 1 no match, 2 invalid regex. SC2319 is about `$?` being clobbered by a
    # later command, which cannot happen in this `||` list.
    # shellcheck disable=SC2319
    [[ "${path}" =~ ${regex} ]] || rc=$?
    if (( rc == 2 )); then
        fail_unevaluable "${entry}"
    fi
    return "${rc}"
}

# Does the ordered path filter include <path>? Entries are applied in order,
# exactly as GitHub applies `pull_request.paths`: a leading `!` excludes, and
# the LAST matching entry decides. Returns 0 when the path is included.
filter_includes_path() {
    local path="${1}"
    shift
    local included=0
    local entry pattern regex negated
    if (( $# == 0 )); then
        return 1
    fi
    for entry in "$@"; do
        negated=0
        pattern="${entry}"
        if [ "${entry}" != "${entry#!}" ]; then
            negated=1
            pattern="${entry#!}"
        fi
        regex="$(gha_path_pattern_to_regex "${pattern}")"
        # Defensive: an unevaluable pattern must never be treated as a
        # non-match, so fail rather than guess.
        if [ "${regex}" = "${UNEVALUABLE}" ]; then
            fail_unevaluable "${entry}"
        fi
        # Covers both the including and the negated branch: a regex that does
        # not compile must fail the run, never count as "no match".
        if path_matches_regex "${path}" "${regex}" "${entry}"; then
            if (( negated )); then
                included=0
            else
                included=1
            fi
        fi
    done
    (( included ))
}

if [ -d "${GITHUB_WORKSPACE%/}/.github/actions" ]; then
    # The filter is read once into an ordered array: the gate must trigger on
    # EVERY composite action file, so the check evaluates this list per path.
    gate_entries=()
    while IFS= read -r entry; do
        if [ -n "${entry}" ]; then
            gate_entries+=("${entry}")
        fi
    done < "${gate_pr_paths}"

    # Patterns the evaluator cannot model (brace sets, character classes, and
    # operand-less or operand-ambiguous '?'/'+' quantifiers) are detected by the
    # translator itself, so this scan and the evaluation below share one code
    # path and one message. Coverage cannot be proven for them, so fail
    # conservatively rather than claim the gate is safe.
    for entry in "${gate_entries[@]}"; do
        if [ "$(gha_path_pattern_to_regex "${entry#!}")" = "${UNEVALUABLE}" ]; then
            fail_unevaluable "${entry}"
        fi
    done

    # Representative paths: every composite action file in the workspace, or a
    # synthetic one when the directory exists but holds no action file (that
    # still proves the trigger is reachable, and the message names the shape).
    composite_paths=()
    while IFS= read -r composite_abs; do
        if [ -n "${composite_abs}" ]; then
            composite_paths+=("${composite_abs#"${GITHUB_WORKSPACE%/}/"}")
        fi
    done < <(find "${GITHUB_WORKSPACE%/}/.github/actions" -type f \
        \( -name action.yml -o -name action.yaml \) | LC_ALL=C sort)
    if (( ${#composite_paths[@]} == 0 )); then
        composite_paths=('.github/actions/example/action.yml')
    fi

    for composite_path in "${composite_paths[@]}"; do
        if filter_includes_path "${composite_path}" "${gate_entries[@]}"; then
            continue
        fi
        excluding=()
        for entry in "${gate_entries[@]}"; do
            if [ "${entry}" = "${entry#!}" ]; then
                continue
            fi
            entry_regex="$(gha_path_pattern_to_regex "${entry#!}")"
            if [ "${entry_regex}" = "${UNEVALUABLE}" ]; then
                fail_unevaluable "${entry}"
            fi
            if path_matches_regex "${composite_path}" "${entry_regex}" "${entry}"; then
                excluding+=("${entry}")
            fi
        done
        if (( ${#excluding[@]} == 0 )); then
            detail="no entry in pull_request.paths matches it at all"
        else
            detail="it is excluded by ${excluding[*]}"
        fi
        fail "${GATE_WORKFLOW}'s ordered pull_request.paths filter does not run the gate when '${composite_path}' changes, because ${detail}. That cancels the required composite trigger: composite-internal pins live in ${LOCKFILE}, so an excluded composite means those pins can change without the gate running. Every composite action file must still match the filter after negation is applied: remove or narrow the negated entry, or add a later entry that re-includes the composite path."
    done
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
