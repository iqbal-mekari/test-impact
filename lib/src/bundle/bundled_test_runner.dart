import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../lcov.dart';
import 'package_test_runner.dart';
import '../process.dart';
import 'reporter.dart';
import 'package.dart';
import 'bundle_plan.dart';
import 'bundle_policy.dart';

/// Compiles a package's bundleable tests once (a generated, afterwards
/// deleted `test/flutter_test_bundle.g.dart`) and runs hazardous files in a
/// second process; anything else goes to [plain].
///
/// A red bundle is re-run unbundled before it is reported, so bundling can
/// cost time but never produces a false red. Coverage of all attempts is
/// summed into `request.coveragePath`.
final class BundledTestRunner implements PackageTestRunner {
  /// Creates the runner. [policyPath] is repo-relative unless absolute;
  /// null means no policy.
  BundledTestRunner({
    required this.plain,
    required this.enabled,
    required this.policyPath,
    this.isolationPatterns,
    required this.repoRoot,
    void Function(String message)? log,
  }) : log = log ?? ((m) => stderr.writeln('[flutter-test-bundle] $m'));

  final PackageTestRunner plain;
  final bool enabled;
  final String? policyPath;

  /// Soft-hazard patterns; null means the generic defaults (see `Tooling`).
  final List<RegExp>? isolationPatterns;
  final String repoRoot;
  final void Function(String message) log;

  @override
  Future<PackageRunResult> run(PackageRunRequest request) async {
    final files = enabled ? _candidates(request) : null;
    if (files == null) return plain.run(request);
    final plan = loadBundlePlan(
      packageDir: request.packageDir,
      policyPath: policyPath == null ? null : p.join(repoRoot, policyPath!),
      isolationPatterns: isolationPatterns,
      packageKey: request.package.root,
      log: log,
      files: files,
    ).plan;
    if (plan.bundled.isEmpty) return plain.run(request);
    log('bundled ${plan.bundled.length} file(s), isolated '
        '${plan.isolated.length} (see `test_impact bundle audit`)');
    for (final file in plan.unreviewed) {
      log('unreviewed isolate candidate: $file');
    }
    return (await execute(request, plan)).result;
  }

  /// Test files [request] asks for when they can be bundled (flutter
  /// package; `test/` or two or more `*_test.dart` files), else null.
  List<String>? _candidates(PackageRunRequest request) {
    final targets = request.targets;
    if (request.package.runner != RunnerKind.flutter) return null;
    if (targets.length == 1 && const {'test', 'test/'}.contains(targets[0])) {
      final all = discoverTests(request.packageDir);
      return all.isEmpty ? null : all;
    }
    final subset = targets.length >= minBundle &&
        targets.every((t) =>
            isSafeTestPath(t) &&
            t.endsWith('_test.dart') &&
            File(p.join(request.packageDir, t)).existsSync());
    return subset ? (targets.toSet().toList()..sort()) : null;
  }

  /// Runs [plan]: the bundle, an unbundled retry of it when it is red and
  /// [retry] is set, then the isolated files; merges coverage into
  /// `request.coveragePath`. `bundle verify` passes `retry: false` to see
  /// raw bundle outcomes.
  Future<({PackageRunResult result, List<TestOutcome> outcomes})> execute(
    PackageRunRequest request,
    BundlePlan plan, {
    bool retry = true,
  }) async {
    final name = request.package.name;
    final merged = request.coveragePath;
    Directory(request.workDir).createSync(recursive: true);
    if (merged != null && File(merged).existsSync()) File(merged).deleteSync();

    final combined = StringBuffer();
    final reports = <String>{};
    final outcomes = <TestOutcome>[];
    Future<PackageRunResult> attempt(
      String role,
      List<String> targets, {
      Map<String, List<String>> bundles = const {},
    }) async {
      final dir = p.join(request.workDir, role);
      // The retry replaces the bundle's coverage.
      final slot = role == 'retry' ? 'bundle' : role;
      final coverage =
          merged == null ? null : p.join(request.workDir, '$slot.lcov.info');
      if (coverage != null) reports.add(coverage);
      final result = await plain.run(PackageRunRequest(
        package: request.package,
        packageDir: request.packageDir,
        targets: targets,
        workDir: dir,
        coveragePath: coverage,
        console: request.console,
      ));
      final file = File(p.join(dir, 'reporter.json'));
      final summary = parseReporter(
        file.existsSync()
            ? const LineSplitter().convert(
                utf8.decode(file.readAsBytesSync(), allowMalformed: true))
            : const <String>[],
        package: name,
        packageDir: request.packageDir,
        repoRoot: repoRoot,
        bundles: bundles,
      );
      final output = File(p.join(dir, 'output.txt'));
      combined
        ..writeln('=== $role run (${targets.length} target(s)), '
            'exit ${result.exitCode}')
        ..writeln(output.existsSync() ? output.readAsStringSync() : '');
      outcomes.addAll(summary.outcomes);
      // The plain runner cannot attribute bundled tests; keep only its
      // synthetic `<package>::...` failures and use the attributed ones.
      final failures = {
        ...summary.failures,
        ...result.failures.where((f) => f.startsWith('$name::')),
      };
      return PackageRunResult(
          result.exitCode, failures.toList()..sort(), result.completed);
    }

    final finals = <PackageRunResult>[];
    if (plan.bundled.isNotEmpty) {
      final entry = File(p.join(request.packageDir, 'test', bundleFileName))
        ..writeAsStringSync(renderBundle(plan.bundled));
      late PackageRunResult run;
      try {
        run = await attempt(
          'bundle',
          ['test/$bundleFileName'],
          bundles: {entry.resolveSymbolicLinksSync(): plan.bundled},
        );
      } finally {
        if (entry.existsSync()) entry.deleteSync();
      }
      if (run.exitCode != 0 && retry) {
        log('bundled run failed (exit ${run.exitCode}); '
            're-running ${plan.bundled.length} bundled file(s) unbundled to '
            'rule out bundling artifacts');
        run = await attempt('retry', plan.bundled);
        log(run.exitCode == 0
            ? 'bundling artifact: the bundled run failed but the unbundled '
                'run passed; confirm with `test_impact bundle verify` and '
                'add the file to the bundle policy isolate list'
            : 'failure reproduced unbundled; reporting it');
      }
      finals.add(run);
    }
    if (plan.isolated.isNotEmpty) {
      finals.add(await attempt('isolated', plan.isolated.keys.toList()));
    }
    var code = finals
        .map((a) => a.exitCode)
        .firstWhere((c) => c != 0, orElse: () => 0);
    final failures = <String>{for (final a in finals) ...a.failures};
    var completed = finals.isNotEmpty && finals.every((a) => a.completed);
    if (merged != null) {
      final present = reports.where((r) => File(r).existsSync()).toList();
      if (present.length != reports.length && code == 0) {
        log('a coverage report is missing');
        code = 1;
        failures.add('$name::missing coverage report');
      }
      try {
        if (present.isNotEmpty) {
          LcovTrace.sum(present.map(LcovTrace.read))
              .write(merged, functions: false, branches: false);
          for (final report in present) {
            File(report).deleteSync();
          }
        }
      } on Exception catch (e) {
        log('coverage merge failed: $e');
        if (code == 0) code = 1;
        failures.add('$name::coverage merge failed');
        completed = false;
      }
    }
    if (request.console == ConsoleMode.toFile) {
      File(p.join(request.workDir, 'output.txt'))
          .writeAsStringSync(combined.toString());
    }
    return (
      result: PackageRunResult(code, failures.toList()..sort(), completed),
      outcomes: outcomes,
    );
  }
}
