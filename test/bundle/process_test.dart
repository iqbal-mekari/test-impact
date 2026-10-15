import 'dart:io';

import 'package:test_impact/src/process.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  late Directory temp;
  final runner = IoProcessRunner();
  setUp(() => temp = Directory.systemTemp.createTempSync('process_test_'));
  tearDown(() => temp.deleteSync(recursive: true));

  Future<RunResult> sh(String script,
          {ConsoleMode console = ConsoleMode.capture,
          String? logFile,
          IoProcessRunner? using}) =>
      (using ?? runner).run('sh', ['-c', script],
          workingDirectory: temp.path,
          environment: {'MTS_TEST_VALUE': 'merged'},
          console: console,
          logFile: logFile);

  test('should capture output, exit code, env and stdin', () async {
    final result = await sh(r'echo out; echo $MTS_TEST_VALUE >&2; exit 3');
    final cat = await runner.run('cat', [],
        workingDirectory: temp.path, stdin: 'hello');

    expect([result.exitCode, result.stdout, result.stderr],
        [3, 'out\n', 'merged\n']);
    expect(cat.stdout, 'hello');
  });

  test('should write both streams to the log in toFile mode', () async {
    final log = p.join(temp.path, 'logs', 'output.txt');

    final result = await sh('echo out; echo err >&2',
        console: ConsoleMode.toFile, logFile: log);

    expect(result.stdout, isEmpty);
    expect(File(log).readAsLinesSync()..sort(), ['err', 'out']);
    expect(() => sh('true', console: ConsoleMode.toFile), throwsArgumentError);
  });

  test('should redact secrets in inherit mode', () async {
    const secret = 'sentinel-secret-xyz';
    final seen = <String>[];
    final io = IoProcessRunner(stdoutSink: seen.add, stderrSink: seen.add);

    await io.run('sh', ['-c', 'echo token=$secret; echo "x $secret" >&2'],
        workingDirectory: temp.path,
        console: ConsoleMode.inherit,
        redact: (line) => line.replaceAll(secret, '[REDACTED]'));

    expect(seen.join(), isNot(contains(secret)));
    expect(seen.join(), contains('token=[REDACTED]'));
  });

  test('should throw ProcessException for a missing binary', () {
    expect(
        runner.run('definitely-not-a-binary-xyz', [],
            workingDirectory: temp.path),
        throwsA(isA<ProcessException>()));
  });
}
