import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:test_impact/test_impact.dart';

import 'fixture.dart';

void git(Directory d, List<String> args) {
  final r = Process.runSync(
      'git',
      [
        '-c',
        'user.email=t@example.com',
        '-c',
        'user.name=t',
        '-c',
        'commit.gpgsign=false',
        ...args,
      ],
      workingDirectory: d.path);
  if (r.exitCode != 0) fail('git $args: ${r.stderr}');
}

void main() {
  tearDown(runTearDowns);

  group('config', () {
    String? err(String yaml) {
      final d = makeRepo({'test_impact.yaml': yaml});
      try {
        loadConfig(p.join(d.path, 'test_impact.yaml'));
        return null;
      } on ConfigException catch (e) {
        return e.toString();
      }
    }

    test('valid config parses', () {
      final d = makeRepo({'test_impact.yaml': rootYaml});
      final c = loadConfig(p.join(d.path, 'test_impact.yaml'));
      expect(c.name, 'app');
      expect(c.areas['payment']!.dependsOn, ['promo']);
      expect(c.conventions.single.sources, 'lib/features/{area}/**');
      expect(c.repo!.safe, contains('**/*.md'));
    });

    test('errors carry file and key', () {
      final e = err('version: 2\npackage: a\n')!;
      expect(e, allOf(contains('test_impact.yaml'), contains('version')));
      expect(err('version: 1\n'), contains('package'));
      expect(err('version: 1\npackage: a\nbogus: 1\n'), contains('bogus'));
      expect(err('version: 1\npackage: a\nrun_all: x\n'), contains('run_all'));
      expect(
          err('version: 1\npackage: a\nconventions:\n'
              '  - sources: "lib/**"\n    tests: "test/{area}/**"\n'),
          contains('{area}'));
      expect(err('version: 1\npackage: a\nareas:\n  x:\n    nope: 1\n'),
          contains('areas.x'));
      expect(err('not: [valid'), contains('test_impact.yaml'));
    });

    test('runtime_tests parse and reject bad shapes', () {
      final d = makeRepo({
        'test_impact.yaml': '$rootYaml\n'.replaceFirst(
            'conventions:',
            '  runtime_tests:\n    - paths: ["a/**"]\n'
                '      except: ["a/x"]\n      tests: ["test/a_test.dart"]\n'
                'conventions:'),
      });
      final c = loadConfig(p.join(d.path, 'test_impact.yaml'));
      expect(c.repo!.runtimeTests.single.paths, ['a/**']);
      expect(c.repo!.runtimeTests.single.except, ['a/x']);
      expect(c.repo!.runtimeTests.single.tests, ['test/a_test.dart']);
      String? bad(String body) {
        final f = makeRepo({
          'test_impact.yaml': 'version: 1\npackage: a\nrepo:\n$body',
        });
        try {
          loadConfig(p.join(f.path, 'test_impact.yaml'));
        } on ConfigException catch (e) {
          return e.toString();
        }
        return null;
      }

      expect(bad('  runtime_tests: x\n'), contains('runtime_tests'));
      expect(bad('  runtime_tests:\n    - paths: ["a"]\n'),
          contains('runtime_tests[0]'));
      expect(bad('  runtime_tests:\n    - paths: []\n      tests: [b]\n'),
          contains('must not be empty'));
      expect(
          bad('  runtime_tests:\n    - paths: [a]\n      tests: [b]\n'
              '      nope: 1\n'),
          contains('nope'));
    });

    test('repo section only in root config', () {
      final d = makeRepo({
        ...standardRepo(),
        'modules/pkg_b/test_impact.yaml': "$bYaml\nrepo:\n  safe: ['x']\n",
      });
      final ws = Workspace.load(d.path);
      expect(ws.errors.single.toString(), contains('repo'));
    });

    test('package name must match pubspec', () {
      final d = makeRepo({
        ...standardRepo(),
        'modules/pkg_b/pubspec.yaml': pubspec('other'),
      });
      expect(
          Workspace.load(d.path).errors.single.toString(), contains('other'));
    });
  });

  group('glob', () {
    test('wildcards and {area}', () {
      expect(globMatches('**/*.md', 'README.md'), isTrue);
      expect(globMatches('**/*.md', 'a/b/c.md'), isTrue);
      expect(globMatches('lib/*.dart', 'lib/a/b.dart'), isFalse);
      expect(globMatches('lib/**', 'lib/a/b.dart'), isTrue);
      expect(globMatches('lib/a?.dart', 'lib/ab.dart'), isTrue);
      expect(bindArea('lib/f/{area}/**', 'lib/f/pay/a/b.dart'), 'pay');
      expect(bindArea('lib/f/{area}/**', 'lib/f/pay.dart'), isNull);
      expect(bindArea('lib/f/{area}', 'lib/f/a/b'), isNull);
    });
  });

  group('workspace', () {
    test('discovers packages and transitive dependents', () {
      final ws = Workspace.load(makeRepo(standardRepo()).path);
      expect(ws.packages.map((p) => p.dir),
          unorderedEquals(['.', 'modules/pkg_a', 'modules/pkg_b']));
      expect(ws.dependentsOf('modules/pkg_b'),
          unorderedEquals(['.', 'modules/pkg_a']));
      expect(ws.dependentsOf('.'), isEmpty);
      expect(ws.ownerOf('modules/pkg_a/lib/x.dart')!.dir, 'modules/pkg_a');
      expect(ws.ownerOf('lib/x.dart')!.dir, '.');
    });
  });

  group('diff', () {
    test('changed-files override', () {
      final d = makeRepo({
        'list.txt': 'a.dart\n\nM\tb.dart\nR90\tc.dart\td.dart\n',
      });
      expect(
          collectChanges(d.path, changedFilesPath: p.join(d.path, 'list.txt')),
          ['a.dart', 'b.dart', 'c.dart', 'd.dart']);
    });

    test('git diff includes both paths of a rename', () {
      final d = makeRepo({'a.txt': 'hello hello hello\nmore\nlines\n'});
      git(d, ['init', '-q', '-b', 'main']);
      git(d, ['add', '.']);
      git(d, ['commit', '-qm', 'one']);
      git(d, ['checkout', '-qb', 'feat']);
      git(d, ['mv', 'a.txt', 'b.txt']);
      File(p.join(d.path, 'c.txt')).writeAsStringSync('new');
      git(d, ['add', '.']);
      git(d, ['commit', '-qm', 'two']);
      expect(collectChanges(d.path, base: 'main', head: 'feat'),
          unorderedEquals(['a.txt', 'b.txt', 'c.txt']));
    });

    test('bad ref throws DiffException', () {
      final d = makeRepo({'a.txt': 'x'});
      git(d, ['init', '-q']);
      expect(() => collectChanges(d.path, base: 'nope', head: 'HEAD'),
          throwsA(isA<DiffException>()));
    });
  });
}
