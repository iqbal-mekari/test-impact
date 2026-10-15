import 'dart:io';

/// Raised when the changed-file list cannot be produced.
class DiffException implements Exception {
  /// Creates the exception.
  DiffException(this.message);

  /// What went wrong.
  final String message;

  @override
  String toString() => message;
}

/// Changed repo-relative paths, renames contributing both old and new.
///
/// With [changedFilesPath], reads one path per line (a leading
/// `<status>\t` column, as in `git diff --name-status`, is tolerated);
/// otherwise runs `git diff --name-status -M <base>...<head>` in [root].
List<String> collectChanges(String root,
    {String? base, String? head, String? changedFilesPath}) {
  final String text;
  if (changedFilesPath != null) {
    try {
      text = File(changedFilesPath).readAsStringSync();
    } on FileSystemException catch (e) {
      throw DiffException('cannot read changed files: ${e.message}');
    }
  } else {
    final r = Process.runSync(
        'git',
        [
          '-c',
          'core.quotepath=off',
          'diff',
          '--name-status',
          '-M',
          '$base...$head',
        ],
        workingDirectory: root);
    if (r.exitCode != 0) {
      throw DiffException('git diff $base...$head failed: ${r.stderr}'.trim());
    }
    text = r.stdout as String;
  }
  final out = <String>{};
  for (final raw in text.split('\n')) {
    final line = raw.trim();
    if (line.isEmpty) continue;
    final cols = line.split('\t');
    out.addAll(cols.length > 1 ? cols.skip(1) : cols);
  }
  return out.toList();
}
