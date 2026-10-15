import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:test_impact/test_impact.dart';

import 'fixture.dart';
import 'bundle/bundle_support.dart';
import 'index_fixture.dart';

/// Records `flutter test` calls (with the generated bundle's source, read
/// while it still exists) and forwards them to a scripted fake flutter.
class Spy implements ProcessRunner {
  Spy([FakeFlutter? flutter]) : inner = flutter ?? FakeFlutter();
  final FakeFlutter inner;
  final calls = <Call>[];

  @override
  Future<RunResult> run(
    String executable,
    List<String> arguments, {
    required String workingDirectory,
    Map<String, String>? environment,
    ConsoleMode console = ConsoleMode.capture,
    String? logFile,
    String? stdin,
    String Function(String line)? redact,
  }) {
    final bundle = File(p.join(workingDirectory, 'test', bundleName));
    calls.add(Call([executable, ...arguments], workingDirectory,
        bundle.existsSync() ? bundle.readAsStringSync() : null));
    return inner.processes.run(executable, arguments,
        workingDirectory: workingDirectory,
        environment: environment,
        console: console,
        logFile: logFile);
  }
}

class Call {
  Call(this.cmd, this.cwd, this.bundle);
  final List<String> cmd;
  final String cwd;
  final String? bundle;

  /// Test files named on the command line.
  List<String> get targets =>
      cmd.where((a) => a.startsWith('test/') && a.endsWith('.dart')).toList();
}

const bundleName = 'flutter_test_bundle.g.dart';

