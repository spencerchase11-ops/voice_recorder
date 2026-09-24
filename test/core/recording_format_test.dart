import 'package:flutter_test/flutter_test.dart';
import 'package:voice_recorder/src/core/format.dart';
import 'package:voice_recorder/src/core/recording_format.dart';

void main() {
  test('defaults match the original: MP3, "The best quality" (160 kbps)', () {
    final p = RecordingProfile.of(RecordingType.mp3, RecordingQuality.best);
    expect(p.sampleRate, 44100);
    expect(p.bitRateKbps, 160);
    // 33:57 at 160 kbps is ~39800 KB, like the original's 39819 KB file.
    final bytes = p.bytesPerSecond * (33 * 60 + 57);
    expect(bytes / 1024, closeTo(39819, 60));
  });

  test('remaining time from free space', () {
    final p = RecordingProfile.of(RecordingType.mp3, RecordingQuality.best);
    const free = (9665 * 3600 + 13 * 60 + 10) * 20000;
    expect(formatRemaining(p.remainingFor(free)), '9665:13:10');
    final wav = RecordingProfile.of(RecordingType.wav, RecordingQuality.best);
    expect(wav.bytesPerSecond, 88200);
  });

  test('every MP3 profile uses a sample rate/bitrate pair LAME supports', () {
    for (final q in RecordingQuality.values) {
      final p = RecordingProfile.of(RecordingType.mp3, q);
      expect([16000, 22050, 44100], contains(p.sampleRate));
      // MPEG-2 (16/22.05 kHz) tops out at 160 kbps, MPEG-1 at 320 kbps.
      expect(
        p.bitRateKbps,
        lessThanOrEqualTo(p.sampleRate < 32000 ? 160 : 320),
      );
    }
  });

  test('labels shown in Settings', () {
    expect(RecordingType.values.map((t) => t.label), ['MP3', 'WAV', 'M4A']);
    expect(RecordingQuality.best.label, 'The best quality');
  });
}
