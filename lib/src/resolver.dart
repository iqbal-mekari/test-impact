import 'package:path/path.dart' as p;

import 'areas.dart';
import 'glob.dart';
import 'imports.dart';
import 'index.dart';
import 'workspace.dart';

/// Why a changed path led to the selection it did.
class Reason {
  /// Creates a reason.
  const Reason(this.path, this.rule, this.detail);

  /// Changed repo-relative path.
  final String path;

  /// Rule id, e.g. `safe`, `area`, `unmapped`, `config_error`.
  final String rule;

  /// Free-text explanation.
  final String detail;

  /// JSON form.
  Map<String, String> toJson() =>
      {'path': path, 'rule': rule, 'detail': detail};
}

/// What to run in one package.
class PackageSelection {
  /// Creates a selection.
  PackageSelection(this.mode, [Iterable<String> tests = const []])
      : tests = tests.toSet().toList()..sort();

  /// `full` or `selected`.
  final String mode;

  /// Package-relative test files (only meaningful for `selected`).
  final List<String> tests;

  /// JSON form.
  Map<String, Object> toJson() => {
        'mode': mode,
        'tests': mode == 'full' ? <String>[] : tests,
      };
}

/// Result of resolving a diff: `none`, `selected` or `all`.
class Selection {
  /// Creates a selection.
  Selection(this.mode, this.packages, this.reasons);

  /// `none`, `selected` or `all`.
  final String mode;

  /// Per-package selection keyed by repo-relative dir.
  final Map<String, PackageSelection> packages;

  /// Explanation per changed path.
  final List<Reason> reasons;

  /// JSON form per the CLI contract.
  Map<String, Object> toJson() => {
        'mode': mode,
        'packages': {
          for (final k in packages.keys.toList()..sort())
            k: packages[k]!.toJson()
        },
        'reasons': [for (final r in reasons) r.toJson()],
      };
}

/// Builds the fail-safe "run everything" selection.
Selection selectAll(Workspace ws, List<Reason> reasons) => Selection(
    'all',
    {
      for (final pkg in ws.packages)
        if (pkg.testFiles.isNotEmpty) pkg.dir: PackageSelection('full')
    },
    reasons);

/// Package dirs an [ImpactIndex] must cover to refine [changed]: owner and
/// transitive dependents of every path resolved by an area rule. Empty
/// means no refinement is possible, so no index is needed.
Set<String> indexPackagesFor(Workspace ws, List<String> changed) {
  final out = <String>{};
  for (final r in resolve(ws, changed).reasons) {
    if (r.rule != 'area') continue;
    final dir = ws.ownerOf(r.path)!.dir;
    out
      ..add(dir)
      ..addAll(ws.dependentsOf(dir));
  }
  return out;
}

