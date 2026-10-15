import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

/// Per-file lcov data: line number -> hit count.
typedef Lcov = Map<String, Map<int, int>>;

/// Parses lcov [text] from a `flutter test --coverage` run in [pkgDir]
/// (repo-relative, `.` for the root). `SF:` paths are package-relative;
/// the result is keyed by repo-relative paths. Absolute paths under [root]
/// are relativised. Malformed `DA` lines are skipped.
Lcov parseLcov(String text, {required String pkgDir, required String root}) {
  final out = <String, Map<int, int>>{};
  Map<int, int>? cur;
  for (final raw in text.split('\n')) {
    final line = raw.trim();
    if (line.startsWith('SF:')) {
      var path = line.substring(3);
      if (p.isAbsolute(path)) {
        path = p.isWithin(root, path) ? p.relative(path, from: root) : path;
      } else {
        path = p.normalize(p.join(pkgDir, path));
      }
      cur = out.putIfAbsent(p.posix.normalize(path), () => {});
    } else if (line.startsWith('DA:') && cur != null) {
      final parts = line.substring(3).split(',');
      if (parts.length < 2) continue;
      final n = int.tryParse(parts[0]), h = int.tryParse(parts[1]);
      if (n == null || h == null) continue;
      cur[n] = (cur[n] ?? 0) + h;
    } else if (line == 'end_of_record') {
      cur = null;
    }
  }
  return out;
}

/// Merges several lcov maps, summing hits per file and line.
Lcov mergeLcov(Iterable<Lcov> parts) {
  final out = <String, Map<int, int>>{};
  for (final l in parts) {
    l.forEach((f, lines) {
      final dst = out.putIfAbsent(f, () => {});
      lines.forEach((n, h) => dst[n] = (dst[n] ?? 0) + h);
    });
  }
  return out;
}

final _hunk = RegExp(r'^@@ -\d+(?:,\d+)? \+(\d+)(?:,(\d+))? @@');

/// Parses `git diff -U0` output into head path -> added/modified lines.
/// Deleted files and pure deletions contribute nothing; renames use the
/// head path.
Map<String, Set<int>> parseDiffHunks(String diff) {
  final out = <String, Set<int>>{};
  String? file;
  for (final line in diff.split('\n')) {
    if (line.startsWith('+++ ')) {
      var path = line.substring(4).split('\t').first;
      if (path == '/dev/null') {
        file = null;
      } else {
        if (path.startsWith('b/')) path = path.substring(2);
        file = path;
      }
    } else if (line.startsWith('diff --git ')) {
      file = null;
    } else if (file != null) {
      final m = _hunk.firstMatch(line);
      if (m == null) continue;
      final start = int.parse(m.group(1)!);
      final count = m.group(2) == null ? 1 : int.parse(m.group(2)!);
      if (count == 0) continue;
      out
          .putIfAbsent(file, () => {})
          .addAll([for (var i = 0; i < count; i++) start + i]);
    }
  }
  return out;
}

/// Runs `git diff -U0 -M base...head` in [root] and parses the hunks.
/// Throws [StateError] when git fails.
Map<String, Set<int>> collectChangedLines(String root,
    {required String base, required String head}) {
  final r = Process.runSync(
      'git',
      [
        '-c',
        'core.quotepath=off',
        'diff',
        '-U0',
        '--no-color',
        '-M',
        '$base...$head',
      ],
      workingDirectory: root);
  if (r.exitCode != 0) {
    throw StateError('git diff $base...$head failed: ${r.stderr}'.trim());
  }
  return parseDiffHunks(r.stdout as String);
}

const _generated = [
  '.g.dart',
  '.freezed.dart',
  '.mocks.dart',
  '.config.dart',
  '.gr.dart'
];

/// Whether [path] is a production source counted for coverage: a
/// non-generated `lib/**/*.dart` file.
bool isTrackedSource(String path) {
  if (!path.endsWith('.dart')) return false;
  if (!(path.startsWith('lib/') || path.contains('/lib/'))) return false;
  return !_generated.any(path.endsWith);
}

double? _pct(int hit, int total) =>
    total == 0 ? null : (hit * 1000 / total).round() / 10;

String _fmt(double? v) => v == null ? 'n/a' : '${v.toStringAsFixed(1)}%';

/// Coverage of one changed file.
class FileCoverage {
  /// Creates an entry.
  FileCoverage(this.path,
      {required this.changedLines,
      required this.instrumented,
      required this.hit,
      required this.filePct,
      this.loaded = true});

  /// Repo-relative path.
  final String path;

  /// Number of added/modified lines.
  final int changedLines;

  /// Changed lines that are instrumented (have a DA record).
  final int instrumented;

  /// Instrumented changed lines with at least one hit.
  final int hit;

  /// Whole-file line coverage (0 when not loaded).
  final double filePct;

  /// False when absent from lcov.
  final bool loaded;

  /// Changed-line coverage, null when nothing is instrumented.
  double? get changedPct => _pct(hit, instrumented);

  /// Changed lines that could not be measured.
  int get unmeasuredChangedLines => changedLines - instrumented;

  /// JSON form.
  Map<String, Object?> toJson() => {
        'path': path,
        'changed_lines': changedLines,
        'instrumented_changed_lines': instrumented,
        'hit_changed_lines': hit,
        'changed_line_pct': changedPct,
        'file_line_pct': filePct,
        if (!loaded) 'unmeasured_changed_lines': changedLines,
      };
}

