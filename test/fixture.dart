import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test_impact/test_impact.dart';

/// Creates a temp repo from [files] (repo-relative path -> content).
Directory makeRepo(Map<String, String> files) {
  final dir = Directory.systemTemp.createTempSync('test_impact_');
  addTearDown0(() => dir.deleteSync(recursive: true));
  files.forEach((path, content) {
    final f = File(p.join(dir.path, path));
    f.parent.createSync(recursive: true);
    f.writeAsStringSync(content);
  });
  return dir;
}

final _tearDowns = <void Function()>[];

/// Registers cleanup run by [runTearDowns] (wired in each test file).
void addTearDown0(void Function() fn) => _tearDowns.add(fn);

/// Runs and clears registered cleanups.
void runTearDowns() {
  for (final fn in _tearDowns) {
    fn();
  }
  _tearDowns.clear();
}

String pubspec(String name, {List<String> paths = const []}) {
  final deps = paths.map((d) => '  ${p.basename(d)}:\n    path: $d');
  return 'name: $name\ndependencies:\n${deps.join('\n')}\n';
}

const rootYaml = '''
version: 1
package: app
repo:
  safe: ["**/*.md", "integration_test/**"]
  run_all: ["melos.yaml", "**/pubspec.yaml"]
conventions:
  - sources: "lib/features/{area}/**"
    tests: "test/features/{area}/**"
areas:
  payment:
    depends_on: [promo]
    extra_tests: ["test/shared/payment_helper_test.dart"]
''';

const aYaml = '''
version: 1
package: pkg_a
run_all: ["lib/configs/**"]
run_package: ["assets/**"]
conventions:
  - sources: "lib/src/{area}/**"
    tests: "test/src/{area}/**"
areas:
  net:
    sources: ["lib/net/**"]
    tests: ["test/net/**"]
''';

const bYaml = '''
version: 1
package: pkg_b
areas:
  core:
    sources: ["lib/**"]
    tests: ["test/**"]
''';

const testBody = 'void main() {}\n';

/// Standard three-package fixture: app -> pkg_a -> pkg_b.
Map<String, String> standardRepo() => {
      'test_impact.yaml': rootYaml,
      'pubspec.yaml': pubspec('app', paths: ['modules/pkg_a']),
      'lib/main.dart': '',
      'lib/features/payment/pay.dart': '',
      'lib/features/promo/promo.dart': '',
      'lib/features/cart/cart.dart': '',
      'test/features/payment/pay_test.dart': testBody,
      'test/features/promo/promo_test.dart': testBody,
      'test/features/cart/cart_test.dart': testBody,
      'test/shared/payment_helper_test.dart': testBody,
      'test/main_test.dart': testBody,
      'modules/pkg_a/test_impact.yaml': aYaml,
      'modules/pkg_a/pubspec.yaml': pubspec('pkg_a', paths: ['../pkg_b']),
      'modules/pkg_a/lib/configs/c.dart': '',
      'modules/pkg_a/lib/src/auth/auth.dart': '',
      'modules/pkg_a/lib/src/auth/auth.g.dart': '',
      'modules/pkg_a/lib/net/client.dart': '',
      'modules/pkg_a/assets/x.json': '',
      'modules/pkg_a/test/src/auth/auth_test.dart': testBody,
      'modules/pkg_a/test/net/client_test.dart': testBody,
      'modules/pkg_a/test/mocks/m.dart': '',
      'modules/pkg_a/test/mocks/n.dart': "import 'm.dart';\n",
      'modules/pkg_a/test/mocks/orphan.dart': '',
      'modules/pkg_a/test/net/uses_n_test.dart':
          "import '../mocks/n.dart';\nvoid main() {}\n",
      'modules/pkg_b/test_impact.yaml': bYaml,
      'modules/pkg_b/pubspec.yaml': pubspec('pkg_b'),
      'modules/pkg_b/lib/b.dart': '',
      'modules/pkg_b/test/b_test.dart': testBody,
    };

Selection select(Directory repo, List<String> changed) =>
    resolve(Workspace.load(repo.path), changed);
