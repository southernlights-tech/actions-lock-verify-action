# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- Coverage check that runs before any network call: the `workflows:` value the
  action receives and `actions.lock`'s `workflows:` keys must agree as sets in
  both directions; every listed path must exist; no `excluded-workflows` entry
  may appear in any list; `.github/actions/**` must be in the gate's
  `pull_request.paths` when the repository has composites; and the gate may
  never silence the verifier (resolved input, CLI flag or YAML input, comments
  excepted). New inputs: `gate-workflow`, `excluded-workflows`,
  `check-gate-coverage`.
- The coverage check takes the `workflows:` list from the action input verbatim
  instead of re-parsing the gate YAML, and rejects an ordered negation that
  cancels `.github/actions/**` in the gate's `pull_request.paths`, including
  ancestor globs such as `!.github/**`.
- `tests/gate-coverage.bats` covering each assertion and its failure mode.

### Fixed

- The coverage check no longer parses the gate YAML for the `workflows:` list: a
  `workflow_run: workflows: [...]` trigger is no longer counted as a duplicate
  action input.
- Negations that could cancel `.github/actions`, including ancestor globs such as
  `!.github/**` and brace sets whose overlap cannot be ruled out, are rejected.
- A truthy **resolved** `ignore-local-actions` input (for example
  `${{ true }}`) now fails the check.

### Deprecated

- `ignore-local-actions`: it silences the verifier while the runner still enforces
  the lockfile at job start, so jobs fail with `lockfile missing pin for <action>`.
  The action now emits a warning when it is set. Use `$/...` composite references
  instead. Scheduled for removal in the next major version.

## [1.1.0]

See the [`v1.1.0` tag](https://github.com/southernlights-tech/actions-lock-verify-action/releases/tag/v1.1.0).
