# test_impact

Pure-Dart CLI that maps a git diff to the minimal set of unit tests, using one
hand-maintained `test_impact.yaml` per package. The rules are explicit,
validated, and fail safe to "run everything". It also ships coverage
tooling (test bundling, lcov filtering); see "Bundling and lcov commands".

## Install

Pin a release tag and activate it as a global tool, isolated from your
app's dependency graph (the exact `analyzer` pin would otherwise clash):

```bash
dart pub global activate --source git \
  https://github.com/iqbal-mekari/test-impact.git --git-ref v0.0.1
dart pub global run test_impact --help
```

Run every command from the workspace (git) root.

## Mapping file (`<package>/test_impact.yaml`)

Editor validation: `schema/test_impact.schema.json`.

```yaml
# yaml-language-server: $schema=https://raw.githubusercontent.com/iqbal-mekari/test-impact/v0.0.1/schema/test_impact.schema.json
version: 1
package: my_feature            # must equal pubspec `name`
repo:                          # ROOT file only, repo-relative globs
  safe:    ["**/*.md", "assets/**", "**/assets.gen.dart"]  # no tests
  run_all: ["melos.yaml", "**/pubspec.yaml", "**/pubspec.lock"]  # all, full
  runtime_tests:               # files tests READ at runtime (not imported)
    - paths:  ["integration_test/fixtures/mock/**"]
      except: ["**/*.g.dart"]  # optional
      tests:  ["test/mock/fixture_contract_test.dart"]  # repo-relative
run_all:     ["lib/configs/**"]  # this package + transitive dependents, full
run_package: ["build.yaml"]      # this package, full
conventions:                     # {area} binds exactly ONE path segment
  - sources: "lib/src/features/{area}/**"
    tests:   "test/src/features/{area}/**"
areas:                           # explicit; same name as a convention => merged
  payment:
    depends_on: [promo]          # change in promo ALSO runs payment (transitive)
    extra_tests: ["test/src/shared/payment_helper_test.dart"]
  networking:
    sources: ["lib/src/shared/networking/**"]
    tests:   ["test/src/shared/networking/**"]
```

Globs: `*` one segment, `**` any depth, `?` one char. Package-level globs are
package-relative. A package is managed iff it has `test_impact.yaml` next to
`pubspec.yaml`. Package dependents come from pubspec `path:` dependencies
(transitive).

## Resolution (per changed path; renames contribute old and new path)

Precedence: `repo.run_all` > `repo.runtime_tests` > `repo.safe` > package
rules. So any `pubspec.yaml` or `pubspec.lock` anywhere (including
`tools/**`, which is otherwise `safe`) selects ALL.

1. `repo.run_all` -> ALL packages, full.
2. `repo.runtime_tests` -> the listed tests are selected (each mapped to its
   owning package and package-relative path), IN ADDITION to whatever else
   the path matches below: a path may be both `safe` and a runtime trigger
   (the runtime match wins, so it is not ignored), or a lib file that also
   hits an area. Use it for files a test reads via `File`/`Directory`/
   `rootBundle`, which no import scan can see. `except` globs carve paths out
   of a rule. A listed test that does not exist runs its package fully
   (reason `runtime_test_missing`) and fails `validate` rule g.
3. `repo.safe` -> ignored.
4. No owning package (deepest package dir) -> ALL.
5. `<pkg>/test/**`: a `*_test.dart` selects itself (deleted: ignored); any other
   `.dart` file selects every test importing it transitively
   (import/export/part scan), none -> ignored; a non-Dart file (fixture, image)
   runs the package fully, since it is read at runtime, not imported.
6. Other package paths, first match wins: package `run_all` (package + all
   dependents full) -> `run_package` (package full) -> area (tests of the area
   and of every area that transitively `depends_on` it, including
   `extra_tests`; dependent packages run FULL at `--precision area`) ->
   unmapped (package + dependents full, reason `unmapped`).
7. Generated files (`*.g.dart`, ...) follow the same path rules.
8. Any config error, or a failing `git diff`, -> ALL.

