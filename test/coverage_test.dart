import 'package:test/test.dart';
import 'package:test_impact/src/coverage.dart';

const lcovA = '''
SF:lib/a.dart
DA:1,1
DA:2,0
DA:3,2
end_of_record
SF:lib/gen.g.dart
DA:1,1
end_of_record
''';

const lcovB = '''
SF:lib/a.dart
DA:2,3
DA:4,0
end_of_record
''';

const diffText = '''
diff --git a/modules/p/lib/a.dart b/modules/p/lib/a.dart
index 1..2 100644
--- a/modules/p/lib/a.dart
+++ b/modules/p/lib/a.dart
@@ -1,0 +2,2 @@
+x
+y
@@ -5 +7 @@
-old
+new
@@ -9,2 +10,0 @@
-gone
-gone
diff --git a/modules/p/lib/gone.dart b/modules/p/lib/gone.dart
deleted file mode 100644
--- a/modules/p/lib/gone.dart
+++ /dev/null
@@ -1,3 +0,0 @@
-a
diff --git a/old.dart b/modules/p/lib/moved.dart
similarity index 80%
rename from old.dart
rename to modules/p/lib/moved.dart
--- a/old.dart
+++ b/modules/p/lib/moved.dart
@@ -3 +3,2 @@
-a
+b
+c
''';

void main() {
  group('parseLcov', () {
    test('prefixes package-relative SF', () {
      final m = parseLcov(lcovA, pkgDir: 'modules/p', root: '/r');
      expect(m.keys, contains('modules/p/lib/a.dart'));
      expect(m['modules/p/lib/a.dart'], {1: 1, 2: 0, 3: 2});
    });

    test('root pkg keeps path; absolute is relativised', () {
      final m = parseLcov(
          'SF:/r/modules/p/lib/z.dart\nDA:1,1\n'
          'end_of_record\n',
          pkgDir: '.',
          root: '/r');
      expect(m.keys.single, 'modules/p/lib/z.dart');
      final n = parseLcov(lcovA, pkgDir: '.', root: '/r');
      expect(n.keys, contains('lib/a.dart'));
    });

    test('ignores malformed lines', () {
      final m = parseLcov(
          'SF:lib/a.dart\nDA:x,y\nDA:5\nDA:6,1\n'
          'end_of_record\n',
          pkgDir: '.',
          root: '/r');
      expect(m['lib/a.dart'], {6: 1});
    });
  });

  test('mergeLcov sums hits per line', () {
    final a = parseLcov(lcovA, pkgDir: '.', root: '/r');
    final b = parseLcov(lcovB, pkgDir: '.', root: '/r');
    final m = mergeLcov([a, b]);
    expect(m['lib/a.dart'], {1: 1, 2: 3, 3: 2, 4: 0});
  });

  group('parseDiffHunks', () {
    final h = parseDiffHunks(diffText);
    test('added and modified lines', () {
      expect(h['modules/p/lib/a.dart'], {2, 3, 7});
    });
    test('deleted file and pure deletions ignored', () {
      expect(h.containsKey('modules/p/lib/gone.dart'), isFalse);
    });
    test('rename uses head path', () {
      expect(h['modules/p/lib/moved.dart'], {3, 4});
      expect(h.containsKey('old.dart'), isFalse);
    });
    test('empty diff', () => expect(parseDiffHunks(''), isEmpty));
  });

  group('isTrackedSource', () {
    test('lib dart only, generated excluded', () {
      expect(isTrackedSource('modules/p/lib/a.dart'), isTrue);
      expect(isTrackedSource('lib/a.dart'), isTrue);
      expect(isTrackedSource('test/a_test.dart'), isFalse);
      for (final s in ['g', 'freezed', 'mocks', 'config', 'gr']) {
        expect(isTrackedSource('lib/a.$s.dart'), isFalse, reason: s);
      }
      expect(isTrackedSource('lib/a.md'), isFalse);
    });
  });

  group('computeCoverage', () {
    test('changed-line and file coverage', () {
      // changed {2,3,7} in a.dart; DA lines 1..4 (7 uninstrumented)
      final lcov = mergeLcov([
        parseLcov(lcovA, pkgDir: 'modules/p', root: '/r'),
        parseLcov(lcovB, pkgDir: 'modules/p', root: '/r'),
      ]);
      final r = computeCoverage(parseDiffHunks(diffText), lcov);
      final f = r.files.singleWhere((f) => f.path.endsWith('a.dart'));
      expect(f.changedLines, 3);
      expect(f.instrumented, 2); // lines 2,3; 7 is blank/comment
      expect(f.hit, 2); // 2 -> 3 hits, 3 -> 2 hits
      expect(f.changedPct, 100.0);
      expect(f.filePct, 75.0); // 3 of 4 DA hit
    });

    test('not_loaded counted, reported separately', () {
      final r = computeCoverage(parseDiffHunks(diffText), {});
      expect(r.notLoaded.length, 2);
      expect(r.notLoaded.first.filePct, 0.0);
      expect(r.notLoaded.first.unmeasuredChangedLines, greaterThan(0));
      expect(r.overallPct, isNull);
      expect(r.summary(), contains('2 files not loaded'));
    });

    test('generated files and tests excluded', () {
      final r = computeCoverage({
        'lib/x.g.dart': {1},
        'lib/x.freezed.dart': {1},
        'test/x_test.dart': {1},
      }, {});
      expect(r.files, isEmpty);
      expect(r.notLoaded, isEmpty);
    });

    test('loaded file with only blank changes is n/a', () {
      final r = computeCoverage({
        'lib/a.dart': {9},
      }, {
        'lib/a.dart': {1: 1}
      });
      expect(r.files.single.changedPct, isNull);
      expect(r.overallPct, isNull);
      expect(r.notLoaded, isEmpty);
    });

    test('overall aggregates and summary format', () {
      final r = computeCoverage({
        'lib/a.dart': {1, 2},
        'lib/b.dart': {1},
        'lib/c.dart': {4},
      }, {
        'lib/a.dart': {1: 1, 2: 0},
        'lib/b.dart': {1: 5},
      });
      expect(r.hit, 2);
      expect(r.instrumented, 3);
      expect(
          r.summary(), 'Changed-line coverage: 66.7% (2/3), 1 file not loaded');
    });

    test('empty diff: no changed production lines', () {
      final r = computeCoverage({}, {});
      expect(r.overallPct, isNull);
      expect(r.summary(), contains('n/a'));
      expect(r.toMarkdown(), contains('no changed production lines'));
      final j = r.toJson();
      expect(j['overall_changed_line_pct'], isNull);
      expect(j['files'], isEmpty);
    });

    test('markdown table has rows', () {
      final r = computeCoverage({
        'lib/a.dart': {1, 2}
      }, {
        'lib/a.dart': {1: 1, 2: 0}
      });
      final md = r.toMarkdown();
      expect(md, contains('| lib/a.dart | 2 | 1 | 50.0% | 50.0% |'));
    });
  });
}
