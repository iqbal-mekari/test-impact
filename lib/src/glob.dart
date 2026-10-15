/// Minimal glob support: `*` (one segment), `**` (any depth), `?`, and the
/// `{area}` placeholder that binds exactly one path segment.
///
/// Example: `bindArea('lib/f/{area}/**', 'lib/f/pay/a.dart') == 'pay'`.
RegExp compileGlob(String glob, {String? area}) {
  final b = StringBuffer('^');
  var i = 0;
  while (i < glob.length) {
    if (glob.startsWith('{area}', i)) {
      b.write(area == null ? '([^/]+)' : RegExp.escape(area));
      i += 6;
    } else if (glob.startsWith('**/', i)) {
      b.write('(?:.*/)?');
      i += 3;
    } else if (glob.startsWith('**', i)) {
      b.write('.*');
      i += 2;
    } else {
      final c = glob[i];
      b.write(c == '*'
          ? '[^/]*'
          : c == '?'
              ? '[^/]'
              : RegExp.escape(c));
      i++;
    }
  }
  return RegExp('$b\$');
}

/// Whether [path] (posix, relative) matches [glob].
bool globMatches(String glob, String path) => compileGlob(glob).hasMatch(path);

/// Whether [path] matches any glob in [globs].
bool matchesAny(Iterable<String> globs, String path) =>
    globs.any((g) => globMatches(g, path));

/// Returns the area bound by `{area}` in [glob] for [path], or null.
String? bindArea(String glob, String path) =>
    compileGlob(glob).firstMatch(path)?.group(1);
