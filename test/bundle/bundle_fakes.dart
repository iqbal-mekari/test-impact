import 'package:test_impact/src/process.dart';

/// One recorded [ProcessRunner] call.
final class RecordedCall {
  RecordedCall(this.executable, this.arguments, this.workingDirectory,
      this.environment, this.console, this.logFile);

  final String executable;
  final List<String> arguments;
  final String workingDirectory;
  final Map<String, String>? environment;
  final ConsoleMode console;
  final String? logFile;
}

/// Scriptable [ProcessRunner] used by tests in place of dart:io.
final class FakeProcessRunner implements ProcessRunner {
  FakeProcessRunner(this.handler);

  final Future<RunResult> Function(RecordedCall call) handler;
  final List<RecordedCall> calls = [];

  @override
  Future<RunResult> run(
    String executable,
    List<String> arguments, {
    required String workingDirectory,
    Map<String, String>? environment,
    ConsoleMode console = ConsoleMode.capture,
    String? logFile,
    String? stdin,
    String Function(String line)? redact,
  }) {
    final call = RecordedCall(
        executable, arguments, workingDirectory, environment, console, logFile);
    calls.add(call);
    return handler(call);
  }
}
