import 'dart:io';

import 'package:path/path.dart' as p;

import 'index_builder.dart';
import 'workspace.dart';

/// Declaration-level reachability index of the HEAD tree (spec v2 D2).
///
/// Nodes are top-level declarations keyed `file#name` (repo-relative
/// file of the declaring unit, so a part file such as `x.g.dart` owns its
/// own declarations), plus one `test:<file>` root per `*_test.dart` file.
/// Edges point from a declaration to every declaration it references.
/// A second, file-level graph of import/export/part directives serves
/// files that declare nothing (barrels).
///
/// ```dart
/// final index = await ImpactIndex.build(ws);
/// final r = index.testsReaching('modules/a/lib/x.dart');
/// if (r.tests != null) print(r.tests); else print(r.why);
/// ```
class ImpactIndex {
  /// Creates an index from raw graph data (see [IndexBuilder]).
  ImpactIndex({
    required this.root,
    required this.packages,
    required this.unavailable,
    required this.indexed,
    required this.tainted,
    required this.declsByFile,
    required this.edges,
    required this.imports,
    required this.wildcardTests,
    this.failure,
  });

  /// An index that could not be built; every lookup falls back.
  ImpactIndex.failed(this.root, String why)
      : packages = const {},
        unavailable = const {},
        indexed = const {},
        tainted = const {},
        declsByFile = const {},
        edges = const {},
        imports = const {},
        wildcardTests = const {},
        failure = why;

  /// Builds the index for [packageDirs] (default: every package of [ws]).
  ///
  /// Never throws: a crash yields [ImpactIndex.failed].
  static Future<ImpactIndex> build(Workspace ws,
      {Iterable<String>? packageDirs}) async {
    final sw = Stopwatch()..start();
    try {
      final idx = await IndexBuilder(ws, packageDirs: packageDirs).build();
      return idx..buildTime = sw.elapsed;
    } on Object catch (e) {
      return ImpactIndex.failed(ws.root, 'index build failed: $e');
    }
  }

  /// Absolute repo root.
  final String root;

  /// Repo-relative dirs of the packages this index covers.
  final Set<String> packages;

  /// Covered packages that could not be analyzed (no package config).
  final Set<String> unavailable;

  /// Repo-relative files whose library resolved without errors.
  final Set<String> indexed;

  /// Repo-relative files whose library failed or had errors.
  final Set<String> tainted;

  /// Node keys declared in each indexed file.
  final Map<String, Set<String>> declsByFile;

  /// Forward declaration edges (node -> referenced nodes).
  final Map<String, Set<String>> edges;

  /// Forward directive edges (file -> imported/exported/part files).
  final Map<String, Set<String>> imports;

  /// Repo-relative tests whose reach is unknown; kept for every change.
  final Set<String> wildcardTests;

  /// Why the index is unusable, or null.
  final String? failure;

  /// Wall time of [build].
  Duration buildTime = Duration.zero;

  late final Map<String, Set<String>> _reverse = _invert(edges);
  late final Map<String, Set<String>> _importers = _invert(imports);

  /// Tests (repo-relative) whose closure contains a declaration of the
  /// repo-relative lib [file], or the reason it cannot be refined.
  Refinement testsReaching(String file) {
    if (failure != null) return const Refinement.fallback('index_failed');
    final pkg = _packageOf(file);
    if (pkg == null) return const Refinement.fallback('not_covered');
    if (unavailable.contains(pkg)) {
      return const Refinement.fallback('index_unavailable');
    }
    if (!File(p.join(root, file)).existsSync()) {
      return const Refinement.fallback('deleted');
    }
    if (tainted.contains(file)) {
      return const Refinement.fallback('analysis_error');
    }
    if (!indexed.contains(file)) {
      return const Refinement.fallback('not_indexed');
    }
    final decls = declsByFile[file] ?? const <String>{};
    final hits = decls.isNotEmpty ? _declTests(decls) : _directiveTests(file);
    return Refinement({...hits, ...wildcardTests});
  }

  /// Number of declarations reachable from each test (debug output).
  Map<String, int> closureSizes() {
    final out = <String, int>{};
    for (final key in edges.keys) {
      if (!key.startsWith(testPrefix)) continue;
      final seen = <String>{key};
      final queue = [key];
      while (queue.isNotEmpty) {
        for (final n in edges[queue.removeLast()] ?? const <String>{}) {
          if (seen.add(n)) queue.add(n);
        }
      }
      out[key.substring(testPrefix.length)] = seen.length - 1;
    }
    return out;
  }

  Set<String> _declTests(Set<String> start) {
    final seen = {...start};
    final queue = [...start];
    final out = <String>{};
    while (queue.isNotEmpty) {
      for (final n in _reverse[queue.removeLast()] ?? const <String>{}) {
        if (!seen.add(n)) continue;
        if (n.startsWith(testPrefix)) {
          out.add(n.substring(testPrefix.length));
        } else {
          queue.add(n);
        }
      }
    }
    return out;
  }

  Set<String> _directiveTests(String file) {
    final seen = {file};
    final queue = [file];
    while (queue.isNotEmpty) {
      for (final n in _importers[queue.removeLast()] ?? const <String>{}) {
        if (seen.add(n)) queue.add(n);
      }
    }
    return {
      for (final f in seen)
        if (edges.containsKey('$testPrefix$f')) f
    };
  }

  String? _packageOf(String file) {
    String? best;
    for (final d in packages) {
      if ((d == '.' || file.startsWith('$d/')) &&
          (best == null || d.length > best.length)) {
        best = d;
      }
    }
    return best;
  }

  static Map<String, Set<String>> _invert(Map<String, Set<String>> g) {
    final out = <String, Set<String>>{};
    g.forEach((from, tos) {
      for (final t in tos) {
        out.putIfAbsent(t, () => {}).add(from);
      }
    });
    return out;
  }
}

/// Prefix of the synthetic root node of a test file.
const testPrefix = 'test:';

/// Outcome of [ImpactIndex.testsReaching].
class Refinement {
  /// Refined result: the reaching tests.
  const Refinement(Set<String> this.tests) : why = null;

  /// Not refinable; the caller keeps the unrefined v1 candidates.
  const Refinement.fallback(String this.why) : tests = null;

  /// Repo-relative tests reaching the file, or null when [why] is set.
  final Set<String>? tests;

  /// Fallback reason, e.g. `deleted`, `index_failed`.
  final String? why;
}
