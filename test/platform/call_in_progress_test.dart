import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:voice_recorder/src/platform/native_bridge.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('com.spencerchase.voicerecorder/native');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  tearDown(() => messenger.setMockMethodCallHandler(channel, null));

  test('iOS: whether a call is in progress is asked of AppDelegate.swift '
      '(its "callInProgress")', () async {
    final asked = <String>[];
    var answer = true;
    messenger.setMockMethodCallHandler(channel, (call) async {
      asked.add(call.method);
      return answer;
    });
    final native = NativeBridge();
    expect(await native.callInProgress(), isTrue);
    answer = false;
    expect(await native.callInProgress(), isFalse);
    expect(asked, ['callInProgress', 'callInProgress']);
  });

  test('without an answer it fails, so the recorder engine takes the audio '
      'session to find out, as before', () async {
    await expectLater(
      NativeBridge().callInProgress(),
      throwsA(isA<MissingPluginException>()),
    );
    messenger.setMockMethodCallHandler(channel, (call) async => null);
    await expectLater(NativeBridge().callInProgress(), throwsA(anything));
  });
}