`run_all`/`run_package` are checked before areas, so a file matching both runs
the larger set. Packages without `*_test.dart` files are never listed.

### Precision: `--precision area|file` (default `file`)

`area` is the v1 mapping only. `file` adds a declaration-level index (step 5,
area matches only): `package:analyzer` resolves every managed package and
builds a graph of top-level declarations (`file#name`) with one
`test:<file>` root per test. A changed lib file keeps only the candidate tests
whose closure reaches one of its declarations. This also narrows across
packages: dependent packages run the tests that reach the file instead of
their full suite. Files that declare nothing (barrels) use the file-level
import/export/part graph.

The mapping stays the outer candidate set and stays authoritative: the index
only removes tests from it, never adds any, and a stale mapping still gives
wrong results. Keep `validate` green.

`analyzer` is pinned to an exact version (6.11.0 in
`pubspec.yaml`) because `index_builder.dart` imports analyzer
`src` APIs. Bump it deliberately and run the tool tests.

Reasons in `select` output for an area match:

- `refined`: narrowed by the index.
- `no_test_reaches`: no candidate test reaches the file. A legitimate empty
  result (for example an unused file), not a failure.
- `unrefined:<why>`: refinement not possible, the v1 candidates are kept and
  dependent packages run fully. `<why>` is one of `index_failed` (build
  crashed), `index_unavailable` (package has no
  `.dart_tool/package_config.json`), `deleted` (file no longer exists), `analysis_error` (library has analysis
  errors), `not_indexed`, `not_covered` (file outside the indexed packages).
- `area`: `--precision area`, or no index was needed.

Tests whose reach is unknown are kept for every change (wildcards). Every
package to index needs `.dart_tool/package_config.json`, so resolve
dependencies (`dart pub get`, `flutter pub get` or `melos bootstrap`) first.

## CLI

Run from the repo root:

```sh
test_impact select \
  --base origin/develop --head HEAD [--output sel.json]
test_impact select --changed-files list.txt
test_impact validate
test_impact run --base origin/develop --head HEAD
test_impact run --coverage \
  --base origin/develop --head HEAD
test_impact index --output idx.json
test_impact ci --coverage \
  --base origin/develop --head HEAD --output test-impact.json
```

`ci` = `validate` + `select` + `run` with ONE declaration-index build (the
index covers every area package plus what the selection needs). Options: the
`select`/`run` ones (`--base`, `--head`, `--changed-files`, `--precision`,
`--output`, `--coverage`, `--coverage-json`, `--coverage-md`). Exit codes:
0 ok; 1 validation violations (tests are not run) or failing tests; 2
config/environment (invalid mapping, index unavailable, usage). Phase
timings (`index_ms`, `validate_ms`, `select_ms`, `run_ms`) go to stderr and
under `timings` in the `--output` JSON (written before the run, rewritten
with `run_ms` after it). No selection file is written on validation failure.

`select` and `run` take `--precision area|file`. `index` is a debug command: it
builds the full index and prints per-test closure sizes, wildcard tests,
unavailable and tainted files (`--output` writes that JSON; exit 1 if the
build failed).

Exit codes: 0 ok, 1 test/validation failure, 2 usage or config error
(`validate` exits 2 on unparsable mappings or when rule f cannot build the
index; `select`/`run` fail safe to ALL).
`--changed-files` takes one path per line (a `git --name-status` style leading
status column is tolerated). The diff is `git diff --name-status -M base...head`.

`select` output:

```json
{
  "mode": "selected",
  "packages": {
    "packages/my_feature": {"mode": "selected", "tests": ["test/src/a_test.dart"]},
    ".": {"mode": "full", "tests": []}
  },
  "reasons": [{"path": "packages/my_feature/lib/...", "rule": "area", "detail": "..."}]
}
```

