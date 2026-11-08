import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:voice_recorder/src/core/recording_file.dart';
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

  group('a folder picked while the app was not running', () {
    // Android can end the app's process while the folder picker covers it,
    // and starts it again to deliver the choice; the platform side keeps
    // the folder until the store asks.
    const picked =
        'content://com.android.externalstorage.documents/tree/primary%3ANotes';
    late String? waiting;

    setUp(() {
      waiting = picked;
      const channel = MethodChannel('com.spencerchase.voicerecorder/native');
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            switch (call.method) {
              case 'takePickedFolder':
                final p = waiting;
                waiting = null;
                return p;
              case 'hasFolderAccess':
                return true;
              case 'folderPath':
                return (call.arguments as Map)['treeUri'] == picked
                    ? '/storage/emulated/0/Notes'
                    : '/storage/emulated/0/Recorders';
            }
            return null;
          });
    });

    test('becomes the folder on the first run', () async {
      SharedPreferences.setMockInitialValues({});
      final settings = await Settings.load();
      final store = AndroidRecordingStore(NativeBridge(), settings);
      await store.init();
      expect(settings.folder, picked);
      expect(store.folderChosen, isTrue);
      expect(store.isReady, isTrue);
      expect(store.folderDisplayPath, '/storage/emulated/0/Notes');
    });

    test('replaces the folder chosen before', () async {
      final store = await open();
      expect(store.folderDisplayPath, '/storage/emulated/0/Notes');
      // Only once: a later check keeps it.
      await store.init();
      expect(store.folderDisplayPath, '/storage/emulated/0/Notes');
    });
  });

  group('renaming only the letter case', () {
    // A folder on internal storage or an SD card ignores case, and the
    // provider gives a name in use a " (1)" suffix, counting the file being
    // renamed (ExternalStorageProvider's buildUniqueFile).
    late Map<String, String> folder; // document id -> name
    late Set<String> refused;
    late List<String> asked;

    String idFor(String name) => '$_tree/document/${Uri.encodeComponent(name)}';

    Map<String, Object?> row(String id) => {
      'id': id,
      'name': folder[id],
      'size': 10,
      'modified': 0,
    };

    setUp(() {
      folder = {idFor('meeting.mp3'): 'meeting.mp3'};
      refused = {};
      asked = [];
      const channel = MethodChannel('com.spencerchase.voicerecorder/native');
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            final args = (call.arguments as Map?) ?? const {};
            switch (call.method) {
              case 'hasFolderAccess':
                return true;
              case 'folderPath':
                return '/storage/emulated/0/Recorders';
              case 'renameDocument':
                final id = args['documentUri'] as String;
                final wanted = args['displayName'] as String;
                asked.add(wanted);
                if (refused.contains(wanted) || !folder.containsKey(id)) {
                  throw PlatformException(code: 'native_error');
                }
                bool taken(String n) => folder.values.any(
                  (v) => v.toLowerCase() == n.toLowerCase(),
                );
                final dot = wanted.lastIndexOf('.');
                final base = wanted.substring(0, dot);
                final ext = wanted.substring(dot);
                var name = wanted;
                for (var n = 1; taken(name); n++) {
                  name = '$base ($n)$ext';
                }
                folder.remove(id);
                folder[idFor(name)] = name;
                return row(idFor(name));
            }
            return null;
          });
    });

    RecordingFile meeting() => RecordingFile(
      id: idFor('meeting.mp3'),
      name: 'meeting.mp3',
      size: 10,
      modified: DateTime(2026),
    );

    test('gives exactly the new name, without a " (1)"', () async {
      final store = await open();
      final renamed = await store.rename(meeting(), 'Meeting');
      expect(renamed?.name, 'Meeting.mp3');
      expect(folder.values, ['Meeting.mp3']);
    });

    test('a refused new name puts the old one back', () async {
      final store = await open();
      refused = {'Meeting.mp3'};
      try {
        expect(await store.rename(meeting(), 'Meeting'), isNull);
      } on PlatformException {
        // Refusing may also be reported as an error.
      }
      expect(folder.values, ['meeting.mp3']);
    });

    test('a recording that can get no name back stays in the list', () async {
      final store = await open();
      refused = {'Meeting.mp3', 'meeting.mp3'};
      try {
        await store.rename(meeting(), 'Meeting');
      } on PlatformException {
        // Reported as an error.
      }
      expect(folder, hasLength(1));
      expect(isAudioFileName(folder.values.single), isTrue);
    });

    test('another name is a single rename', () async {
      final store = await open();
      final renamed = await store.rename(meeting(), 'Interview');
      expect(renamed?.name, 'Interview.mp3');
      expect(asked, ['Interview.mp3']);
    });
  });
}
