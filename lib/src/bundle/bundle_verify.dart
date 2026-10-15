import 'package:path/path.dart' as p;

import '../lcov.dart';
import 'package_test_runner.dart';
import 'reporter.dart';
import 'package.dart';
import 'bundle_plan.dart';
import 'bundled_test_runner.dart';

/// Runs a package unbundled and bundled (no retry) and diffs per-test
/// outcomes (with multiplicity) and merged LCOV. Returns the JSON summary;
/// the runs happen in `<workDir>/unbundled` and `<workDir>/bundled`.
Future<Map<String, Object?>> verifyBundle({
  required BundledTestRunner runner,
  required BundlePackage package,
  required String packageDir,
  required String workDir,
  required String packageKey,
  required LoadedBundlePlan loaded,
}) async {
  final plan = loaded.plan;
  final seconds = <String, double>{};
  final counts = <String, Map<String, int>>{};
  Future<Map<String, Object?>> measure(String dir, BundlePlan plan) async {
    final timer = Stopwatch()..start();
    final run = await runner.execute(
      PackageRunRequest(
        package: package,
        packageDir: packageDir,
        targets: const ['test/'],
        workDir: p.join(workDir, dir),
        coveragePath: p.join(workDir, '$dir.lcov.info'),
      ),
      plan,
      retry: false,
    );
    seconds[dir] = timer.elapsedMilliseconds / 1000;
    final count = counts[dir] = <String, int>{};
    for (final o in run.outcomes) {
      final key = '${o.file}\u0000${o.name}\u0000${o.result.name}';
      count[key] = (count[key] ?? 0) + 1;
    }
    return {
      'seconds': _round(seconds[dir]!, 1),
      'exit': run.result.exitCode,
      for (final r in TestResult.values)
        r.name: run.outcomes.where((o) => o.result == r).length,
    };
  }

  // Unbundled: every file isolated, so each runs through the plain runner.
  final unbundled = await measure('unbundled', (
    bundled: <String>[],
    isolated: {for (final f in loaded.files) f: <String>[]},
    unreviewed: <String>[],
  ));
  final bundle = await measure('bundled', plan);

  final left = counts['unbundled']!;
  final right = counts['bundled']!;
  final differing = {
    for (final key in {...left.keys, ...right.keys})
      if (left[key] != right[key]) key.split('\u0000').first,
  };
  final relative = p.relative(packageDir, from: runner.repoRoot);
  final prefix =
      relative == '.' ? '' : '${p.posix.joinAll(p.split(relative))}/';
  Map<String, Object?> lcov;
  try {
    lcov = compareLcovTraces(
      LcovTrace.read(p.join(workDir, 'unbundled.lcov.info')),
      LcovTrace.read(p.join(workDir, 'bundled.lcov.info')),
    );
  } on Exception catch (e) {
    lcov = {'equivalent': false, 'error': '$e'};
  }
  final fast = seconds['bundled']!;
  return {
    'package': packageKey,
    'files': loaded.files.length,
    'bundled': plan.bundled.length,
    'isolated': plan.isolated.length,
    'unreviewed': plan.unreviewed,
    'unbundled': unbundled,
    'bundle': bundle,
    'speedup': _round(seconds['unbundled']! / (fast <= 0 ? 1e-9 : fast), 2),
    'outcomes_identical': differing.isEmpty,
    'differing_files': [
      for (final file in differing)
        file.startsWith(prefix) ? file.substring(prefix.length) : file,
    ]..sort(),
    'lcov': lcov,
  };
}

/// Whether [summary] (from [verifyBundle]) shows no difference at all.
bool verifyPassed(Map<String, Object?> summary) =>
    summary['outcomes_identical'] == true &&
    (summary['lcov']! as Map<String, Object?>)['equivalent'] == true;

double _round(double v, int digits) => double.parse(v.toStringAsFixed(digits));