`mode` is `none` | `selected` | `all`; per package `full` | `selected`; test
paths are package-relative. Rules: `safe`, `repo_run_all`, `runtime_test`, `runtime_test_missing`,
`no_package`,
`test`, `test_deleted`, `test_helper`, `test_helper_unused`, `pkg_run_all`,
`pkg_run_package`, `area`, `refined`, `no_test_reaches`, `unrefined:<why>`,
`unmapped`, `config_error`, `diff_error`.

### `validate` rules

a. lib file owned by no area / `run_all` / `run_package`; b. lib file owned by
more than one explicit area; c. `*_test.dart` not covered by any area
`tests`/`extra_tests` or package `run_*` glob; d. dead glob (matches no file;
`repo.*` globs are not checked); e. `depends_on` unknown or self; g. a test
listed in `repo.runtime_tests` does not exist; f. undeclared
cross-area dependency inside one package: a top-level declaration in a lib file
of area A references (resolved by the declaration index) a declaration in a lib
file of area B without `A depends_on B`, directly or transitively. Imports and
barrels (including a package importing its own barrel) are irrelevant; files
without an area (`run_all`/`run_package`) are ignored. One violation per
(package, A, B) with an example `file#decl -> file#decl`.

Rule f builds the index for every package with areas, so `validate` needs
`.dart_tool/package_config.json` in each package (pub get) and takes about
1-2 minutes; the build time is printed to stderr. A package the index cannot
cover is reported as `rule f: index unavailable: <why>` and `validate` exits
2. Libraries with analysis errors are skipped for rule f with a warning on
stderr (not a failure).

### `run`

`full` -> plain `<flutter_command> test --no-pub` in the package.
`selected` -> the same bundler as `bundle test` (see "Coverage bundling"),
with the selected files as explicit input: the bundleable files compile once
as a generated `<pkg>/test/flutter_test_bundle.g.dart` (`group('<path>',
tN.main)` per test, deleted afterwards, listed in `.gitignore`, never
commit it). Files that cannot share the bundle run in a second process:
async `main`, `main(args)`, file-level `@TestOn/@Tags/@Timeout/@Skip`, a
`flutter_test_config.dart`, and anything matching `tooling.isolation_patterns`
directly or via a relative helper (unless the bundle policy marks it
`bundle_safe`). A red bundle is re-run unbundled before it is reported, so
bundling can cost time but never gives a false red. One selected file runs
directly. `FLUTTER_TEST_BUNDLE=0` turns bundling off. Remaining limitation:
bundled tests share one isolate, so other leaks (statics, pending timers) can
cross files; use `bundle verify` to confirm and add the file to the policy.

### `run --coverage`

Runs the selected tests with coverage and reports coverage of the changed
lines (from `git diff -U0 base...head`) only. Options: `--coverage-json`
(default `test-impact-coverage.json`), `--coverage-md` (default
`test-impact-coverage.md`). Changed files absent from lcov are listed as
`not_loaded` (no test loaded them) and count as uncovered. Report-only: it
never changes the exit code. Needs `--base`; without it the report notes that
changed lines are unavailable.

## CI

A typical CI step fetches the base branch, resolves dependencies, runs
codegen and `flutter analyze`, then diffs `origin/<BASE_BRANCH>...HEAD`:

```sh
test_impact ci --coverage \
  --base "origin/$BASE_BRANCH" --head HEAD --output test-impact.json
```

`ci` runs `validate`, `select` and `run --coverage` with a single analyzer
index build shared by all three phases.

Artifacts: `test-impact.json`, `test-impact-coverage.json`,
`test-impact-coverage.md`. The base ref must be fetched (not a shallow clone
without it); otherwise the diff fails and everything runs.

Cost: the index build scales with workspace size (about 1-2 minutes on a
large multi-package Flutter app). There is no cache yet.

## Bundling and lcov commands

`run` uses the same bundler. The commands are also available on their own
for local runs or for a project's own coverage scripts.

```sh
test_impact bundle test --target test/ --coverage-path coverage/lcov.info
test_impact bundle audit [--strict]
test_impact bundle verify [--out-dir dir]
test_impact lcov filter <input> <output> [glob...]
```

