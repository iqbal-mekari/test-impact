import 'dart:io';

import 'package:test/test.dart';
import 'package:test_impact/test_impact.dart';

import 'fixture.dart';
import 'index_fixture.dart';

const a = 'modules/pkg_a';
const b = 'modules/pkg_b';

void main() {
  tearDown(runTearDowns);

  group('D1: repo.run_all wins over repo.safe', () {
    final yaml = rootYaml
        .replaceFirst('safe: ["**/*.md", "integration_test/**"]',
            'safe: ["**/*.md", "tools/**", "samples/**"]')
        .replaceFirst('run_all: ["melos.yaml", "**/pubspec.yaml"]',
            'run_all: ["melos.yaml", "**/pubspec.yaml", "**/pubspec.lock"]');

    for (final path in [
      'tools/x/pubspec.yaml',
      'samples/a/pubspec.yaml',
      'modules/pkg_a/pubspec.lock',
    ]) {
      test('$path is ALL', () {
        final repo = standardRepo()..['test_impact.yaml'] = yaml;
        final s = select(makeRepo(repo), [path]);
        expect(s.mode, 'all');
        expect(s.reasons.single.rule, 'repo_run_all');
      });
    }

    test('other tools/ paths stay safe', () {
      final repo = standardRepo()..['test_impact.yaml'] = yaml;
      expect(select(makeRepo(repo), ['tools/x/lib/a.dart']).mode, 'none');
    });
  });

  group('D2: refinement', () {
    late Directory repo;
    late Workspace ws;
    late ImpactIndex index;

    setUpAll(() async {
      repo = writeRepo(twoPackageRepo());
      ws = Workspace.load(repo.path);
      index = await ImpactIndex.build(ws);
    });
    tearDownAll(() => repo.deleteSync(recursive: true));

    Selection refined(List<String> changed, [ImpactIndex? idx]) =>
        resolve(ws, changed, index: idx ?? index);

    test('indexPackagesFor lists owner and dependents', () {
      expect(indexPackagesFor(ws, ['$a/lib/src/x.dart']), {a, b});
      expect(indexPackagesFor(ws, ['$b/lib/b.dart']), {b});
      expect(indexPackagesFor(ws, ['$a/test/x_test.dart']), isEmpty);
    });

    test('narrows owner and dependent packages', () {
      final s = refined(['$a/lib/src/x.dart']);
      expect(s.mode, 'selected');
      expect(s.packages[a]!.mode, 'selected');
      expect(s.packages[a]!.tests, [
        'test/mock_x_test.dart',
        'test/x_test.dart',
        'test/z_test.dart',
      ]);
      expect(s.packages[b]!.mode, 'selected');
      expect(s.packages[b]!.tests, ['test/xb_test.dart']);
      expect(s.reasons.single.rule, 'refined');
    });

    test('precision area keeps v1 behaviour', () {
      final s = resolve(ws, ['$a/lib/src/x.dart']);
      expect(s.packages[a]!.tests.length, 5);
      expect(s.packages[b]!.mode, 'full');
      expect(s.reasons.single.rule, 'area');
    });

    test('generated part selects its users', () {
      final s = refined(['$a/lib/src/model.g.dart']);
      expect(s.packages.keys, [a]);
      expect(s.packages[a]!.tests, ['test/model_test.dart']);
    });

    test('no reaching test is a legit empty selection', () {
      final s = refined(['$a/lib/src/lonely.dart']);
      expect(s.mode, 'none');
      expect(s.reasons.single.rule, 'no_test_reaches');
    });

    test('deleted file falls back to v1 candidates', () {
      final s = refined(['$a/lib/src/gone.dart']);
      expect(s.packages[a]!.tests.length, 5);
      expect(s.packages[b]!.mode, 'full');
      expect(s.reasons.single.rule, 'unrefined:deleted');
    });

    test('failed index falls back to v1 candidates', () {
      final s =
          refined(['$a/lib/src/x.dart'], ImpactIndex.failed(repo.path, 'boom'));
      expect(s.packages[a]!.tests.length, 5);
      expect(s.packages[b]!.mode, 'full');
      expect(s.reasons.single.rule, 'unrefined:index_failed');
    });

    test('full from another path still wins', () {
      final s = refined(['$a/lib/src/x.dart', '$b/lib/b.dart']);
      expect(s.packages[b]!.mode, 'selected');
      expect(s.packages[b]!.tests, ['test/b_test.dart', 'test/xb_test.dart']);
      final t =
          resolve(ws, ['$a/lib/src/x.dart', '$b/pubspec.yaml'], index: index);
      expect(t.mode, isNot('none'));
    });

    test('changed test file is unaffected by refinement', () {
      final s = refined(['$b/test/plain_test.dart']);
      expect(s.packages[b]!.tests, ['test/plain_test.dart']);
    });
  });

  group('D2: degraded index', () {
    late Directory repo;
    late Workspace ws;
    late ImpactIndex index;

    setUpAll(() async {
      repo = writeRepo(degradedRepo());
      ws = Workspace.load(repo.path);
      index = await ImpactIndex.build(ws);
    });
    tearDownAll(() => repo.deleteSync(recursive: true));

    test('unavailable dependent keeps all its tests', () {
      final s = resolve(ws, ['$a/lib/src/y.dart'], index: index);
      expect(s.packages[a]!.tests,
          ['test/broken_user_test.dart', 'test/y_test.dart']);
      expect(s.packages[b]!.tests, [
        'test/b_test.dart',
        'test/plain_test.dart',
        'test/xb_test.dart',
      ]);
    });

    test('file with errors falls back', () {
      final s = resolve(ws, ['$a/lib/src/broken.dart'], index: index);
      expect(s.reasons.single.rule, 'unrefined:analysis_error');
      expect(s.packages[b]!.mode, 'full');
    });
  });
}
