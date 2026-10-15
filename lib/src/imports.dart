import 'dart:io';

import 'package:path/path.dart' as p;

final _directive =
    RegExp(r'''^\s*(import|export|part)\s+['"]([^'"]+)['"]''', multiLine: true);

/// Intra-package file edges (import/export/part) of [file].
///
/// [file] and results are package-relative posix paths; [pkgRoot] is the
/// absolute package dir and [name] its pubspec name. Only `package:<name>/`
/// and relative URIs are followed (conditional imports are not). Targets are
/// not checked for existence, so deleted files still resolve.
List<String> importsOf(String pkgRoot, String name, String file,
    {bool parts = true}) {
  final String src;
  try {
    src = File(p.join(pkgRoot, file)).readAsStringSync();
  } on FileSystemException {
    return const [];
  }
  final out = <String>[];
  for (final m in _directive.allMatches(src)) {
    if (!parts && m.group(1) == 'part') continue;
    final t = resolveUri(m.group(2)!, name, file);
    if (t != null) out.add(t);
  }
  return out;
}

/// Resolves [uri] seen in [from] to a package-relative path, or null.
String? resolveUri(String uri, String name, String from) {
  if (uri.startsWith('dart:')) return null;
  if (uri.startsWith('package:')) {
    final prefix = 'package:$name/';
    return uri.startsWith(prefix)
        ? p.posix.normalize('lib/${uri.substring(prefix.length)}')
        : null;
  }
  if (uri.contains(':')) return null;
  return p.posix.normalize(p.posix.join(p.posix.dirname(from), uri));
}
