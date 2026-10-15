import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

/// Writes [files] (repo-relative path -> content) into a new temp dir.
Directory writeRepo(Map<String, String> files) {
  final dir = Directory.systemTemp.createTempSync('test_impact_idx_');
  files.forEach((path, content) {
    final f = File(p.join(dir.path, path));
    f.parent.createSync(recursive: true);
    f.writeAsStringSync(content);
  });
  return dir;
}

/// Hand-written `.dart_tool/package_config.json` for a fixture package at
/// repo-relative [dir], resolving [packages] (name -> repo-relative dir).
MapEntry<String, String> packageConfig(
    String dir, Map<String, String> packages) {
  final entries = [
    for (final e in packages.entries)
      {
        'name': e.key,
        'rootUri': p.posix.relative(e.value, from: '$dir/.dart_tool'),
        'packageUri': 'lib/',
        'languageVersion': '3.6',
      }
  ];
  return MapEntry('$dir/.dart_tool/package_config.json',
      jsonEncode({'configVersion': 2, 'packages': entries}));
}

String _pubspec(String name, [String? dep]) => 'name: $name\n'
    'environment:\n  sdk: ">=3.6.0 <4.0.0"\n'
    '${dep == null ? '' : 'dependencies:\n  $dep:\n    path: ../$dep\n'}';

String _mapping(String name) => 'version: 1\npackage: $name\n'
    'areas:\n  core:\n    sources: ["lib/**"]\n    tests: ["test/**"]\n';

const _a = 'modules/pkg_a';
const _b = 'modules/pkg_b';

/// Two packages; pkg_b depends on pkg_a, which has a barrel `pkg_a.dart`.
Map<String, String> twoPackageRepo() => {
      '$_a/pubspec.yaml': _pubspec('pkg_a'),
      '$_a/test_impact.yaml': _mapping('pkg_a'),
      packageConfig(_a, {'pkg_a': _a}).key:
          packageConfig(_a, {'pkg_a': _a}).value,
      '$_a/lib/pkg_a.dart': "export 'src/x.dart';\nexport 'src/y.dart';\n"
          "export 'src/model.dart';\n",
      '$_a/lib/src/x.dart': 'class X {\n  int v() => 1;\n}\n',
      '$_a/lib/src/y.dart': 'class Y {\n  int w() => 2;\n}\n',
      '$_a/lib/src/z.dart': "import 'x.dart';\n\n"
          'class Z {\n  final X x = X();\n}\n',
      '$_a/lib/src/lonely.dart': 'class Lonely {}\n',
      '$_a/lib/src/model.dart': "part 'model.g.dart';\n\n"
          'class Model {\n  Model();\n'
          '  factory Model.fromJson(Map<String, dynamic> j) =>\n'
          r'      _$ModelFromJson(j);'
          '\n}\n',
      '$_a/lib/src/model.g.dart': "part of 'model.dart';\n\n"
          r'Model _$ModelFromJson(Map<String, dynamic> j) => Model();'
          '\n',
      '$_a/lib/src/orphan.g.dart': "part of 'missing.dart';\n",
      '$_a/test/x_test.dart': "import 'package:pkg_a/pkg_a.dart';\n\n"
          'void main() {\n  X().v();\n}\n',
      '$_a/test/y_test.dart': "import 'package:pkg_a/pkg_a.dart';\n\n"
          'void main() {\n  Y().w();\n}\n',
      '$_a/test/z_test.dart': "import 'package:pkg_a/src/z.dart';\n\n"
          'void main() {\n  Z();\n}\n',
      '$_a/test/model_test.dart': "import 'package:pkg_a/pkg_a.dart';\n\n"
          'void main() {\n  Model.fromJson({});\n}\n',
      '$_a/test/mocks.dart': "import 'package:pkg_a/pkg_a.dart';\n\n"
          'class MockX extends X {}\n\nclass MockY extends Y {}\n',
      '$_a/test/mock_x_test.dart': "import 'mocks.dart';\n\n"
          'void main() {\n  MockX();\n}\n',
      '$_b/pubspec.yaml': _pubspec('pkg_b', 'pkg_a'),
      '$_b/test_impact.yaml': _mapping('pkg_b'),
      packageConfig(_b, {'pkg_a': _a, 'pkg_b': _b}).key:
          packageConfig(_b, {'pkg_a': _a, 'pkg_b': _b}).value,
      '$_b/lib/b.dart': "import 'package:pkg_a/pkg_a.dart';\n\n"
          'class B {\n  final Y y = Y();\n}\n',
      '$_b/test/b_test.dart': "import 'package:pkg_b/b.dart';\n\n"
          'void main() {\n  B();\n}\n',
      '$_b/test/xb_test.dart': "import 'package:pkg_a/pkg_a.dart';\n\n"
          'void main() {\n  X();\n}\n',
      '$_b/test/plain_test.dart': 'void main() {}\n',
    };

/// [twoPackageRepo] with an analysis error in pkg_a and no package
/// config for pkg_b.
Map<String, String> degradedRepo() => {
      ...twoPackageRepo(),
      '$_a/lib/src/broken.dart': 'class Broken extends Missing {}\n',
      '$_a/test/broken_user_test.dart':
          "import 'package:pkg_a/src/broken.dart';\n\n"
              'void main() {\n  Broken();\n}\n',
    }..remove(packageConfig(_b, const {}).key);
