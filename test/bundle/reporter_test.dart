import 'dart:convert';
import 'dart:io';

import 'package:test_impact/src/bundle/reporter.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  late Directory repo;
  late String appDir;

  setUp(() {
    repo = Directory.systemTemp.createTempSync('reporter_test_');
    appDir = p.join(repo.resolveSymbolicLinksSync(), 'app');
    Directory(p.join(appDir, 'test')).createSync(recursive: true);
  });
  tearDown(() => repo.deleteSync(recursive: true));

  ReporterSummary parse(List<Object> events,
          {Map<String, List<String>> bundles = const {}}) =>
      parseReporter([for (final e in events) e is String ? e : jsonEncode(e)],
          package: 'app',
          packageDir: appDir,
          repoRoot: p.dirname(appDir),
          bundles: bundles);

  /// A suite at [path], one test [name] ([id] 2) and its events.
  List<Object> run(String path, String name,
          {String result = 'success',
          bool done = true,
          Map<String, Object?> extra = const {},
          int suite = 1,
          int id = 2}) =>
      [
        {
          'type': 'suite',
          'suite': {'id': suite, 'path': path},
        },
        {
          'type': 'testStart',
          'test': {'id': id, 'suiteID': suite, 'name': name, ...extra},
        },
        if (result != 'success') {'type': 'error', 'testID': id},
        if (done) {'type': 'testDone', 'testID': id, 'result': result},
      ];
  const finish = {'type': 'done', 'success': true};
  String aTest() => p.join(appDir, 'test', 'a_test.dart');

  test('should complete only when every started test is done', () {
    final ok = parse([...run(aTest(), 'works'), finish]);

    expect(ok.completed, isTrue);
    expect(ok.failures, isEmpty);
    expect(ok.outcomes.map((o) => (o.file, o.name, o.result)),
        [('app/test/a_test.dart', 'works', TestResult.pass)]);
    expect(parse([finish]).completed, isFalse);
    expect(parse([...run(aTest(), 'hangs', done: false), finish]).completed,
        isFalse);
  });

  test('should keep failure identity across transient ids', () {
    final path = File(p.join(appDir, 'test', 'name with space_test.dart'))
      ..writeAsStringSync('');
    final runs = [
      for (final (suite, id) in [(1, 7), (8, 42)])
        parse([
          ...run(path.uri.toString(), 'fails',
              result: 'error', suite: suite, id: id),
          {'type': 'done', 'success': false},
        ]).failures,
    ];

    expect(runs[0], runs[1]);
    expect(runs[0], [
      'app/test/name with space_test.dart::fails',
      'app::reporter failure',
    ]);
  });

  test('should blame orphan errors on the package, helpers on suites', () {
    final summary = parse([
      'not json',
      '[1]',
      {'type': 'error', 'testID': 99},
      ...run(aTest(), 'works',
          result: 'failure',
          extra: {'url': 'package:bloc_test/src/bloc_test.dart'}),
      finish,
    ]);

    expect(summary.failures,
        ['app/test/a_test.dart::works', 'app::reporter error']);
  });

  test('should attribute bundled tests by the longest file prefix', () {
    final bundle = p.join(appDir, 'test', 'flutter_test_bundle.g.dart');

    final summary = parse([
      ...run(bundle, 'test/a_test.dart.x/b_test.dart group t', result: 'error'),
      finish,
    ], bundles: {
      bundle: ['test/a_test.dart', 'test/a_test.dart.x/b_test.dart'],
    });

    expect(summary.failures, ['app/test/a_test.dart.x/b_test.dart::group t']);
    expect(summary.outcomes.single.name, 'group t');
  });

  test('should drop hidden tests and map skipped ones', () {
    final summary = parse([
      ...run(aTest(), 'loading a', done: false),
      {'type': 'testDone', 'testID': 2, 'result': 'success', 'hidden': true},
      ...run(aTest(), 'later', done: false, id: 3),
      {'type': 'testDone', 'testID': 3, 'result': 'success', 'skipped': true},
      finish,
    ]);

    expect(summary.outcomes.map((o) => (o.name, o.result)),
        [('later', TestResult.skip)]);
  });
}
