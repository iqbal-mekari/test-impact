import 'dart:io';

/// Read-only view of the environment variables `test_impact` honours. An empty
/// value counts as unset; values are never exposed through `toString`.
final class BundleEnv {
  /// Reads [source], or [Platform.environment] when it is omitted.
  BundleEnv([Map<String, String>? source])
      : _source = source ?? Platform.environment;

  final Map<String, String> _source;

  String? _get(String name) {
    final value = _source[name];
    return value == null || value.isEmpty ? null : value;
  }

  /// `FLUTTER_TEST_BUNDLE`: on when unset or `1`, off otherwise.
  bool get bundleEnabled => (_get('FLUTTER_TEST_BUNDLE') ?? '1') == '1';
}
