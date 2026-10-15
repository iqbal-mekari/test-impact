import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

/// Result of one test.
enum TestResult { pass, fail, skip }

/// One finished, visible test; [file] is repo-relative when inside the repo
/// and [name] has no bundle file prefix.
final class TestOutcome {
  /// Creates an outcome.
  const TestOutcome(this.file, this.name, this.result);

  final String file;
  final String name;
  final TestResult result;
}

/// What [parseReporter] learned. [failures] are sorted, unique
/// `<file>::<name>`, `<package>::reporter error` or
/// `<package>::reporter failure`; [completed] needs `done`, at least one
/// test and a `testDone` for every started test.
final class ReporterSummary {
  /// Creates a summary.
  const ReporterSummary(this.failures, this.completed, this.outcomes);

  final List<String> failures;
  final bool completed;
  final List<TestOutcome> outcomes;
}

/// Parses `package:test` JSON reporter [lines]; non-object lines are ignored.
///
/// Bundled suites are attributed back to their files through [bundles]
/// (absolute entrypoint to package-relative files). `package:`/`dart:` test
/// URLs (helpers such as `blocTest`) fall back to the suite path.
ReporterSummary parseReporter(
  Iterable<String> lines, {
  required String package,
  required String packageDir,
  required String repoRoot,
  Map<String, List<String>> bundles = const {},
}) {
  final root = _resolve(repoRoot);
  final packagePath = _resolve(packageDir);
  final failures = <String>{};
  final active = <String, String>{};
  final finished = <String>{};
  final suites = <String, String>{};
  final named = <String, (String, String)>{};
  final outcomes = <TestOutcome>[];
  var done = false;

  String relative(String path) => p.isWithin(root, path)
      ? p.posix.joinAll(p.split(p.relative(path, from: root)))
      : path;
  String inPackage(String file) => _resolve(p.join(packagePath, file));

  for (final line in lines) {
    final Object? event;
    try {
      event = jsonDecode(line);
    } on FormatException {
      continue;
    }
    if (event is! Map<String, Object?>) continue;
    final kind = event['type'];
    final suite = event['suite'];
    final test = event['test'];

    if (kind == 'suite' && suite is Map<String, Object?>) {
      suites['${suite['id']}'] = '${suite['path'] ?? ''}';
    }
    if (kind == 'testStart' && test is Map<String, Object?>) {
      var name = '${test['name'] ?? 'unknown'}';
      final suiteValue = suites['${test['suiteID']}'] ?? '';
      final suitePath = _suiteFile(suiteValue, packagePath);
      final found = suiteValue.isEmpty
          ? null
          : _attribute(name, bundles[suitePath] ?? const []);
      final String path;
      if (found != null) {
        path = inPackage(found.$1);
        name = found.$2;
      } else {
        var value = '${test['url'] ?? ''}';
        // package:/dart: URLs name the helper that declared the test (for
        // example blocTest), not the test file; use the suite instead.
        if (value.isEmpty ||
            (RegExp(r'^[A-Za-z][A-Za-z0-9+.-]+:').hasMatch(value) &&
                !value.startsWith('file:'))) {
          value = suiteValue;
        }
        path = _suiteFile(value, packagePath);
      }
      final id = '${test['id'] ?? event['testID']}';
      active[id] = '${relative(path)}::$name';
      named[id] = (suitePath, '${test['name'] ?? ''}');
    }
    final key = '${event['testID']}';
    if (kind == 'testDone' && active.containsKey(key)) finished.add(key);
    final failed = kind == 'testFailure' ||
        kind == 'error' ||
        (kind == 'testDone' &&
            (event['result'] == 'failure' || event['result'] == 'error'));
    if (failed) failures.add(active[key] ?? '$package::reporter error');
    if (kind == 'testDone' && event['hidden'] != true) {
      final (suitePath, name) = named[key] ?? ('', '');
      final found = _attribute(name, bundles[suitePath] ?? const []);
      outcomes.add(TestOutcome(
          found != null
              ? relative(inPackage(found.$1))
              : suitePath.isEmpty
                  ? ''
                  : relative(suitePath),
          found?.$2 ?? name,
          event['skipped'] == true
              ? TestResult.skip
              : event['result'] == 'success'
                  ? TestResult.pass
                  : TestResult.fail));
    }
    if (kind == 'done') {
      done = true;
      if (event['success'] == false) failures.add('$package::reporter failure');
    }
  }
  final completed =
      done && active.isNotEmpty && finished.containsAll(active.keys);
  return ReporterSummary(failures.toList()..sort(), completed, outcomes);
}

/// Original `(file, test name)` for a bundled test [name], longest file
/// prefix first; null when no file matches.
(String, String)? _attribute(String name, Iterable<String> files) {
  final byLength = files.toList()
    ..sort(
        (a, b) => b.length != a.length ? b.length - a.length : a.compareTo(b));
  for (final file in byLength) {
    if (name == file) return (file, '');
    if (name.startsWith('$file ')) {
      return (file, name.substring(file.length + 1));
    }
  }
  return null;
}

/// Absolute, resolved file for a suite path or `file:` URL; an empty value
/// names the package directory.
String _suiteFile(String value, String packagePath) {
  var path = value;
  if (value.startsWith('file:')) {
    try {
      path = Uri.parse(value).toFilePath();
    } on Object {
      path = value;
    }
  }
  if (path.isEmpty) return packagePath;
  return _resolve(p.isAbsolute(path) ? path : p.join(packagePath, path));
}

String _resolve(String path) {
  final absolute = p.normalize(p.absolute(path));
  try {
    return File(absolute).resolveSymbolicLinksSync();
  } on FileSystemException {
    return absolute;
  }
}
