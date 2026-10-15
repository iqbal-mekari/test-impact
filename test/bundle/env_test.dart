import 'package:test_impact/src/bundle/env.dart';
import 'package:test/test.dart';

void main() {
  test('should bundle only when unset or 1', () {
    final cases = {null: true, '': true, '1': true, '0': false, 'true': false};
    cases.forEach((raw, on) => expect(
        BundleEnv({if (raw != null) 'FLUTTER_TEST_BUNDLE': raw}).bundleEnabled,
        on));
  });
}
