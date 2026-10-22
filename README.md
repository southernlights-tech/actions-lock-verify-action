# actions-lock-verify-action

A composite action that installs the pinned `github/gh-actions-lock` extension
and verifies that the listed onboarded workflow paths are locked and current, so
a moved tag cannot change which commit executes.

## Usage

```yaml
name: Actions lockfile verify
on:
  pull_request:
    paths:
      - '.github/workflows/actions.lock'
      - '.github/workflows/**'
permissions:
  contents: read
jobs:
  verify-lockfile:
    runs-on: self-hosted-arm64
    timeout-minutes: 10
    steps:
      - uses: actions/checkout@v7
      - uses: southernlights-tech/actions-lock-verify-action@v1
        with:
          workflows: .github/workflows/deploy-prod.yml .github/workflows/deploy-prod.reusable.yaml
        env:
          GH_TOKEN: ${{ secrets.GITHUB_TOKEN }}
```

The caller owns the `pull_request` trigger and the explicit onboarded-path list,
and `GH_TOKEN` must be supplied by the caller (e.g. job-level
`GH_TOKEN: ${{ secrets.GITHUB_TOKEN }}`).

## Inputs

| Input | Required | Default | Description |
| --- | --- | --- | --- |
| `workflows` | yes | — | Space-separated list of workflow paths to verify. |
| `extension-pin` | no | `v0.2.0` | Pinned version of `github/gh-actions-lock`. |

## Why the explicit path list

A repo-wide `gh actions-lock --verify` exits non-zero until every workflow is
onboarded, which would leave a permanently red gate. The list is therefore
explicit and per-onboarded-workflow, so the gate is green only for the workflows
a repo has actually onboarded.

## Why a composite action

The action runs inside the caller's job, so `runs-on`, `permissions`, and the
self-hosted runner stay in the consuming repo. The reusable gate ships only the
verification logic, not the runner or permission model.

## Development

Run the behavioral tests:

```bash
docker run --rm -v "$PWD":/code -w /code bats/bats:latest tests/
```

Lint the script:

```bash
shellcheck scripts/verify-actions-lock.sh
```
