import 'dart:io';

import 'package:test_impact/test_impact.dart';

Future<void> main(List<String> args) async {
  exitCode = await runCli(args);
}