All `bundle` commands take `--package-root` (default `.`), `--repo-root`,
`--package-key` (policy key, default the repo-relative root) and `--policy`
(default `tooling.bundle_policy`); `bundle test` and `verify` also take
`--flutter <path>` (wins over `tooling.flutter_command`).

- `bundle test`: compiles the bundleable tests once, runs isolated files in a
  second process, re-runs a red bundle unbundled, and sums coverage into
  `--coverage-path`. With `FLUTTER_TEST_BUNDLE=0` (or any value other than
  `1`) it runs plain `flutter test --coverage`. Exit 1 if the report is
  missing.
- `bundle audit`: lists bundled and isolated files with reasons, files whose
  soft hazard has no policy verdict (`UNREVIEWED`) and stale policy entries.
  `--strict` exits 1 when anything is unreviewed.
- `bundle verify`: runs bundled and unbundled and diffs per-file outcomes and
  coverage; use it before adding a `bundle_safe` verdict.
- `lcov filter`: removes records matching the globs; refuses to write an
  empty report (exit 1, "no records left after filtering").

Bundle policy (`tooling.bundle_policy`, JSON, see
`config/bundle_policy.json`): per package key, `isolate` (file -> reason, run
alone) and `bundle_safe` (file -> evidence, a soft hazard that was verified).
An unusable policy isolates everything (`policy-error`), so it can only cost
time.

### `tooling:` block (root `test_impact.yaml` only)

```yaml
tooling:
  flutter_command: ["fvm", "flutter"]   # default ["flutter"]
  dart_command: ["fvm", "dart"]         # default ["dart"]
  isolation_patterns:                   # regexes; replaces the defaults
    - 'Foo\s*\.\s*init\s*\('
  bundle_policy: "test_impact_bundle_policy.json"  # repo-relative
```

- `isolation_patterns`: a test (or relative helper it imports) matching one
  is a soft hazard and runs in the isolated process. Default: generic
  process-global state (`HttpOverrides.global`, binding init, `setUpAll`,
  platform-channel mocks, `*Platform.instance =`, Bloc globals, Hive,
  get_it registration without `reset`). Setting the key replaces the whole
  list, so repeat the defaults you still want.
- `bundle_policy`: repo-relative path; absent means no policy (every soft
  hazard stays unreviewed and isolated).

The block is validated by `schema/test_impact.schema.json`; unknown keys and
invalid regexes fail with the offending key.

## Limitations

- The index is static. Blind spots: runtime get_it bindings, string routes,
  platform channels, reflection/dynamic calls, and directive-only edits
  (import/export/part changes with no declaration change use the coarser
  file-level graph). Fixtures loaded from disk are not imports: a changed
  non-Dart file under `test/` runs the package fully.
- Import scans for `test/` helpers handle plain `import/export/part 'uri'`
  only (no conditional imports).
- Files outside any `lib/` area or `test/` (e.g. `tools/`, `scripts/` inside
  the root package) are "unmapped" -> root + dependents full; list them under
  `repo.safe` or `run_package` if that is not wanted.
- Directories named `build`, `node_modules`, `Pods`, or starting with `.` are
  not scanned.

## For AI agents: maintaining `test_impact.yaml`

- Run `validate` after every change to lib/test layout or to a mapping.
- New folder under a convention root: nothing to do (area is discovered). New
  top-level folder: add an area (`sources` + `tests`) or a `run_package` glob.
- New test file: place it under the area's test folder; otherwise rule c fires.
- Rule f says area A imports area B: add `depends_on: [B]` to A only if the
  coupling is real; prefer removing the import. Never add `depends_on` just to
  silence the check blindly.
- Rule d (dead glob): delete the glob; do not add placeholder files.
- Never widen `repo.safe` to hide code; `safe` is for non-code only.
- When unsure, use `run_package` (correct but slower) rather than guessing an
  area. Keep `package:` equal to the pubspec name.
