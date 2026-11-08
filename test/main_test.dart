import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:voice_recorder/main.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('the app starts although iOS refuses the audio session', () async {
    final logged = <String?>[];
    final print = debugPrint;
    debugPrint = (m, {wrapWidth}) => logged.add(m);
    try {
      // What iOS answers while its media services restart.
      await configureAtLaunch(
        () async => throw PlatformException(code: '561015905'),
      );
    } finally {
      debugPrint = print;
    }
    expect(logged.single, contains('561015905'));
  });

  test('uncaught errors are logged and the app carries on', () {
    final onError = FlutterError.onError;
    final present = FlutterError.presentError;
    final platformOnError = PlatformDispatcher.instance.onError;
    final print = debugPrint;
    final presented = <FlutterErrorDetails>[];
    final logged = <String?>[];
    try {
      logUncaughtErrors();
      FlutterError.presentError = presented.add;
      debugPrint = (m, {wrapWidth}) => logged.add(m);
      // Flutter's own: presented as before.
      FlutterError.onError!(
        FlutterErrorDetails(exception: StateError('build')),
      );
      // Any other: logged, and handled (true), so nothing goes down.
      final handled = PlatformDispatcher.instance.onError!(
        StateError('async'),
        StackTrace.empty,
      );
      expect(handled, isTrue);
    } finally {
      FlutterError.onError = onError;
      FlutterError.presentError = present;
      PlatformDispatcher.instance.onError = platformOnError;
      debugPrint = print;
    }
    expect(presented, hasLength(1));
    expect(logged.single, contains('async'));
  });
}
