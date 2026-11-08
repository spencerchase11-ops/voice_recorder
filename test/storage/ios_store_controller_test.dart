// The iPhone folder with the controller on top: a listing that is still
// being read when the list is changed must not bring back what it saw.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:voice_recorder/src/app_controller.dart';
import 'package:voice_recorder/src/core/settings.dart';
import 'package:voice_recorder/src/storage/recording_store.dart';

import '../support/fakes.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory docs;
  late Directory work;
  setUp(() async {
    docs = await Directory.systemTemp.createTemp('ios_docs');
    work = await Directory.systemTemp.createTemp('ios_work');
  });
  tearDown(() async {
    await docs.delete(recursive: true);
    await work.delete(recursive: true);
  });

  /// The app over a folder of 2,500 recordings (long enough to list that a
  /// change can land while it is read), listed once.
  Future<AppController> start() async {
    final dir = Directory('${docs.path}/Recorders')..createSync();
    String two(int n) => '$n'.padLeft(2, '0');
    for (var i = 0; i < 2500; i++) {
      final name =
          '2016_01_01_${two(i ~/ 3600)}_${two(i ~/ 60 % 60)}_${two(i % 60)}';
      File('${dir.path}/$name.mp3').writeAsBytesSync(const [1, 2, 3]);
    }
    SharedPreferences.setMockInitialValues({});
    final app = AppController(
      settings: await Settings.load(),
      store: IosRecordingStore(FakeNative(), documents: () async => docs),
      engine: FakeEngine(),
      playback: FakePlayback(),
      native: FakeNative(),
      workDir: () async => work,
    );
    addTearDown(app.dispose);
    await app.init();
    await app.refreshFiles();
    expect(app.files, hasLength(2500));
    return app;
  }

  // How long after a refresh starts the change is made: from at once to
  // after the listing is done.
  const delays = [0, 1, 2, 3, 5, 8, 12, 20, 40];

  test('a recording deleted while the list is read stays out', () async {
    final app = await start();
    for (final ms in delays) {
      final victim = app.files[ms];
      final refresh = app.refreshFiles();
      await Future<void>.delayed(Duration(milliseconds: ms));
      final deleted = await app.delete([victim]);
      await refresh;
      expect(deleted.items, hasLength(1));
      expect(File(victim.id).existsSync(), isFalse);
      expect(
        app.files.map((f) => f.id),
        isNot(contains(victim.id)),
        reason: 'deleted ${ms}ms into a refresh',
      );
      expect(app.files, hasLength(2500 - delays.indexOf(ms) - 1));
    }
  });

  test('recordings brought back while the list is read stay in', () async {
    final app = await start();
    for (final ms in delays) {
      final victims = app.files.sublist(ms, ms + 2);
      final deleted = await app.delete(victims);
      expect(app.files, hasLength(2498));
      final refresh = app.refreshFiles();
      await Future<void>.delayed(Duration(milliseconds: ms));
      expect(await app.undoDelete(deleted), 2);
      await refresh;
      expect(
        {for (final f in app.files) f.id},
        containsAll([for (final f in victims) f.id]),
        reason: 'brought back ${ms}ms into a refresh',
      );
      expect(app.files, hasLength(2500));
    }
  });

  test('a recording renamed while the list is read keeps its name', () async {
    final app = await start();
    for (final ms in delays) {
      final victim = app.files[ms];
      final refresh = app.refreshFiles();
      await Future<void>.delayed(Duration(milliseconds: ms));
      final renamed = await app.rename(victim, 'renamed $ms');
      await refresh;
      expect(renamed?.name, 'renamed $ms.mp3');
      final names = {for (final f in app.files) f.name};
      expect(names, contains('renamed $ms.mp3'), reason: '${ms}ms in');
      expect(names, isNot(contains(victim.name)), reason: '${ms}ms in');
      expect(app.files, hasLength(2500));
    }
  });
}
