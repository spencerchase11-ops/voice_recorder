/// Recording types and qualities offered in Settings.
library;

enum RecordingType {
  mp3('MP3', 'mp3', 'audio/mpeg'),
  wav('WAV', 'wav', 'audio/x-wav'),
  m4a('M4A', 'm4a', 'audio/mp4');

  const RecordingType(this.label, this.extension, this.mimeType);

  /// Text shown in Settings ("Recording type / MP3").
  final String label;
  final String extension;
  final String mimeType;
}

enum RecordingQuality {
  low('Low quality'),
  medium('Medium quality'),
  high('High quality'),
  best('The best quality');

  const RecordingQuality(this.label);

  final String label;
}

/// Encoder parameters for a type/quality pair. Recordings are mono, like a
/// phone's built-in microphone.
class RecordingProfile {
  const RecordingProfile({
    required this.type,
    required this.sampleRate,
    this.bitRateKbps,
  });

  final RecordingType type;
  final int sampleRate;

  /// Compressed formats only (MP3, AAC).
  final int? bitRateKbps;

  static RecordingProfile of(RecordingType type, RecordingQuality quality) {
    switch (type) {
      case RecordingType.mp3:
        // "The best quality" is 160 kbps: a 33:57 recording made by the
        // original app is 39819 KB.
        return switch (quality) {
          RecordingQuality.low => const RecordingProfile(
            type: RecordingType.mp3,
            sampleRate: 16000,
            bitRateKbps: 32,
          ),
          RecordingQuality.medium => const RecordingProfile(
            type: RecordingType.mp3,
            sampleRate: 22050,
            bitRateKbps: 64,
          ),
          RecordingQuality.high => const RecordingProfile(
            type: RecordingType.mp3,
            sampleRate: 44100,
            bitRateKbps: 128,
          ),
          RecordingQuality.best => const RecordingProfile(
            type: RecordingType.mp3,
            sampleRate: 44100,
            bitRateKbps: 160,
          ),
        };
      case RecordingType.wav:
        return switch (quality) {
          RecordingQuality.low => const RecordingProfile(
            type: RecordingType.wav,
            sampleRate: 8000,
          ),
          RecordingQuality.medium => const RecordingProfile(
            type: RecordingType.wav,
            sampleRate: 16000,
          ),
          RecordingQuality.high => const RecordingProfile(
            type: RecordingType.wav,
            sampleRate: 22050,
          ),
          RecordingQuality.best => const RecordingProfile(
            type: RecordingType.wav,
            sampleRate: 44100,
          ),
        };
      case RecordingType.m4a:
        return switch (quality) {
          RecordingQuality.low => const RecordingProfile(
            type: RecordingType.m4a,
            sampleRate: 16000,
            bitRateKbps: 32,
          ),
          RecordingQuality.medium => const RecordingProfile(
            type: RecordingType.m4a,
            sampleRate: 22050,
            bitRateKbps: 64,
          ),
          RecordingQuality.high => const RecordingProfile(
            type: RecordingType.m4a,
            sampleRate: 44100,
            bitRateKbps: 96,
          ),
          RecordingQuality.best => const RecordingProfile(
            type: RecordingType.m4a,
            sampleRate: 44100,
            bitRateKbps: 128,
          ),
        };
    }
  }

  /// Bytes written per second of audio, used for "Remaining time".
  double get bytesPerSecond => switch (type) {
    RecordingType.wav => sampleRate * 2.0,
    _ => bitRateKbps! * 1000 / 8,
  };

  /// How long the given amount of free space lasts with this profile.
  Duration remainingFor(int freeBytes) =>
      Duration(seconds: (freeBytes / bytesPerSecond).floor());
}
