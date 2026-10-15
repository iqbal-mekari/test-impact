import 'package:test/test.dart';
import 'package:test_impact/test_impact.dart';

import 'fixture.dart';

String cfg(String body, {String name = 'pkg'}) =>
    'version: 1\npackage: $name\n$body';

/// Single-package repo; returns violations as `rule` list + messages.
List<Violation> check(Map<String, String> files, String yaml) {
  final d = makeRepo({
    'test_impact.yaml': cfg(yaml),
    'pubspec.yaml': pubspec('pkg'),
    ...files,
  });
  return validate(Workspace.load(d.path));
}

Iterable<String> rules(List<Violation> v) => v.map((e) => e.rule);

const ok = '''
areas:
  one:
    sources: ["lib/one/**"]
    tests: ["test/one/**"]
  two:
    sources: ["lib/two/**"]
    tests: ["test/two/**"]
''';

void main() {
  tearDown(runTearDowns);

  final base = {
    'lib/one/a.dart': '',
    'lib/two/b.dart': '',
    'test/one/a_test.dart': testBody,
    'test/two/b_test.dart': testBody,
  };

  test('clean mapping has no violations', () {
    expect(check(base, ok), isEmpty);
  });

  test('a: unowned lib file', () {
    final v = check({...base, 'lib/stray.dart': ''}, ok);
    expect(rules(v), ['a']);
    expect(v.single.path, 'lib/stray.dart');
  });

  test('a: run_all/run_package glob counts as owner', () {
    final v = check({...base, 'lib/stray.dart': ''},
        '${ok}run_package: ["lib/stray.dart"]\n');
    expect(v, isEmpty);
  });

  test('b: lib file owned by two explicit areas', () {
    final v = check(base, '''
areas:
  one:
    sources: ["lib/**"]
    tests: ["test/one/**"]
  two:
    sources: ["lib/two/**"]
    tests: ["test/two/**"]
''');
    expect(rules(v), ['b']);
    expect(v.single.path, 'lib/two/b.dart');
  });

  test('c: test not covered by any area', () {
    final v = check({...base, 'test/loose_test.dart': testBody}, ok);
    expect(rules(v), ['c']);
    expect(v.single.path, 'test/loose_test.dart');
  });

  test('c: extra_tests and package globs cover', () {
    final y = ok.replaceFirst('sources: ["lib/two/**"]',
        'sources: ["lib/two/**"]\n    extra_tests: ["test/loose_test.dart"]');
    expect(check({...base, 'test/loose_test.dart': testBody}, y), isEmpty);
  });

  test('d: dead globs everywhere', () {
    final v = check(base, '''
run_all: ["nothing/**"]
conventions:
  - sources: "lib/nope/{area}/**"
    tests: "test/nope/{area}/**"
areas:
  one:
    sources: ["lib/one/**", "lib/ghost/**"]
    tests: ["test/one/**"]
    extra_tests: ["test/missing_test.dart"]
  two:
    sources: ["lib/two/**"]
    tests: ["test/two/**"]
''');
    expect(rules(v).toSet(), {'d'});
    final msgs = v.map((e) => e.message).join('|');
    for (final g in [
      'nothing/**',
      'lib/nope/{area}/**',
      'test/nope/{area}/**',
      'lib/ghost/**',
      'test/missing_test.dart',
    ]) {
      expect(msgs, contains(g));
    }
    expect(v.length, 5);
  });

  test('e: unknown and self depends_on', () {
    final v = check(base, '''
areas:
  one:
    sources: ["lib/one/**"]
    tests: ["test/one/**"]
    depends_on: [one, ghost]
  two:
    sources: ["lib/two/**"]
    tests: ["test/two/**"]
''');
    expect(rules(v), ['e', 'e']);
  });

  test('e: depends_on may name a convention area', () {
    final v = check({
      'lib/f/x/a.dart': '',
      'test/f/x/a_test.dart': testBody,
      'lib/g/b.dart': '',
      'test/g_test.dart': testBody,
    }, '''
conventions:
  - sources: "lib/f/{area}/**"
    tests: "test/f/{area}/**"
areas:
  g:
    sources: ["lib/g/**"]
    tests: ["test/g_test.dart"]
    depends_on: [x]
''');
    expect(v, isEmpty);
  });

  test('self-barrel and cross-area imports are not checked here', () {
    final f = {
      ...base,
      'lib/pkg.dart': "export 'one/a.dart';\nexport 'two/b.dart';\n",
      'lib/one/a.dart': "import 'package:pkg/pkg.dart';\n"
          "import '../two/b.dart';\n",
    };
    expect(check(f, '${ok}run_package: ["lib/pkg.dart"]\n'), isEmpty);
  });

  test('violation formatting', () {
    final v = check({...base, 'lib/stray.dart': ''}, ok).single;
    expect(v.toString(), allOf(startsWith('a'), contains('lib/stray.dart')));
  });

  test('g: runtime_tests entry must exist', () {
    final d = makeRepo({
      'test_impact.yaml': cfg('''
repo:
  runtime_tests:
    - paths: ["data/**"]
      tests: ["test/one/a_test.dart", "test/one/gone_test.dart"]
$ok'''),
      'pubspec.yaml': pubspec('pkg'),
      ...base,
    });
    final v = validate(Workspace.load(d.path));
    expect(rules(v), ['g']);
    expect(v.single.message, contains('test/one/gone_test.dart'));
  });

  test('g: valid runtime_tests is clean', () {
    final d = makeRepo({
      'test_impact.yaml': cfg('''
repo:
  runtime_tests:
    - paths: ["data/**"]
      tests: ["test/one/a_test.dart"]
$ok'''),
      'pubspec.yaml': pubspec('pkg'),
      ...base,
    });
    expect(validate(Workspace.load(d.path)), isEmpty);
  });
}
