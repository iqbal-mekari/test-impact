import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:yaml/yaml.dart';

/// A mapping/config problem, with file and (dotted) key context.
class ConfigException implements Exception {
  /// Creates an exception for [file], optionally scoped to [key].
  ConfigException(this.file, this.message, {this.key});

  /// Offending file path.
  final String file;

  /// Dotted key path inside the file, if known.
  final String? key;

  /// Human-readable problem.
  final String message;

  @override
  String toString() => '$file: ${key == null ? '' : '$key: '}$message';
}

/// A runtime (non-import) dependency: [paths] are read from disk by
/// [tests] while they run, so no import analysis can link them.
class RuntimeTestRule {
  /// Creates a rule.
  const RuntimeTestRule(this.paths, this.tests, {this.except = const []});

  /// Repo-relative globs of the files the tests read.
  final List<String> paths;

  /// Repo-relative globs excluded from [paths] (e.g. generated files the
  /// tests skip).
  final List<String> except;

  /// Repo-relative test files (`<package dir>/test/..._test.dart`).
  final List<String> tests;
}

/// Repo-wide rules (root `test_impact.yaml` only).
class RepoRules {
  /// Creates the rules.
  const RepoRules({
    this.safe = const [],
    this.runAll = const [],
    this.runtimeTests = const [],
  });

  /// Repo-relative globs that never trigger tests.
  final List<String> safe;

  /// Repo-relative globs that trigger every package's full suite.
  final List<String> runAll;

  /// Files read at runtime by tests; a match selects those tests even when
  /// the path is also `safe`.
  final List<RuntimeTestRule> runtimeTests;
}

/// Generic process-global-state hazards: tests (or helpers they import)
/// matching any of these run as their own entrypoint instead of sharing a
/// bundle isolate. Used when `tooling.isolation_patterns` is absent.
final defaultIsolationPatternSources = List<String>.unmodifiable([
  r'(HttpOverrides|IOOverrides)\s*\.\s*global\s*=',
  r'\w*FlutterBinding\s*\.\s*ensureInitialized',
  r'\bsetUpAll\s*\(',
  r'setMock(MethodCall|Message|Stream)Handler|setMockInitialValues',
  r'debugDefaultTargetPlatformOverride\s*=',
  r'\w+Platform\s*\.\s*instance\s*=',
  r'(Bloc\s*\.\s*observer|HydratedBloc\s*\.\s*storage)\s*=',
  r'\bHive\s*\.\s*(init|registerAdapter|openBox)',
  r'^(?![\s\S]*\.reset\s*\()[\s\S]*'
      r'\.register(Singleton|LazySingleton|Factory)\w*\s*[<(]',
]);

/// Tool settings from the optional root-only `tooling:` block.
class Tooling {
  /// Creates settings; every field has a generic default.
  Tooling({
    this.flutterCommand = const ['flutter'],
    this.dartCommand = const ['dart'],
    List<String>? isolationPatterns,
    this.bundlePolicy,
  }) : isolationPatterns = isolationPatterns ?? defaultIsolationPatternSources;

  /// Command prefix that runs Flutter (e.g. `[wrapper, flutter]`).
  final List<String> flutterCommand;

  /// Command prefix that runs Dart (e.g. `[wrapper, dart]`).
  final List<String> dartCommand;

  /// Regex sources; a test matching one runs as its own entrypoint.
  final List<String> isolationPatterns;

  /// Repo-relative path of the optional bundle policy file.
  final String? bundlePolicy;

  /// [isolationPatterns] compiled.
  late final List<RegExp> isolationRegExps = [
    for (final s in isolationPatterns) RegExp(s)
  ];
}

/// Tool settings of the repo at [repoRoot]: the `tooling:` block of its
/// root `test_impact.yaml`, or generic defaults when the file or block is
/// absent. Throws [ConfigException] when the file is invalid.
Tooling loadTooling(String repoRoot) {
  final path = p.join(repoRoot, 'test_impact.yaml');
  if (!File(path).existsSync()) return Tooling();
  return loadConfig(path).tooling ?? Tooling();
}

