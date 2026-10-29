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
| `gate-workflow` | no | `.github/workflows/actions-lock-verify.yaml` | Path to the caller's lockfile gate workflow. The coverage check compares it against `workflows` and the lockfile. Override if your gate file has another name. |
| `excluded-workflows` | no | empty | Space-separated paths deliberately kept out of the lockfile and the gate. The coverage check asserts none of them appear in any of the three lists. |
| `check-gate-coverage` | no | `true` | Assert that the caller's gate workflow and `actions.lock` agree before verifying. Escape hatch for non-standard gates; not recommended. |
| `extension-pin` | no | `v0.4.0` | Pinned version of `github/gh-actions-lock`. |
| `ignore-local-actions` | no | `false` | **DEPRECATED.** Silences the verifier while the runner still enforces the lockfile at job start, so jobs then fail with `lockfile missing pin for <action>`. Reference same-repo composites as `$/...` instead. Emits a warning when set; scheduled for removal in the next major version. |
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

## Coverage check

Before any network call, the action asserts that the two descriptions of "what
is onboarded" agree, so a gate cannot be green for a set of workflows nobody
declared:

- The `workflows:` value the action **receives** and the `workflows:` keys in
  `actions.lock` must agree **as sets in both directions**. A path in one list
  but not the other fails, and the error names the path and the list it is
  missing from. The caller's YAML is **not** parsed for that value: the resolved
  action input is compared directly, so a second `workflows:` key in the same
  file (such as a `workflow_run: workflows: [Build]` trigger) is irrelevant.
- Every listed path must exist in the workspace.
- No `excluded-workflows` entry may appear in any list.
- **When the repository has composites**, the gate's ordered `pull_request.paths`
  filter is **evaluated** against every composite action file
  (`.github/actions/**/action.yml` and `action.yaml`), the way GitHub applies it:
  entries in order, the last matching entry wins, and a leading `!` re-excludes.
  The check fails if any composite file would be excluded, so a descendant
  exclusion (`- '!.github/actions/example/**'`) or a wildcard exclusion
  (`- '!.github/*/**'`) is caught exactly like an ancestor one
  (`- '!.github/**'`), even when a positive `- '.github/actions/**'` entry is
  present. Unrelated negations such as `- '!docs/**'` pass. Path patterns are
  evaluated with GitHub's documented semantics, including `?` (zero-or-one) and
  `+` (one-or-more) as **quantifiers on the preceding character** rather than
  character classes; patterns the check cannot model — brace sets (`{`/`}`),
  character classes (`[`/`]`), or a `?`/`+` with no single preceding character
  to quantify — fail conservatively with a "cannot be evaluated" error instead
  of a false OK. A repo without a `.github/actions` directory is not forced to
  carry a dead path filter.
- The gate may never silence the verifier. A truthy **resolved**
  `ignore-local-actions` input fails the check — which is what catches
  `ignore-local-actions: ${{ true }}` and values supplied through variables,
  since the resolved value is what matters. The `--ignore-local-actions` CLI
  flag and a truthy literal input (`true`/`yes`/`on`/`1`, quoted or unquoted)
  also fail. An explicit `ignore-local-actions: false` keeps verification on and
  is accepted. Comments that merely mention the flag are ignored.
- The `workflows:` input may be a multi-line `workflows: |` block scalar (one
  path per line). Both this check and `verify-actions-lock.sh` normalise the
  same value identically — all whitespace collapsed, then split — so a block
  scalar is fully honoured and can never be silently truncated to its first
  line.

The check reads only `sed`/`grep`/`awk`/coreutils, so it needs no extra tooling.
Set `check-gate-coverage: false` to skip it for a non-standard gate; the verifier
itself still runs.

## Same-repo composite actions

`gh-actions-lock` cannot lock a `uses: ./.github/actions/...` reference: the
reference resolves against the runner workspace, so the verifier can see the
files but has no commit to record pins against.

Reference same-repo composites as `$/...` instead. A `$/...` reference runs at
the workflow's own commit, so the lockfile can record the actions inside the
composite, including nested chains of composites.

`--ignore-local-actions` (and the `ignore-local-actions: true` input) is **not**
a fix. It only silences the verifier; the GitHub Actions runner still enforces
the lockfile when the job starts, so the job fails with
`lockfile missing pin for <action>`. The action now emits a deprecation warning
whenever the input is used, and the input is scheduled for removal in the next
major version.

## Upgrade note for v1.2.0

Consumers upgrading to v1.2.0 must:

1. **Bump the `uses:` ref** to the new version.
2. **Re-run `gh actions-lock <paths>`** so the lockfile records the new ref — a
   lockfile change decides which commit executes, so this is a code-execution
   change and must be reviewed.
3. **Confirm the gate file is named `actions-lock-verify.yaml`**, or set
   `gate-workflow:` to its actual path, since the coverage check reads that file.

If your gate genuinely cannot follow the standard shape, set
`check-gate-coverage: false` to skip the check. That is an escape hatch, not a
recommendation: it gives up the guarantee that the gate covers what the lockfile
locks.

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

Lint the scripts:

```bash
shellcheck scripts/verify-actions-lock.sh scripts/gate-coverage.sh
```
