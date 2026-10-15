import 'dart:convert';
import 'dart:io';

import 'package:args/args.dart';
import 'package:args/command_runner.dart';
import 'package:path/path.dart' as p;

import '../config.dart';
import '../lcov.dart';
import '../process.dart';
import 'bundle_plan.dart';
import 'bundle_policy.dart';
import 'bundle_verify.dart';
import 'bundled_test_runner.dart';
import 'env.dart';
import 'exit_code_exception.dart';
import 'package.dart';
import 'package_test_runner.dart';

/// Resolves the [Tooling] for a repo root (typically from the
/// `tooling:` block of its `test_impact.yaml`).
typedef ToolingLoader = Tooling Function(String repoRoot);

/// One command. [options] is a space-separated spec: `name!` is mandatory,
/// `name=a|b` defaults to `a` (allowing only `a`, `b`), `name?` is a flag
/// and `name+` a negatable flag that defaults on. With [noRest] a
/// positional argument is a usage error. An [ExitCodeException] thrown by
/// the body is printed and becomes the exit code.
class SpecCommand extends Command<int> {
  /// Creates the command.
  SpecCommand(
    this.name,
    this.description, {
    String options = '',
    Future<int> Function(SpecCommand command, ArgResults args)? run,
    List<Command<int>> subcommands = const [],
    this.errorSink,
  }) : _run = run {
    for (final spec in options.split(' ').where((s) => s.isNotEmpty)) {
      final name = spec.replaceAll(RegExp(r'[!?+]$|=.*'), '');
      final values = spec.contains('=') ? spec.split('=')[1].split('|') : null;
      if (spec.endsWith('?') || spec.endsWith('+')) {
        argParser.addFlag(name,
            negatable: spec.endsWith('+'), defaultsTo: spec.endsWith('+'));
      } else {
        argParser.addOption(name,
            mandatory: spec.endsWith('!'),
            defaultsTo: values?.first,
            allowed: values != null && values.length > 1 ? values : null);
      }
    }
    subcommands.forEach(addSubcommand);
  }

  @override
  final String name, description;
  final Future<int> Function(SpecCommand command, ArgResults args)? _run;

  /// Where [ExitCodeException] messages go.
  final StringSink? errorSink;

  @override
  Future<int> run() async {
    try {
      return await _run!(this, argResults!);
    } on ExitCodeException catch (e) {
      (errorSink ?? stderr).writeln('test_impact: $e');
      return e.exitCode;
    }
  }
}

