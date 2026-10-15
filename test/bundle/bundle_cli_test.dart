import 'dart:convert';
import 'dart:io';

import 'package:args/command_runner.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:test_impact/test_impact.dart';

import 'bundle_fakes.dart';

import 'bundle_support.dart';

void main() {
  late String temp;
  setUp(() => temp = Directory.systemTemp
      .createTempSync('cli_test_')
      .resolveSymbolicLinksSync());
  tearDown(() => Directory(temp).deleteSync(recursive: true));

  String write(String path, String content) {
    File(p.join(temp, path))
      ..createSync(recursive: true)
      ..writeAsStringSync(content);
    return p.join(temp, path);
  }

  test('should map help and usage errors to exit codes', () async {
    final cases = {
      <String>[]: 2,
      ['help']: 0,
      ['--help']: 0,
      ['no-such-command']: 2,
      ['lcov', 'filter', 'only-input']: 2,
      ['bundle']: 2,
    };
    for (final MapEntry(key: args, value: code) in cases.entries) {
      expect(await runCli(args), code, reason: '$args');
    }
  });

  test('should filter lcov records with lcov -r exit codes', () async {
    String rec(String path) => 'SF:$path\nFN:1,f\nDA:1,1\nend_of_record\n';
    final cases = <(String, List<String>), (int, String?)>{
      (rec('lib/a.dart') + rec('lib/a.g.dart'), ['*.g.dart', '*x*']): (
        0,
        'TN:\nSF:lib/a.dart\nDA:1,1\nLF:1\nLH:1\nend_of_record\n'
      ),
      (rec('lib/a.dart'), []): (0, 'SF:lib/a.dart'),
      ('', []): (1, null),
      (rec('lib/a.g.dart'), ['*.g.dart']): (1, null),
    };
    for (final MapEntry(key: (input, globs), value: (code, text))
        in cases.entries) {
      final output = p.join(temp, 'out.info');
      if (File(output).existsSync()) File(output).deleteSync();

      final exit = await runCli(
          ['lcov', 'filter', write('in.info', input), output, ...globs]);

      expect(exit, code, reason: input);
      final file = File(output);
      expect(file.existsSync() ? file.readAsStringSync() : null,
          text == null ? isNull : contains(text));
    }
    expect(await runCli(['lcov', 'filter', '$temp/none', '$temp/o']), 1);
  });

  group('bundle', () {
    late TestPackage pkg;
    late StringBuffer out, err;
    setUp(() {
      pkg = TestPackage.create();
      out = StringBuffer();
      err = StringBuffer();
    });

    Future<int> bundleCmd(FakeFlutter fake, List<String> args,
            {Map<String, String> env = const {}}) async =>
        await _runner(
                processes: fake.processes, environment: env, out: out, err: err)
            .run(['bundle', ...args]) ??
        0;
    List<String> common([String? policy]) => [
          ...['--flutter', 'flutter', '--package-root', pkg.dir],
          ...['--policy', policy ?? pkg.policy()],
        ];
    String lcov() =>
        File(p.join(pkg.dir, 'coverage', 'lcov.info')).readAsStringSync();
    const off = {'FLUTTER_TEST_BUNDLE': '0'};

    test('should run plain flutter when off or for another target', () async {
      final cov = ['--coverage-path', p.join(pkg.dir, 'c.info')];
      final cases = <(Map<String, String>, List<String>), List<String>>{
        (off, ['--target', 'test/']): ['test/'],
        (const {}, ['--target', 'test/a_test.dart']): ['test/a_test.dart'],
        (off, ['--target', 'test/', ...cov]): [...cov, 'test/'],
      };
      for (final MapEntry(key: (env, args), value: tail) in cases.entries) {
        final fake = FakeFlutter();

        await bundleCmd(fake, ['test', ...common(), ...args], env: env);

        expect(fake.invocations.single,
            ['test', '--coverage', '--no-pub', ...tail]);
      }
    });

    test('should keep the flutter exit code and fail without lcov', () async {
      final args = ['test', ...common(), '--target', 'test/'];

      expect(
          await bundleCmd(
              FakeFlutter(exitCode: 17, partialCoverage: true), args,
              env: off),
          17);
      expect(lcov(), contains('SF:lib/partial.dart'));
      File(p.join(pkg.dir, 'coverage', 'lcov.info')).deleteSync();
      for (final env in [off, const <String, String>{}]) {
        expect(
            await bundleCmd(FakeFlutter(writeCoverage: false), args, env: env),
            1);
      }
      expect(err.toString(), contains('coverage report is missing'));
      for (final stem in ['a', 'b', 'c']) {
        File(p.join(pkg.dir, 'test', '${stem}_test.dart')).deleteSync();
      }
      final fake = FakeFlutter();
      expect(await bundleCmd(fake, args), 1);
      expect(err.toString(), contains('no test files found'));
      expect(fake.invocations, isEmpty);
      expect(() => bundleCmd(FakeFlutter(), ['test', ...common()]),
          throwsA(isA<UsageException>()));
    });

    test('should run the configured flutter command', () async {
      final fake = FakeProcessRunner((_) async => const RunResult(0));
      final runner = _runner(
        processes: fake,
        out: out,
        err: err,
        tooling: (_) => Tooling(flutterCommand: ['wrapper', 'flutter']),
      );

      await runner.run([
        'bundle',
        'test',
        ...['--package-root', pkg.dir, '--target', 'test/a_test.dart'],
      ]);

      final call = fake.calls.single;
      expect(call.executable, 'wrapper');
      expect(call.arguments,
          ['flutter', 'test', '--coverage', '--no-pub', 'test/a_test.dart']);
    });

    test('should read the policy path from the tooling', () async {
      pkg.write('test/d_test.dart', softTest);
      final runner = _runner(
        out: out,
        err: err,
        tooling: (_) => Tooling(
            bundlePolicy: pkg.policy({
          'pkg': {
            'isolate': {'test/d_test.dart': 'collides'},
          },
        })),
      );

      await runner.run(['bundle', 'audit', '--package-root', pkg.dir]);

      expect(out.toString(), contains('isolate test/d_test.dart: policy:'));
      expect(out.toString(), isNot(contains('UNREVIEWED')));
    });

    test('should audit verdicts, stale entries and strict mode', () async {
      pkg.write('test/d_test.dart', softTest);
      final args = ['audit', '--package-root', pkg.dir, '--policy'];

      expect(
          await bundleCmd(FakeFlutter(), [...args, pkg.policy(), '--strict']),
          1);
      expect(out.toString(), contains('pkg: 4 test file(s), 3 bundled, 1 '));
      expect(out.toString(),
          contains('isolate test/d_test.dart: isolation-pattern'));
      expect(out.toString(), contains('UNREVIEWED test/d_test.dart'));
      out.clear();
      final policy = pkg.policy({
        'other': {
          'isolate': {'test/d_test.dart': 'collides'},
          'bundle_safe': {'test/gone_test.dart': 'removed'},
        },
      });
      expect(
          await bundleCmd(
              FakeFlutter(), [...args, policy, '--package-key', 'other']),
          0);
      expect(out.toString(), isNot(contains('UNREVIEWED')));
      expect(out.toString(), contains('isolate test/d_test.dart: policy: '));
      expect(
          out.toString(), contains('STALE policy entry: test/gone_test.dart'));
    });

    test('should verify identical outcomes and name flipped files', () async {
      final work = p.join(pkg.repoRoot, 'verify');
      Map<String, Object?> summary() {
        final json = jsonDecode('$out') as Map<String, Object?>;
        out.clear();
        return json;
      }

      expect(
          await bundleCmd(
              FakeFlutter(), ['verify', ...common(), '--out-dir', work]),
          0,
          reason: '$err');
      final same = summary();
      expect(same, containsPair('outcomes_identical', true));
      expect((same['lcov']! as Map)['equivalent'], isTrue);
      expect(
          await bundleCmd(
              FakeFlutter(failBundle: true), ['verify', ...common()]),
          1);
      expect(summary()['differing_files'], hasLength(3));
      expect(pkg.leftovers, isEmpty);
    });
  });
}

CommandRunner<int> _runner({
  ProcessRunner? processes,
  Map<String, String>? environment,
  Tooling Function(String repoRoot)? tooling,
  StringSink? out,
  StringSink? err,
}) {
  final commands = buildBundleCommands(
    tooling: tooling ?? (_) => Tooling(),
    processes: processes,
    environment: environment,
    out: out,
    err: err,
  );
  return CommandRunner<int>('test_impact', 'test')
    ..addCommand(commands[0])
    ..addCommand(commands[1]);
}
