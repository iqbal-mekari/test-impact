import 'dart:io';

import 'package:path/path.dart' as p;

import 'bundle/bundled_test_runner.dart';
import 'bundle/env.dart';
import 'bundle/package.dart';
import 'bundle/package_test_runner.dart';
import 'process.dart';
import 'resolver.dart';
import 'workspace.dart';

/// Package-relative lcov output used for every `--coverage` invocation.
const coverageLcovPath = 'coverage/test_impact_lcov.info';

/// Runs [sel] with the commands, isolation patterns and bundle policy of
/// the `tooling:` block. `full` packages run plain; `selected` packages go
/// through the bundler shared with `bundle test`: the bundleable files
/// compile once, files with process-global state or an own-entrypoint need
/// (async `main`, annotations, ...) run in a second process, and a red
/// bundle is re-run unbundled before it is reported. `FLUTTER_TEST_BUNDLE=0`
/// in [environment] turns bundling off.
///
/// With [coverage], every package also writes `$coverageLcovPath` (stale
/// lcov is removed first). Returns 0 on success, 1 if any package failed,
/// 2 when ALL was requested but no package is known. [processes] is the
/// process seam (default: real processes inheriting stdio).
Future<int> runSelection(Workspace ws, Selection sel,
    {ProcessRunner? processes,
    Map<String, String>? environment,
    StringSink? out,
    StringSink? err,
    bool coverage = false}) async {
  final o = out ?? stdout, e = err ?? stderr;
  if (sel.mode == 'none') {
    o.writeln('test_impact: no tests selected');
    return 0;
  }
  if (sel.packages.isEmpty) {
    e.writeln('test_impact: ALL requested but no packages are configured');
    return 2;
  }
  final tooling = ws.tooling;
  final bundling = BundleEnv(environment).bundleEnabled;
  final io = processes ?? IoProcessRunner();
  var failed = false;
  for (final dir in sel.packages.keys.toList()..sort()) {
    final ps = sel.packages[dir]!;
    final pkg = ws.byDir(dir)!;
    final cwd = p.normalize(p.join(ws.root, dir));
    final selected = ps.mode == 'selected';
    o.writeln('test_impact: ${pkg.name} ($dir) ${ps.mode}'
        '${selected ? ' ${ps.tests.length} test file(s)' : ''}');
    final work = Directory.systemTemp.createTempSync('test_impact_run_');
    try {
      final result = await BundledTestRunner(
        plain: PlainTestRunner(
          processes: io,
          repoRoot: ws.root,
          flutterCommand: tooling.flutterCommand,
          dartCommand: tooling.dartCommand,
        ),
        enabled: bundling && selected,
        policyPath: tooling.bundlePolicy,
        isolationPatterns: tooling.isolationRegExps,
        repoRoot: ws.root,
        log: (m) => e.writeln('test_impact: $m'),
      ).run(PackageRunRequest(
        package: BundlePackage(pkg.name, dir, RunnerKind.flutter),
        packageDir: cwd,
        targets: selected ? ps.tests : const ['test'],
        workDir: work.path,
        coveragePath: coverage ? p.join(cwd, coverageLcovPath) : null,
        console: ConsoleMode.inherit,
      ));
      if (result.exitCode != 0) {
        failed = true;
        e.writeln('test_impact: ${pkg.name} failed '
            '(exit ${result.exitCode})');
        for (final f in result.failures) {
          e.writeln('test_impact:   $f');
        }
      }
    } finally {
      work.deleteSync(recursive: true);
    }
  }
  return failed ? 1 : 0;
}