/// An implicit folder convention: `sources` -> `tests`, both with `{area}`.
class Convention {
  /// Creates a convention.
  const Convention(this.sources, this.tests);

  /// Source glob containing `{area}`.
  final String sources;

  /// Test glob containing `{area}`.
  final String tests;
}

/// An explicit area definition.
class AreaConfig {
  /// Creates an area.
  const AreaConfig(this.name,
      {this.sources = const [],
      this.tests = const [],
      this.extraTests = const [],
      this.dependsOn = const []});

  /// Area name.
  final String name;

  /// Package-relative source globs.
  final List<String> sources;

  /// Package-relative test globs.
  final List<String> tests;

  /// Extra test files/globs run whenever this area is affected.
  final List<String> extraTests;

  /// Areas this area depends on (change in them also runs this area).
  final List<String> dependsOn;
}

/// Parsed `<package>/test_impact.yaml`.
class PackageConfig {
  /// Creates a config.
  const PackageConfig({
    required this.file,
    required this.name,
    this.repo,
    this.tooling,
    this.runAll = const [],
    this.runPackage = const [],
    this.conventions = const [],
    this.areas = const {},
  });

  /// Source file path.
  final String file;

  /// Pubspec package name.
  final String name;

  /// Repo-wide rules (root file only).
  final RepoRules? repo;

  /// Tool settings (root file only), null when the block is absent.
  final Tooling? tooling;

  /// Globs running this package and all its dependents fully.
  final List<String> runAll;

  /// Globs running this package fully.
  final List<String> runPackage;

  /// Folder conventions.
  final List<Convention> conventions;

  /// Explicit areas by name.
  final Map<String, AreaConfig> areas;
}

const _topKeys = {
  'version', 'package', 'repo', 'tooling', 'run_all', 'run_package', //
  'conventions', 'areas',
};
const _toolingKeys = {
  'flutter_command',
  'dart_command',
  'isolation_patterns',
  'bundle_policy',
};
const _areaKeys = {'sources', 'tests', 'extra_tests', 'depends_on'};

