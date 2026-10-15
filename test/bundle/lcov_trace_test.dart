import 'dart:io';

import 'package:test_impact/src/bundle/exit_code_exception.dart';
import 'package:test_impact/src/lcov.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

LcovTrace _parse(String text) => LcovTrace.parse(text, origin: 'test');

String _rec(String source, [String body = 'DA:1,1\n']) =>
    'SF:$source\n${body}end_of_record\n';

void main() {
  late Directory temp;
  setUp(() => temp = Directory.systemTemp.createTempSync('lcov_test_'));
  tearDown(() => temp.deleteSync(recursive: true));

  test('should reject malformed reports with exit 1', () {
    for (final text in [
      'SF:lib/x.dart\nDA:1,1\n',
      'SF:a\nSF:b\n',
      _rec(''),
      'DA:1,1\n',
      'end_of_record\n',
      _rec('a', 'DA:0,1\n'),
      _rec('a', 'DA:1,-1\n'),
      _rec('a', 'DA:x,1\n'),
    ]) {
      expect(
          () => _parse(text),
          throwsA(isA<ExitCodeException>()
              .having((e) => e.exitCode, 'exitCode', 1)),
          reason: text);
    }
    expect(() => LcovTrace.parse('', origin: 't', requireRecords: true),
        throwsA(isA<ExitCodeException>()));
    expect(_parse('').records, isEmpty);
  });

  test('should not inflate a repeated source and keep SF spelling', () {
    final lcov = _parse(_rec('lib/e.dart', 'DA:1,0\n') +
        _rec(' lib/e.dart', 'DA:1,3,abc\nLF:9\n') +
        _rec('lib/e.dart', 'DA:1,2\n'));

    expect(lcov.sources, {'lib/e.dart', ' lib/e.dart'});
    expect(lcov.records['lib/e.dart']!.lines, {1: 2});
    expect(lcov.records[' lib/e.dart']!.lines, {1: 3});
  });

  test('should sum lines, functions and branches across shards', () {
    final a = _parse(_rec('/r/a.dart',
        'FN:3,main\nFNDA:1,main\nDA:1,1\nBRDA:1,0,0,-\nBRDA:1,0,1,2\n'));
    final b = _parse(_rec(
            '/r/a.dart',
            'FN:3,main\nFNDA:2,main\nDA:1,2\nDA:2,0\nBRDA:1,0,0,1\n'
                'BRDA:1,0,1,-\nBRDA:2,0,0,-\n') +
        _rec('lib/y.dart', 'DA:1,0\n'));

    final out = p.join(temp.path, 'x', 'y', 'lcov.info');
    LcovTrace.sum([b]).write(out, functions: false, branches: false);

    expect(File(out).readAsStringSync(),
        startsWith('TN:\nSF:/r/a.dart\nDA:1,2\nDA:2,0\nLF:2\nLH:1\nend'));
    expect(
        LcovTrace.sum([a, b]).render(),
        'TN:\nSF:/r/a.dart\nFN:3,main\nFNDA:3,main\nFNF:1\nFNH:1\n'
        'DA:1,3\nDA:2,0\nLF:2\nLH:1\n'
        'BRDA:1,0,0,1\nBRDA:1,0,1,2\nBRDA:2,0,0,-\nBRF:3\nBRH:2\n'
        'end_of_record\n'
        'TN:\nSF:lib/y.dart\nDA:1,0\nLF:1\nLH:0\nend_of_record\n');
  });

  group('absolutize', () {
    late String package;
    setUp(() {
      package = p.join(temp.path, 'modules', 'core');
      File(p.join(package, 'lib', 'example.dart')).createSync(recursive: true);
    });

    test('should resolve and merge spellings of one file', () {
      final real = File(p.join(package, 'lib', 'example.dart'))
          .resolveSymbolicLinksSync();
      final lcov = _parse(_rec('lib/example.dart', 'DA:1,1\n') +
          _rec('./lib/example.dart', 'DA:1,2\n'));

      final once = lcov.absolutize(package, repoRoot: temp.path);

      expect(once.records.keys, [real]);
      expect(once.records[real]!.lines, {1: 3});
      expect(once.absolutize(package, repoRoot: temp.path).sources, {real});
    });

    test('should reject outside or missing sources with a repo root', () {
      for (final source in ['/different-checkout/e.dart', 'lib/gone.dart']) {
        expect(
            () => _parse(_rec(source)).absolutize(package, repoRoot: temp.path),
            throwsA(isA<ExitCodeException>()));
      }
      final loose = _parse(_rec('lib/gone.dart')).absolutize(package);
      expect(p.isAbsolute(loose.sources.single), isTrue);
    });
  });

  test('should remove records with anchored lcov -r globs', () {
    final lcov = _parse(_rec('/a/lib/x.g.dart') +
        _rec('/a/lib/x.dart') +
        _rec('/a/lib/utils/y.dart') +
        _rec('ab.dart') +
        _rec('/a+b.dart'));
    Set<String> keep(List<String> globs) => lcov.removeMatching(globs).sources;

    expect(keep(['*.g.dart', '*/utils/*', 'a?.dart', '/a+b.dart']),
        {'/a/lib/x.dart'});
    expect(keep(['lib', '/a/lib/x.dar', '/a.b.dart']), lcov.sources);
  });

  test('should compare covered lines, not hit counts', () {
    final a = _parse(_rec('x', 'DA:1,5\nDA:2,0\n') + _rec('a'));
    final same = _parse(_rec('x', 'DA:1,1\nDA:2,0\n') + _rec('a'));
    final dropped = _parse(_rec('x', 'DA:1,0\nDA:2,0\n') + _rec('b'));

    expect(compareLcovTraces(a, same), containsPair('equivalent', true));
    expect(
        compareLcovTraces(a, same), containsPair('hit_count_differences', 1));
    expect(compareLcovTraces(a, dropped), {
      'sources': [2, 2],
      'sources_only_first': ['a'],
      'sources_only_second': ['b'],
      'line_set_differences': 0,
      'covered_line_differences': 1,
      'hit_count_differences': 1,
      'covered_lines': [2, 1],
      'equivalent': false,
    });
  });
}
