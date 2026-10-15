import 'dart:io';
import 'dart:math' as math;

import 'package:path/path.dart' as p;

import 'bundle/exit_code_exception.dart';

/// One `SF:` record: `DA` hits, `FN` locations, `FNDA` hits and `BRDA`
/// (line, block, branch) hits, where a `-` is null.
final class LcovTraceRecord {
  /// Creates an empty record for [source].
  LcovTraceRecord(this.source);

  final String source;
  final Map<int, int> lines = {};
  final Map<String, String> functions = {};
  final Map<String, int> functionHits = {};
  final Map<(int, String, String), int?> branches = {};

  void _add(LcovTraceRecord other) {
    other.lines.forEach((k, v) => lines[k] = (lines[k] ?? 0) + v);
    functions.addAll(other.functions);
    other.functionHits
        .forEach((k, v) => functionHits[k] = (functionHits[k] ?? 0) + v);
    other.branches.forEach((k, v) => v == null
        ? branches.putIfAbsent(k, () => null)
        : branches[k] = (branches[k] ?? 0) + v);
  }
}

/// A parsed LCOV tracefile: records by `SF:` value, in insertion order.
/// Every failure is an [ExitCodeException] with exit code 1.
final class LcovTrace {
  /// Creates a report from [records], keyed by source.
  LcovTrace(this.records);

  final Map<String, LcovTraceRecord> records;

  /// Strict parse: rejects nested or empty `SF:`, `DA:` outside a record, a
  /// stray terminator, a truncated last record, line < 1 or count < 0, and
  /// (with [requireRecords]) an empty report. A repeated source keeps the
  /// highest count, so a duplicate record cannot inflate coverage.
  static LcovTrace parse(
    String text, {
    required String origin,
    bool requireRecords = false,
  }) {
    final records = <String, LcovTraceRecord>{};
    LcovTraceRecord? current;
    Never fail(int line, String why) => throw ExitCodeException(
        'invalid coverage report $origin:${line + 1}: $why', 1);
    int number(String value, int line, {required int min}) {
      final parsed = int.tryParse(value);
      if (parsed == null || parsed < min) fail(line, 'invalid counter');
      return parsed;
    }

    final lines = text.split(RegExp(r'\r?\n'));
    for (var i = 0; i < lines.length; i++) {
      final line = lines[i];
      if (line.startsWith('SF:')) {
        final source = line.substring(3);
        if (current != null || source.isEmpty) {
          fail(i, 'nested or empty SF record');
        }
        current = records.putIfAbsent(source, () => LcovTraceRecord(source));
      } else if (line == 'end_of_record') {
        if (current == null) fail(i, 'terminator without SF record');
        current = null;
      } else if (line.startsWith('DA:')) {
        if (current == null) fail(i, 'DA outside a record');
        final parts = line.substring(3).split(',');
        if (parts.length < 2) fail(i, 'malformed DA');
        final at = number(parts[0], i, min: 1);
        final hits = number(parts[1], i, min: 0);
        current.lines[at] = math.max(current.lines[at] ?? 0, hits);
      } else if (current == null) {
        continue;
      } else if (line.startsWith('FNDA:')) {
        final comma = line.indexOf(',');
        if (comma < 0) fail(i, 'malformed FNDA');
        final name = line.substring(comma + 1);
        final hits = number(line.substring(5, comma), i, min: 0);
        current.functionHits[name] =
            math.max(current.functionHits[name] ?? 0, hits);
      } else if (line.startsWith('FN:')) {
        final comma = line.indexOf(',');
        if (comma < 0) fail(i, 'malformed FN');
        current.functions[line.substring(comma + 1)] = line.substring(3, comma);
      } else if (line.startsWith('BRDA:')) {
        final parts = line.substring(5).split(',');
        if (parts.length != 4) fail(i, 'malformed BRDA');
        final key = (number(parts[0], i, min: 0), parts[1], parts[2]);
        if (parts[3] == '-') {
          current.branches.putIfAbsent(key, () => null);
        } else {
          final hits = number(parts[3], i, min: 0);
          current.branches[key] = math.max(current.branches[key] ?? 0, hits);
        }
      }
    }
    if (current != null) {
      throw ExitCodeException('truncated coverage report: $origin', 1);
    }
    if (requireRecords && records.isEmpty) {
      throw ExitCodeException('empty coverage report: $origin', 1);
    }
    return LcovTrace(records);
  }

  /// Reads and parses [path]; see [parse].
  static LcovTrace read(String path, {bool requireRecords = false}) {
    final String text;
    try {
      text = File(path).readAsStringSync();
    } on FileSystemException catch (e) {
      throw ExitCodeException(
          'cannot read coverage report $path: ${e.message}', 1);
    } on FormatException {
      throw ExitCodeException('coverage report is not valid UTF-8: $path', 1);
    }
    return parse(text, origin: path, requireRecords: requireRecords);
  }

  /// Sums hits per line, function and branch across [reports]; a `-` branch
  /// stays unless a count exists. The `SF:` spelling is preserved.
  static LcovTrace sum(Iterable<LcovTrace> reports) {
    final merged = <String, LcovTraceRecord>{};
    for (final record in reports.expand((r) => r.records.values)) {
      merged
          .putIfAbsent(record.source, () => LcovTraceRecord(record.source))
          ._add(record);
    }
    return LcovTrace(merged);
  }

