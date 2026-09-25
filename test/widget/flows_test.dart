// Drives the screens the way a user would, on the reference phone.
import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/material.dart' show LicensePage;
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:voice_recorder/src/audio/recorder_engine.dart';
import 'package:voice_recorder/src/core/format.dart';
import 'package:voice_recorder/src/core/recording_file.dart';
import 'package:voice_recorder/src/core/recording_format.dart';
import 'package:voice_recorder/src/licenses.dart';
import 'package:voice_recorder/src/ui/dialogs/dialogs.dart';
import 'package:voice_recorder/src/ui/screens/recording_list_screen.dart';
import 'package:voice_recorder/src/ui/widgets/frame.dart';
import 'package:voice_recorder/src/ui/widgets/recorder_widgets.dart';

import '../support/fakes.dart';
import '../support/harness.dart';

/// Records the methods called on the app's native channel.
List<String> mockNativeChannel() {
  final calls = <String>[];
  const channel = MethodChannel('com.spencerchase.voicerecorder/native');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  messenger.setMockMethodCallHandler(channel, (call) async {
    calls.add(call.method);
    return null;
  });
  addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
  return calls;
}

const _kris = 'kris n evan got back then zach.mp3';
const _folder = '/storage/emulated/0/Recorders';

/// A button by its accessibility label.
Finder labeled(String label) => find.byWidgetPredicate(
  (w) =>
      (w is PressableArea && w.semanticLabel == label) ||
      (w is GlossyButton && w.semanticLabel == label),
);

bool enabled(WidgetTester tester, String label) {
  final w = tester.widget(labeled(label));
  return w is PressableArea
      ? w.onTap != null
      : (w as GlossyButton).onTap != null;
}

/// Lets real file I/O started by the app finish, pumping frames in between.
Future<void> pumpUntil(WidgetTester tester, bool Function() done) async {
  for (var i = 0; i < 100 && !done(); i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 20)),
    );
    await tester.pump();
  }
  expect(done(), isTrue, reason: 'condition not reached');
  await tester.pump();
}

