import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:test_impact/test_impact.dart';

import 'bundle/bundle_support.dart';
import 'index_fixture.dart';

const _pkg = 'modules/pkg';

/// One package, areas one/two; `one` uses `two` undeclared (rule f).
Map<String, String> _violating() {
  final cfg = packageConfig(_pkg, {'pkg': _pkg});
  return {
    '$_pkg/pubspec.yaml': 'name: pkg\n'
        'environment:\n  sdk: ">=3.6.0 <4.0.0"\n',
    '$_pkg/test_impact.yaml': 'version: 1\npackage: pkg\n'
        'areas:\n'
        '  one:\n    sources: ["lib/one/**"]\n    tests: ["test/one/**"]\n'
        '  two:\n    sources: ["lib/two/**"]\n    tests: ["test/two/**"]\n',
    cfg.key: cfg.value,
    '$_pkg/lib/two/b.dart': 'class B {}\n',
    '$_pkg/lib/one/a.dart': "import '../two/b.dart';\n\n"
        'class A {\n  final B b = B();\n}\n',
    '$_pkg/test/one/a_test.dart': 'void main() {}\n',
    '$_pkg/test/two/b_test.dart': 'void main() {}\n',
  };
}

void main() {
  final dirs = <Directory>[];
  tearDown(() {
    for (final d in dirs) {
      d.deleteSync(recursive: true);
    }
    dirs.clear();
  });

  late int builds;
  Future<ImpactIndex> counting(Workspace ws, Set<String> d) {
    builds++;
    return ImpactIndex.build(ws, packageDirs: d);
  }

  Future<(int, String, String, Directory)> ci(
      Map<String, String> files, List<String> args,
      {FakeFlutter? flutter, IndexBuilderFn? builder}) async {
    builds = 0;
    final d = writeRepo({
      ...files,
      'changed.txt': 'modules/pkg_a/lib/src/y.dart\n',
    });
    dirs.add(d);
    final out = StringBuffer(), err = StringBuffer();
    final code = await runCli([
      'ci',
      '--changed-files',
      p.join(d.path, 'changed.txt'),
      '--output',
      p.join(d.path, 'sel.json'),
      ...args,
    ],
        root: d.path,
        out: out,
        err: err,
        processes: (flutter ?? FakeFlutter()).processes,
        indexBuilder: builder ?? counting);
    return (code, '$out', '$err', d);
  }

  Map<String, Object?> selection(Directory d) =>
      jsonDecode(File(p.join(d.path, 'sel.json')).readAsStringSync())
          as Map<String, Object?>;

  test('builds the index exactly once and runs the selection', () async {
    final flutter = FakeFlutter();
    final (code, _, err, d) =
        await ci(twoPackageRepo(), const [], flutter: flutter);
    expect(code, 0);
    expect(builds, 1);
    expect(err, contains('index of 2 package(s)'));
    expect(flutter.invocations, isNotEmpty);
    expect(selection(d)['mode'], 'selected');
  });

  test('selection JSON carries every phase timing', () async {
    final (_, _, err, d) = await ci(twoPackageRepo(), const []);
    final t = selection(d)['timings']! as Map;
    expect(t.keys,
        containsAll(['index_ms', 'validate_ms', 'select_ms', 'run_ms']));
    expect(t.values, everyElement(isA<int>()));
    expect(err, contains('timings index_ms='));
  });

  test('validation failure exits 1 before running tests', () async {
    final flutter = FakeFlutter();
    final (code, out, _, d) =
        await ci(_violating(), const [], flutter: flutter);
    expect(code, 1);
    expect(builds, 1);
    expect(out, contains('f [$_pkg]'));
    expect(flutter.invocations, isEmpty);
    expect(File(p.join(d.path, 'sel.json')).existsSync(), isFalse);
  });

  test('unavailable index exits 2 before running tests', () async {
    final flutter = FakeFlutter();
    final (code, _, _, _) = await ci(twoPackageRepo(), const [],
        flutter: flutter, builder: (ws, d) async {
      builds++;
      return ImpactIndex.failed(ws.root, 'boom');
    });
    expect(code, 2);
    expect(builds, 1);
    expect(flutter.invocations, isEmpty);
  });

  test('test failure exits 1 and keeps the selection', () async {
    final (code, _, _, d) =
        await ci(twoPackageRepo(), const [], flutter: FakeFlutter(exitCode: 1));
    expect(code, 1);
    expect(builds, 1);
    expect((selection(d)['timings'] as Map).containsKey('run_ms'), isTrue);
  });

  test('config errors exit 2 without building an index', () async {
    final (code, _, _, _) = await ci({
      ...twoPackageRepo(),
      'modules/pkg_a/test_impact.yaml': 'version: 99\n',
    }, const []);
    expect(code, 2);
    expect(builds, 0);
  });

  test('missing --base and --changed-files is a usage error', () async {
    final out = StringBuffer(), err = StringBuffer();
    final code = await runCli(['ci'], out: out, err: err);
    expect(code, 2);
  });
}
