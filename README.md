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
          workflows: .github/workflows/release.yml .github/workflows/build.yml
```

The caller owns the `pull_request` trigger and the explicit onboarded-path list.
The token defaults to the workflow's `GITHUB_TOKEN`; pass `token:` only to use a
different credential.

## Inputs

| Input | Required | Default | Description |
| --- | --- | --- | --- |
| `workflows` | yes | - | Space-separated list of workflow paths to verify. |
| `extension-pin` | no | `v0.4.0` | Pinned version of `github/gh-actions-lock`. |
| `ignore-local-actions` | no | `false` | Pass `--ignore-local-actions` so workflows that call same-repo composite actions (`uses: ./…`) are kept as warnings instead of blocking the verify. |
| `token` | no | `github.token` | Token used by the `gh` CLI. |

## Onboarding and governance

- **Onboard one workflow at a time, by explicit path.** Never run the extension
  bare (`gh actions-lock` with no path): that onboards every workflow at once.
- **Add the newly onboarded path to the caller's `workflows` list in the same
  pull request**, so the gate covers it from the moment it is onboarded.
- **Never hand-edit the lockfile.** It is machine-generated; fix the workflow
  files and regenerate.
- **A lockfile change decides which commit executes**, so it is a
  code-execution change and must be reviewed by a human.
- **Do not name a lockfile-change branch `dependabot/*`** -- a Dependabot merge
  train will auto-approve and auto-merge those.
- Reference: <https://gh.io/actions-lockfile>

## Why the explicit path list

A repo-wide `gh actions-lock --verify` exits non-zero until every workflow is
onboarded, which would leave a permanently red gate. The list is therefore
explicit and per-onboarded-workflow, so the gate is green only for the workflows
a repo has actually onboarded.

## Local composite actions

`gh-actions-lock` cannot follow or lock a same-repo composite action
(`uses: ./.github/actions/...`): the action runs whatever is in the workspace.
From `v0.3.0` such a reference blocks `--verify` by default. Pass
`ignore-local-actions: true` to keep it as a non-failing warning, so a workflow
that calls a local composite can still be onboarded.

The extension's default is to block, because a local action is outside the
lockfile's guarantee. Enable the input only where the workflow genuinely needs
the local composite; prefer moving shared logic into a published action when
the supply-chain guarantee matters.

## Why a composite action

The action runs inside the caller's job, so `runs-on`, `permissions`, and the
self-hosted runner stay in the consuming repo. The reusable gate ships only the
verification logic, not the runner or permission model.

## Runner assumptions

`gh extension install` is not idempotent: it errors when the extension is
already present. This action therefore assumes an **ephemeral** runner, where
every job starts clean (GitHub-hosted runners, or autoscaled pods such as an ARC
`self-hosted` pool). On a long-lived self-hosted runner, clear the extension
between runs (`gh extension remove gh-actions-lock`) or run the job in a
container.

## Development

Run the behavioral tests:

```bash
docker run --rm -v "$PWD":/code -w /code bats/bats:latest tests/
```

Lint the script:

```bash
shellcheck scripts/verify-actions-lock.sh
```