void main() {
  group('Recorder', () {
    testWidgets('record, then stop saves the recording', (tester) async {
      useReferenceDevice(tester);
      final t = await pumpReferenceApp(tester);
      final app = t.controller;
      expect(find.text('33:57'), findsOneWidget);
      expect(find.text('Remaining time: 9665:13:10'), findsOneWidget);

      await tester.tap(labeled('Record'));
      await pumpUntil(tester, () => app.isRecording && !app.isBusy);
      expect(labeled('Stop recording'), findsOneWidget);
      expect(find.text('00:00'), findsOneWidget);
      final name = app.currentPath!.split('/').last;
      expect(name, matches(RegExp(r'^\d{4}_\d\d_\d\d_\d\d_\d\d_\d\d\.mp3$')));
      expect(find.text('$_folder/$name'), findsOneWidget);
      for (final l in ['Share', 'Rename', 'Delete', 'Play']) {
        expect(enabled(tester, l), isFalse, reason: l);
      }

      t.engine.levelController.add(1.0);
      await tester.pump();
      expect(app.litSegments, 10);

      await tester.tap(labeled('Stop recording'));
      await pumpUntil(tester, () => !app.isRecording && !app.isBusy);
      await tester.pumpAndSettle();
      expect(t.store.saved, [name]);
      expect(labeled('Record'), findsOneWidget);
      expect(find.text('$_folder/$name'), findsOneWidget);
      expect(enabled(tester, 'Play'), isTrue);
      expect(app.litSegments, 1);
    });

    testWidgets('the first recording asks for the folder', (tester) async {
      useReferenceDevice(tester);
      final t = await pumpReferenceApp(tester);
      final app = t.controller;
      t.store.ready = false;

      await tester.tap(labeled('Record'));
      await tester.pumpAndSettle();
      expect(
        find.textContaining('Choose the folder for your recordings.'),
        findsOneWidget,
      );
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(app.isRecording, isFalse);
      expect(t.store.folderChoices, 0);

      await tester.tap(labeled('Record'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('OK'));
      await pumpUntil(tester, () => app.isRecording && !app.isBusy);
      expect(t.store.folderChoices, 1);

      await tester.tap(labeled('Stop recording'));
      await pumpUntil(tester, () => !app.isRecording && !app.isBusy);
      await tester.pumpAndSettle();
      expect(t.store.saved, hasLength(1));
    });

    testWidgets(
      'without microphone access it explains why and offers Settings',
      (tester) async {
        final calls = mockNativeChannel();
        useReferenceDevice(tester);
        final t = await pumpReferenceApp(tester);
        t.engine.permission = false;

        await tester.tap(labeled('Record'));
        await tester.pumpAndSettle();
        expect(
          find.textContaining('needs access to the microphone'),
          findsOneWidget,
        );
        await tester.tap(find.text('Cancel'));
        await tester.pumpAndSettle();
        expect(calls, isEmpty);

        await tester.tap(labeled('Record'));
        await tester.pumpAndSettle();
        await tester.tap(find.widgetWithText(HoloButton, 'Settings'));
        await tester.pumpAndSettle();
        expect(calls, ['openAppSettings']);
        expect(t.controller.isRecording, isFalse);
      },
    );

    testWidgets('a recording that cannot be saved asks for the folder again', (
      tester,
    ) async {
      useReferenceDevice(tester);
      final t = await pumpReferenceApp(tester);
      final app = t.controller;
      await tester.tap(labeled('Record'));
      await pumpUntil(tester, () => app.isRecording && !app.isBusy);

      // Folder access is lost while recording (Android).
      t.store
        ..failSaves = true
        ..ready = false;
      await tester.tap(labeled('Stop recording'));
      await pumpUntil(tester, () => !app.isRecording && !app.isBusy);
      await tester.pumpAndSettle();
      expect(
        find.textContaining("The recording couldn't be saved to the folder."),
        findsOneWidget,
      );
      expect(Directory('${t.workDir.path}/pending').listSync(), hasLength(1));

      // Choosing the folder saves the kept recording.
      t.store.failSaves = false;
      await tester.tap(find.text('OK'));
      await pumpUntil(tester, () => t.store.saved.isNotEmpty);
      await tester.pumpAndSettle();
      expect(t.store.folderChoices, 1);
      expect(Directory('${t.workDir.path}/pending').listSync(), isEmpty);
    });

    testWidgets('a recording that stops on its own is saved and says so', (
      tester,
    ) async {
      useReferenceDevice(tester);
      final t = await pumpReferenceApp(tester);
      final app = t.controller;
      await tester.tap(labeled('Record'));
      await pumpUntil(tester, () => app.isRecording && !app.isBusy);

      t.engine.endedController.add(CaptureEnd.stopped);
      await pumpUntil(tester, () => !app.isRecording && !app.isBusy);
      await tester.pump();
      expect(
        find.textContaining('The recording stopped unexpectedly.'),
        findsOneWidget,
      );
      expect(t.store.saved, hasLength(1));
      expect(labeled('Record'), findsOneWidget);
      await tester.pump(const Duration(seconds: 4));
      await tester.pumpAndSettle();
    });

    testWidgets("a file that can't be opened says so", (tester) async {
      useReferenceDevice(tester);
      final t = await pumpReferenceApp(tester);
      t.playback.broken.add('mem://$_kris');
      await tester.tap(labeled('Play'));
      await tester.pump();
      expect(find.text("Can't play this file"), findsOneWidget);
      expect(t.playback.fileId, isNull);
      await tester.pump(const Duration(seconds: 2));

      // During a call the reason is different.
      t.playback.broken.clear();
      t.playback.audioBusy = true;
      await tester.tap(labeled('Play'));
      await tester.pump();
      expect(
        find.text("Can't play while a call or another app uses audio"),
        findsOneWidget,
      );
      await tester.pump(const Duration(seconds: 2));
      t.playback.audioBusy = false;

      // Once it opens again it plays.
      t.playback.broken.clear();
      await tester.tap(labeled('Play'));
      await tester.pump();
      expect(t.playback.playing, isTrue);
    });

    testWidgets('play and pause the last recording', (tester) async {
      useReferenceDevice(tester);
      final t = await pumpReferenceApp(tester);
      await tester.tap(labeled('Play'));
      await tester.pump();
      expect(t.playback.played, ['mem://$_kris']);
      expect(find.text('00:00'), findsOneWidget);
      t.playback.setPosition(const Duration(minutes: 2, seconds: 5));
      await tester.pump();
      expect(find.text('02:05'), findsOneWidget);
      await tester.tap(labeled('Pause'));
      await tester.pump();
      expect(t.playback.playing, isFalse);
      expect(labeled('Play'), findsOneWidget);
    });

    testWidgets('delete asks first', (tester) async {
      useReferenceDevice(tester);
      final t = await pumpReferenceApp(tester);

      await tester.tap(labeled('Delete'));
      await tester.pumpAndSettle();
      expect(find.text('Delete file'), findsOneWidget);
      expect(find.text('Are you sure to delete file? /$_kris'), findsOneWidget);
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(t.store.files, hasLength(10));

      await tester.tap(labeled('Delete'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('OK'));
      await tester.pumpAndSettle();
      expect(t.store.files.map((f) => f.name), isNot(contains(_kris)));
      expect(find.text('$_folder/$_kris'), findsNothing);
      expect(find.text('00:00'), findsOneWidget);
      expect(labeled('Delete'), findsNothing);
      expect(find.text('Voice Recorder'), findsOneWidget);
    });

    testWidgets('rename keeps the extension and drops illegal characters', (
      tester,
    ) async {
      useReferenceDevice(tester);
      final t = await pumpReferenceApp(tester);

      await tester.tap(labeled('Rename'));
      await tester.pumpAndSettle();
      expect(find.text('Enter new file name'), findsOneWidget);
      final field = find.byType(EditableText);
      expect(
        tester.widget<EditableText>(field).controller.text,
        'kris n evan got back then zach',
      );
      await tester.enterText(field, 'evan/zach: part 2');
      expect(
        tester.widget<EditableText>(field).controller.text,
        'evanzach part 2',
      );
      await tester.tap(find.text('OK'));
      await tester.pumpAndSettle();

      expect(find.text('$_folder/evanzach part 2.mp3'), findsOneWidget);
      expect(t.store.files.map((f) => f.name), contains('evanzach part 2.mp3'));
      expect(find.text('33:57'), findsOneWidget);
    });

    testWidgets('without a recording: app name, no file actions, grey play', (
      tester,
    ) async {
      useReferenceDevice(tester);
      await pumpReferenceApp(tester, current: null);
      expect(find.text('Voice Recorder'), findsOneWidget);
      for (final l in ['Share', 'Rename', 'Delete']) {
        expect(labeled(l), findsNothing, reason: l);
      }
      expect(enabled(tester, 'Play'), isFalse);
      expect(
        tester.widget<GlossyButton>(labeled('Play')).disabledAsset,
        'assets/images/play_disabled.png',
      );
      expect(find.text('00:00'), findsOneWidget);
      expect(find.textContaining(_folder), findsNothing);
    });

    testWidgets('the first recording fills in the empty screen', (
      tester,
    ) async {
      useReferenceDevice(tester);
      final t = await pumpReferenceApp(tester, current: null);
      final app = t.controller;

      await tester.tap(labeled('Record'));
      await pumpUntil(tester, () => app.isRecording && !app.isBusy);
      expect(find.text('Voice Recorder'), findsOneWidget);
      expect(find.textContaining(_folder), findsOneWidget);

      await tester.tap(labeled('Stop recording'));
      await pumpUntil(tester, () => !app.isRecording && !app.isBusy);
      await tester.pumpAndSettle();
      expect(find.text('Voice Recorder'), findsNothing);
      expect(find.text('Recorder'), findsNWidgets(2)); // header and tab
      for (final l in ['Share', 'Rename', 'Delete', 'Play']) {
        expect(enabled(tester, l), isTrue, reason: l);
      }
    });

    testWidgets('large system font sizes keep text inside the timer and tabs', (
      tester,
    ) async {
      useReferenceDevice(tester);
      tester.platformDispatcher.textScaleFactorTestValue = 2.0;
      await pumpReferenceApp(tester);
      final box = tester.getRect(find.byType(TimerBox));
      final digits = tester.getRect(find.text('33:57'));
      expect(box.contains(digits.topLeft), isTrue);
      expect(box.contains(digits.bottomRight), isTrue);
      // "Recording list" is shrunk to fit its third of the tab bar, not cut.
      final tab = tester.getRect(labeled('Recording list'));
      final label = tester.getRect(find.text('Recording list'));
      expect(label.width, lessThanOrEqualTo(tab.width));
      expect(label.left, greaterThanOrEqualTo(tab.left));
    });

    testWidgets('share, and no ads upsell', (tester) async {
      useReferenceDevice(tester);
      final t = await pumpReferenceApp(tester);
      await tester.tap(labeled('Share'));
      await tester.pump();
      expect(t.store.shared, [_kris]);
      expect(labeled('Remove ads'), findsNothing);
    });
  });

  group('Recording list', () {
    Future<TestApp> openList(WidgetTester tester) async {
      useReferenceDevice(tester);
      final t = await pumpReferenceApp(tester);
      await tester.tap(labeled('Recording list'));
      await tester.pumpAndSettle();
      return t;
    }

    testWidgets('lists every recording, newest first', (tester) async {
      await openList(tester);
      final names = [
        for (final e in find.byType(AText).evaluate()) (e.widget as AText).text,
      ].where(isAudioName).toList();
      expect(names.first, _kris);
      expect(names, hasLength(10));
      expect(find.text('39819KB'), findsOneWidget);
      expect(find.text('2026-09-23'), findsOneWidget);
    });

    testWidgets('actions need a selection', (tester) async {
      final t = await openList(tester);
      for (final l in ['Delete', 'Rename', 'Share']) {
        await tester.tap(labeled(l));
        await tester.pump();
        expect(find.text('Please select a file'), findsOneWidget, reason: l);
        await tester.pump(const Duration(seconds: 2));
        expect(find.text('Please select a file'), findsNothing);
      }
      expect(t.store.shared, isEmpty);
    });

    testWidgets('select, share, rename and delete', (tester) async {
      final t = await openList(tester);

      await tester.tap(find.text('2026_09_18_21_23_04.mp3'));
      await tester.pumpAndSettle();
      await tester.tap(labeled('Share'));
      await tester.pump();
      expect(t.store.shared, ['2026_09_18_21_23_04.mp3']);

      await tester.tap(labeled('Rename'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(EditableText), 'late night idea');
      await tester.tap(find.text('OK'));
      await tester.pumpAndSettle();
      expect(find.text('late night idea.mp3'), findsOneWidget);
      expect(find.text('2026_09_18_21_23_04.mp3'), findsNothing);

      // the renamed row stays selected
      await tester.tap(labeled('Delete'));
      await tester.pumpAndSettle();
      expect(
        find.text('Are you sure to delete file? /late night idea.mp3'),
        findsOneWidget,
      );
      await tester.tap(find.text('OK'));
      await tester.pumpAndSettle();
      expect(find.text('late night idea.mp3'), findsNothing);
      expect(t.store.files, hasLength(9));
    });

    testWidgets('play buttons play and pause rows', (tester) async {
      final t = await openList(tester);
      const name = '2026_09_20_17_26_27.mp3';
      await tester.tap(labeled('Play $name'));
      await tester.pumpAndSettle();
      expect(t.playback.played, ['mem://$name']);
      expect(labeled('Pause $name'), findsOneWidget);
      // the seek section opens under the playing row
      expect(find.text('00:00'), findsOneWidget);
      t.playback.setPosition(const Duration(seconds: 42));
      await tester.pump();
      expect(find.text('00:42'), findsOneWidget);

      await tester.tap(labeled('Pause $name'));
      await tester.pump();
      expect(t.playback.playing, isFalse);
    });

    testWidgets('asks for the folder when none is chosen yet (Android)', (
      tester,
    ) async {
      useReferenceDevice(tester);
      final t = await pumpReferenceApp(tester);
      t.store.ready = false;
      await tester.tap(labeled('Recording list'));
      await tester.pumpAndSettle();
      expect(
        find.textContaining('Choose the folder for your recordings.'),
        findsOneWidget,
      );
      await tester.tap(find.text('OK'));
      await pumpUntil(tester, () => t.store.folderChoices == 1);
      await tester.pumpAndSettle();
      expect(find.text(_kris), findsOneWidget);
    });

    testWidgets("can't play while recording", (tester) async {
      useReferenceDevice(tester);
      final t = await pumpReferenceApp(tester);
      final app = t.controller;
      await tester.tap(labeled('Record'));
      await pumpUntil(tester, () => app.isRecording && !app.isBusy);
      // pumpAndSettle can't be used while the microphone light pulses.
      await tester.tap(labeled('Recording list'));
      await tester.pump(const Duration(seconds: 1));
      await tester.pump(const Duration(seconds: 1));
      await tester.tap(labeled('Play 2026_09_20_17_26_27.mp3'));
      await tester.pump();
      expect(find.text('Stop recording to play a file'), findsOneWidget);
      expect(t.playback.played, isEmpty);
      await tester.pump(const Duration(seconds: 2));

      Navigator.of(tester.element(labeled('Back'))).pop();
      await tester.pump(const Duration(seconds: 1));
      await tester.pump(const Duration(seconds: 1));
      await tester.tap(labeled('Stop recording'));
      await pumpUntil(tester, () => !app.isRecording && !app.isBusy);
      await tester.pumpAndSettle();
    });

    testWidgets(
      'dragging the seek bar seeks once, on release, without playing',
      (tester) async {
        final t = await openList(tester);
        const name = '2026_09_20_17_26_27.mp3';
        await tester.tap(find.text(name));
        await tester.pumpAndSettle();
        final bar = find.byType(HoloSeekBar);
        final box = tester.getRect(bar);
        // Drag the thumb from the start to the middle of the track.
        final gesture = await tester.startGesture(
          Offset(box.left + 23, box.center.dy),
        );
        await gesture.moveBy(const Offset(40, 0));
        await gesture.moveBy(const Offset(40, 0));
        await tester.pump();
        expect(t.playback.fileId, isNull); // nothing loaded while dragging
        await gesture.up();
        await tester.pumpAndSettle();
        expect(t.playback.fileId, 'mem://$name');
        expect(t.playback.playing, isFalse);
        expect(t.playback.position, greaterThan(Duration.zero));
        expect(t.playback.seeks, 1);
      },
    );

    testWidgets('a list of 2,500 recordings scrolls to the oldest', (
      tester,
    ) async {
      useReferenceDevice(tester);
      final start = DateTime(2016, 3, 1, 9);
      await pumpReferenceApp(
        tester,
        files: [
          for (var i = 0; i < 2500; i++)
            () {
              final t = start.add(Duration(hours: 29 * i));
              final name = '${timestampName(t)}.mp3';
              return RecordingFile(
                id: 'mem://$name',
                name: name,
                size: 25000000,
                modified: t,
              );
            }(),
        ],
        current: null,
      );
      await tester.tap(labeled('Recording list'));
      await tester.pumpAndSettle();
      final newest =
          '${timestampName(start.add(const Duration(hours: 29 * 2499)))}.mp3';
      expect(find.text(newest), findsOneWidget);
      final oldest = '${timestampName(start)}.mp3';
      // 2,500 rows are about 166,000 dp tall.
      await tester.scrollUntilVisible(
        find.text(oldest),
        2000,
        scrollable: find.byType(Scrollable).last,
        maxScrolls: 200,
      );
      expect(find.text(oldest), findsOneWidget);
      expect(find.text('2016-03-01'), findsOneWidget);
    });

    testWidgets('leaving the list while a slow delete finishes is safe', (
      tester,
    ) async {
      final t = await openList(tester);
      await tester.tap(find.text('2026_09_18_21_23_04.mp3'));
      await tester.pumpAndSettle();
      t.store.slow = Completer<void>();
      await tester.tap(labeled('Delete'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('OK'));
      await tester.pump();
      // Back while the storage is still busy.
      Navigator.of(tester.element(labeled('Back'))).pop();
      await tester.pumpAndSettle();
      t.store.slow!.complete();
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(t.store.files, hasLength(9));
    });

    testWidgets('back returns to the Recorder', (tester) async {
      await openList(tester);
      await tester.tap(labeled('Back'));
      await tester.pumpAndSettle();
      expect(labeled('Record'), findsOneWidget);
    });
  });

  group('Settings', () {
    Future<TestApp> openSettings(WidgetTester tester) async {
      useReferenceDevice(tester);
      final t = await pumpReferenceApp(tester);
      await tester.tap(labeled('Settings'));
      await tester.pumpAndSettle();
      return t;
    }

    testWidgets('recording type and quality', (tester) async {
      final t = await openSettings(tester);
      final settings = t.controller.settings;

      await tester.tap(labeled('Recording type, MP3'));
      await tester.pumpAndSettle();
      expect(find.text('M4A'), findsOneWidget);
      await tester.tap(find.text('WAV'));
      await tester.pumpAndSettle();
      expect(settings.type, RecordingType.wav);
      expect(labeled('Recording type, WAV'), findsOneWidget);

      await tester.tap(labeled('Recording quality, The best quality'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(settings.quality, RecordingQuality.best);

      await tester.tap(labeled('Recording quality, The best quality'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Low quality'));
      await tester.pumpAndSettle();
      expect(settings.quality, RecordingQuality.low);
      expect(labeled('Recording quality, Low quality'), findsOneWidget);

      // Back on the Recorder, the remaining time reflects 8 kHz WAV.
      Navigator.of(tester.element(labeled('Recording quality, Low quality')))
          .pop();
      await tester.pumpAndSettle();
      final left = settings.profile.remainingFor(referenceFreeBytes);
      expect(
        find.text('Remaining time: ${formatRemaining(left)}'),
        findsOneWidget,
      );
    });

    testWidgets('folder, rate and about', (tester) async {
      LicenseRegistry.reset();
      registerThirdPartyLicenses();
      addTearDown(LicenseRegistry.reset);
      PackageInfo.setMockInitialValues(
        appName: 'Voice Recorder',
        packageName: 'com.spencerchase.voicerecorder',
        version: '1.0.0',
        buildNumber: '1',
        buildSignature: '',
      );
      await openSettings(tester);
      expect(labeled('Folder, $_folder'), findsOneWidget);

      expect(find.text('Remove ads'), findsNothing);

      await tester.tap(labeled('About'));
      await tester.pumpAndSettle();
      expect(find.textContaining('Version 1.0.0 (1)'), findsOneWidget);
      await tester.tap(find.text('OK'));
      await tester.pumpAndSettle();
      expect(find.textContaining('Version 1.0.0 (1)'), findsNothing);

      // About > Licenses lists the bundled third-party code and artwork.
      await tester.tap(labeled('About'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Licenses'));
      await tester.pumpAndSettle();
      expect(find.byType(LicensePage), findsOneWidget);
      for (final name in [
        'LAME MP3 encoder',
        'Roboto',
        'Font Awesome',
        'Ionicons',
      ]) {
        expect(find.text(name), findsOneWidget, reason: name);
      }
      Navigator.of(tester.element(find.byType(LicensePage))).pop();
      await tester.pumpAndSettle();

      // No store listing yet (see AppConfig.appStoreId): just a thank-you.
      await tester.tap(labeled('Rate 5 stars'));
      await tester.pump();
      expect(find.text('Thank you!'), findsOneWidget);
      await tester.pump(const Duration(seconds: 2));
    });
  });
}

bool isAudioName(String? s) => s != null && s.endsWith('.mp3');