/// Changed-code coverage report.
class CoverageReport {
  /// Creates a report; [note] explains a degraded report.
  CoverageReport(this.files, this.notLoaded, {this.note});

  /// Changed files present in lcov.
  final List<FileCoverage> files;

  /// Changed files absent from lcov (counted as 0% file coverage).
  final List<FileCoverage> notLoaded;

  /// Optional explanation (for example, no diff available).
  final String? note;

  /// Instrumented changed lines over loaded files.
  int get instrumented => files.fold(0, (s, f) => s + f.instrumented);

  /// Hit changed lines over loaded files.
  int get hit => files.fold(0, (s, f) => s + f.hit);

  /// Overall changed-line coverage, null if nothing is instrumented.
  double? get overallPct => _pct(hit, instrumented);

  /// One-line summary.
  String summary() {
    final n = notLoaded.length;
    final nl = n == 0 ? '' : ', $n file${n == 1 ? '' : 's'} not loaded';
    if (instrumented == 0) {
      return 'Changed-line coverage: n/a (0/0)$nl';
    }
    return 'Changed-line coverage: ${_fmt(overallPct)} '
        '($hit/$instrumented)$nl';
  }

  /// JSON form.
  Map<String, Object?> toJson() => {
        'overall_changed_line_pct': overallPct,
        'instrumented_changed_lines': instrumented,
        'hit_changed_lines': hit,
        'files': [for (final f in files) f.toJson()],
        'not_loaded': [for (final f in notLoaded) f.toJson()],
        'unmeasured_changed_lines':
            notLoaded.fold<int>(0, (s, f) => s + f.changedLines) +
                files.fold<int>(0, (s, f) => s + f.unmeasuredChangedLines),
        if (note != null) 'note': note,
      };

  /// Markdown report.
  String toMarkdown() {
    final b = StringBuffer('# Test impact: changed-line coverage\n\n');
    if (note != null) b.writeln('Note: $note\n');
    if (files.isEmpty && notLoaded.isEmpty) {
      b.writeln('There are no changed production lines '
          '(coverage: n/a).');
      return b.toString();
    }
    b
      ..writeln('${summary()}\n')
      ..writeln('| File | Changed lines instrumented | Changed lines hit '
          '| Changed-line % | File % |')
      ..writeln('|---|---|---|---|---|');
    for (final f in files) {
      b.writeln('| ${f.path} | ${f.instrumented} | ${f.hit} '
          '| ${_fmt(f.changedPct)} | ${_fmt(f.filePct)} |');
    }
    if (notLoaded.isNotEmpty) {
      b
        ..writeln('\n## Not loaded by any selected test '
            '(counted as 0% file coverage)\n')
        ..writeln('| File | Changed lines (unmeasured) | File % |')
        ..writeln('|---|---|---|');
      for (final f in notLoaded) {
        b.writeln('| ${f.path} | ${f.changedLines} | 0.0% |');
      }
    }
    return b.toString();
  }
}

/// Computes coverage of [changed] (head path -> lines) against [lcov].
CoverageReport computeCoverage(Map<String, Set<int>> changed, Lcov lcov,
    {String? note}) {
  final files = <FileCoverage>[], notLoaded = <FileCoverage>[];
  for (final path in changed.keys.toList()..sort()) {
    final lines = changed[path]!;
    if (!isTrackedSource(path) || lines.isEmpty) continue;
    final da = lcov[path];
    if (da == null) {
      notLoaded.add(FileCoverage(path,
          changedLines: lines.length,
          instrumented: 0,
          hit: 0,
          filePct: 0,
          loaded: false));
      continue;
    }
    final inst = lines.where(da.containsKey);
    files.add(FileCoverage(path,
        changedLines: lines.length,
        instrumented: inst.length,
        hit: inst.where((n) => da[n]! > 0).length,
        filePct: _pct(da.values.where((h) => h > 0).length, da.length) ?? 0));
  }
  return CoverageReport(files, notLoaded, note: note);
}

/// Default report names, written at the repo root.
const coverageJsonName = 'test-impact-coverage.json';

/// Markdown report name.
const coverageMdName = 'test-impact-coverage.md';

/// Merges the lcov of [pkgDirs] under [root], computes the changed-line
/// report for `base...head` and writes the JSON and markdown reports to
/// [jsonPath] / [mdPath]. Report only: never throws on missing lcov or a
/// failing diff (a [CoverageReport.note] says what was unavailable).
CoverageReport writeCoverageReports(String root, Iterable<String> pkgDirs,
    {String? base,
    String head = 'HEAD',
    required String jsonPath,
    required String mdPath}) {
  final parts = <Lcov>[];
  for (final dir in pkgDirs) {
    final f = File(p.join(root, dir, 'coverage', 'test_impact_lcov.info'));
    if (f.existsSync()) {
      parts.add(parseLcov(f.readAsStringSync(), pkgDir: dir, root: root));
    }
  }
  Map<String, Set<int>> changed = {};
  String? note;
  if (base == null) {
    note = 'no --base given; changed lines unavailable';
  } else {
    try {
      changed = collectChangedLines(root, base: base, head: head);
    } on StateError catch (e) {
      note = '$e; changed lines unavailable';
    }
  }
  final r = computeCoverage(changed, mergeLcov(parts), note: note);
  File(jsonPath).writeAsStringSync(
      '${const JsonEncoder.withIndent('  ').convert(r.toJson())}\n');
  File(mdPath).writeAsStringSync(r.toMarkdown());
  return r;
}
