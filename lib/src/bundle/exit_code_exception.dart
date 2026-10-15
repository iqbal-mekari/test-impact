/// A failure that maps to a process exit code (2 unless stated). Its text
/// never contains environment values.
class ExitCodeException implements Exception {
  /// Creates the exception.
  ExitCodeException(this._message, [this.exitCode = 2]);

  final String _message;

  /// The process exit code this failure maps to.
  final int exitCode;

  @override
  String toString() => _message;
}
