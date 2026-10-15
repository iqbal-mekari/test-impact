import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:test_impact/src/bundle/bundle_plan.dart';
import 'package:test_impact/src/bundle/bundle_policy.dart';

import 'bundle_support.dart';

void main() {
  late TestPackage pkg;
  late List<String> logs;

  setUp(() {
    pkg = TestPackage.create();
    logs = [];
  });

  BundlePlan plan({
    Map<String, Object?> policy = const {},
    String? path,
    List<RegExp>? patterns,
  }) =>
      loadBundlePlan(
        packageDir: pkg.dir,
        policyPath: path ?? pkg.policy({'pkg': policy}),
        packageKey: 'pkg',
        log: logs.add,
        isolationPatterns: patterns,
      ).plan;

  List<String>? reasonsOf(String text) {
    pkg.write('test/d_test.dart', text);
    return plan().isolated['test/d_test.dart'];
  }

  test('should flag every default soft hazard as unreviewed', () {
    const soft = [
      'HttpOverrides.global = X();',
      'TestFlutterBinding.ensureInitialized();',
      'setUpAll(() {});',
      'debugDefaultTargetPlatformOverride = 1;',
      'X.setMockInitialValues({});',
      'PathPlatform.instance = F();',
      'Bloc.observer = O();',
      "Hive.init('x');",
      'g.registerFactory<A>(() => A());',
    ];
    for (final code in soft) {
      final reasons = reasonsOf('void main() {$code}');
      expect(reasons, hasLength(1), reason: code);
      expect(reasons!.single, startsWith('isolation-pattern /'));
      expect(reasons.single, endsWith(' in test/d_test.dart'));
      expect(plan().unreviewed, ['test/d_test.dart']);
    }
  });

  test('should use caller patterns instead of the defaults', () {
    pkg.write('test/d_test.dart', 'void main() {Singleton.init();}');
    final custom = [RegExp(r'Singleton\s*\.\s*init\s*\(')];

    expect(plan(patterns: custom).isolated['test/d_test.dart'], [
      r'isolation-pattern /Singleton\s*\.\s*init\s*\(/ in test/d_test.dart'
    ]);
    expect(plan().isolated, isEmpty);
    pkg.write('test/e_test.dart', softTest);
    expect(plan(patterns: custom).isolated.keys, ['test/d_test.dart']);
  });

  test('should treat a null policy path as no policy', () {
    pkg.write('test/d_test.dart', softTest);
    final result = loadBundlePlan(
      packageDir: pkg.dir,
      policyPath: null,
      packageKey: 'pkg',
      log: logs.add,
    ).plan;

    expect(result.unreviewed, ['test/d_test.dart']);
    expect(logs, isEmpty);
  });

  test('should isolate every hard hazard without review', () {
    const hard = {
      "@Tags(['slow'])\nlibrary;\nvoid main() {}": 'file-annotation',
      'Future<void> main() async {}': 'async-main',
      'void main() async {}': 'async-main',
      'void main(List<String> args) {}': 'main-with-args',
      'void helper() {}': 'no-main',
    };
    for (final MapEntry(key: text, value: code) in hard.entries) {
      expect(reasonsOf(text), ['$code in test/d_test.dart']);
      expect(plan().unreviewed, isEmpty);
    }
    expect(reasonsOf('void main() {g.registerFactory(f); g.reset();}'), isNull);
    expect(reasonsOf('@GenerateMocks([A])\nvoid main() {}'), isNull);
  });

  test('should flag a test config above the file', () {
    pkg
      ..write('test/sub/flutter_test_config.dart', 'x\n')
      ..write('test/sub/d_test.dart');
    expect(plan().isolated['test/sub/d_test.dart'],
        ['flutter-test-config in test/sub/flutter_test_config.dart']);
  });

  test('should follow helper imports, cycles, skip outside ones', () {
    pkg
      ..write('test/h/s.dart', "import 'deeper.dart';\nimport 's.dart';\n")
      ..write('test/h/deeper.dart', "import 's.dart';\nHive.init('x');")
      ..write('../outside.dart', 'HttpOverrides.global = 1;')
      ..write(
          'test/d_test.dart',
          "import 'h/s.dart';\nimport 'package:x/y.dart';\n"
              "import '../../outside.dart';\nvoid main() {}\n");
    expect(plan().isolated['test/d_test.dart'],
        [matches(r'^isolation-pattern .* in test/h/deeper\.dart$')]);
  });

  test('should apply verdicts and sort the isolated files', () {
    pkg
      ..write('test/z_test.dart', softTest)
      ..write('test/d_test.dart', softTest)
      ..write('test/e_test.dart', 'Future<void> main() async {}\n');
    final result = plan(policy: {
      'isolate': {'test/a_test.dart': 'collides'},
      'bundle_safe': {'test/d_test.dart': 'ok', 'test/e_test.dart': 'ok'},
    });
    expect(result.bundled,
        ['test/b_test.dart', 'test/c_test.dart', 'test/d_test.dart']);
    expect(result.isolated, {
      'test/a_test.dart': ['policy: collides'],
      'test/e_test.dart': ['async-main in test/e_test.dart'],
      'test/z_test.dart': [
        matches(r'^isolation-pattern .*setUpAll.* in test/z_test\.dart$')
      ],
    });
    expect(result.unreviewed, ['test/z_test.dart']);
  });

  test('should not bundle fewer than two files', () {
    for (final name in ['b', 'c']) {
      File(p.join(pkg.dir, 'test', '${name}_test.dart')).deleteSync();
    }
    expect(plan().bundled, isEmpty);
    expect(plan().isolated['test/a_test.dart'], ['bundle-too-small']);
  });

  test('should isolate everything when the policy is unusable', () {
    final result = plan(path: p.join(pkg.repoRoot, 'missing.json'));
    expect(result.bundled, isEmpty);
    expect(result.isolated['test/a_test.dart'], ['policy-error']);
    expect(logs.single, contains('bundle policy unusable'));
  });

  group('BundlePolicy.load', () {
    test('should reject malformed policies', () {
      const pkg1 = '{"version": 1, "packages": {"pkg": ';
      const bad = [
        '{"version": 2, "packages": {}}',
        '$pkg1{"unknown": {}}}}',
        '$pkg1{"isolate": ["test/a_test.dart"]}}}',
        '$pkg1{"isolate": {"../x_test.dart": "r"}}}}',
        '$pkg1{"bundle_safe": {"test/a_test.dart": ""}}}}',
        'not json',
      ];
      final path = p.join(pkg.repoRoot, 'bad.json');
      for (final text in bad) {
        File(path).writeAsStringSync(text);
        expect(() => BundlePolicy.load(path, 'pkg'),
            throwsA(isA<BundlePolicyException>()));
      }
    });
  });

  test('should render groups, escape quotes and reject non-test files', () {
    final text = renderBundle(['test/a_test.dart', "test/x/it's_test.dart"]);

    expect(text, contains('GENERATED by test_impact'));
    expect(text, contains("import 'a_test.dart' as t0;"));
    expect(text, contains(r"import 'x/it\'s_test.dart' as t1;"));
    expect(text, contains("group('test/a_test.dart', t0.main);"));
    expect(() => renderBundle(['lib/a_test.dart']), throwsArgumentError);
  });
}
