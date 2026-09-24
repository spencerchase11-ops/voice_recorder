// Keeps the three places that list the native sources in sync: the vendored
// files in src/, the CMake build (Android, host) and the iOS forwarders.
// Needs no native library.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

Set<String> _cFiles(String directory) =>
    Directory(directory)
        .listSync()
        .whereType<File>()
        .map((File file) => file.uri.pathSegments.last)
        .where((String name) => name.endsWith('.c'))
        .toSet();

void main() {
  final Set<String> lameSources = _cFiles('src/lame/libmp3lame');

  test('LAME sources are vendored', () {
    expect(lameSources, contains('lame.c'));
    expect(lameSources, hasLength(19));
  });

  test('CMakeLists.txt builds every vendored C file', () {
    final String cmake = File('src/CMakeLists.txt').readAsStringSync();
    for (final String source in lameSources) {
      expect(cmake, contains('"\${LAME_DIR}/libmp3lame/$source"'));
    }
    expect(cmake, contains('"lame_mp3.c"'));
  });

  test('iOS has exactly one forwarder per C file', () {
    expect(_cFiles('ios/Classes/libmp3lame'), lameSources);
    for (final String source in lameSources) {
      expect(
        File('ios/Classes/libmp3lame/$source').readAsStringSync(),
        contains('#include "../../../src/lame/libmp3lame/$source"'),
      );
    }
    expect(_cFiles('ios/Classes'), <String>{'lame_mp3.c'});
    expect(
      File('ios/Classes/lame_mp3.c').readAsStringSync(),
      contains('#include "../../src/lame_mp3.c"'),
    );
  });
}
