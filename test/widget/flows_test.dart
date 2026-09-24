// Drives the screens the way a user would, on the reference phone.
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart' show LicensePage;
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:voice_recorder/src/core/format.dart';
import 'package:voice_recorder/src/core/recording_format.dart';
import 'package:voice_recorder/src/licenses.dart';
import 'package:voice_recorder/src/ui/widgets/frame.dart';
import 'package:voice_recorder/src/ui/widgets/recorder_widgets.dart';

import '../support/fakes.dart';
import '../support/harness.dart';

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

    testWidgets('without microphone access it explains why', (tester) async {
      useReferenceDevice(tester);
      final t = await pumpReferenceApp(tester);
      t.engine.permission = false;
      await tester.tap(labeled('Record'));
      await tester.pumpAndSettle();
      expect(
        find.textContaining('needs access to the microphone'),
        findsOneWidget,
      );
      await tester.tap(find.text('OK'));
      await tester.pumpAndSettle();
      expect(t.controller.isRecording, isFalse);
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
      expect(enabled(tester, 'Delete'), isFalse);
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

    testWidgets('header actions are off until there is a recording', (
      tester,
    ) async {
      useReferenceDevice(tester);
      await pumpReferenceApp(tester, current: null);
      for (final l in ['Share', 'Rename', 'Delete', 'Play']) {
        expect(enabled(tester, l), isFalse, reason: l);
      }
      expect(find.text('00:00'), findsOneWidget);
      expect(find.textContaining(_folder), findsNothing);
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
