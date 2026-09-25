import AVFoundation
import Flutter
import MediaPlayer
import UIKit
import UniformTypeIdentifiers

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
    if let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "VoiceRecorderNative") {
      VoiceRecorderNative.register(with: registrar)
    }
  }
}

/// Platform side of lib/src/platform/native_bridge.dart (the iOS subset).
final class VoiceRecorderNative: NSObject, FlutterPlugin {
  /// The channel of the running engine, for reporting lock-screen buttons.
  private static var channel: FlutterMethodChannel?

  /// What a home-screen quick action opened the app for, until Dart asks.
  private static var launchAction: String?

  private let importer = RecordingImporter()

  static func register(with registrar: FlutterPluginRegistrar) {
    let channel = FlutterMethodChannel(
      name: "com.spencerchase.voicerecorder/native",
      binaryMessenger: registrar.messenger())
    Self.channel = channel
    registrar.addMethodCallDelegate(VoiceRecorderNative(), channel: channel)
  }

  /// A home-screen quick action ("Record"). Returns whether it was ours.
  @discardableResult
  static func handle(shortcut: UIApplicationShortcutItem) -> Bool {
    guard shortcut.type.hasSuffix(".record") else { return false }
    launchAction = "record"
    return true
  }

  static func send(_ method: String, _ arguments: [String: Any]) {
    channel?.invokeMethod(method, arguments: arguments)
  }

  func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    let args = call.arguments as? [String: Any]
    switch call.method {
    case "freeBytes":
      let path = (args?["location"] as? String) ?? NSHomeDirectory()
      result(Self.freeBytes(at: path))
    case "deviceKind":
      // The hardware, not the idiom: this iPhone-only app also runs on iPads.
      result(UIDevice.current.model.hasPrefix("iPad") ? "iPad" : "iPhone")
    case "resetAudioSampleRate":
      // A recording at a low quality leaves its sample rate as the session's
      // preference, which can make later playback sound muffled.
      try? AVAudioSession.sharedInstance().setPreferredSampleRate(48000)
      result(nil)
    case "openAppSettings":
      if let url = URL(string: UIApplication.openSettingsURLString) {
        UIApplication.shared.open(url)
      }
      result(nil)
    case "updateMediaSession":
      NowPlaying.shared.update(
        title: (args?["title"] as? String) ?? "",
        duration: Double((args?["durationMs"] as? NSNumber)?.int64Value ?? 0) / 1000,
        position: Double((args?["positionMs"] as? NSNumber)?.int64Value ?? 0) / 1000,
        playing: (args?["playing"] as? Bool) ?? false,
        speed: (args?["speed"] as? NSNumber)?.doubleValue ?? 1)
      result(nil)
    case "clearMediaSession":
      NowPlaying.shared.clear()
      result(nil)
    case "takeLaunchAction":
      result(Self.launchAction)
      Self.launchAction = nil
    case "importRecordings":
      guard let destination = args?["destination"] as? String else {
        result(FlutterError(code: "bad_args", message: "No destination", details: nil))
        return
      }
      importer.pick(into: URL(fileURLWithPath: destination), result: result)
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  /// Space available for user content on the volume holding `path`.
  private static func freeBytes(at path: String) -> NSNumber? {
    let url = URL(fileURLWithPath: path)
    if let values = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]),
       let bytes = values.volumeAvailableCapacityForImportantUsage {
      return NSNumber(value: bytes)
    }
    if let attrs = try? FileManager.default.attributesOfFileSystem(forPath: path),
       let free = attrs[.systemFreeSize] as? NSNumber {
      return free
    }
    return nil
  }
}

/// The lock screen's and Control Center's "Now Playing" controls, and the
/// headphone buttons: play/pause, back and forward 10 seconds, seeking.
/// The Flutter side plays the audio; the buttons go back to it as
/// "mediaAction" calls.
final class NowPlaying {
  static let shared = NowPlaying()

  private var targets: [(MPRemoteCommand, Any)] = []

  func update(title: String, duration: Double, position: Double, playing: Bool, speed: Double) {
    attach()
    MPNowPlayingInfoCenter.default().nowPlayingInfo = [
      MPMediaItemPropertyTitle: title,
      MPMediaItemPropertyArtist: "Voice Recorder",
      MPMediaItemPropertyPlaybackDuration: duration,
      MPNowPlayingInfoPropertyElapsedPlaybackTime: position,
      MPNowPlayingInfoPropertyPlaybackRate: playing ? speed : 0.0,
      MPNowPlayingInfoPropertyDefaultPlaybackRate: 1.0,
    ]
  }

  func clear() {
    MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
    let center = MPRemoteCommandCenter.shared()
    for (command, target) in targets {
      command.removeTarget(target)
    }
    targets.removeAll()
    for command in [
      center.playCommand, center.pauseCommand, center.togglePlayPauseCommand,
      center.skipForwardCommand, center.skipBackwardCommand,
      center.changePlaybackPositionCommand,
    ] {
      command.isEnabled = false
    }
  }

