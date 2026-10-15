import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:test_impact/test_impact.dart';

import 'bundle/bundle_support.dart';
import 'fixture.dart';

void main() {
  tearDown(runTearDowns);

  String rootWith(String tooling) => '${rootYaml}tooling:\n$tooling';

  PackageConfig load(String yaml) {
    final d = makeRepo({'test_impact.yaml': yaml});
    return loadConfig(p.join(d.path, 'test_impact.yaml'));
  }

  Matcher fails(String key) => throwsA(isA<ConfigException>()
      .having((e) => e.key, 'key', key)
      .having((e) => e.file, 'file', endsWith('test_impact.yaml')));

  group('tooling config', () {
    test('absent block yields null and generic defaults', () {
      final cfg = load(rootYaml);
      expect(cfg.tooling, isNull);
      final t = Tooling();
      expect(t.flutterCommand, ['flutter']);
      expect(t.dartCommand, ['dart']);
      expect(t.bundlePolicy, isNull);
      expect(t.isolationPatterns, defaultIsolationPatternSources);
    });

    test('default patterns hold no repo-specific names', () {
      expect(
          defaultIsolationPatternSources.any((s) =>
              RegExp(s).hasMatch("Hive.init('x');") ||
              RegExp(s).hasMatch('Bloc.observer = o;')),
          isTrue);
    });

    test('overrides are parsed', () {
      final t = load(rootWith('''
  flutter_command: [fvm, flutter]
  dart_command: [fvm, dart]
  isolation_patterns: ['Foo\\.init\\(']
  bundle_policy: cfg/policy.json
''')).tooling!;
      expect(t.flutterCommand, ['fvm', 'flutter']);
      expect(t.dartCommand, ['fvm', 'dart']);
      expect(t.isolationPatterns, [r'Foo\.init\(']);
      expect(t.isolationRegExps.single.hasMatch('Foo.init('), isTrue);
      expect(t.bundlePolicy, 'cfg/policy.json');
    });

    test('empty block keeps defaults', () {
      final t = load('${rootYaml}tooling: {}\n').tooling!;
      expect(t.flutterCommand, ['flutter']);
    });

    test('invalid regex names the key', () {
      expect(() => load(rootWith("  isolation_patterns: ['ok', '(']\n")),
          fails('tooling.isolation_patterns[1]'));
    });

    test('bad types and unknown keys fail with context', () {
      expect(() => load(rootWith('  flutter_command: fvm\n')),
          fails('tooling.flutter_command'));
      expect(() => load(rootWith('  dart_command: []\n')),
          fails('tooling.dart_command'));
      // Removed key: nothing consumes it, so it is rejected as unknown.
      expect(() => load(rootWith('  coverage_packages: [a]\n')),
          fails('tooling.coverage_packages'));
      expect(() => load(rootWith('  bundle_policy: 3\n')),
          fails('tooling.bundle_policy'));
      expect(() => load(rootWith('  nope: 1\n')), fails('tooling.nope'));
      expect(() => load('${rootYaml}tooling: 3\n'), fails('tooling'));
    });

    test('non-root tooling is a workspace config error', () {
      final repo = standardRepo();
      repo['modules/pkg_a/test_impact.yaml'] =
          '$aYaml\ntooling:\n  flutter_command: [x]\n';
      final ws = Workspace.load(makeRepo(repo).path);
      expect(
          ws.errors.map((e) => e.toString()),
          contains(allOf(contains('pkg_a'), contains('tooling'),
              contains('root mapping'))));
    });
  });

  group('loadTooling', () {
    test('reads the root block; defaults without file or block', () {
      final d = makeRepo({
        'test_impact.yaml': rootWith('  flutter_command: [fvm, flutter]\n'
            '  bundle_policy: p.json\n'),
      });
      final t = loadTooling(d.path);
      expect(t.flutterCommand, ['fvm', 'flutter']);
      expect(t.bundlePolicy, 'p.json');
      expect(loadTooling(makeRepo({}).path).flutterCommand, ['flutter']);
      expect(
          loadTooling(makeRepo({'test_impact.yaml': rootYaml}).path)
              .bundlePolicy,
          isNull);
    });
  });

  group('workspace tooling', () {
    test('defaults without a root block', () {
      final ws = Workspace.load(makeRepo(standardRepo()).path);
      expect(ws.tooling.flutterCommand, ['flutter']);
    });

    test('root block is honoured', () {
      final repo = standardRepo()
        ..['test_impact.yaml'] =
            rootWith('  flutter_command: [fvm, flutter]\n');
      final ws = Workspace.load(makeRepo(repo).path);
      expect(ws.errors, isEmpty);
      expect(ws.tooling.flutterCommand, ['fvm', 'flutter']);
    });
  });

  group('runner uses tooling', () {
    test('configured command and isolation patterns', () async {
      final repo = standardRepo()
        ..['test_impact.yaml'] = rootWith('  flutter_command: [fvm, flutter]\n'
            "  isolation_patterns: ['ZZ_GLOBAL']\n")
        ..['modules/pkg_a/test/net/client_test.dart'] =
            'void main() { ZZ_GLOBAL; }\n'
        ..['modules/pkg_a/test/net/uses_n_test.dart'] = 'void main() {}\n'
        ..['modules/pkg_a/test/net/third_test.dart'] =
            'void main() { Hive.init(1); }\n';
      final d = makeRepo(repo);
      final ws = Workspace.load(d.path);
      expect(ws.errors, isEmpty);
      final s = resolve(ws, [
        for (final t in ['client', 'uses_n', 'third'])
          'modules/pkg_a/test/net/${t}_test.dart',
      ]);
      final spy = FakeFlutter().processes;
      await runSelection(ws, s,
          processes: spy, out: StringBuffer(), err: StringBuffer());
      final calls =
          spy.calls.where((c) => c.workingDirectory.endsWith('pkg_a'));
      // Bundle first, then the isolated files; both use the configured
      // command prefix.
      expect(calls.length, 2);
      for (final c in calls) {
        expect(c.executable, 'fvm');
        expect(c.arguments.take(2), ['flutter', 'test']);
      }
      // Custom pattern isolates client (and replaces the default Hive
      // pattern, so third is bundled).
      final isolated = calls.last.arguments;
      expect(isolated, contains('test/net/client_test.dart'));
      expect(isolated, isNot(contains('test/net/third_test.dart')));
      expect(
          File(p.join(d.path, 'modules/pkg_a/test/flutter_test_bundle.g.dart'))
              .existsSync(),
          isFalse);
    });
  });
}
