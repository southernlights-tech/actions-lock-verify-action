# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- Coverage check that runs before any network call: the caller's gate `workflows:`
  input, the `workflows:` input passed to the action, and `actions.lock`'s
  `workflows:` keys must agree as sets in both directions; every listed path must
  exist; no `excluded-workflows` entry may appear in any list; `.github/actions/**`
  must be in the gate's `pull_request.paths` when the repository has composites;
  and the gate may never silence the verifier (CLI flag or YAML input, comments
  excepted). New inputs: `gate-workflow`, `excluded-workflows`, `check-gate-coverage`.
- The coverage check accepts the `workflows:` input quoted or unquoted, and
  rejects an ordered negation that cancels `.github/actions/**` in the gate's
  `pull_request.paths`.
- `tests/gate-coverage.bats` covering each assertion and its failure mode.

### Deprecated

- `ignore-local-actions`: it silences the verifier while the runner still enforces
  the lockfile at job start, so jobs fail with `lockfile missing pin for <action>`.
  The action now emits a warning when it is set. Use `$/...` composite references
  instead. Scheduled for removal in the next major version.

## [1.1.0]

See the [`v1.1.0` tag](https://github.com/southernlights-tech/actions-lock-verify-action/releases/tag/v1.1.0).