/// Maps [changed] repo-relative paths to a [Selection] (spec section 2).
///
/// With an [index] (precision `file`), area matches are narrowed to the
/// candidate tests that reach a declaration of the changed file (spec v2
/// D2); without one, area matches select v1 candidates (precision `area`).
Selection resolve(Workspace ws, List<String> changed, {ImpactIndex? index}) {
  if (ws.errors.isNotEmpty) {
    return selectAll(
        ws, [for (final e in ws.errors) Reason(e.file, 'config_error', '$e')]);
  }
  final reasons = <Reason>[];
  final repo = ws.repoRules;
  final full = <String>{}; // package dirs run fully
  final picked = <String, Set<String>>{};
  final models = <String, AreaModel>{};
  var all = false;

  void fullWithDependents(String dir, {bool dependents = true}) {
    full.add(dir);
    if (dependents) full.addAll(ws.dependentsOf(dir));
  }

  for (final path in changed.map(p.posix.normalize).toSet()) {
    void why(String rule, String detail) =>
        reasons.add(Reason(path, rule, detail));

    // run_all beats safe: e.g. tools/**/pubspec.yaml must run everything.
    if (matchesAny(repo.runAll, path)) {
      all = true;
      why('repo_run_all', 'matches repo.run_all');
      continue;
    }
    // runtime_tests beats safe and ADDS to package rules: the tests read
    // the file from disk, so no import analysis can see the dependency.
    final runtime = [
      for (final r in repo.runtimeTests)
        if (matchesAny(r.paths, path) && !matchesAny(r.except, path)) ...r.tests
    ];
    for (final t in runtime.toSet()) {
      final owner = ws.ownerOf(t);
      if (owner == null) {
        all = true;
        why('runtime_test_missing',
            'runtime test $t has no owning package; failing safe to ALL');
        continue;
      }
      final rel = owner.dir == '.' ? t : t.substring(owner.dir.length + 1);
      if (owner.files.contains(rel)) {
        picked.putIfAbsent(owner.dir, () => {}).add(rel);
        why('runtime_test', 'read at runtime by $t');
      } else {
        fullWithDependents(owner.dir, dependents: false);
        why('runtime_test_missing',
            '$t does not exist; ${owner.name} runs fully');
      }
    }
    if (matchesAny(repo.safe, path)) {
      if (runtime.isEmpty) why('safe', 'matches repo.safe');
      continue;
    }
    final pkg = ws.ownerOf(path);
    if (pkg == null) {
      all = true;
      why('no_package', 'no owning package; failing safe to ALL');
      continue;
    }
    final rel = pkg.dir == '.' ? path : path.substring(pkg.dir.length + 1);
    final cfg = pkg.config;

    if (rel.startsWith('test/')) {
      if (rel.endsWith('_test.dart')) {
        if (pkg.files.contains(rel)) {
          picked.putIfAbsent(pkg.dir, () => {}).add(rel);
          why('test', 'changed test file');
        } else {
          why('test_deleted', 'test file no longer exists');
        }
      } else if (!rel.endsWith('.dart')) {
        // Fixtures/assets are read at runtime (File, rootBundle), not
        // imported, so no import scan can find their users: fail safe.
        fullWithDependents(pkg.dir, dependents: false);
        why('test_asset', 'non-Dart test file; ${pkg.name} runs fully');
      } else {
        final hits = _importingTests(ws, pkg, rel);
        if (hits.isEmpty) {
          why('test_helper_unused', 'no test imports it transitively');
        } else {
          picked.putIfAbsent(pkg.dir, () => {}).addAll(hits);
          why('test_helper', 'imported by ${hits.length} test(s)');
        }
      }
      continue;
    }

    if (matchesAny(cfg.runAll, rel)) {
      fullWithDependents(pkg.dir);
      why('pkg_run_all', '${pkg.name} and dependents run fully');
      continue;
    }
    if (matchesAny(cfg.runPackage, rel)) {
      fullWithDependents(pkg.dir, dependents: false);
      why('pkg_run_package', '${pkg.name} runs fully');
      continue;
    }
    final model = models.putIfAbsent(pkg.dir, () => AreaModel(cfg, pkg.files));
    final owners = model.ownersOf(rel);
    if (owners.isEmpty) {
      fullWithDependents(pkg.dir);
      why('unmapped', '$rel has no area; ${pkg.name} and dependents run fully');
      continue;
    }
    final affected = {for (final a in owners) ...model.affectedBy(a)};
    final tests = {for (final a in affected) ...model.testsOf(a)};
    final areas = (affected.toList()..sort()).join(', ');
    final refinement = index?.testsReaching(path);
    final reach = refinement?.tests;
    if (reach == null) {
      picked.putIfAbsent(pkg.dir, () => {}).addAll(tests);
      full.addAll(ws.dependentsOf(pkg.dir));
      why(
          refinement == null ? 'area' : 'unrefined:${refinement.why}',
          'areas $areas: ${tests.length} test(s); '
          'dependent packages run fully');
      continue;
    }
    // Candidates stay the v1 set; keep those whose closure reaches F.
    var kept = 0;
    void keep(String dir, Iterable<String> candidates) {
      final hits = candidates.where((t) => reach.contains(_join(dir, t)));
      picked.putIfAbsent(dir, () => {}).addAll(hits);
      kept += hits.length;
    }

    keep(pkg.dir, tests);
    final deps = ws.dependentsOf(pkg.dir);
    for (final d in deps) {
      final dep = ws.byDir(d);
      if (dep != null) keep(d, dep.testFiles);
    }
    if (kept == 0) {
      why('no_test_reaches',
          'areas $areas: no candidate test reaches a declaration of it');
    } else {
      why(
          'refined',
          'areas $areas: $kept of ${tests.length} area test(s) + '
              'tests of ${deps.length} dependent package(s) reach it');
    }
  }

  if (all) return selectAll(ws, reasons);
  final out = <String, PackageSelection>{};
  for (final pkg in ws.packages) {
    if (pkg.testFiles.isEmpty) continue;
    if (full.contains(pkg.dir)) {
      out[pkg.dir] = PackageSelection('full');
    } else if (picked[pkg.dir]?.isNotEmpty ?? false) {
      out[pkg.dir] = PackageSelection('selected', picked[pkg.dir]!);
    }
  }
  return Selection(out.isEmpty ? 'none' : 'selected', out, reasons);
}

/// Test files in [pkg] that import [helper] transitively (within test/).
Set<String> _importingTests(Workspace ws, ImpactPackage pkg, String helper) {
  final root = p.join(ws.root, pkg.dir);
  final importers = <String, Set<String>>{};
  for (final f in pkg.files) {
    if (!f.startsWith('test/') || !f.endsWith('.dart')) continue;
    for (final t in importsOf(root, pkg.name, f)) {
      importers.putIfAbsent(t, () => {}).add(f);
    }
  }
  final seen = <String>{helper};
  final queue = [helper];
  while (queue.isNotEmpty) {
    for (final f in importers[queue.removeLast()] ?? const <String>{}) {
      if (seen.add(f)) queue.add(f);
    }
  }
  return {
    for (final f in seen)
      if (f != helper && f.endsWith('_test.dart')) f
  };
}

String _join(String dir, String rel) => dir == '.' ? rel : '$dir/$rel';
