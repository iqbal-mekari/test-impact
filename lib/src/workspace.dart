import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:yaml/yaml.dart';

import 'config.dart';

/// Name of the mapping file that marks a package as managed.
const mappingFileName = 'test_impact.yaml';

const _skipDirs = {'build', 'node_modules', 'Pods'};

/// One managed package (a dir with `test_impact.yaml` and `pubspec.yaml`).
class ImpactPackage {
  /// Creates a package record.
  ImpactPackage(this.dir, this.name, this.config, this.files, this.pathDeps);

  /// Repo-relative dir (`.` for the root package).
  final String dir;

  /// Pubspec name.
  final String name;

  /// Parsed mapping.
  final PackageConfig config;

  /// Every file in the package (package-relative), nested packages excluded.
  final List<String> files;

  /// Repo-relative dirs of path dependencies.
  final List<String> pathDeps;

  /// Package-relative `*_test.dart` files under `test/`.
  late final List<String> testFiles = files
      .where((f) => f.startsWith('test/') && f.endsWith('_test.dart'))
      .toList()
    ..sort();
}

/// All managed packages of a repo plus any config problems found.
class Workspace {
  Workspace._(this.root, this.packages, this.errors);

  /// Absolute repo root.
  final String root;

  /// Managed packages with a valid config.
  final List<ImpactPackage> packages;

  /// Config problems; non-empty means selection must fail safe to ALL.
  final List<ConfigException> errors;

  /// Dirs of every discovered package, valid or not (for fail-safe ALL).
  late final Set<String> allDirs = {
    ...packages.map((e) => e.dir),
    ..._brokenDirs,
  };
  final Set<String> _brokenDirs = {};

  /// Repo-wide rules from the root package config, if any.
  RepoRules get repoRules {
    for (final pkg in packages) {
      if (pkg.dir == '.' && pkg.config.repo != null) return pkg.config.repo!;
    }
    return const RepoRules();
  }

  /// Tool settings from the root mapping; generic defaults when absent.
  Tooling get tooling {
    for (final pkg in packages) {
      if (pkg.dir == '.' && pkg.config.tooling != null) {
        return pkg.config.tooling!;
      }
    }
    return Tooling();
  }

  /// Package by repo-relative [dir].
  ImpactPackage? byDir(String dir) {
    for (final pkg in packages) {
      if (pkg.dir == dir) return pkg;
    }
    return null;
  }

  /// Deepest package containing repo-relative [path], or null.
  ImpactPackage? ownerOf(String path) {
    ImpactPackage? best;
    for (final pkg in packages) {
      final inside = pkg.dir == '.' || path.startsWith('${pkg.dir}/');
      if (inside && (best == null || pkg.dir.length > best.dir.length)) {
        best = pkg;
      }
    }
    return best;
  }

  /// Dirs of packages that depend (transitively) on [dir].
  Set<String> dependentsOf(String dir) {
    final out = <String>{};
    final queue = [dir];
    while (queue.isNotEmpty) {
      final cur = queue.removeLast();
      for (final pkg in packages) {
        if (pkg.pathDeps.contains(cur) && out.add(pkg.dir)) {
          queue.add(pkg.dir);
        }
      }
    }
    return out;
  }

  /// Discovers packages under [root] and loads their mappings.
  static Workspace load(String root) {
    final all = <String>[];
    _walk(Directory(root), root, all);
    final dirs = all
        .where((f) => p.posix.basename(f) == mappingFileName)
        .map((f) => p.posix.dirname(f))
        .toList();
    String? ownerDir(String file) {
      String? best;
      for (final d in dirs) {
        if ((d == '.' || file.startsWith('$d/')) &&
            (best == null || d.length > best.length)) {
          best = d;
        }
      }
      return best;
    }

    final byPkg = {for (final d in dirs) d: <String>[]};
    for (final f in all) {
      final d = ownerDir(f);
      if (d != null) {
        byPkg[d]!.add(d == '.' ? f : f.substring(d.length + 1));
      }
    }

    final errors = <ConfigException>[];
    final broken = <String>{};
    final loaded = <(String, String, PackageConfig, List<String>)>[];
    for (final d in dirs) {
      final cfgPath = p.join(root, d, mappingFileName);
      try {
        final cfg = loadConfig(cfgPath);
        final pub = File(p.join(root, d, 'pubspec.yaml'));
        if (!pub.existsSync()) {
          throw ConfigException(cfgPath, 'no pubspec.yaml next to mapping');
        }
        final y = loadYaml(pub.readAsStringSync());
        final name = y is Map ? y['name'] : null;
        if (name != cfg.name) {
          throw ConfigException(
              cfgPath, 'pubspec name is "$name", mapping says "${cfg.name}"',
              key: 'package');
        }
        if (d != '.' && cfg.repo != null) {
          throw ConfigException(cfgPath, 'only allowed in the root mapping',
              key: 'repo');
        }
        if (d != '.' && cfg.tooling != null) {
          throw ConfigException(cfgPath, 'only allowed in the root mapping',
              key: 'tooling');
        }
        loaded.add((d, cfg.name, cfg, byPkg[d]!));
      } on ConfigException catch (e) {
        errors.add(e);
        broken.add(d);
      } on YamlException catch (e) {
        errors.add(ConfigException(cfgPath, 'bad pubspec: ${e.message}'));
        broken.add(d);
      }
    }

    final dirSet = dirs.toSet();
    final pkgs = <ImpactPackage>[];
    for (final (d, name, cfg, files) in loaded) {
      pkgs.add(ImpactPackage(d, name, cfg, files, _pathDeps(root, d, dirSet)));
    }
    return Workspace._(root, pkgs, errors).._brokenDirs.addAll(broken);
  }

  static List<String> _pathDeps(String root, String dir, Set<String> known) {
    final out = <String>[];
    try {
      final y =
          loadYaml(File(p.join(root, dir, 'pubspec.yaml')).readAsStringSync());
      if (y is! Map) return out;
      for (final sec in [
        'dependencies',
        'dev_dependencies',
        'dependency_overrides'
      ]) {
        final deps = y[sec];
        if (deps is! Map) continue;
        for (final v in deps.values) {
          if (v is Map && v['path'] is String) {
            final target =
                p.posix.normalize(p.posix.join(dir, v['path'] as String));
            if (known.contains(target)) out.add(target);
          }
        }
      }
    } on Object {
      // Unreadable pubspec: treated as having no path deps.
    }
    return out;
  }

  static void _walk(Directory d, String root, List<String> out) {
    for (final e in d.listSync(followLinks: false)) {
      final name = p.basename(e.path);
      if (e is Directory) {
        if (name.startsWith('.') || _skipDirs.contains(name)) continue;
        _walk(e, root, out);
      } else if (e is File && !name.startsWith('.')) {
        out.add(p.posix.joinAll(p.split(p.relative(e.path, from: root))));
      }
    }
  }
}
