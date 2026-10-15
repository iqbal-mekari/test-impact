import 'config.dart';
import 'glob.dart';

/// Area view of one package: ownership of files, tests per area and the
/// `depends_on` graph. Convention areas are discovered from real files.
class AreaModel {
  /// Builds the model for [config] over package-relative [files].
  AreaModel(this.config, this.files) {
    names.addAll(config.areas.keys);
    for (final f in files) {
      for (final c in config.conventions) {
        final a = bindArea(c.sources, f);
        if (a != null) names.add(a);
      }
    }
    for (final a in names) {
      _deps[a] = {...?config.areas[a]?.dependsOn};
    }
  }

  /// The package mapping.
  final PackageConfig config;

  /// Package-relative files.
  final List<String> files;

  /// Explicit and discovered convention area names.
  final Set<String> names = {};
  final Map<String, Set<String>> _deps = {};

  /// Areas whose explicit `sources` match [path].
  List<String> explicitOwners(String path) => [
        for (final a in config.areas.values)
          if (matchesAny(a.sources, path)) a.name
      ];

  /// Owning areas of [path]: explicit ones, else convention-bound ones.
  List<String> ownersOf(String path) {
    final explicit = explicitOwners(path);
    if (explicit.isNotEmpty) return explicit;
    final out = <String>{};
    for (final c in config.conventions) {
      final a = bindArea(c.sources, path);
      if (a != null) out.add(a);
    }
    return out.toList();
  }

  /// Test files (package-relative) belonging directly to [area].
  Set<String> testsOf(String area) {
    final out = <String>{};
    bool isTest(String f) => f.startsWith('test/') && f.endsWith('_test.dart');
    final a = config.areas[area];
    for (final f in files) {
      if (a != null &&
          (isTest(f) && matchesAny(a.tests, f) ||
              matchesAny(a.extraTests, f))) {
        out.add(f);
      }
    }
    for (final c in config.conventions) {
      final re = compileGlob(c.tests, area: area);
      out.addAll(files.where((f) => isTest(f) && re.hasMatch(f)));
    }
    return out;
  }

  /// [area] plus every area that depends on it, transitively.
  Set<String> affectedBy(String area) {
    final out = {area};
    var grew = true;
    while (grew) {
      grew = false;
      _deps.forEach((a, deps) {
        if (!out.contains(a) && deps.any(out.contains)) {
          out.add(a);
          grew = true;
        }
      });
    }
    return out;
  }

  /// Every area [area] depends on, transitively.
  Set<String> dependenciesOf(String area) {
    final out = <String>{};
    final queue = [area];
    while (queue.isNotEmpty) {
      for (final d in _deps[queue.removeLast()] ?? const <String>{}) {
        if (out.add(d)) queue.add(d);
      }
    }
    return out;
  }

  /// All test files this package's mapping covers through areas.
  Set<String> get coveredTests => {for (final a in names) ...testsOf(a)};
}
