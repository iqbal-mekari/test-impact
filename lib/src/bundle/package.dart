import 'dart:io';

import 'package:path/path.dart' as p;

/// Which test runner a package uses: `flutter test` or cached `package:test`.
enum RunnerKind { flutter, dart }

/// A package under test: pubspec [name], repo-relative posix [root] (`'.'`
/// for the root package) and [runner].
final class BundlePackage {
  /// Creates a package description.
  const BundlePackage(this.name, this.root, this.runner);

  /// Pubspec name.
  final String name;

  /// Repo-relative posix directory; `'.'` for the repo root package.
  final String root;

  /// How its tests are run.
  final RunnerKind runner;
}

final _bundleName = RegExp(r'^flutter_test_bundle(\.[\w-]+)?\.g\.dart$');

/// Sorted package-relative `test/**/*_test.dart`, without generated
/// `flutter_test_bundle*.g.dart` entrypoints.
List<String> discoverTests(String packageDir) {
  final tests = Directory(p.join(packageDir, 'test'));
  if (!tests.existsSync()) return const [];
  return [
    for (final file in tests.listSync(recursive: true).whereType<File>())
      if (file.path.endsWith('_test.dart') &&
          !_bundleName.hasMatch(p.basename(file.path)))
        p.posix.joinAll(p.split(p.relative(file.path, from: packageDir))),
  ]..sort();
}
