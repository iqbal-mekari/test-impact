import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../process.dart';
import 'reporter.dart';
import 'package.dart';

/// One test run of one package. [targets] are package-relative;
/// [coveragePath] is honoured for flutter packages only; [ConsoleMode.toFile]
/// logs to `<workDir>/output.txt`.
final class PackageRunRequest {
  /// Creates a request.
  const PackageRunRequest({
    required this.package,
    required this.packageDir,
    required this.targets,
    required this.workDir,
    this.coveragePath,
    this.console = ConsoleMode.toFile,
  });

  final BundlePackage package;
  final String packageDir;
  final List<String> targets;
  final String workDir;
  final String? coveragePath;
  final ConsoleMode console;
}

/// Outcome of a [PackageRunRequest]: a fail-closed [exitCode] (never 0 with
/// failures), reporter plus synthetic `<package>::...` [failures], and
/// whether the reporter stream was [completed].
final class PackageRunResult {
  /// Creates a result.
  const PackageRunResult(this.exitCode, this.failures, this.completed);

  final int exitCode;
  final List<String> failures;
  final bool completed;
}

/// Something that can run a package's tests.
abstract interface class PackageTestRunner {
  /// Runs [request] and reports the result.
  Future<PackageRunResult> run(PackageRunRequest request);
}

/// One process per request: `flutter test --no-pub --file-reporter ...`, or
/// the cached `package:test` CLI for dart packages (a missing one gives exit
/// 2, never `pub get`). Stale reporter/coverage files are deleted first; a
/// green exit with an incomplete stream or failures becomes exit 2.
final class PlainTestRunner implements PackageTestRunner {
  /// Creates a runner; reporter paths are made relative to [repoRoot].
  PlainTestRunner({
    required this.processes,
    required this.repoRoot,
    this.flutterCommand = const ['flutter'],
    this.dartCommand = const ['dart'],
  });

  /// Command prefixes that start flutter / dart (e.g. `['puro', 'flutter']`).
  final List<String> flutterCommand, dartCommand;

  final ProcessRunner processes;
  final String repoRoot;

  @override
  Future<PackageRunResult> run(PackageRunRequest request) async {
    final name = request.package.name;
    final output = p.join(request.workDir, 'output.txt');
    final reporter = p.join(request.workDir, 'reporter.json');
    Directory(request.workDir).createSync(recursive: true);
    _delete(reporter);
    final coverage = request.package.runner == RunnerKind.flutter
        ? request.coveragePath
        : null;
    if (coverage != null) _delete(coverage);

    final List<String> command;
    if (request.package.runner == RunnerKind.flutter) {
      command = [
        ...flutterCommand,
        'test',
        '--no-pub',
        '--file-reporter',
        'json:$reporter',
        if (coverage != null) ...['--coverage', '--coverage-path', coverage],
        ...request.targets,
      ];
    } else {
      final config =
          p.join(request.packageDir, '.dart_tool', 'package_config.json');
      final cli = _cachedTestCli(config);
      if (cli == null) {
        File(output).writeAsStringSync(
            'cached Dart test runner is unavailable for $name\n');
        return PackageRunResult(
            2, ['$name::missing cached test runner'], false);
      }
      command = [
        ...dartCommand,
        '--packages=$config',
        cli,
        '--file-reporter',
        'json:$reporter',
        ...request.targets,
      ];
    }

    int code;
    try {
      code = (await processes.run(command.first, command.sublist(1),
              workingDirectory: request.packageDir,
              console: request.console,
              logFile: request.console == ConsoleMode.toFile ? output : null))
          .exitCode;
    } on ProcessException catch (e) {
      File(output).writeAsStringSync('${e.message}\n');
      code = 127;
    }

    final file = File(reporter);
    final summary = parseReporter(
        file.existsSync()
            ? const LineSplitter().convert(
                utf8.decode(file.readAsBytesSync(), allowMalformed: true))
            : const <String>[],
        package: name,
        packageDir: request.packageDir,
        repoRoot: repoRoot);
    final failures = [...summary.failures];
    final completed = summary.completed;
    if (code == 0 && (!completed || failures.isNotEmpty)) {
      code = 2;
      if (!completed) failures.add('$name::incomplete reporter stream');
    }
    if (code != 0 && failures.isEmpty) {
      failures.add('$name::test process failed');
    }
    if (coverage != null && !File(coverage).existsSync()) {
      code = code == 0 ? 2 : code;
      failures.add('$name::missing coverage report');
    }
    return PackageRunResult(code, failures, completed);
  }

  /// Path of `bin/test.dart` in the cached `test` package, or null.
  static String? _cachedTestCli(String configPath) {
    try {
      final data = jsonDecode(File(configPath).readAsStringSync());
      final entry =
          ((data as Map<String, Object?>)['packages'] as List<Object?>)
              .cast<Map<String, Object?>>()
              .firstWhere((package) => package['name'] == 'test');
      final root = Uri.file(configPath).resolve('${entry['rootUri']}');
      if (root.scheme != 'file') return null;
      final cli = File(p.join(root.toFilePath(), 'bin', 'test.dart'));
      return cli.existsSync() ? cli.resolveSymbolicLinksSync() : null;
    } on Object {
      return null;
    }
  }

  static void _delete(String path) {
    final file = File(path);
    if (file.existsSync()) file.deleteSync();
  }
}
