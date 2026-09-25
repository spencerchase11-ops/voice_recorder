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
      // After a recording. A low quality leaves its sample rate as the
      // session's preference, which can make later playback sound muffled.
      // And other apps' audio it paused (music, a podcast) may go on: iOS
      // tells them once this app's session lets go.
      let session = AVAudioSession.sharedInstance()
      try? session.setPreferredSampleRate(48000)
      try? session.setActive(false, options: .notifyOthersOnDeactivation)
      result(nil)
    case "excludeFromBackup":
      // A recording in progress (possibly gigabytes of WAV) stays out of
      // iCloud and computer backups.
      guard let path = args?["path"] as? String else {
        result(FlutterError(code: "bad_args", message: "No path", details: nil))
        return
      }
      var url = URL(fileURLWithPath: path)
      var values = URLResourceValues()
      values.isExcludedFromBackup = true
      do {
        try url.setResourceValues(values)
        result(nil)
      } catch {
        result(FlutterError(code: "backup", message: error.localizedDescription, details: nil))
      }
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
/// folders with their subfolders, from On My iPhone, iCloud Drive or a USB
/// drive) into the recordings folder. It reports how far it has got
/// ("importProgress") and answers with what was copied, what was there
/// already and what couldn't be copied. Running it again carries on where
/// an interrupted import stopped.
final class RecordingImporter: NSObject, UIDocumentPickerDelegate,
  UIAdaptivePresentationControllerDelegate
{
  /// The formats iPhones play (AMR, Ogg and Opus files would only fail).
  private static let audioExtensions: Set<String> = [
    "mp3", "wav", "m4a", "aac", "flac",
  ]

  /// Name start of a file being copied in; renamed once complete.
  private static let partialPrefix = ".importing-"

  /// How deep into subfolders recordings are looked for.
  private static let maxDepth = 8

  private enum Outcome { case copied, skipped, failed }

  private var destination: URL?
  private var result: FlutterResult?
  private var backgroundTask: UIBackgroundTaskIdentifier = .invalid

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
    Self.removePartialCopies(in: destination)
    let picker = UIDocumentPickerViewController(
      forOpeningContentTypes: [.audio, .folder], asCopy: false)
    picker.allowsMultipleSelection = true
    picker.delegate = self
    // Swiping the sheet down doesn't always count as Cancel.
    picker.presentationController?.delegate = self
    presenter.present(picker, animated: true)
  }

  func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
    finish(nil)
  }

  func presentationControllerDidDismiss(_ presentationController: UIPresentationController) {
    finish(nil)
  }

  func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
    guard let destination = destination else {
      finish(nil)
      return
    }
    // Thousands of recordings take a while: the screen stays on, and a copy
    // goes on for a while if the user leaves the app (it continues when
    // they come back).
    UIApplication.shared.isIdleTimerDisabled = true
    backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "Import recordings") {
      [weak self] in self?.endBackgroundTask()
    }
    DispatchQueue.global(qos: .userInitiated).async {
      let counts = Self.copy(urls, into: destination)
      DispatchQueue.main.async { self.finish(counts) }
    }
  }

  private func finish(_ counts: [String: Int]?) {
    UIApplication.shared.isIdleTimerDisabled = false
    let r = result
    result = nil
    destination = nil
    endBackgroundTask()
    r?(counts)
  }

  private func endBackgroundTask() {
    guard backgroundTask != .invalid else { return }
    UIApplication.shared.endBackgroundTask(backgroundTask)
    backgroundTask = .invalid
  }

  /// Copies an earlier import didn't finish (the app was closed meanwhile).
  private static func removePartialCopies(in folder: URL) {
    let fm = FileManager.default
    let items = (try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
    for item in items where item.lastPathComponent.hasPrefix(partialPrefix) {
      try? fm.removeItem(at: item)
    }
  }

  private static func isAudio(_ url: URL) -> Bool {
    !url.lastPathComponent.hasPrefix(".")
      && audioExtensions.contains(url.pathExtension.lowercased())
  }

  /// Copies the audio files among `urls` and in picked folders, telling the
  /// Flutter side how far it got. Returns the counts for the answer.
  private static func copy(_ urls: [URL], into destination: URL) -> [String: Int] {
    // Access to a picked folder covers everything inside it.
    let scoped = urls.filter { $0.startAccessingSecurityScopedResource() }
    defer { for url in scoped { url.stopAccessingSecurityScopedResource() } }
    func report(_ done: Int, _ total: Int) {
      let progress = ["done": done, "total": total]
      DispatchQueue.main.async { VoiceRecorderNative.send("importProgress", progress) }
    }
    report(0, 0)  // looking
    var items: [URL] = []
    for url in urls {
      items += isFolder(url) ? files(under: url) : (isAudio(url) ? [url] : [])
    }
    let ours = destination.resolvingSymlinksInPath().path
    var copied = 0
    var skipped = 0
    var failed = 0
    var lastReport = Date.distantPast
    for (i, item) in items.enumerated() {
      // The app's own folder (when a folder above it was picked).
      if item.resolvingSymlinksInPath().path.hasPrefix(ours + "/") {
        skipped += 1
      } else {
        switch copyOne(item, into: destination) {
        case .copied: copied += 1
        case .skipped: skipped += 1
        case .failed: failed += 1
        }
      }
      if Date().timeIntervalSince(lastReport) > 0.25 || i == items.count - 1 {
        lastReport = Date()
        report(i + 1, items.count)
      }
    }
    return ["copied": copied, "skipped": skipped, "failed": failed]
  }

  private static func isFolder(_ url: URL) -> Bool {
    (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
  }

  /// The recordings in `folder` and its subfolders, including ones that are
  /// only in iCloud so far: some iOS versions list those as ".name.icloud"
  /// placeholders. Their download starts here; the coordinated read in
  /// `copyOne` waits for it.
  private static func files(under folder: URL) -> [URL] {
    let fm = FileManager.default
    guard let walk = fm.enumerator(
      at: folder, includingPropertiesForKeys: [.isDirectoryKey],
      options: [.skipsPackageDescendants], errorHandler: { _, _ in true })
    else { return [] }
    var found: [URL] = []
    for case let item as URL in walk {
      let name = item.lastPathComponent
      if isFolder(item) {
        if name.hasPrefix(".") || walk.level >= maxDepth { walk.skipDescendants() }
        continue
      }
      if name.hasPrefix("."), name.hasSuffix(".icloud") {
        let real = item.deletingLastPathComponent().appendingPathComponent(
          String(name.dropFirst().dropLast(".icloud".count)))
        if isAudio(real) {
          try? fm.startDownloadingUbiquitousItem(at: real)
          found.append(real)
        }
      } else if isAudio(item) {
        found.append(item)
      }
    }
    // In name order: timestamp names then come in the order they were made.
    return found.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
  }

  /// Copies one file, unless the folder already has it (the same name, or
  /// a numbered variant of it, with the same size).
  private static func copyOne(_ source: URL, into destination: URL) -> Outcome {
    var outcome = Outcome.failed
    var error: NSError?
    // Coordinated, so a file that lives only in iCloud is downloaded first.
    NSFileCoordinator().coordinate(readingItemAt: source, options: [], error: &error) { url in
      let fm = FileManager.default
      func size(_ u: URL) -> Int64? {
        guard let attributes = try? fm.attributesOfItem(atPath: u.path) else { return nil }
        return (attributes[.size] as? NSNumber)?.int64Value
      }
      let name = url.lastPathComponent
      let base = (name as NSString).deletingPathExtension
      let ext = (name as NSString).pathExtension
      let length = size(url)
      var target = destination.appendingPathComponent(name)
      var n = 1
      while fm.fileExists(atPath: target.path) {
        if size(target) == length {
          outcome = .skipped  // imported before
          return
        }
        target = destination.appendingPathComponent(
          ext.isEmpty ? "\(base) (\(n))" : "\(base) (\(n)).\(ext)")
        n += 1
      }
      // Under a hidden name until complete, so a copy cut short never shows
      // up as a recording. On the same volume the copy is a clone: instant,
      // and it takes no extra space.
      let partial = destination.appendingPathComponent(
        "\(partialPrefix)\(UUID().uuidString).\(ext)")
      do {
        try fm.copyItem(at: url, to: partial)
        try fm.moveItem(at: partial, to: target)
        outcome = .copied
      } catch {
        try? fm.removeItem(at: partial)
        NSLog("Voice Recorder: could not import %@: %@", name, "\(error)")
      }
    }
    if let error = error {
      NSLog("Voice Recorder: could not read %@: %@", source.lastPathComponent, "\(error)")
    }
    return outcome
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