/// Builds the `bundle` (`test`, `audit`, `verify`) and `lcov` (`filter`)
/// commands. [tooling] supplies the repo's commands, isolation patterns
/// and policy; the seams default to the real process runner, environment,
/// stdout and stderr.
List<Command<int>> buildBundleCommands({
  required ToolingLoader tooling,
  ProcessRunner? processes,
  Map<String, String>? environment,
  StringSink? out,
  StringSink? err,
}) {
  final io = processes ?? IoProcessRunner();
  final stdOut = out ?? stdout;
  final stdErr = err ?? stderr;
  void log(String message) => stdErr.writeln('[flutter-test-bundle] $message');

  BundledTestRunner bundled(_Target t, ArgResults a, bool on) =>
      BundledTestRunner(
        plain: PlainTestRunner(
          processes: io,
          repoRoot: t.repo,
          flutterCommand: t.flutter(a),
          dartCommand: t.tooling.dartCommand,
        ),
        enabled: on,
        policyPath: t.policy,
        isolationPatterns: t.tooling.isolationRegExps,
        repoRoot: t.repo,
        log: log,
      );

  Future<int> filter(SpecCommand c, ArgResults a) async {
    final rest = a.rest;
    if (rest.length < 2) {
      throw UsageException('Missing arguments.',
          'Usage: test_impact lcov filter <input> <output> [glob...]');
    }
    String? error;
    if (!FileSystemEntity.isFileSync(rest[0])) {
      error = 'input file not found: ${rest[0]}';
    } else {
      try {
        final kept = LcovTrace.read(rest[0], requireRecords: true)
            .removeMatching(rest.sublist(2));
        // Like `lcov -r`, refuse to write an emptied report so an
        // over-broad pattern cannot silently drop all coverage.
        if (kept.records.isEmpty) {
          error = 'no records left after filtering';
        } else {
          kept.write(rest[1], functions: false);
        }
      } on ExitCodeException catch (e) {
        error = '$e';
      } on FileSystemException catch (e) {
        error = e.message;
      }
    }
    if (error != null) stdErr.writeln('test_impact lcov filter: $error');
    return error == null ? 0 : 1;
  }

  // `bundle test|audit|verify`: resolves the package, repo, key and policy,
  // then [body] runs with them.
  SpecCommand bundle(
    String name,
    String description,
    String options,
    Future<int> Function(SpecCommand c, ArgResults a, _Target t) body,
  ) =>
      SpecCommand(name, description,
          errorSink: stdErr,
          options: 'package-root=. policy package-key repo-root $options',
          run: (c, a) => body(c, a, _target(a, tooling)));

  Future<int> bundleTest(SpecCommand c, ArgResults a, _Target t) async {
    final target = a['target'] as String? ??
        c.usageException('Missing required option --target.');
    final coverage = a['coverage-path'] as String?;
    final report = p.join(t.root, coverage ?? p.join('coverage', 'lcov.info'));
    final enabled = BundleEnv(environment).bundleEnabled;
    final missing = 'coverage report is missing: '
        '${p.relative(report, from: t.root)}';
    if (enabled && target == 'test/') {
      if (discoverTests(t.root).isEmpty) {
        log('no test files found');
        return 1;
      }
      final work = Directory.systemTemp.createTempSync('flutter-test-bundle-');
      try {
        final result = await bundled(t, a, enabled).run(PackageRunRequest(
          package: t.package,
          packageDir: t.root,
          targets: [target],
          workDir: work.path,
          coveragePath: report,
          console: ConsoleMode.inherit,
        ));
        final onlyMissing = result.failures.length == 1 &&
            result.failures.single ==
                '${t.package.name}::missing coverage report';
        if (result.exitCode != 2 || !onlyMissing) return result.exitCode;
        log(missing);
        return 1;
      } finally {
        work.deleteSync(recursive: true);
      }
    }
    final int code;
    final flutter = t.flutter(a);
    try {
      code = (await io.run(
        flutter.first,
        [
          ...flutter.skip(1),
          'test',
          '--coverage',
          '--no-pub',
          if (coverage != null) ...['--coverage-path', coverage],
          target,
        ],
        workingDirectory: t.root,
        console: ConsoleMode.inherit,
      ))
          .exitCode;
    } on ProcessException catch (e) {
      stdErr.writeln('test_impact bundle test: ${e.message}');
      return 127;
    }
    if (code != 0 || File(report).existsSync()) return code;
    log(missing);
    return 1;
  }

  Future<int> bundleAudit(SpecCommand c, ArgResults a, _Target t) async {
    final loaded = loadBundlePlan(
      packageDir: t.root,
      policyPath: t.policy,
      packageKey: t.key,
      log: log,
      isolationPatterns: t.tooling.isolationRegExps,
    );
    final plan = loaded.plan;
    stdOut.writeln('${t.key}: ${loaded.files.length} test file(s), '
        '${plan.bundled.length} bundled, ${plan.isolated.length} isolated');
    for (final entry in plan.isolated.entries) {
      stdOut.writeln('  isolate ${entry.key}: ${entry.value.join('; ')}');
    }
    for (final file in plan.unreviewed) {
      stdOut.writeln('  UNREVIEWED $file: record a verdict in the bundle '
          'policy (isolate, or bundle_safe after `verify` passes)');
    }
    var policy = const BundlePolicy();
    if (t.policy != null) {
      try {
        policy = BundlePolicy.load(t.policy!, t.key);
      } on BundlePolicyException {
        // Already logged by loadBundlePlan.
      }
    }
    final known = loaded.files.toSet();
    for (final file in ({...policy.isolate.keys, ...policy.bundleSafe.keys}
        .where((f) => !known.contains(f))
        .toList()
      ..sort())) {
      stdOut.writeln('  STALE policy entry: $file');
    }
    return (a['strict'] as bool) && plan.unreviewed.isNotEmpty ? 1 : 0;
  }

  Future<int> bundleVerify(SpecCommand c, ArgResults a, _Target t) async {
    final loaded = loadBundlePlan(
      packageDir: t.root,
      policyPath: t.policy,
      packageKey: t.key,
      log: log,
      isolationPatterns: t.tooling.isolationRegExps,
    );
    final outDir = a['out-dir'] as String?;
    final work = outDir == null
        ? Directory.systemTemp.createTempSync('bundle-verify-')
        : Directory(p.absolute(outDir))
      ..createSync(recursive: true);
    final summary = await verifyBundle(
      runner: bundled(t, a, true),
      package: t.package,
      packageDir: t.root,
      workDir: work.path,
      packageKey: t.key,
      loaded: loaded,
    );
    stdOut.writeln(const JsonEncoder.withIndent('  ').convert(summary));
    return verifyPassed(summary) ? 0 : 1;
  }

  return [
    SpecCommand(
      'bundle',
      'Bundle test files into one compile (test, audit, verify).',
      subcommands: [
        bundle('test', 'Run flutter tests with coverage, bundled.',
            'flutter target coverage-path', bundleTest),
        bundle('audit', 'List bundled and isolated files with reasons.',
            'strict?', bundleAudit),
        bundle(
            'verify',
            'Run bundled and unbundled and diff outcomes and coverage.',
            'flutter out-dir',
            bundleVerify),
      ],
    ),
    SpecCommand('lcov', 'LCOV tracefile tools.', subcommands: [
      SpecCommand('filter', 'Remove records matching glob patterns.',
          errorSink: stdErr, run: filter),
    ]),
  ];
}

