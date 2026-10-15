import 'package:test/test.dart';
import 'package:test_impact/test_impact.dart';

import 'fixture.dart';

void main() {
  tearDown(runTearDowns);

  Selection sel(List<String> changed, [Map<String, String>? repo]) =>
      select(makeRepo(repo ?? standardRepo()), changed);

  Set<String> tests(Selection s, String pkg) => s.packages[pkg]!.tests.toSet();

  test('safe paths select nothing', () {
    final s = sel(['README.md', 'integration_test/a_test.dart']);
    expect(s.mode, 'none');
    expect(s.packages, isEmpty);
    expect(s.reasons.first.rule, 'safe');
  });

  test('repo run_all selects every package fully', () {
    final s = sel(['melos.yaml']);
    expect(s.mode, 'all');
    expect(s.packages.keys,
        unorderedEquals(['.', 'modules/pkg_a', 'modules/pkg_b']));
    expect(s.packages.values.every((v) => v.mode == 'full'), isTrue);
  });

  test('safe wins over run_all, nested pubspec is run_all', () {
    expect(sel(['modules/pkg_b/pubspec.yaml']).mode, 'all');
  });

  test('path with no owning package is ALL', () {
    final repo = standardRepo()..remove('test_impact.yaml');
    final s = sel(['lib/main.dart'], repo);
    expect(s.mode, 'all');
    expect(s.reasons.single.rule, 'no_package');
  });

  test('changed test file selects itself', () {
    final s = sel(['modules/pkg_a/test/net/client_test.dart']);
    expect(s.mode, 'selected');
    expect(s.packages.keys, ['modules/pkg_a']);
    expect(tests(s, 'modules/pkg_a'), {'test/net/client_test.dart'});
  });

  test('deleted test file selects nothing', () {
    final s = sel(['modules/pkg_a/test/net/gone_test.dart']);
    expect(s.mode, 'none');
    expect(s.reasons.single.rule, 'test_deleted');
  });

  test('helper selects transitive importers', () {
    final s = sel(['modules/pkg_a/test/mocks/m.dart']);
    expect(tests(s, 'modules/pkg_a'), {'test/net/uses_n_test.dart'});
  });

  test('unused helper is ignored', () {
    final s = sel(['modules/pkg_a/test/mocks/orphan.dart']);
    expect(s.mode, 'none');
    expect(s.reasons.single.rule, 'test_helper_unused');
  });

  test('non-Dart test asset runs its package fully', () {
    final s = sel(['modules/pkg_a/test/fixtures/data.json']);
    expect(s.packages['modules/pkg_a']!.mode, 'full');
    expect(s.packages.containsKey('.'), isFalse);
    expect(s.reasons.single.rule, 'test_asset');
  });

  test('pkg run_all: package full plus dependents full', () {
    final s = sel(['modules/pkg_a/lib/configs/c.dart']);
    expect(s.mode, 'selected');
    expect(s.packages['modules/pkg_a']!.mode, 'full');
    expect(s.packages['.']!.mode, 'full');
    expect(s.packages.containsKey('modules/pkg_b'), isFalse);
  });

  test('pkg run_package: package full only', () {
    final s = sel(['modules/pkg_a/assets/x.json']);
    expect(s.packages.keys, ['modules/pkg_a']);
    expect(s.packages['modules/pkg_a']!.mode, 'full');
  });

  test('convention area selects its tests, dependents full', () {
    final s = sel(['modules/pkg_a/lib/src/auth/auth.dart']);
    expect(tests(s, 'modules/pkg_a'), {'test/src/auth/auth_test.dart'});
    expect(s.packages['modules/pkg_a']!.mode, 'selected');
    expect(s.packages['.']!.mode, 'full');
  });

  test('explicit area sources are mapped', () {
    final s = sel(['modules/pkg_a/lib/net/client.dart']);
    expect(tests(s, 'modules/pkg_a'),
        {'test/net/client_test.dart', 'test/net/uses_n_test.dart'});
  });

  test('depends_on: dependents tests + extra_tests run', () {
    final s = sel(['lib/features/promo/promo.dart']);
    expect(tests(s, '.'), {
      'test/features/promo/promo_test.dart',
      'test/features/payment/pay_test.dart',
      'test/shared/payment_helper_test.dart',
    });
    expect(s.packages.length, 1);
  });

  test('depends_on is directional', () {
    final s = sel(['lib/features/payment/pay.dart']);
    expect(tests(s, '.'), {
      'test/features/payment/pay_test.dart',
      'test/shared/payment_helper_test.dart',
    });
  });

  test('depends_on is transitive', () {
    final repo = standardRepo();
    repo['test_impact.yaml'] = '$rootYaml  cart:\n    depends_on: [payment]\n';
    final s = sel(['lib/features/promo/promo.dart'], repo);
    expect(tests(s, '.'), contains('test/features/cart/cart_test.dart'));
  });

  test('unmapped lib file: package + dependents full', () {
    final s = sel([
      'modules/pkg_b/lib/new/x.dart'
    ], {
      ...standardRepo(),
      'modules/pkg_b/test_impact.yaml':
          bYaml.replaceFirst('"lib/**"', '"lib/b.dart"'),
    });
    expect(s.reasons.single.rule, 'unmapped');
    expect(s.packages.keys,
        unorderedEquals(['.', 'modules/pkg_a', 'modules/pkg_b']));
    expect(s.packages.values.every((v) => v.mode == 'full'), isTrue);
  });

  test('generated files follow path rules', () {
    final s = sel(['modules/pkg_a/lib/src/auth/auth.g.dart']);
    expect(tests(s, 'modules/pkg_a'), {'test/src/auth/auth_test.dart'});
  });

  test('config error falls back to ALL', () {
    final repo = standardRepo()..['modules/pkg_b/test_impact.yaml'] = 'x: [';
    final s = sel(['modules/pkg_a/lib/net/client.dart'], repo);
    expect(s.mode, 'all');
    expect(s.reasons.first.rule, 'config_error');
    expect(s.reasons.first.detail, contains('pkg_b'));
  });

  test('combined: full beats selected, tests are sorted', () {
    final s = sel([
      'modules/pkg_a/test/net/client_test.dart',
      'modules/pkg_a/assets/x.json',
      'test/main_test.dart',
      'test/features/cart/cart_test.dart',
    ]);
    expect(s.packages['modules/pkg_a']!.mode, 'full');
    expect(s.packages['.']!.tests,
        ['test/features/cart/cart_test.dart', 'test/main_test.dart']);
  });

  test('JSON shape', () {
    final s = sel(['modules/pkg_a/lib/net/client.dart']);
    final j = s.toJson();
    expect(j.keys, ['mode', 'packages', 'reasons']);
    final pkg = (j['packages'] as Map)['modules/pkg_a'] as Map;
    expect(pkg['mode'], 'selected');
    expect(pkg['tests'], isA<List<dynamic>>());
    final r = (j['reasons'] as List).first as Map;
    expect(r.keys, ['path', 'rule', 'detail']);
  });

  group('repo.runtime_tests', () {
    String root(String runtime) =>
        rootYaml.replaceFirst('conventions:', '$runtime\nconventions:');
    Map<String, String> repoWith(String runtime) => {
          ...standardRepo(),
          'test_impact.yaml': root(runtime),
          'integration_test/fixtures/mock/m.json': '{}',
        };
    const rule = '''
  runtime_tests:
    - paths: ["integration_test/fixtures/mock/**", "lib/features/cart/**"]
      tests: ["modules/pkg_a/test/net/client_test.dart"]
    - paths: ["melos.yaml"]
      tests: ["test/main_test.dart"]''';

    test('runtime match wins over safe and selects its test', () {
      final s = sel(['integration_test/fixtures/mock/m.json'], repoWith(rule));
      expect(s.mode, 'selected');
      expect(s.packages.keys, ['modules/pkg_a']);
      expect(tests(s, 'modules/pkg_a'), {'test/net/client_test.dart'});
      expect(s.reasons.single.rule, 'runtime_test');
    });

    test('is added to what package rules select', () {
      final s = sel(['lib/features/cart/cart.dart'], repoWith(rule));
      expect(tests(s, '.'), {'test/features/cart/cart_test.dart'});
      expect(tests(s, 'modules/pkg_a'), {'test/net/client_test.dart'});
    });

    test('repo run_all beats runtime_tests', () {
      final s = sel(['melos.yaml'], repoWith(rule));
      expect(s.mode, 'all');
      expect(s.reasons.single.rule, 'repo_run_all');
      expect(s.packages.values.every((v) => v.mode == 'full'), isTrue);
    });

    test('except excludes paths from a rule', () {
      final r = rule.replaceFirst('tests: ["modules/pkg_a/test/net/client',
          'except: ["**/m.json"]\n      tests: ["modules/pkg_a/test/net/client');
      expect(sel(['integration_test/fixtures/mock/m.json'], repoWith(r)).mode,
          'none');
    });

    test('unrelated safe path still selects nothing', () {
      expect(sel(['README.md'], repoWith(rule)).mode, 'none');
    });

    test('missing test runs its package fully', () {
      final bad = rule.replaceFirst('net/client_test', 'net/gone_test');
      final s = sel(['integration_test/fixtures/mock/m.json'], repoWith(bad));
      expect(s.mode, 'selected');
      expect(s.packages['modules/pkg_a']!.mode, 'full');
      expect(s.reasons.single.rule, 'runtime_test_missing');
    });
  });
}