void main() {
  tearDown(runTearDowns);

  group('runner', () {
    test('full package runs plain flutter test', () async {
      final d = makeRepo(standardRepo());
      final ws = Workspace.load(d.path);
      final s = resolve(ws, ['modules/pkg_a/assets/x.json']);
      final spy = Spy();
      final code = await runSelection(ws, s,
          processes: spy, out: StringBuffer(), err: StringBuffer());
      expect(code, 0);
      final c = spy.calls.single;
      expect(c.cmd.take(3), ['flutter', 'test', '--no-pub']);
      expect(c.cmd.last, 'test');
      expect(c.cwd, p.join(d.path, 'modules/pkg_a'));
      expect(c.bundle, isNull);
    });

    test('selected tests: one bundle, deleted afterwards', () async {
      final d = makeRepo(standardRepo());
      final ws = Workspace.load(d.path);
      final s = resolve(ws, ['modules/pkg_a/lib/net/client.dart']);
      final spy = Spy();
      final code = await runSelection(ws, s,
          processes: spy, out: StringBuffer(), err: StringBuffer());
      expect(code, 0);
      expect(spy.calls.length, 2); // pkg_a selected + app (dependent) full
      final c = spy.calls.firstWhere((c) => c.cwd.endsWith('pkg_a'));
      expect(c.cmd.take(2), ['flutter', 'test']);
      expect(c.cmd.last, 'test/$bundleName');
      expect(c.bundle, contains("import 'net/client_test.dart' as t0;"));
      expect(c.bundle, contains("group('test/net/client_test.dart', t0.main)"));
      expect(c.bundle, contains("import 'net/uses_n_test.dart' as t1;"));
      expect(
          File(p.join(d.path, 'modules/pkg_a/test', bundleName)).existsSync(),
          isFalse);
    });

    test('single selected test runs directly, no bundle', () async {
      final d = makeRepo(standardRepo());
      final ws = Workspace.load(d.path);
      final s = resolve(ws, ['modules/pkg_a/test/src/auth/auth_test.dart']);
      final spy = Spy();
      await runSelection(ws, s,
          processes: spy, out: StringBuffer(), err: StringBuffer());
      expect(spy.calls.single.cmd.last, 'test/src/auth/auth_test.dart');
      expect(spy.calls.single.bundle, isNull);
    });

    test('async main and annotated tests run in their own process', () async {
      final repo = standardRepo()
        ..['modules/pkg_a/test/net/client_test.dart'] =
            'Future<void> main() async {}\n'
        ..['modules/pkg_a/test/net/uses_n_test.dart'] =
            "@Tags(['x'])\nlibrary;\nvoid main() {}\n"
        ..['modules/pkg_a/test/net/third_test.dart'] = testBody
        ..['modules/pkg_a/test/net/fourth_test.dart'] = testBody;
      final d = makeRepo(repo);
      final ws = Workspace.load(d.path);
      final s = resolve(ws, [
        'modules/pkg_a/test/net/client_test.dart',
        'modules/pkg_a/test/net/uses_n_test.dart',
        'modules/pkg_a/test/net/third_test.dart',
        'modules/pkg_a/test/net/fourth_test.dart',
      ]);
      final spy = Spy();
      await runSelection(ws, s,
          processes: spy, out: StringBuffer(), err: StringBuffer());
      expect(spy.calls.length, 2);
      final bundle = spy.calls.first;
      expect(bundle.cmd.last, 'test/$bundleName');
      expect(bundle.bundle, contains('third_test.dart'));
      expect(bundle.bundle, contains('fourth_test.dart'));
      expect(bundle.bundle, isNot(contains('client_test.dart')));
      expect(spy.calls.last.targets, [
        'test/net/client_test.dart',
        'test/net/uses_n_test.dart',
      ]);
    });

    test('process-global state (direct or via helper) runs isolated', () async {
      final repo = standardRepo()
        ..['modules/pkg_a/test/net/client_test.dart'] =
            'void main() { Hive.init(1); }\n'
        ..['modules/pkg_a/test/net/h.dart'] =
            'void setup() { GetIt.I.registerSingleton<A>(A()); }\n'
        ..['modules/pkg_a/test/net/uses_n_test.dart'] =
            "import 'h.dart';\nvoid main() {}\n"
        ..['modules/pkg_a/test/net/third_test.dart'] = testBody
        ..['modules/pkg_a/test/net/fourth_test.dart'] = testBody;
      final d = makeRepo(repo);
      final ws = Workspace.load(d.path);
      final s = resolve(ws, [
        for (final t in ['client', 'uses_n', 'third', 'fourth'])
          'modules/pkg_a/test/net/${t}_test.dart',
      ]);
      final spy = Spy();
      await runSelection(ws, s,
          processes: spy, out: StringBuffer(), err: StringBuffer());
      final bundle = spy.calls.first.bundle!;
      expect(bundle, isNot(contains('client_test.dart')));
      expect(bundle, isNot(contains('uses_n_test.dart')));
      expect(spy.calls.last.targets,
          ['test/net/client_test.dart', 'test/net/uses_n_test.dart']);
    });

    test('FLUTTER_TEST_BUNDLE=0 runs the selection unbundled', () async {
      final d = makeRepo(standardRepo());
      final ws = Workspace.load(d.path);
      final s = resolve(ws, ['modules/pkg_a/lib/net/client.dart']);
      final spy = Spy();
      await runSelection(ws, s,
          processes: spy,
          environment: {'FLUTTER_TEST_BUNDLE': '0'},
          out: StringBuffer(),
          err: StringBuffer());
      final c = spy.calls.firstWhere((c) => c.cwd.endsWith('pkg_a'));
      expect(c.bundle, isNull);
      expect(c.targets, [
        'test/net/client_test.dart',
        'test/net/uses_n_test.dart',
      ]);
    });

    test('bundle removed even when run fails; exit non-zero', () async {
      final d = makeRepo(standardRepo());
      final ws = Workspace.load(d.path);
      final s = resolve(ws, ['modules/pkg_a/lib/net/client.dart']);
      final err = StringBuffer();
      final code = await runSelection(ws, s,
          processes: Spy(FakeFlutter(failBundle: true, exitCode: 7)),
          out: StringBuffer(),
          err: err);
      expect(code, 1);
      expect(err.toString(), contains('failed (exit 7)'));
      final left = Directory(p.join(d.path, 'modules/pkg_a/test'))
          .listSync(recursive: true)
          .any((e) => e.path.endsWith(bundleName));
      expect(left, isFalse);
    });

    test('continues after a failing package and reports failure', () async {
      final d = makeRepo(standardRepo());
      final ws = Workspace.load(d.path);
      final s = resolve(ws, ['melos.yaml']);
      final spy = Spy(FakeFlutter(failFiles: {'test'}));
      final code = await runSelection(ws, s,
          processes: spy, out: StringBuffer(), err: StringBuffer());
      expect(spy.calls.length, 3);
      expect(code, 1);
    });

    test('mode none runs nothing and succeeds', () async {
      final d = makeRepo(standardRepo());
      final ws = Workspace.load(d.path);
      final spy = Spy();
      final s = resolve(ws, ['README.md']);
      final code = await runSelection(ws, s,
          processes: spy, out: StringBuffer(), err: StringBuffer());
      expect(code, 0);
      expect(spy.calls, isEmpty);
    });
  });

  group('runner coverage', () {
    test('every invocation gets coverage; lcov merged into one file', () async {
      final d = makeRepo(standardRepo());
      final ws = Workspace.load(d.path);
      final s = resolve(ws, ['modules/pkg_a/lib/net/client.dart']);
      final spy = Spy();
      await runSelection(ws, s,
          processes: spy,
          coverage: true,
          out: StringBuffer(),
          err: StringBuffer());
      expect(spy.calls, isNotEmpty);
      for (final c in spy.calls) {
        expect(c.cmd, contains('--coverage'));
        expect(c.cmd, contains('--coverage-path'));
      }
      final merged = File(p.join(d.path, 'modules/pkg_a', coverageLcovPath));
      expect(merged.existsSync(), isTrue);
      expect(merged.readAsStringSync(), contains('SF:lib/'));
    });

    test('full package also gets coverage; stale lcov removed', () async {
      final d = makeRepo({
        ...standardRepo(),
        'modules/pkg_a/$coverageLcovPath': 'stale',
      });
      final ws = Workspace.load(d.path);
      final s = resolve(ws, ['modules/pkg_a/assets/x.json']);
      final spy = Spy();
      await runSelection(ws, s,
          processes: spy,
          coverage: true,
          out: StringBuffer(),
          err: StringBuffer());
      expect(spy.calls.single.cmd, contains('--coverage'));
      final merged = File(p.join(d.path, 'modules/pkg_a', coverageLcovPath));
      expect(merged.readAsStringSync(), isNot('stale'));
    });
  });

  group('cli', () {
    Future<(int, String, String)> cli(List<String> args, Directory d,
        {ProcessRunner? processes}) async {
      final out = StringBuffer(), err = StringBuffer();
      final code = await runCli(args,
          root: d.path, out: out, err: err, processes: processes);
      return (code, out.toString(), err.toString());
    }

    test('select prints JSON and writes --output', () async {
      final d = makeRepo({
        ...standardRepo(),
        'changed.txt': 'modules/pkg_a/lib/net/client.dart\n',
      });
      final outFile = p.join(d.path, 'out.json');
      final (code, out, _) = await cli([
        'select',
        '--changed-files',
        p.join(d.path, 'changed.txt'),
        '--output',
        outFile,
      ], d);
      expect(code, 0);
      final j = jsonDecode(out) as Map<String, dynamic>;
      expect(j['mode'], 'selected');
      expect(jsonDecode(File(outFile).readAsStringSync()), j);
    });

    test('select with failing git diff falls back to ALL', () async {
      final d = makeRepo(standardRepo());
      final (code, out, err) =
          await cli(['select', '--base', 'x', '--head', 'y'], d);
      expect(code, 0);
      expect((jsonDecode(out) as Map)['mode'], 'all');
      expect(err, isNotEmpty);
    });

    test('usage errors exit 2', () async {
      final d = makeRepo(standardRepo());
      expect((await cli(['select'], d)).$1, 2);
      expect((await cli(['bogus'], d)).$1, 2);
      expect((await cli([], d)).$1, 2);
    });

    test('validate exits 0 clean, 1 on violations, 2 on config error',
        () async {
      // Rule f needs the index, hence package configs; without them
      // validate reports an environment problem (exit 2).
      final configs = Map.fromEntries([
        for (final (dir, deps) in [
          ('.', ['.', 'modules/pkg_a', 'modules/pkg_b']),
          ('modules/pkg_a', ['modules/pkg_a', 'modules/pkg_b']),
          ('modules/pkg_b', ['modules/pkg_b']),
        ])
          packageConfig(
              dir, {for (final d in deps) d == '.' ? 'app' : p.basename(d): d})
      ]);
      var d = makeRepo(standardRepo());
      expect((await cli(['validate'], d)).$1, 2);
      d = makeRepo({...standardRepo(), ...configs});
      expect((await cli(['validate'], d)).$1, anyOf(0, 1));
      d = makeRepo({
        ...standardRepo(),
        ...configs,
        'modules/pkg_b/lib/stray/x.dart': '',
        'modules/pkg_b/test_impact.yaml':
            bYaml.replaceFirst('"lib/**"', '"lib/b.dart"'),
      });
      final (code, out, _) = await cli(['validate'], d);
      expect(code, 1);
      expect(out, contains('lib/stray/x.dart'));
      d = makeRepo({...standardRepo(), 'modules/pkg_b/test_impact.yaml': '['});
      expect((await cli(['validate'], d)).$1, 2);
    });

    test('run uses the injected executor', () async {
      final d = makeRepo({
        ...standardRepo(),
        'changed.txt': 'modules/pkg_a/assets/x.json\n',
      });
      final spy = Spy();
      final (code, _, _) = await cli(
          ['run', '--changed-files', p.join(d.path, 'changed.txt')], d,
          processes: spy);
      expect(code, 0);
      expect(spy.calls, hasLength(1));
    });

    group('run --coverage', () {
      Directory gitRepo() {
        final d = makeRepo(standardRepo());
        void git(List<String> a) {
          final r = Process.runSync('git', a, workingDirectory: d.path);
          expect(r.exitCode, 0, reason: '${r.stderr}');
        }

        git(['init', '-q', '-b', 'main']);
        git(['config', 'user.email', 't@example.invalid']);
        git(['config', 'user.name', 't']);
        git(['add', '.']);
        git(['commit', '-q', '-m', 'base']);
        File(p.join(d.path, 'modules/pkg_a/lib/net/client.dart'))
            .writeAsStringSync('// c\nint a = 1;\nint b = 2;\n');
        git(['commit', '-qam', 'head']);
        return d;
      }

      // Scripted flutter that, like the real one, honours the lcov path
      // it was given.
      ProcessRunner lcovWriter() => Spy(FakeFlutter(onRun: (call) {
            if (call.workingDirectory.endsWith('pkg_a')) {
              final i = call.arguments.indexOf('--coverage-path');
              File(call.arguments[i + 1])
                ..parent.createSync(recursive: true)
                ..writeAsStringSync('SF:lib/net/client.dart\nDA:2,1\n'
                    'DA:3,0\nend_of_record\n');
            }
          }));

      test('writes json + md and prints summary', () async {
        final d = gitRepo();
        final (code, out, err) = await cli(
            ['run', '--coverage', '--base', 'HEAD~1', '--head', 'HEAD'], d,
            processes: lcovWriter());
        expect(code, 0, reason: err);
        expect(out, contains('Changed-line coverage: 50.0% (1/2)'));
        final j = jsonDecode(File(p.join(d.path, 'test-impact-coverage.json'))
            .readAsStringSync()) as Map;
        expect(j['overall_changed_line_pct'], 50.0);
        expect(
            File(p.join(d.path, 'test-impact-coverage.md')).readAsStringSync(),
            contains('client.dart'));
      });

      test('no lcov means not_loaded and a failed run', () async {
        final d = gitRepo();
        final (code, out, _) = await cli(
            ['run', '--coverage', '--base', 'HEAD~1', '--head', 'HEAD'], d,
            processes: Spy(FakeFlutter(writeCoverage: false)));
        // A green run without a report fails closed; the coverage report
        // is still written and flags the file.
        expect(code, 1);
        expect(out, contains('1 file not loaded'));
      });

      test('without base reports n/a with a note', () async {
        final d = makeRepo({
          ...standardRepo(),
          'changed.txt': 'modules/pkg_a/assets/x.json\n',
        });
        final (code, out, _) = await cli([
          'run',
          '--coverage',
          '--changed-files',
          p.join(d.path, 'changed.txt'),
        ], d, processes: Spy());
        expect(code, 0);
        expect(out, contains('Changed-line coverage: n/a'));
        expect(
            File(p.join(d.path, 'test-impact-coverage.md')).readAsStringSync(),
            contains('Note:'));
      });
    });
  });
}
