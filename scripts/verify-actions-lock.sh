#!/usr/bin/env bash
# scripts/verify-actions-lock.sh
#
# Installs the pinned github/gh-actions-lock extension and verifies that the
# given onboarded workflow paths are locked and current. Intended to be run by
# the composite action (action.yml) inside a caller's job.
#
# Required env:
#   WORKFLOWS      space-separated list of workflow paths to verify (>= 1)
# Optional env:
#   EXTENSION_PIN          github/gh-actions-lock version (default v0.4.0)
#   IGNORE_LOCAL_ACTIONS   "true" to pass --ignore-local-actions, keeping
#                          same-repo composite actions (uses: ./…) as warnings
#                          instead of blocking the verify. Default false.
#   GH_TOKEN               authenticated gh CLI token (the action passes the
#                          workflow token by default; see action.yml)
set -euo pipefail

EXTENSION_PIN="${EXTENSION_PIN:-v0.4.0}"
WORKFLOWS="${WORKFLOWS:?WORKFLOWS must be set (space-separated workflow paths)}"
IGNORE_LOCAL_ACTIONS="${IGNORE_LOCAL_ACTIONS:-false}"

read -r -a paths <<< "${WORKFLOWS}"
if (( ${#paths[@]} == 0 )); then
  echo "::error::verify-actions-lock: WORKFLOWS is empty; nothing to verify." >&2
  exit 1
fi

echo "Installing gh-actions-lock ${EXTENSION_PIN}..."
gh extension install github/gh-actions-lock --pin "${EXTENSION_PIN}"

verify_args=(--verify)
if [ "${IGNORE_LOCAL_ACTIONS}" = "true" ]; then
  verify_args+=(--ignore-local-actions)
fi

echo "Verifying lockfile for: ${paths[*]}"
gh actions-lock "${verify_args[@]}" "${paths[@]}"