  private func attach() {
    guard targets.isEmpty else { return }
    let center = MPRemoteCommandCenter.shared()
    center.skipForwardCommand.preferredIntervals = [10]
    center.skipBackwardCommand.preferredIntervals = [10]
    let simple: [(MPRemoteCommand, String)] = [
      (center.playCommand, "play"),
      (center.pauseCommand, "pause"),
      (center.togglePlayPauseCommand, "toggle"),
      (center.skipForwardCommand, "forward"),
      (center.skipBackwardCommand, "rewind"),
    ]
    for (command, action) in simple {
      command.isEnabled = true
      let target = command.addTarget { _ in
        VoiceRecorderNative.send("mediaAction", ["action": action])
        return .success
      }
      targets.append((command, target))
    }
    let seek = center.changePlaybackPositionCommand
    seek.isEnabled = true
    let target = seek.addTarget { event in
      guard let event = event as? MPChangePlaybackPositionCommandEvent else {
        return .commandFailed
      }
      VoiceRecorderNative.send(
        "mediaAction",
        ["action": "seek", "position": Int(event.positionTime * 1000)])
      return .success
    }
    targets.append((seek, target))
  }
}

/// Copies recordings the user picks in the Files app (single files or whole
/// folders, from On My iPhone, iCloud Drive or a USB drive) into the
/// recordings folder.
final class RecordingImporter: NSObject, UIDocumentPickerDelegate {
  private static let audioExtensions: Set<String> = [
    "mp3", "wav", "m4a", "aac", "amr", "3gp", "ogg", "opus", "flac",
  ]

  private var destination: URL?
  private var result: FlutterResult?

  func pick(into destination: URL, result: @escaping FlutterResult) {
    guard self.result == nil else {
      result(FlutterError(code: "busy", message: "The picker is already open", details: nil))
      return
    }
    guard let presenter = Self.topViewController() else {
      result(FlutterError(code: "no_view", message: "Nothing to show the picker on", details: nil))
      return
    }
    self.destination = destination
    self.result = result
    let picker = UIDocumentPickerViewController(
      forOpeningContentTypes: [.audio, .folder], asCopy: false)
    picker.allowsMultipleSelection = true
    picker.delegate = self
    presenter.present(picker, animated: true)
  }

  func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
    finish(nil)
  }

  func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
    guard let destination = destination else {
      finish(nil)
      return
    }
    DispatchQueue.global(qos: .userInitiated).async {
      let count = Self.copy(urls, into: destination)
      DispatchQueue.main.async { self.finish(count) }
    }
  }

  private func finish(_ count: Int?) {
    let r = result
    result = nil
    destination = nil
    r?(count)
  }

  private static func isAudio(_ url: URL) -> Bool {
    !url.lastPathComponent.hasPrefix(".")
      && audioExtensions.contains(url.pathExtension.lowercased())
  }

  /// Copies the audio files among `urls` (and inside picked folders).
  private static func copy(_ urls: [URL], into destination: URL) -> Int {
    var count = 0
    for url in urls {
      let scoped = url.startAccessingSecurityScopedResource()
      defer { if scoped { url.stopAccessingSecurityScopedResource() } }
      var isFolder: ObjCBool = false
      guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isFolder) else {
        continue
      }
      if isFolder.boolValue {
        let items = (try? FileManager.default.contentsOfDirectory(
          at: url, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
        for item in items where isAudio(item) {
          if copyOne(item, into: destination) { count += 1 }
        }
      } else if isAudio(url) {
        if copyOne(url, into: destination) { count += 1 }
      }
    }
    return count
  }

  /// Copies one file, unless the folder already has it (same name and size).
  private static func copyOne(_ source: URL, into destination: URL) -> Bool {
    var copied = false
    var error: NSError?
    // Coordinated, so a file that lives only in iCloud is downloaded first.
    NSFileCoordinator().coordinate(readingItemAt: source, options: [], error: &error) { url in
      let fm = FileManager.default
      func size(_ u: URL) -> Int64? {
        guard let attributes = try? fm.attributesOfItem(atPath: u.path) else { return nil }
        return (attributes[.size] as? NSNumber)?.int64Value
      }
      let name = url.lastPathComponent
      var target = destination.appendingPathComponent(name)
      if fm.fileExists(atPath: target.path) {
        if size(target) == size(url) { return }  // already there
        let base = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension
        var n = 1
        repeat {
          target = destination.appendingPathComponent(
            ext.isEmpty ? "\(base) (\(n))" : "\(base) (\(n)).\(ext)")
          n += 1
        } while fm.fileExists(atPath: target.path)
      }
      do {
        try fm.copyItem(at: url, to: target)
        copied = true
      } catch {
        NSLog("Voice Recorder: could not import \(name): \(error)")
      }
    }
    return copied
  }

  private static func topViewController() -> UIViewController? {
    let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
    let window = scenes.flatMap { $0.windows }.first { $0.isKeyWindow }
      ?? scenes.first?.windows.first
    var top = window?.rootViewController
    while let presented = top?.presentedViewController {
      top = presented
    }
    return top
  }
}
