import 'areas.dart';
import 'glob.dart';
import 'index.dart';
import 'workspace.dart';

/// One mapping problem found by [validate].
class Violation {
  /// Creates a violation.
  const Violation(this.rule, this.package, this.message,
      {this.path, this.environment = false});

  /// Rule letter `a`..`g` (spec section 3).
  final String rule;

  /// Package dir.
  final String package;

  /// Problem description.
  final String message;

  /// Offending package-relative path, if any.
  final String? path;

  /// True when the check could not run (e.g. no index), not a mapping bug.
  final bool environment;

  @override
  String toString() =>
      '$rule [$package] ${path ?? ''} $message'.replaceAll(RegExp(r' +'), ' ');
}

/// Checks every package mapping against the file tree (rules a-e, g).
///
/// Rule f needs the declaration index; see [validateAreaDeps].
/// Empty list means valid.
List<Violation> validate(Workspace ws) {
  final out = <Violation>[];
  // Rule g: every repo.runtime_tests test must exist in its package.
  for (final rule in ws.repoRules.runtimeTests) {
    for (final t in rule.tests) {
      final owner = ws.ownerOf(t);
      final rel = owner == null || owner.dir == '.'
          ? t
          : t.substring(owner.dir.length + 1);
      if (owner == null || !owner.files.contains(rel)) {
        out.add(Violation('g', owner?.dir ?? '.',
            'repo.runtime_tests lists "$t" which does not exist',
            path: t));
      }
    }
  }
  for (final pkg in ws.packages) {
    final cfg = pkg.config;
    final model = AreaModel(cfg, pkg.files);
    void add(String rule, String msg, {String? path}) =>
        out.add(Violation(rule, pkg.dir, msg, path: path));
    final pkgGlobs = [...cfg.runAll, ...cfg.runPackage];
    final libFiles = pkg.files.where((f) => f.startsWith('lib/')).toList();

    for (final f in libFiles) {
      final explicit = model.explicitOwners(f);
      if (explicit.length > 1) {
        add('b', 'owned by several areas: ${explicit.join(', ')}', path: f);
      }
      if (model.ownersOf(f).isEmpty && !matchesAny(pkgGlobs, f)) {
        add('a', 'not owned by any area, run_all or run_package', path: f);
      }
    }

    final covered = model.coveredTests;
    for (final f in pkg.testFiles) {
      if (!covered.contains(f) && !matchesAny(pkgGlobs, f)) {
        add('c', 'test is not covered by any area tests/extra_tests', path: f);
      }
    }

    void dead(String glob, {String? where}) {
      if (!pkg.files.any((f) => globMatches(glob, f))) {
        add(
            'd',
            'glob "$glob"${where == null ? '' : ' ($where)'} '
                'matches no file');
      }
    }

    for (final g in cfg.runAll) {
      dead(g, where: 'run_all');
    }
    for (final g in cfg.runPackage) {
      dead(g, where: 'run_package');
    }
    for (final c in cfg.conventions) {
      dead(c.sources, where: 'convention sources');
      dead(c.tests, where: 'convention tests');
    }
    for (final a in cfg.areas.values) {
      for (final g in a.sources) {
        dead(g, where: 'area ${a.name} sources');
      }
      for (final g in a.tests) {
        dead(g, where: 'area ${a.name} tests');
      }
      for (final g in a.extraTests) {
        dead(g, where: 'area ${a.name} extra_tests');
      }
      for (final d in a.dependsOn) {
        if (d == a.name) {
          add('e', 'area ${a.name} depends on itself');
        } else if (!model.names.contains(d)) {
          add('e', 'area ${a.name} depends_on unknown area "$d"');
        }
      }
    }
  }
  return out;
}

/// Result of [validateAreaDeps].
class AreaDepReport {
  /// Creates a report.
  const AreaDepReport(this.violations, this.warnings);

  /// Rule f violations, including environment problems.
  final List<Violation> violations;

  /// Non-fatal notes, e.g. libraries skipped for analysis errors.
  final List<String> warnings;
}

/// Dirs of packages that declare at least one area (rule f scope).
Set<String> areaPackages(Workspace ws) => {
      for (final pkg in ws.packages)
        if (AreaModel(pkg.config, pkg.files).names.isNotEmpty) pkg.dir
    };

/// Rule f: a top-level declaration in a lib file of area A that references
/// a declaration in a lib file of area B of the same package (B != A)
/// requires A to depend_on B, directly or transitively.
///
/// Uses the resolved declaration graph of [index], so barrels (including
/// a package importing its own barrel) are irrelevant. Files without an
/// area (run_all/run_package) are ignored on both sides. A package the
/// index could not cover yields an `environment` violation, never a pass.
/// Violations are deduplicated per (package, A, B) with one example.
AreaDepReport validateAreaDeps(Workspace ws, ImpactIndex index) {
  final out = <Violation>[];
  final warnings = <String>[];
  for (final pkg in ws.packages) {
    final model = AreaModel(pkg.config, pkg.files);
    if (model.names.isEmpty) continue;
    final why = index.failure ??
        (!index.packages.contains(pkg.dir)
            ? 'package not indexed'
            : index.unavailable.contains(pkg.dir)
                ? 'no .dart_tool/package_config.json (run pub get)'
                : null);
    if (why != null) {
      out.add(Violation('f', pkg.dir, 'rule f: index unavailable: $why',
          environment: true));
      continue;
    }
    final prefix = pkg.dir == '.' ? '' : '${pkg.dir}/';
    String? libRel(String file) {
      if (!file.startsWith(prefix)) return null;
      final rel = file.substring(prefix.length);
      return rel.startsWith('lib/') ? rel : null;
    }

    final seen = <String>{};
    for (final file in index.declsByFile.keys.toList()..sort()) {
      final rel = libRel(file);
      if (rel == null) continue;
      final from = model.ownersOf(rel);
      if (index.tainted.contains(file)) {
        warnings.add('rule f: skipped $file (analysis errors)');
        continue;
      }
      if (from.isEmpty) continue;
      final deps = {for (final a in from) ...model.dependenciesOf(a)};
      final area = (from.toList()..sort()).first;
      for (final decl in index.declsByFile[file]!.toList()..sort()) {
        for (final target in index.edges[decl] ?? const <String>{}) {
          final tRel = libRel(target.substring(0, target.indexOf('#')));
          if (tRel == null) continue;
          for (final b in model.ownersOf(tRel)) {
            if (from.contains(b) || deps.contains(b)) continue;
            if (!seen.add('$area>$b')) continue;
            out.add(Violation(
                'f',
                pkg.dir,
                'area $area references area $b without depends_on, e.g. '
                    '${decl.substring(prefix.length)} -> '
                    '${target.substring(prefix.length)}'));
          }
        }
      }
    }
  }
  return AreaDepReport(out, warnings);
}
