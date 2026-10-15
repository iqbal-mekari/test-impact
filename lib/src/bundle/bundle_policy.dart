import 'dart:convert';
import 'dart:io';

import 'exit_code_exception.dart';

/// Per-package verdicts the hazard scan cannot reach, each mapping a test
/// path to a reason: `isolate` files collide when bundled; `bundleSafe`
/// files are SOFT-flagged but proven harmless by `test_impact bundle verify`.
final class BundlePolicy {
  const BundlePolicy({this.isolate = const {}, this.bundleSafe = const {}});

  final Map<String, String> isolate;
  final Map<String, String> bundleSafe;

  /// Reads the entry for [packageKey] from the policy at [path]
  /// (`{"version": 1, "packages": {<key>: {"isolate": {}, "bundle_safe":
  /// {}}}}`); empty when absent. Throws [BundlePolicyException] when the
  /// file is unreadable or malformed.
  static BundlePolicy load(String path, String packageKey) {
    Never fail(String why) => throw BundlePolicyException(why);
    final Object? data;
    try {
      data = jsonDecode(File(path).readAsStringSync());
    } on Exception catch (e) {
      fail('cannot read policy: $e');
    }
    final packages = data is Map<String, Object?> && data['version'] == 1
        ? data['packages']
        : null;
    if (packages is! Map<String, Object?>) {
      fail('bundle policy must be {version: 1, packages: {}}');
    }
    final entry = packages[packageKey];
    if (entry == null) return const BundlePolicy();
    if (entry is! Map<String, Object?> ||
        entry.keys.any((k) => k != 'isolate' && k != 'bundle_safe')) {
      fail('invalid bundle policy entry: $packageKey');
    }
    Map<String, String> section(String name) {
      final value = entry[name] ?? const <String, Object?>{};
      if (value is! Map<String, Object?> ||
          !value.entries.every((e) =>
              isSafeTestPath(e.key) &&
              e.key.endsWith('_test.dart') &&
              e.value is String &&
              (e.value! as String).isNotEmpty)) {
        fail('invalid bundle policy $name: $packageKey');
      }
      return {for (final e in value.entries) e.key: e.value! as String};
    }

    return BundlePolicy(
      isolate: section('isolate'),
      bundleSafe: section('bundle_safe'),
    );
  }
}

/// True for a posix path under `test/` without `..` segments.
bool isSafeTestPath(String value) =>
    value.startsWith('test/') && !value.split('/').contains('..');

/// The bundling policy is unreadable or malformed. Exit code 1.
final class BundlePolicyException extends ExitCodeException {
  BundlePolicyException(String message) : super(message, 1);
}
