import 'dart:io';

import 'package:test/test.dart';
import 'package:test_impact/test_impact.dart';

import 'index_fixture.dart';

const a = 'modules/pkg_a';
const b = 'modules/pkg_b';

void main() {
  group('index on a clean two-package repo', () {
    late Directory repo;
    late Workspace ws;
    late ImpactIndex index;

    setUpAll(() async {
      repo = writeRepo(twoPackageRepo());
      ws = Workspace.load(repo.path);
      index = await ImpactIndex.build(ws);
    });
    tearDownAll(() => repo.deleteSync(recursive: true));

    Set<String>? reach(String f) => index.testsReaching(f).tests;

    test('builds without failure or wildcards', () {
      expect(index.failure, isNull);
      expect(index.unavailable, isEmpty);
      expect(index.tainted, isEmpty);
      expect(index.wildcardTests, isEmpty);
    });

    test('barrel is transparent; cross-package narrowing', () {
      expect(reach('$a/lib/src/x.dart'), {
        '$a/test/x_test.dart',
        '$a/test/z_test.dart',
        '$a/test/mock_x_test.dart',
        '$b/test/xb_test.dart',
      });
    });

    test('transitive lib reach crosses packages', () {
      expect(reach('$a/lib/src/y.dart'),
          {'$a/test/y_test.dart', '$b/test/b_test.dart'});
    });

    test('hub mocks are traversed per declaration', () {
      expect(reach('$a/lib/src/y.dart'),
          isNot(contains('$a/test/mock_x_test.dart')));
    });

    test('directive-only barrel reaches its importers', () {
      expect(reach('$a/lib/pkg_a.dart'), {
        '$a/test/x_test.dart',
        '$a/test/y_test.dart',
        '$a/test/model_test.dart',
        '$a/test/mock_x_test.dart',
        '$b/test/b_test.dart',
        '$b/test/xb_test.dart',
      });
    });

    test('part and generated part files', () {
      expect(reach('$a/lib/src/model.dart'), {'$a/test/model_test.dart'});
      expect(reach('$a/lib/src/model.g.dart'), {'$a/test/model_test.dart'});
    });

    test('unreferenced file reaches no test', () {
      expect(reach('$a/lib/src/lonely.dart'), isEmpty);
    });

    test('deleted file falls back', () {
      final r = index.testsReaching('$a/lib/src/gone.dart');
      expect(r.tests, isNull);
      expect(r.why, 'deleted');
    });

    test('part without a library falls back', () {
      expect(
          index.testsReaching('$a/lib/src/orphan.g.dart').why, 'not_indexed');
    });

    test('closure sizes cover every test', () {
      final sizes = index.closureSizes();
      expect(sizes.length, 8);
      expect(sizes['$b/test/plain_test.dart'], 1); // main only
      expect(sizes['$b/test/b_test.dart'], greaterThan(2));
    });
  });

  group('index on a degraded repo', () {
    late Directory repo;
    late ImpactIndex index;

    setUpAll(() async {
      repo = writeRepo(degradedRepo());
      index = await ImpactIndex.build(Workspace.load(repo.path));
    });
    tearDownAll(() => repo.deleteSync(recursive: true));

    test('package without package config is unavailable', () {
      expect(index.unavailable, {b});
      expect(index.testsReaching('$b/lib/b.dart').why, 'index_unavailable');
    });

    test('file with analysis errors falls back', () {
      expect(
          index.testsReaching('$a/lib/src/broken.dart').why, 'analysis_error');
    });

    test('tests of unknown reach are wildcards, kept everywhere', () {
      expect(index.wildcardTests, {
        '$a/test/broken_user_test.dart',
        '$b/test/b_test.dart',
        '$b/test/xb_test.dart',
        '$b/test/plain_test.dart',
      });
      expect(index.testsReaching('$a/lib/src/y.dart').tests,
          containsAll(['$a/test/y_test.dart', ...index.wildcardTests]));
    });
  });

  test('failed index falls back for every file', () {
    final idx = ImpactIndex.failed('/nowhere', 'boom');
    expect(idx.testsReaching('lib/x.dart').why, 'index_failed');
  });
}
