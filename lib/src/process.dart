import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// Finished child process; [stdout] and [stderr] are empty unless captured.
final class RunResult {
  /// Creates a result.
  const RunResult(this.exitCode, {this.stdout = '', this.stderr = ''});

  final int exitCode;
  final String stdout;
  final String stderr;
}

/// How a child's output is handled: collected into the [RunResult],
/// forwarded line by line, or written to the `logFile` argument.
enum ConsoleMode { capture, inherit, toFile }

/// Process seam over `dart:io`, so every slice can test with fakes.
abstract interface class ProcessRunner {
  /// Runs [executable]. [environment] is merged over the inherited one and
  /// never logged; [redact] rewrites each [ConsoleMode.inherit] line;
  /// [logFile] is required for [ConsoleMode.toFile]. A missing executable
  /// throws a [ProcessException].
  Future<RunResult> run(
    String executable,
    List<String> arguments, {
    required String workingDirectory,
    Map<String, String>? environment,
    ConsoleMode console = ConsoleMode.capture,
    String? logFile,
    String? stdin,
    String Function(String line)? redact,
  });
}

/// `dart:io` [ProcessRunner]. The sinks receive [ConsoleMode.inherit] lines
/// (newline included) and default to this process's streams.
final class IoProcessRunner implements ProcessRunner {
  /// Creates a runner.
  IoProcessRunner({
    void Function(String text)? stdoutSink,
    void Function(String text)? stderrSink,
  })  : _stdout = stdoutSink ?? stdout.write,
        _stderr = stderrSink ?? stderr.write;

  final void Function(String text) _stdout;
  final void Function(String text) _stderr;
  static final _decoder = Utf8Decoder(allowMalformed: true);

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
  }) async {
    if (console == ConsoleMode.toFile && logFile == null) {
      throw ArgumentError.value(logFile, 'logFile', 'required for toFile');
    }
    final process = await Process.start(executable, arguments,
        workingDirectory: workingDirectory, environment: environment);
    // A child that exits early closes its stdin; that is not an error.
    final input = () async {
      try {
        if (stdin != null) process.stdin.write(stdin);
        await process.stdin.close();
      } on IOException {
        // Ignored.
      }
    }();
    if (console == ConsoleMode.capture) {
      final out = process.stdout.transform(_decoder).join();
      final err = process.stderr.transform(_decoder).join();
      final code = await process.exitCode;
      final result = RunResult(code, stdout: await out, stderr: await err);
      await input;
      return result;
    }
    IOSink? log;
    if (logFile != null && console == ConsoleMode.toFile) {
      File(logFile).parent.createSync(recursive: true);
      log = File(logFile).openWrite();
    }
    // Line granularity keeps the two streams from splitting each other.
    Future<void> pump(Stream<List<int>> source, void Function(String) sink) =>
        source.transform(_decoder).transform(const LineSplitter()).forEach(
            (line) => log != null
                ? log.writeln(line)
                : sink('${redact == null ? line : redact(line)}\n'));
    final done = Future.wait(
        [pump(process.stdout, _stdout), pump(process.stderr, _stderr)]);
    final code = await process.exitCode;
    await done;
    await log?.close();
    await input;
    return RunResult(code);
  }
}
