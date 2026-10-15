import 'dart:convert';
import 'dart:io';

import 'package:test_impact/src/process.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'bundle_fakes.dart';

const plainTest = "import 'package:flutter_test/flutter_test.dart';\n"
    "void main() {\n  test('works', () {});\n}\n";
const softTest = 'void main() {\n  setUpAll(() {});\n}\n';

final class TestPackage {
  TestPackage._(this.repoRoot);
  final String repoRoot;
  String get dir => p.join(repoRoot, 'pkg');
  static TestPackage create() {
    final temp = Directory.systemTemp.createTempSync('bundle_test_');
    final package = TestPackage._(temp.resolveSymbolicLinksSync());
    addTearDown(() => temp.deleteSync(recursive: true));
    package.write('pubspec.yaml', 'name: pkg\n');
    for (final name in ['a', 'b', 'c']) {
      package.write('test/${name}_test.dart');
    }
    return package;
  }

  void write(String path, [String text = plainTest]) {
    final file = File(p.join(dir, path));
    file.parent.createSync(recursive: true);
    file.writeAsStringSync(text);
  }

  String policy([Map<String, Object?> packages = const {}]) {
    final file = File(p.join(repoRoot, 'policy.json'));
    file.writeAsStringSync(jsonEncode({'version': 1, 'packages': packages}));
    return file.path;
  }

  List<String> get leftovers => Directory(p.join(dir, 'test'))
      .listSync(recursive: true)
      .map((e) => p.basename(e.path))
      .where((n) => n.startsWith('flutter_test_bundle'))
      .toList();
}

/// Scripted `flutter test`: a bundle runs one `<file> works` test per group,
/// any other target one `works` test; [failFiles] fail in every mode.
final class FakeFlutter {
  FakeFlutter({
    this.failFiles = const {},
    this.failBundle = false,
    this.exitCode,
    this.writeCoverage = true,
    this.partialCoverage = false,
    this.onRun,
  }) {
    processes = FakeProcessRunner(_handle);
  }

  final Set<String> failFiles;
  final bool failBundle;
  final int? exitCode;
  final bool writeCoverage;
  final bool partialCoverage;

  /// Extra side effect per call (e.g. writing a custom lcov file).
  final void Function(RecordedCall call)? onRun;
  late final FakeProcessRunner processes;
  List<List<String>> get invocations =>
      processes.calls.map((c) => c.arguments).toList();
  List<List<String>> get targets => invocations.map(_targets).toList();

  static List<String> _targets(List<String> args) {
    final found = <String>[];
    for (var i = args.indexOf('test') + 1; i < args.length; i++) {
      if (args[i] == '--coverage-path' || args[i] == '--file-reporter') {
        i++;
      } else if (!args[i].startsWith('--')) {
        found.add(args[i]);
      }
    }
    return found;
  }

  Future<RunResult> _handle(RecordedCall call) async {
    onRun?.call(call);
    final args = call.arguments;
    String after(String flag) =>
        args.contains(flag) ? args[args.indexOf(flag) + 1] : '';
    final events = <Map<String, Object?>>[];
    final stems = <String>[];
    final targets = _targets(args);
    var code = 0;
    for (var suite = 0; suite < targets.length; suite++) {
      final file = File(p.join(call.workingDirectory, targets[suite]));
      final path =
          file.existsSync() ? file.resolveSymbolicLinksSync() : file.path;
      events.add({
        'type': 'suite',
        'suite': {'id': suite, 'path': path},
      });
      final bundled = path.endsWith('.g.dart');
      final names = bundled
          ? RegExp(r"group\('([^']+)'")
              .allMatches(file.readAsStringSync())
              .map((m) => m.group(1)!)
          : [targets[suite]];
      for (final name in names) {
        final failed = failFiles.contains(name) || (bundled && failBundle);
        final id = events.length;
        final test = {'id': id, 'suiteID': suite};
        if (failed) code = 1;
        stems.add(p.basenameWithoutExtension(name));
        events.addAll([
          {
            'type': 'testStart',
            'test': {...test, 'name': bundled ? '$name works' : 'works'},
          },
          {
            'type': 'testDone',
            'testID': id,
            'result': failed ? 'failure' : 'success',
          },
        ]);
      }
    }
    events.add({'type': 'done', 'success': code == 0});
    final report = after('--file-reporter').replaceFirst('json:', '');
    if (report.isNotEmpty) {
      File(report)
        ..parent.createSync(recursive: true)
        ..writeAsStringSync(events.map(jsonEncode).join('\n'));
    }
    final requested = after('--coverage-path');
    final wanted = partialCoverage || writeCoverage;
    if (wanted && !(requested.isNotEmpty && File(requested).existsSync())) {
      File(partialCoverage || requested.isEmpty
          ? p.join(call.workingDirectory, 'coverage', 'lcov.info')
          : requested)
        ..parent.createSync(recursive: true)
        ..writeAsStringSync((partialCoverage ? ['partial'] : stems)
            .map((s) => 'SF:lib/$s.dart\nDA:1,1\nend_of_record\n')
            .join());
    }
    return RunResult(exitCode ?? code, stdout: 'fake flutter done');
  }
}
