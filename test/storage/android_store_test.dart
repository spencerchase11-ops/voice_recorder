import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:voice_recorder/src/core/settings.dart';
import 'package:voice_recorder/src/platform/native_bridge.dart';
import 'package:voice_recorder/src/storage/recording_store.dart';

const _tree =
    'content://com.android.externalstorage.documents/tree/primary%3ARecorders';

void main() {
  late Map<String, Object?> space;
  late bool access;
  late bool listFails;

  setUp(() {
    space = {'destination': 1000000, 'internal': 1000000, 'sameVolume': true};
    access = true;
    listFails = false;
    const channel = MethodChannel('com.spencerchase.voicerecorder/native');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(channel, (call) async {
      switch (call.method) {
        case 'storageSpace':
          return space;
        case 'hasFolderAccess':
          return access;
        case 'folderPath':
          return '/storage/emulated/0/Recorders';
        case 'listFolder':
          if (listFails) throw PlatformException(code: 'native_error');
          return [
            {
              'id': '$_tree/document/a',
              'name': 'a.mp3',
              'size': 10,
              'modified': 0,
            },
            {
              'id': '$_tree/document/b',
              'name': '.trashed-1-b.mp3',
              'size': 1,
              'modified': 0,
            },
            {
              'id': '$_tree/document/c',
              'name': 'notes.txt',
              'size': 1,
              'modified': 0,
            },
          ];
      }
      return null;
    });
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
  });

  Future<AndroidRecordingStore> open() async {
    SharedPreferences.setMockInitialValues({'folder': _tree});
    final store = AndroidRecordingStore(NativeBridge(), await Settings.load());
    await store.init();
    return store;
  }

  test(
    'on internal storage a recording needs room twice (it is copied)',
    () async {
      final store = await open();
      expect(await store.usableBytes(), 500000);
      // 200 kB already recorded: it grows by x and is copied, 2x <= 800 kB
      expect(await store.usableBytes(pendingBytes: 200000), 400000);
      space = {'destination': 100, 'internal': 100, 'sameVolume': true};
      expect(await store.usableBytes(pendingBytes: 1000), 0);
    },
  );

  test('on an SD card both volumes limit the recording', () async {
    final store = await open();
    space = {'destination': 5000000, 'internal': 800000, 'sameVolume': false};
    expect(await store.usableBytes(pendingBytes: 100000), 800000);
    space = {'destination': 500000, 'internal': 800000, 'sameVolume': false};
    expect(await store.usableBytes(pendingBytes: 100000), 400000);
  });

  test('lists recordings only (no hidden or other files)', () async {
    final store = await open();
    final files = await store.list();
    expect(files.map((f) => f.name), ['a.mp3']);
  });

  test('a folder that can no longer be read is asked for again', () async {
    final store = await open();
    expect(store.isReady, isTrue);
    listFails = true;
    access = false;
    await expectLater(store.list(), throwsA(isA<PlatformException>()));
    expect(store.isReady, isFalse);
  });
}