final class _Target {
  _Target({
    required this.root,
    required this.repo,
    required this.key,
    required this.policy,
    required this.package,
    required this.tooling,
  });

  final String root, repo, key;

  /// Absolute policy path, or null for no policy.
  final String? policy;
  final BundlePackage package;
  final Tooling tooling;

  /// `--flutter <path>` (one executable) wins over the configured command.
  List<String> flutter(ArgResults a) {
    final flag = a.options.contains('flutter') ? a['flutter'] as String? : null;
    if (flag == null) return tooling.flutterCommand;
    return [flag.contains(p.separator) ? p.absolute(flag) : flag];
  }
}

_Target _target(ArgResults a, ToolingLoader loader) {
  String resolve(String path) {
    try {
      return Directory(p.absolute(path)).resolveSymbolicLinksSync();
    } on FileSystemException {
      return p.normalize(p.absolute(path));
    }
  }

  final root = resolve(a['package-root'] as String);
  var repo = a['repo-root'] as String?;
  repo = repo != null ? resolve(repo) : _findRepoRoot(root);
  final relative = p.relative(root, from: repo);
  final posix = relative == '.' ? '.' : p.posix.joinAll(p.split(relative));
  final pubspec = File(p.join(root, 'pubspec.yaml'));
  final name = pubspec.existsSync()
      ? RegExp(r'''^name:\s*['"]?([A-Za-z0-9_]+)''', multiLine: true)
          .firstMatch(pubspec.readAsStringSync())
          ?.group(1)
      : null;
  final Tooling tooling;
  try {
    tooling = loader(repo);
  } on ConfigException catch (e) {
    throw ExitCodeException('$e');
  }
  final policy = a['policy'] as String? ?? tooling.bundlePolicy;
  return _Target(
    root: root,
    repo: repo,
    key: a['package-key'] as String? ?? posix,
    policy: policy == null ? null : p.join(repo, policy),
    package: BundlePackage(name ?? p.basename(root), posix, RunnerKind.flutter),
    tooling: tooling,
  );
}

/// Nearest ancestor that contains this tool, else the package's parent.
String _findRepoRoot(String packageRoot) {
  for (var dir = packageRoot;; dir = p.dirname(dir)) {
    if (File(p.join(dir, 'tools', 'test_impact', 'pubspec.yaml'))
        .existsSync()) {
      return dir;
    }
    if (p.dirname(dir) == dir) return p.dirname(packageRoot);
  }
}
