import 'dart:convert';
import 'dart:io';

import 'package:args/args.dart';
import 'package:args/command_runner.dart';
import 'package:path/path.dart' as p;

import 'bundle/bundle_cli.dart';
import 'config.dart';
import 'coverage.dart';
import 'diff.dart';
import 'index.dart';
import 'process.dart';
import 'resolver.dart';
import 'runner.dart';
import 'validator.dart';
import 'workspace.dart';

/// Builds the declaration index for the given package dirs (test seam of
/// the `ci` command; default [ImpactIndex.build]).
typedef IndexBuilderFn = Future<ImpactIndex> Function(
    Workspace ws, Set<String> packageDirs);

Future<ImpactIndex> _defaultIndexBuilder(Workspace ws, Set<String> dirs) =>
    ImpactIndex.build(ws, packageDirs: dirs);

/// Runs the CLI; returns the exit code (0 ok, 1 failure, 2 usage/config).
///
/// [root] defaults to the current directory (run from the repo root).
/// [bundleTooling] supplies the `bundle` / `lcov` settings per repo root
/// (default: the root `test_impact.yaml` `tooling:` block); [processes]
/// and [environment] are test seams for `run` and those commands;
/// [indexBuilder] is the seam for the `ci` command's single index build.
Future<int> runCli(List<String> args,
    {String? root,
    StringSink? out,
    StringSink? err,
    ToolingLoader? bundleTooling,
    ProcessRunner? processes,
    Map<String, String>? environment,
    IndexBuilderFn? indexBuilder}) async {
  final ctx = _Ctx(root ?? Directory.current.path, out ?? stdout, err ?? stderr,
      processes, environment, indexBuilder ?? _defaultIndexBuilder);
  final runner = CommandRunner<int>(
      'test_impact', 'Map a git diff to the minimal set of unit tests.')
    ..addCommand(_Select(ctx))
    ..addCommand(_Validate(ctx))
    ..addCommand(_Run(ctx))
    ..addCommand(_Index(ctx))
    ..addCommand(_Ci(ctx));
  for (final command in buildBundleCommands(
      tooling: bundleTooling ?? loadTooling,
      processes: processes,
      environment: environment,
      out: ctx.out,
      err: ctx.err)) {
    runner.addCommand(command);
  }
  if (args.isEmpty) {
    ctx.err.writeln(runner.usage);
    return 2;
  }
  try {
    return await runner.run(args) ?? 0;
  } on UsageException catch (e) {
    ctx.err.writeln(e);
    return 2;
  }
}

class _Ctx {
  _Ctx(this.root, this.out, this.err, this.processes, this.environment,
      this.indexBuilder);
  final String root;
  final StringSink out, err;
  final ProcessRunner? processes;
  final Map<String, String>? environment;
  final IndexBuilderFn indexBuilder;
}

abstract class _DiffCommand extends Command<int> {
  _DiffCommand(this.ctx) {
    argParser
      ..addOption('base', help: 'Base git ref (diffed as base...head).')
      ..addOption('head', help: 'Head git ref.', defaultsTo: 'HEAD')
      ..addOption('changed-files',
          help: 'File with changed paths (one per line); skips git.')
      ..addOption('precision',
          allowed: ['area', 'file'],
          defaultsTo: 'file',
          help: 'file: narrow area matches with the declaration index; '
              'area: v1 mapping only.');
  }
  final _Ctx ctx;

  Future<Selection> compute(Workspace ws) async {
    final res = argResults!;
    final file = res['changed-files'] as String?;
    final base = res['base'] as String?;
    if (file == null && base == null) {
      usageException('Provide --base (and --head) or --changed-files.');
    }
    try {
      final changed = collectChanges(ctx.root,
          base: base, head: res['head'] as String?, changedFilesPath: file);
      ImpactIndex? index;
      final dirs = res['precision'] == 'file' && ws.errors.isEmpty
          ? indexPackagesFor(ws, changed)
          : const <String>{};
      if (dirs.isNotEmpty) {
        index = await ImpactIndex.build(ws, packageDirs: dirs);
        ctx.err.writeln('test_impact: index of ${dirs.length} package(s) '
            'built in ${index.buildTime.inSeconds}s'
            '${index.failure == null ? '' : ' (${index.failure})'}');
      }
      return resolve(ws, changed, index: index);
    } on DiffException catch (e) {
      ctx.err.writeln('test_impact: $e; failing safe to ALL');
      return selectAll(ws, [Reason('', 'diff_error', '$e')]);
    }
  }
}

