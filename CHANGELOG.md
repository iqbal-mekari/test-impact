# Changelog

## 0.0.1

First standalone release.

- `select`, `validate`, `run`, `index`, `ci` commands.
- Per-package `test_impact.yaml` mappings with JSON Schema
  (`schema/test_impact.schema.json`).
- Declaration-index refinement (`--precision file`) and changed-line
  coverage (`run --coverage`).
- Bundled test runner and lcov tooling.
- Consumer-specific bundle policy is no longer shipped; point
  `tooling.bundle_policy` at a file in your own repo.
