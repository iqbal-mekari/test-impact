import 'dart:convert';
import 'dart:io';

import 'package:test_impact/src/bundle/package_test_runner.dart';
import 'package:test_impact/src/process.dart';
import 'package:test_impact/src/bundle/package.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'bundle_fakes.dart';

void main() {
  late String root, appDir, workDir, cov;

  setUp(() {
    final temp = Directory.systemTemp.createTempSync('runner_test_');
    addTearDown(() => temp.deleteSync(recursive: true));
    root = temp.resolveSymbolicLinksSync();
    appDir = p.join(root, 'app');
    workDir = p.join(root, 'work');
    cov = p.join(workDir, 'lcov.info');
  });

  /// Fake test process: reports one `works` test in `test/a_test.dart` with
  /// [result] (no events at all when [complete] is false).
  FakeProcessRunner fake(
          {String result = 'success',
          bool complete = true,
          int exitCode = 0,
          bool coverage = false}) =>
      FakeProcessRunner((call) async {
        String after(String flag) =>
            call.arguments[call.arguments.indexOf(flag) + 1];
        final suite = jsonEncode(p.join(appDir, 'test', 'a_test.dart'));
        File(after('--file-reporter').substring(5)).writeAsStringSync([
          if (complete) ...[
            '{"type":"suite","suite":{"id":1,"path":$suite}}',
            '{"type":"testStart","test":{"id":2,"suiteID":1,"name":"works"}}',
            '{"type":"testDone","testID":2,"result":"$result"}',
          ],
          '{"type":"done","success":${result == 'success'}}',
        ].join('\n'));
        if (coverage) File(after('--coverage-path')).writeAsStringSync('x');
        return RunResult(exitCode);
      });

  Future<PackageRunResult> run(FakeProcessRunner fake,
          {RunnerKind kind = RunnerKind.flutter, String? coveragePath}) =>
      PlainTestRunner(
              flutterCommand: const ['/sdk/flutter'],
              dartCommand: const ['/sdk/dart'],
              processes: fake,
              repoRoot: root)
          .run(PackageRunRequest(
              package: BundlePackage('app', 'app', kind),
              packageDir: appDir,
              targets: ['test/a_test.dart'],
              workDir: workDir,
              coveragePath: coveragePath));

  test('should build the flutter command and log to a file', () async {
    final runner = fake(coverage: true);

    final result = await run(runner, coveragePath: cov);

    final call = runner.calls.single;
    expect('${call.executable} ${call.workingDirectory} ${call.console}',
        '/sdk/flutter $appDir ${ConsoleMode.toFile}');
    expect(call.logFile, p.join(workDir, 'output.txt'));
    expect(call.arguments, [
      ...['test', '--no-pub', '--file-reporter'],
      'json:${p.join(workDir, 'reporter.json')}',
      ...['--coverage', '--coverage-path', cov, 'test/a_test.dart'],
    ]);
    expect([result.exitCode, result.failures, result.completed], [0, [], true]);
  });

  test('should fail closed on bad runs', () async {
    final cases = <(FakeProcessRunner, String?), (int, String)>{
      (fake(complete: false), null): (2, 'app::incomplete reporter stream'),
      (FakeProcessRunner((_) async => const RunResult(1)), null): (
        1,
        'app::test process failed'
      ),
      (FakeProcessRunner((_) => throw const ProcessException('f', [])), null): (
        127,
        'app::test process failed'
      ),
      // A stale report must never count as fresh coverage.
      (fake(), cov): (2, 'app::missing coverage report'),
      (fake(result: 'failure', exitCode: 1), null): (
        1,
        'app/test/a_test.dart::works'
      ),
    };
    for (final MapEntry(key: (runner, coverage), value: (code, failure))
        in cases.entries) {
      File(cov)
        ..createSync(recursive: true)
        ..writeAsStringSync('stale');

      final result = await run(runner, coveragePath: coverage);

      expect(result.exitCode, code);
      expect(result.failures, contains(failure));
    }
  });

  test('should run dart packages through the cached test CLI', () async {
    final config = p.join(appDir, '.dart_tool', 'package_config.json');
    final cli = p.join(root, 'cache', 'test-1.0.0', 'bin', 'test.dart');
    final rootUri = p.toUri(p.dirname(p.dirname(cli)));
    File(config)
      ..createSync(recursive: true)
      ..writeAsStringSync(jsonEncode({
        'packages': [
          {'name': 'test', 'rootUri': '$rootUri'},
        ],
      }));
    final missing = fake();

    final absent = await run(missing, kind: RunnerKind.dart);
    File(cli).createSync(recursive: true);
    final runner = fake();
    final present = await run(runner, kind: RunnerKind.dart);

    expect(missing.calls, isEmpty);
    expect(absent.exitCode, 2);
    expect(absent.failures, ['app::missing cached test runner']);
    expect(File(p.join(workDir, 'output.txt')).existsSync(), isTrue);
    expect(runner.calls.single.executable, '/sdk/dart');
    expect(runner.calls.single.arguments.take(2), ['--packages=$config', cli]);
    expect(present.exitCode, 0);
  });
}
