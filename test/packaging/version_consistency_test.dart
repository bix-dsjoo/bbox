import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('release version is 1.0.3 across app and installer metadata', () {
    final pubspec = File('pubspec.yaml').readAsStringSync();
    final installer = File('installer/bbox_labeler.iss').readAsStringSync();
    final runnerRc = File('windows/runner/Runner.rc').readAsStringSync();

    expect(pubspec, contains('version: 1.0.3+4'));
    expect(installer, contains('#define MyAppVersion "1.0.3"'));
    expect(runnerRc, contains('#define VERSION_AS_NUMBER 1,0,3,4'));
    expect(runnerRc, contains('#define VERSION_AS_STRING "1.0.3+4"'));
  });
}
