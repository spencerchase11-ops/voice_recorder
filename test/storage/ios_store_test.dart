import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:voice_recorder/src/core/recording_file.dart';
import 'package:voice_recorder/src/platform/native_bridge.dart';
import 'package:voice_recorder/src/storage/recording_store.dart';

/// An import from Files that goes on until [answer] completes.
class _RunningImport extends NativeBridge {
  final answer = Completer<ImportResult?>();

  @override
  Future<ImportResult?> importRecordings(
    String destination, {
    required bool folder,
  }) => answer.future;
}

void main() {
  late Directory root;
  setUp(() async => root = await Directory.systemTemp.createTemp('ios_store'));
  tearDown(() => root.delete(recursive: true));

  Future<IosRecordingStore> open(
    String container, {
    NativeBridge? native,
  }) async {
    final docs = Directory('${root.path}/$container/Documents');
    await docs.create(recursive: true);
    final store = IosRecordingStore(
      native ?? NativeBridge(),
      documents: () async => docs,
    );
    await store.init();
    return store;
  }

  Future<File> pending(String name, [int bytes = 100]) async {
    final f = File('${root.path}/$name');
    await f.writeAsBytes(List.filled(bytes, 1));
    return f;
  }

  test('saves into Documents/Recorders without overwriting', () async {
    final store = await open('A');
    final a = await store.save(
      await pending('x.mp3'),
      'take.mp3',
      'audio/mpeg',
    );
    final b = await store.save(
      await pending('y.mp3', 50),
      'take.mp3',
      'audio/mpeg',
    );
    expect(a.name, 'take.mp3');
    expect(b.name, 'take (1).mp3');
    expect(b.size, 50);
    expect(a.id, '${root.path}/A/Documents/Recorders/take.mp3');
    expect(
      store.displayPath(a),
      'On My iPhone/Voice Recorder/Recorders/take.mp3',
    );
    expect(store.playbackUri(a), Uri.file(a.id));
  });

  test('Recently deleted: out of the list, back under a free name', () async {
    final store = await open('A');
    final take = await store.save(
      await pending('x.mp3'),
      'take.mp3',
      'audio/mpeg',
    );
    final t = (await store.trash(take, DateTime(2026, 9, 25)))!;
    expect(await store.list(), isEmpty);
    expect((await store.listTrash()).single.originalName, 'take.mp3');
    // A new "take.mp3" meanwhile: the old one comes back beside it.
    await store.save(await pending('y.mp3'), 'take.mp3', 'audio/mpeg');
    final back = (await store.restore(t))!;
    expect(back.name, 'take (1).mp3');
    expect(await store.listTrash(), isEmpty);
  });

  test("Recently deleted: the early test builds' names too", () async {
    final store = await open('A');
    final dir = Directory('${root.path}/A/Documents/Recorders');
    final ms = DateTime(2026, 9, 20).millisecondsSinceEpoch;
    await File('${dir.path}/.trashed-$ms-old.mp3').writeAsBytes([1]);
    await File('${dir.path}/.hidden-notes.mp3').writeAsBytes([1]);
    final trash = await store.listTrash();
    expect(trash.single.originalName, 'old.mp3');
    expect(trash.single, isA<TrashedRecording>());
  });

  test('lists audio files only', () async {
    final store = await open('A');
    await store.save(await pending('x.mp3'), 'one.mp3', 'audio/mpeg');
    await store.save(await pending('y.wav'), 'two.wav', 'audio/x-wav');
    final dir = Directory('${root.path}/A/Documents/Recorders');
    await File('${dir.path}/notes.txt').writeAsString('hi');
    await Directory('${dir.path}/sub.mp3').create();
    final names = (await store.list()).map((f) => f.name).toList()..sort();
    expect(names, ['one.mp3', 'two.wav']);
  });

  test('rename keeps the extension and never overwrites', () async {
    final store = await open('A');
    final a = await store.save(await pending('x.mp3'), 'a.mp3', 'audio/mpeg');
    await store.save(await pending('y.mp3'), 'b.mp3', 'audio/mpeg');
    final r = await store.rename(a, 'b');
    expect(r?.name, 'b (1).mp3');
    expect(File(a.id).existsSync(), isFalse);
    expect(await store.rename(r!, 'b (1)'), same(r));
  });

  test('lists a folder of 2,500 recordings quickly', () async {
    final store = await open('A');
    final dir = Directory('${root.path}/A/Documents/Recorders');
    for (var i = 0; i < 2500; i++) {
      File('${dir.path}/2016_01_01_00_00_${'$i'.padLeft(4, '0')}.mp3')
          .writeAsBytesSync(const [1, 2, 3]);
    }
    final watch = Stopwatch()..start();
    final files = await store.list();
    watch.stop();
    expect(files, hasLength(2500));
    expect(watch.elapsed, lessThan(const Duration(seconds: 3)));
  });

  test('lists 2,500 recordings without stalling the UI isolate', () async {
    final store = await open('A');
    final dir = Directory('${root.path}/A/Documents/Recorders');
    for (var i = 0; i < 2500; i++) {
      File('${dir.path}/2016_01_01_00_00_${'$i'.padLeft(4, '0')}.mp3')
          .writeAsBytesSync(const [1, 2, 3]);
    }
    // The longest this isolate went without running a 1 ms timer, as a
    // share of the whole listing: about all of it when the listing runs
    // here. The best of three, so a busy machine doesn't decide it.
    var best = double.infinity;
    for (var run = 0; run < 3; run++) {
      final sinceTick = Stopwatch()..start();
      var longest = 0;
      final ticks = Timer.periodic(const Duration(milliseconds: 1), (_) {
        longest = math.max(longest, sinceTick.elapsedMicroseconds);
        sinceTick.reset();
      });
      final watch = Stopwatch()..start();
      final files = await store.list();
      final took = watch.elapsedMicroseconds;
      await Future<void>.delayed(const Duration(milliseconds: 5));
      ticks.cancel();
      // In the folder's own order, as before.
      expect(files.map((f) => f.id), [for (final f in dir.listSync()) f.path]);
      best = math.min(best, longest / took);
    }
    expect(best, lessThan(0.5));
  });

  group('copies an import cut short', () {
    // A name AppDelegate.swift gives a file it copies in.
    const partial = '.importing-0F8E2A4C-5B1D-4E7A-9C3B-2D6F8A1E4B7C';

    Future<File> file(
      Directory dir,
      String name, {
      Duration age = const Duration(days: 1),
    }) async {
      final f = File('${dir.path}/$name');
      await f.writeAsBytes(const [1, 2, 3]);
      await f.setLastModified(DateTime.now().subtract(age));
      return f;
    }

    test('are removed at start-up, and nothing else', () async {
      final dir = Directory('${root.path}/A/Documents/Recorders');
      await dir.create(recursive: true);
      final leftovers = [
        await file(dir, '$partial.wav'),
        await file(dir, partial.replaceFirst('0F8E', '1F8E')),
      ];
      final kept = [
        await file(dir, 'take.mp3'),
        await file(dir, '.importing-take.mp3'),
        await file(dir, 'importing-${partial.substring(11)}.mp3'),
        await file(
          dir,
          TrashedRecording.hiddenName(
            '$partial.mp3'.substring(1),
            DateTime(2026, 9, 25),
          ),
        ),
        // Written to just now: it may be a copy going on.
        await file(dir, '$partial.mp3', age: Duration.zero),
      ];
      await open('A');
      for (final f in leftovers) {
        expect(f.existsSync(), isFalse, reason: f.path);
      }
      for (final f in kept) {
        expect(f.existsSync(), isTrue, reason: f.path);
      }
    });

    test('are left alone while an import runs', () async {
      final native = _RunningImport();
      final store = await open('A', native: native);
      final running = store.importRecordings();
      // The import's own copy (a clone has the old file's date).
      final copying = await file(
        Directory('${root.path}/A/Documents/Recorders'),
        '$partial.wav',
      );
      await store.init(); // as after a recording that couldn't be saved
      expect(copying.existsSync(), isTrue);
      native.answer.complete(null);
      expect(await running, isNull);
    });
  });

  test('delete', () async {
    final store = await open('A');
    final a = await store.save(await pending('x.mp3'), 'a.mp3', 'audio/mpeg');
    expect(await store.delete(a), isTrue);
    expect(await store.list(), isEmpty);
    expect(await store.delete(a), isFalse);
  });

  test('finds a recording after an app update moved the container', () async {
    final before = await open('A');
    final a = await before.save(await pending('x.mp3'), 'a.mp3', 'audio/mpeg');
    await Directory('${root.path}/A').rename('${root.path}/B');
    final after = await open('B');
    final found = await after.find(a.id);
    expect(found?.id, '${root.path}/B/Documents/Recorders/a.mp3');
    expect(
      await after.find('${root.path}/A/Documents/Recorders/gone.mp3'),
      isNull,
    );
  });
}