class _Select extends _DiffCommand {
  _Select(super.ctx) {
    argParser.addOption('output', help: 'Also write the JSON here.');
  }
  @override
  final name = 'select';
  @override
  final description = 'Print the test selection for a diff as JSON.';

  @override
  Future<int> run() async {
    final sel = await compute(Workspace.load(ctx.root));
    final json = const JsonEncoder.withIndent('  ').convert(sel.toJson());
    ctx.out.writeln(json);
    final path = argResults!['output'] as String?;
    if (path != null) File(path).writeAsStringSync('$json\n');
    return 0;
  }
}

class _Run extends _DiffCommand {
  _Run(super.ctx) {
    argParser
      ..addFlag('coverage',
          help: 'Run tests with coverage and report changed-line coverage.')
      ..addOption('coverage-json',
          help: 'Coverage JSON path.', defaultsTo: coverageJsonName)
      ..addOption('coverage-md',
          help: 'Coverage markdown path.', defaultsTo: coverageMdName);
  }
  @override
  final name = 'run';
  @override
  final description = 'Select, then run the selected tests per package.';

  @override
  Future<int> run() async {
    final ws = Workspace.load(ctx.root);
    final sel = await compute(ws);
    final res = argResults!;
    final cov = res['coverage'] as bool;
    final code = await runSelection(ws, sel,
        processes: ctx.processes,
        environment: ctx.environment,
        out: ctx.out,
        err: ctx.err,
        coverage: cov);
    if (cov) _writeCoverage(ctx, res, sel);
    return code;
  }
}

class _Validate extends Command<int> {
  _Validate(this.ctx);
  final _Ctx ctx;
  @override
  final name = 'validate';
  @override
  final description = 'Check every test_impact.yaml against the code '
      '(rule f builds the declaration index).';

  /// Exit codes: 0 valid, 1 mapping violations, 2 config or environment
  /// problem (e.g. rule f could not build the index for a package).
  @override
  Future<int> run() async {
    final ws = Workspace.load(ctx.root);
    if (ws.errors.isNotEmpty) {
      ws.errors.forEach(ctx.err.writeln);
      return 2;
    }
    final dirs = areaPackages(ws);
    final index = await ImpactIndex.build(ws, packageDirs: dirs);
    ctx.err.writeln('test_impact: index of ${dirs.length} package(s) '
        'built in ${index.buildTime.inSeconds}s'
        '${index.failure == null ? '' : ' (${index.failure})'}');
    return _reportValidation(ctx, ws, index);
  }
}

/// Validates [ws] against [index], printing as `validate` does.
/// Returns 0 valid, 1 violations, 2 environment problem.
int _reportValidation(_Ctx ctx, Workspace ws, ImpactIndex index) {
  final deps = validateAreaDeps(ws, index);
  deps.warnings.forEach(ctx.err.writeln);
  final v = [...validate(ws), ...deps.violations];
  if (v.isEmpty) {
    ctx.out.writeln('test_impact: ${ws.packages.length} mapping(s) OK');
    return 0;
  }
  v.forEach(ctx.out.writeln);
  ctx.out.writeln('test_impact: ${v.length} violation(s)');
  return v.any((e) => e.environment) ? 2 : 1;
}

/// Writes the changed-line coverage reports as `run --coverage` does.
void _writeCoverage(_Ctx ctx, ArgResults res, Selection sel) {
  String at(String o) => p.join(ctx.root, res[o] as String);
  final r = writeCoverageReports(ctx.root, sel.packages.keys,
      base: res['base'] as String?,
      head: res['head'] as String,
      jsonPath: at('coverage-json'),
      mdPath: at('coverage-md'));
  ctx.out.writeln(r.summary());
}

class _Ci extends Command<int> {
  _Ci(this.ctx) {
    argParser
      ..addOption('base', help: 'Base git ref (diffed as base...head).')
      ..addOption('head', help: 'Head git ref.', defaultsTo: 'HEAD')
      ..addOption('changed-files',
          help: 'File with changed paths (one per line); skips git.')
      ..addOption('precision',
          allowed: ['area', 'file'],
          defaultsTo: 'file',
          help: 'file: narrow area matches with the declaration index; '
              'area: v1 mapping only.')
      ..addOption('output', help: 'Write the selection JSON here.')
      ..addFlag('coverage',
          help: 'Run tests with coverage and report changed-line coverage.')
      ..addOption('coverage-json',
          help: 'Coverage JSON path.', defaultsTo: coverageJsonName)
      ..addOption('coverage-md',
          help: 'Coverage markdown path.', defaultsTo: coverageMdName);
  }
  final _Ctx ctx;
  @override
  final name = 'ci';
  @override
  final description = 'validate + select + run with ONE index build '
      '(exit 1 validation/test failure, 2 config/environment).';

