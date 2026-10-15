import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:test_impact/test_impact.dart';

import 'index_fixture.dart';

void main() {
  late Directory repo;
  setUp(() => repo = writeRepo(twoPackageRepo()));
  tearDown(() => repo.deleteSync(recursive: true));

  Future<(int, String, String)> cli(List<String> args) async {
    final out = StringBuffer(), err = StringBuffer();
    final code = await runCli(args, root: repo.path, out: out, err: err);
    return (code, '$out', '$err');
  }

  Future<Map<String, Object?>> select(String precision) async {
    final f = File(p.join(repo.path, 'changed.txt'))
      ..writeAsStringSync('modules/pkg_a/lib/src/y.dart\n');
    final (code, out, _) = await cli(
        ['select', '--changed-files', f.path, '--precision', precision]);
    expect(code, 0);
    return jsonDecode(out) as Map<String, Object?>;
  }

  test('select defaults to file precision', () async {
    final f = File(p.join(repo.path, 'changed.txt'))
      ..writeAsStringSync('modules/pkg_a/lib/src/y.dart\n');
    final (_, out, err) = await cli(['select', '--changed-files', f.path]);
    final pkgs = (jsonDecode(out) as Map)['packages'] as Map;
    expect((pkgs['modules/pkg_b'] as Map)['tests'], ['test/b_test.dart']);
    expect(err, contains('index of 2 package(s)'));
  });

  test('--precision area keeps v1 selection', () async {
    final j = await select('area');
    final pkgs = j['packages']! as Map;
    expect((pkgs['modules/pkg_b'] as Map)['mode'], 'full');
  });

  test('--precision rejects unknown values', () async {
    final (code, _, _) =
        await cli(['select', '--changed-files', 'x', '--precision', 'x']);
    expect(code, 2);
  });

  test('index writes closure sizes', () async {
    final out = p.join(repo.path, 'idx.json');
    final (code, stdoutText, _) = await cli(['index', '--output', out]);
    expect(code, 0);
    expect(stdoutText, contains('8 test(s)'));
    final j = jsonDecode(File(out).readAsStringSync()) as Map;
    expect((j['tests'] as Map).length, 8);
    expect(j['failure'], isNull);
  });
}