  /// Rewrites each `SF:` to an absolute, symlink-resolved path (relative ones
  /// join [packageDir]) and sums sources that collapse to one file. With
  /// [repoRoot], a source outside it or missing on disk throws.
  LcovTrace absolutize(String packageDir, {String? repoRoot}) {
    final repo = repoRoot == null ? null : _resolve(repoRoot);
    final out = <String, LcovTraceRecord>{};
    for (final record in records.values) {
      final path = _resolve(p.isAbsolute(record.source)
          ? record.source
          : p.join(packageDir, record.source));
      if (repo != null && !p.isWithin(repo, path)) {
        throw ExitCodeException('coverage source outside checkout: $path', 1);
      }
      if (repo != null && !File(path).existsSync()) {
        throw ExitCodeException('coverage source does not exist: $path', 1);
      }
      out.putIfAbsent(path, () => LcovTraceRecord(path))._add(record);
    }
    return LcovTrace(out);
  }

  /// Drops records whose `SF:` matches any glob with `lcov -r` semantics:
  /// anchored, `*` matches any run (including `/`), `?` one character.
  LcovTrace removeMatching(Iterable<String> globs) {
    final patterns = [
      for (final glob in globs)
        RegExp(
            '^${glob.runes.map(String.fromCharCode).map((c) => switch (c) {
                  '*' => '.*',
                  '?' => '.',
                  _ => RegExp.escape(c),
                }).join()}\$',
            dotAll: true),
    ];
    return LcovTrace({
      for (final e in records.entries)
        if (!patterns.any((pattern) => pattern.hasMatch(e.key))) e.key: e.value,
    });
  }

  /// All `SF:` values.
  Set<String> get sources => records.keys.toSet();

  /// Renders the records sorted by source. `FN*` and `BR*` lines are left
  /// out when a record has none or [functions] / [branches] is false.
  String render({bool functions = true, bool branches = true}) {
    final out = StringBuffer();
    List<K> sorted<K>(Iterable<K> keys, [int Function(K, K)? by]) =>
        keys.toList()..sort(by);
    for (final source in sorted(records.keys)) {
      final r = records[source]!;
      out.writeln('TN:\nSF:$source');
      if (functions && r.functions.isNotEmpty) {
        for (final name in sorted(r.functions.keys)) {
          out.writeln('FN:${r.functions[name]},$name');
        }
        for (final name in sorted(r.functionHits.keys)) {
          out.writeln('FNDA:${r.functionHits[name]},$name');
        }
        out.writeln('FNF:${r.functions.length}\n'
            'FNH:${r.functionHits.values.where((c) => c > 0).length}');
      }
      for (final line in sorted(r.lines.keys)) {
        out.writeln('DA:$line,${r.lines[line]}');
      }
      out.writeln('LF:${r.lines.length}\n'
          'LH:${r.lines.values.where((c) => c > 0).length}');
      if (branches && r.branches.isNotEmpty) {
        for (final k in sorted(r.branches.keys, _compareBranch)) {
          out.writeln('BRDA:${k.$1},${k.$2},${k.$3},${r.branches[k] ?? '-'}');
        }
        out.writeln('BRF:${r.branches.length}\n'
            'BRH:${r.branches.values.where((c) => c != null && c > 0).length}');
      }
      out.writeln('end_of_record');
    }
    return out.toString();
  }

  /// Writes [render] to [path], creating parent directories.
  void write(String path, {bool functions = true, bool branches = true}) {
    File(path)
      ..parent.createSync(recursive: true)
      ..writeAsStringSync(render(functions: functions, branches: branches));
  }

  static int _compareBranch((int, String, String) a, (int, String, String) b) {
    final byLine = a.$1.compareTo(b.$1);
    if (byLine != 0) return byLine;
    final byBlock = a.$2.compareTo(b.$2);
    return byBlock != 0 ? byBlock : a.$3.compareTo(b.$3);
  }

  static String _resolve(String path) {
    final absolute = p.normalize(p.absolute(path));
    try {
      return File(absolute).resolveSymbolicLinksSync();
    } on FileSystemException {
      return absolute;
    }
  }
}

/// Line-level comparison of two reports for `bundle verify`: source sets,
/// line-set, covered-line and hit-count differences, covered line totals
/// and `equivalent` (same sources, lines and covered/uncovered state).
Map<String, Object?> compareLcovTraces(LcovTrace first, LcovTrace second) {
  final a = first.records;
  final b = second.records;
  var lineSets = 0;
  var covered = 0;
  var counts = 0;
  for (final source in a.keys.where(b.containsKey)) {
    final left = a[source]!.lines;
    final right = b[source]!.lines;
    for (final line in {...left.keys, ...right.keys}) {
      final l = left[line];
      final r = right[line];
      if (l == null || r == null) {
        lineSets++;
        continue;
      }
      if ((l > 0) != (r > 0)) covered++;
      if (l != r) counts++;
    }
  }
  int coveredLines(Map<String, LcovTraceRecord> records) =>
      records.values.expand((r) => r.lines.values).where((c) => c > 0).length;
  final onlyFirst = a.keys.where((s) => !b.containsKey(s)).toList()..sort();
  final onlySecond = b.keys.where((s) => !a.containsKey(s)).toList()..sort();
  return {
    'sources': [a.length, b.length],
    'sources_only_first': onlyFirst,
    'sources_only_second': onlySecond,
    'line_set_differences': lineSets,
    'covered_line_differences': covered,
    'hit_count_differences': counts,
    'covered_lines': [coveredLines(a), coveredLines(b)],
    'equivalent': onlyFirst.isEmpty &&
        onlySecond.isEmpty &&
        lineSets == 0 &&
        covered == 0,
  };
}