  @override
  Future<int> run() async {
    final res = argResults!;
    final file = res['changed-files'] as String?;
    final base = res['base'] as String?;
    if (file == null && base == null) {
      usageException('Provide --base (and --head) or --changed-files.');
    }
    final ws = Workspace.load(ctx.root);
    if (ws.errors.isNotEmpty) {
      ws.errors.forEach(ctx.err.writeln);
      return 2;
    }
    final timings = <String, int>{};
    final sw = Stopwatch()..start();
    int lap(String k) {
      timings[k] = sw.elapsedMilliseconds;
      sw.reset();
      return timings[k]!;
    }

    // Changed paths first: they decide which packages the single index
    // must cover (superset of validate's and select's needs).
    List<String>? changed;
    String? diffError;
    try {
      changed = collectChanges(ctx.root,
          base: base, head: res['head'] as String?, changedFilesPath: file);
    } on DiffException catch (e) {
      diffError = '$e';
      ctx.err.writeln('test_impact: $e; failing safe to ALL');
    }
    final refine = res['precision'] == 'file' && changed != null;
    final dirs = {
      ...areaPackages(ws),
      if (refine) ...indexPackagesFor(ws, changed),
    };
    final index = await ctx.indexBuilder(ws, dirs);
    ctx.err.writeln('test_impact: index of ${dirs.length} package(s) '
        'built in ${index.buildTime.inSeconds}s'
        '${index.failure == null ? '' : ' (${index.failure})'}');
    lap('index_ms');

    final vcode = _reportValidation(ctx, ws, index);
    lap('validate_ms');
    if (vcode != 0) {
      _logTimings(ctx, timings);
      return vcode;
    }

    final sel = changed == null
        ? selectAll(ws, [Reason('', 'diff_error', diffError!)])
        : resolve(ws, changed, index: refine ? index : null);
    lap('select_ms');
    final path = res['output'] as String?;
    Map<String, Object> doc() => {...sel.toJson(), 'timings': timings};
    void write() {
      if (path == null) return;
      File(path).writeAsStringSync(
          '${const JsonEncoder.withIndent('  ').convert(doc())}\n');
    }

    write();

    final cov = res['coverage'] as bool;
    final code = await runSelection(ws, sel,
        processes: ctx.processes,
        environment: ctx.environment,
        out: ctx.out,
        err: ctx.err,
        coverage: cov);
    if (cov) _writeCoverage(ctx, res, sel);
    lap('run_ms');
    write();
    _logTimings(ctx, timings);
    return code;
  }
}

void _logTimings(_Ctx ctx, Map<String, int> t) {
  final parts = t.entries.map((e) => '${e.key}=${e.value}');
  ctx.err.writeln('test_impact: timings ${parts.join(' ')}');
}

class _Index extends Command<int> {
  _Index(this.ctx) {
    argParser.addOption('output', help: 'Write the index summary JSON here.');
  }
  final _Ctx ctx;
  @override
  final name = 'index';
  @override
  final description =
      'Build the declaration index (debug): per-test closure sizes.';

  @override
  Future<int> run() async {
    final ws = Workspace.load(ctx.root);
    if (ws.errors.isNotEmpty) {
      ws.errors.forEach(ctx.err.writeln);
      return 2;
    }
    final idx = await ImpactIndex.build(ws);
    final sizes = idx.closureSizes();
    final json = const JsonEncoder.withIndent('  ').convert({
      'build_ms': idx.buildTime.inMilliseconds,
      'failure': idx.failure,
      'indexed_files': idx.indexed.length,
      'unavailable': idx.unavailable.toList()..sort(),
      'tainted': idx.tainted.toList()..sort(),
      'wildcard_tests': idx.wildcardTests.toList()..sort(),
      'tests': {for (final k in sizes.keys.toList()..sort()) k: sizes[k]},
    });
    final path = argResults!['output'] as String?;
    if (path != null) File(path).writeAsStringSync('$json\n');
    ctx.out.writeln('test_impact: index ${idx.indexed.length} file(s), '
        '${sizes.length} test(s), ${idx.wildcardTests.length} wildcard, '
        'built in ${idx.buildTime.inSeconds}s'
        '${idx.failure == null ? '' : ', ${idx.failure}'}');
    return idx.failure == null ? 0 : 1;
  }
}