/// Loads and validates the mapping file at [path].
///
/// Throws [ConfigException] naming the file and key on any problem.
PackageConfig loadConfig(String path) {
  Never fail(String msg, [String? key]) =>
      throw ConfigException(path, msg, key: key);

  final Object? doc;
  try {
    doc = loadYaml(File(path).readAsStringSync());
  } on YamlException catch (e) {
    fail('invalid YAML: ${e.message}');
  } on FileSystemException catch (e) {
    fail('cannot read: ${e.message}');
  }
  if (doc is! Map) fail('top level must be a mapping');

  List<String> strings(Object? v, String key) {
    if (v == null) return const [];
    if (v is! List || v.any((e) => e is! String)) {
      fail('must be a list of strings', key);
    }
    return List<String>.from(v);
  }

  for (final k in doc.keys) {
    if (!_topKeys.contains(k)) fail('unknown key', '$k');
  }
  if (doc['version'] != 1) fail('must be 1', 'version');
  final name = doc['package'];
  if (name is! String || name.isEmpty) fail('required string', 'package');

  RepoRules? repo;
  final r = doc['repo'];
  if (r != null) {
    if (r is! Map) fail('must be a mapping', 'repo');
    for (final k in r.keys) {
      if (k != 'safe' && k != 'run_all' && k != 'runtime_tests') {
        fail('unknown key', 'repo.$k');
      }
    }
    final runtime = <RuntimeTestRule>[];
    final rt = r['runtime_tests'];
    if (rt != null) {
      if (rt is! List) fail('must be a list', 'repo.runtime_tests');
      for (var i = 0; i < rt.length; i++) {
        final e = rt[i];
        final key = 'repo.runtime_tests[$i]';
        if (e is! Map) fail('must be a mapping', key);
        for (final k in e.keys) {
          if (k != 'paths' && k != 'tests' && k != 'except')
            fail('unknown key', '$key.$k');
        }
        if (e['paths'] == null || e['tests'] == null) {
          fail('needs `paths` and `tests`', key);
        }
        final paths = strings(e['paths'], '$key.paths');
        final tests = strings(e['tests'], '$key.tests');
        if (paths.isEmpty) fail('must not be empty', '$key.paths');
        if (tests.isEmpty) fail('must not be empty', '$key.tests');
        runtime.add(RuntimeTestRule(paths, tests,
            except: strings(e['except'], '$key.except')));
      }
    }
    repo = RepoRules(
      safe: strings(r['safe'], 'repo.safe'),
      runAll: strings(r['run_all'], 'repo.run_all'),
      runtimeTests: runtime,
    );
  }

  Tooling? tooling;
  final t = doc['tooling'];
  if (t != null) {
    if (t is! Map) fail('must be a mapping', 'tooling');
    for (final k in t.keys) {
      if (!_toolingKeys.contains(k)) fail('unknown key', 'tooling.$k');
    }
    List<String>? command(String k, List<String> fallback) {
      if (t[k] == null) return fallback;
      final v = strings(t[k], 'tooling.$k');
      if (v.isEmpty) fail('must not be empty', 'tooling.$k');
      return v;
    }

    List<String>? patterns;
    if (t['isolation_patterns'] != null) {
      patterns = strings(t['isolation_patterns'], 'tooling.isolation_patterns');
      for (var i = 0; i < patterns.length; i++) {
        try {
          RegExp(patterns[i]);
        } on FormatException catch (e) {
          fail('invalid regex: ${e.message}', 'tooling.isolation_patterns[$i]');
        }
      }
    }
    final policy = t['bundle_policy'];
    if (policy != null && (policy is! String || policy.isEmpty)) {
      fail('must be a non-empty string', 'tooling.bundle_policy');
    }
    tooling = Tooling(
      flutterCommand: command('flutter_command', const ['flutter'])!,
      dartCommand: command('dart_command', const ['dart'])!,
      isolationPatterns: patterns,
      bundlePolicy: policy as String?,
    );
  }

  final conventions = <Convention>[];
  final cs = doc['conventions'];
  if (cs != null) {
    if (cs is! List) fail('must be a list', 'conventions');
    for (var i = 0; i < cs.length; i++) {
      final c = cs[i];
      final key = 'conventions[$i]';
      if (c is! Map) fail('must be a mapping', key);
      final s = c['sources'], t = c['tests'];
      if (s is! String || t is! String) {
        fail('needs string `sources` and `tests`', key);
      }
      for (final g in [s, t]) {
        if ('{area}'.allMatches(g).length != 1) {
          fail('glob "$g" must contain exactly one {area}', key);
        }
      }
      conventions.add(Convention(s, t));
    }
  }

  final areas = <String, AreaConfig>{};
  final as = doc['areas'];
  if (as != null) {
    if (as is! Map) fail('must be a mapping', 'areas');
    as.forEach((k, v) {
      final key = 'areas.$k';
      if (v == null) {
        areas['$k'] = AreaConfig('$k');
        return;
      }
      if (v is! Map) fail('must be a mapping', key);
      for (final f in v.keys) {
        if (!_areaKeys.contains(f)) fail('unknown key', '$key.$f');
      }
      areas['$k'] = AreaConfig('$k',
          sources: strings(v['sources'], '$key.sources'),
          tests: strings(v['tests'], '$key.tests'),
          extraTests: strings(v['extra_tests'], '$key.extra_tests'),
          dependsOn: strings(v['depends_on'], '$key.depends_on'));
    });
  }

  return PackageConfig(
    file: path,
    name: name,
    repo: repo,
    tooling: tooling,
    runAll: strings(doc['run_all'], 'run_all'),
    runPackage: strings(doc['run_package'], 'run_package'),
    conventions: conventions,
    areas: areas,
  );
}
