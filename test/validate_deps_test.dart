import 'dart:io';

import 'package:test/test.dart';
import 'package:test_impact/test_impact.dart';

import 'index_fixture.dart';

const pkg = 'modules/pkg';

const yaml = '''
version: 1
package: pkg
run_package: ["lib/pkg.dart", "lib/shared/**"]
areas:
  one:
    sources: ["lib/one/**"]
    tests: ["test/one/**"]
  two:
    sources: ["lib/two/**"]
    tests: ["test/two/**"]
  mid:
    sources: ["lib/mid/**"]
    tests: ["test/mid/**"]
''';

/// One package whose lib files import their own barrel everywhere.
Map<String, String> repoFiles({String mapping = yaml, bool config = true}) {
  final cfg = packageConfig(pkg, {'pkg': pkg});
  return {
    '$pkg/pubspec.yaml': 'name: pkg\n'
        'environment:\n  sdk: ">=3.6.0 <4.0.0"\n',
    '$pkg/test_impact.yaml': mapping,
    if (config) cfg.key: cfg.value,
    '$pkg/lib/pkg.dart': "export 'one/a.dart';\nexport 'one/a2.dart';\n"
        "export 'two/b.dart';\nexport 'two/c.dart';\n"
        "export 'mid/m.dart';\nexport 'shared/util.dart';\n",
    '$pkg/lib/two/b.dart': 'class B {}\n',
    '$pkg/lib/two/c.dart': "import 'package:pkg/pkg.dart';\n\n"
        'class C {\n  final B b = B();\n}\n',
    '$pkg/lib/one/a.dart': "import 'package:pkg/pkg.dart';\n\n"
        'class A {\n  final B b = B();\n}\n',
    '$pkg/lib/one/a2.dart': "import 'package:pkg/pkg.dart';\n\n"
        'B makeB() => B();\n',
    '$pkg/lib/mid/m.dart': 'class M {}\n',
    '$pkg/lib/shared/util.dart': "import 'package:pkg/pkg.dart';\n\n"
        'final b = B();\nfinal a = A();\n',
    '$pkg/test/one/a_test.dart': 'void main() {}\n',
    '$pkg/test/two/b_test.dart': 'void main() {}\n',
    '$pkg/test/mid/m_test.dart': 'void main() {}\n',
  };
}

void main() {
  final dirs = <Directory>[];
  tearDownAll(() {
    for (final d in dirs) {
      d.deleteSync(recursive: true);
    }
  });

  Future<AreaDepReport> check(Map<String, String> files) async {
    final d = writeRepo(files);
    dirs.add(d);
    final ws = Workspace.load(d.path);
    final idx = await ImpactIndex.build(ws, packageDirs: areaPackages(ws));
    return validateAreaDeps(ws, idx);
  }

  test('undeclared reference through the barrel is flagged once', () async {
    final r = await check(repoFiles());
    expect(r.violations.map((v) => v.rule), ['f']);
    final v = r.violations.single;
    expect(v.package, pkg);
    expect(v.message, contains('area one references area two'));
    expect(v.message, contains('lib/one/a'));
    expect(v.message, contains('-> lib/two/b.dart#B'));
    expect(v.environment, isFalse);
    expect(r.warnings, isEmpty);
  });

  test('direct depends_on passes', () async {
    final m = yaml.replaceFirst(
        'tests: ["test/one/**"]',
        'tests: ["test/one/**"]\n'
            '    depends_on: [two]');
    expect((await check(repoFiles(mapping: m))).violations, isEmpty);
  });

  test('transitive depends_on passes', () async {
    final m = yaml
        .replaceFirst('tests: ["test/one/**"]',
            'tests: ["test/one/**"]\n    depends_on: [mid]')
        .replaceFirst('tests: ["test/mid/**"]',
            'tests: ["test/mid/**"]\n    depends_on: [two]');
    expect((await check(repoFiles(mapping: m))).violations, isEmpty);
  });

  test('unavailable index is an environment violation', () async {
    final r = await check(repoFiles(config: false));
    expect(r.violations.single.rule, 'f');
    expect(r.violations.single.environment, isTrue);
    expect(r.violations.single.message, contains('index unavailable'));
  });

  test('failed index is an environment violation', () {
    final d = writeRepo(repoFiles());
    dirs.add(d);
    final ws = Workspace.load(d.path);
    final r = validateAreaDeps(ws, ImpactIndex.failed(d.path, 'boom'));
    expect(r.violations.single.message, contains('index unavailable: boom'));
    expect(r.violations.single.environment, isTrue);
  });

  test('library with analysis errors is a warning only', () async {
    final r = await check({
      ...repoFiles(
          mapping: yaml.replaceFirst('tests: ["test/one/**"]',
              'tests: ["test/one/**"]\n    depends_on: [two]')),
      '$pkg/lib/mid/broken.dart': 'class X extends Missing {}\n',
    });
    expect(r.violations, isEmpty);
    expect(r.warnings.single, contains('lib/mid/broken.dart'));
  });

  group('cli validate', () {
    Future<(int, String, String)> run(Map<String, String> files) async {
      final d = writeRepo(files);
      dirs.add(d);
      final out = StringBuffer(), err = StringBuffer();
      final code = await runCli(['validate'], root: d.path, out: out, err: err);
      return (code, '$out', '$err');
    }

    test('violation exits 1, index time on stderr', () async {
      final (code, out, err) = await run(repoFiles());
      expect(code, 1);
      expect(out, contains('f [$pkg]'));
      expect(err, contains('index of 1 package(s) built in'));
    });

    test('environment problem exits 2', () async {
      final (code, out, _) = await run(repoFiles(config: false));
      expect(code, 2);
      expect(out, contains('index unavailable'));
    });

    test('clean repo exits 0', () async {
      final m = yaml.replaceFirst('tests: ["test/one/**"]',
          'tests: ["test/one/**"]\n    depends_on: [two]');
      final (code, out, _) = await run(repoFiles(mapping: m));
      expect(code, 0);
      expect(out, contains('mapping(s) OK'));
    });
  });
}
