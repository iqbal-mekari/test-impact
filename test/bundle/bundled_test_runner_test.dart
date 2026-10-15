import 'dart:io';

import 'package:test_impact/src/bundle/bundled_test_runner.dart';
import 'package:test_impact/src/bundle/package_test_runner.dart';
import 'package:test_impact/src/bundle/package.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'bundle_support.dart';

void main() {
  late TestPackage pkg;
  late List<String> logs;

  setUp(() {
    pkg = TestPackage.create();
    logs = [];
  });

  Future<PackageRunResult> run(
    FakeFlutter fake, {
    bool enabled = true,
    List<String> targets = const ['test/'],
    RunnerKind kind = RunnerKind.flutter,
  }) =>
      BundledTestRunner(
        plain:
            PlainTestRunner(processes: fake.processes, repoRoot: pkg.repoRoot),
        enabled: enabled,
        policyPath: pkg.policy(),
        repoRoot: pkg.repoRoot,
        log: logs.add,
      ).run(PackageRunRequest(
        package: BundlePackage('pkg', 'pkg', kind),
        packageDir: pkg.dir,
        targets: targets,
        workDir: p.join(pkg.repoRoot, 'work'),
        coveragePath: p.join(pkg.dir, 'coverage', 'lcov.info'),
      ));

  String lcov() =>
      File(p.join(pkg.dir, 'coverage', 'lcov.info')).readAsStringSync();

  test('should compile once, isolate soft files, keep coverage', () async {
    pkg.write('test/d_test.dart', softTest);
    final fake = FakeFlutter();

    final result = await run(fake);

    expect(result.exitCode, 0);
    expect(fake.targets.map((t) => t.single),
        ['test/flutter_test_bundle.g.dart', 'test/d_test.dart']);
    for (final stem in ['a', 'b', 'c', 'd']) {
      expect(lcov(), contains('SF:lib/${stem}_test.dart'));
    }
    expect(pkg.leftovers, isEmpty);
    expect(logs.join('\n'), contains('bundled 3 file(s), isolated 1'));
    expect(logs.join('\n'), contains('unreviewed isolate candidate'));
  });

  test('should rerun a red bundle unbundled and pass', () async {
    final fake = FakeFlutter(failBundle: true);

    final result = await run(fake);

    expect(result.exitCode, 0);
    expect(fake.targets.last,
        ['test/a_test.dart', 'test/b_test.dart', 'test/c_test.dart']);
    expect(logs.join('\n'), contains('bundling artifact'));
  });

  test('should name the file of a failure that reproduces', () async {
    pkg.write('test/d_test.dart', softTest);
    final fake =
        FakeFlutter(failFiles: {'test/b_test.dart', 'test/d_test.dart'});

    final result = await run(fake);

    expect(result.exitCode, isNot(0));
    expect(
        result.failures,
        containsAll(
            ['pkg/test/b_test.dart::works', 'pkg/test/d_test.dart::works']));
    expect(logs.join('\n'), contains('reproduced unbundled'));
    expect(fake.invocations, hasLength(3));
  });

  test('should bundle a subset of two or more files', () async {
    final fake = FakeFlutter();

    await run(fake, targets: ['test/a_test.dart', 'test/c_test.dart']);

    expect(fake.targets.single, ['test/flutter_test_bundle.g.dart']);
    expect(lcov(), isNot(contains('b_test')));
  });

  test('should take the plain path when bundling does not apply', () async {
    Future<List<String>> plain({
      bool enabled = true,
      RunnerKind kind = RunnerKind.flutter,
      List<String> targets = const ['test/'],
    }) async {
      final fake = FakeFlutter();
      await run(fake, enabled: enabled, kind: kind, targets: targets);
      return [for (final call in fake.targets) ...call];
    }

    expect(await plain(enabled: false), ['test/']);
    expect(await plain(targets: ['test/a_test.dart']), ['test/a_test.dart']);
    expect(await plain(kind: RunnerKind.dart), isEmpty);
    File(p.join(pkg.dir, 'test', 'b_test.dart')).deleteSync();
    File(p.join(pkg.dir, 'test', 'c_test.dart')).deleteSync();
    expect(await plain(), ['test/']);
  });

  test('should keep a partial exit code and drop stale coverage', () async {
    File(p.join(pkg.dir, 'coverage', 'lcov.info'))
      ..parent.createSync(recursive: true)
      ..writeAsStringSync('SF:lib/stale.dart\nDA:1,1\nend_of_record\n');

    final result = await run(FakeFlutter(exitCode: 17));

    expect(result.exitCode, 17);
    expect(lcov(), allOf(contains('a_test'), isNot(contains('stale'))));
  });
}
