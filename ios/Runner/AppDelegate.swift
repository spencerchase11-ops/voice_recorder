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
      importer.pick(
        into: URL(fileURLWithPath: destination),
        folder: (args?["folder"] as? Bool) ?? true,
        result: result)
    case "cancelImport":
      RecordingImporter.cancel()
      result(nil)
    case "keepScreenOn":
      UIApplication.shared.isIdleTimerDisabled = (args?["on"] as? Bool) ?? false
      result(nil)
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

/// Copies recordings the user picks in the Files app (a whole folder with
/// its subfolders, or single files, from On My iPhone, iCloud Drive or a USB
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

  /// Other sound formats: counted, so the user hears they were left out.
  private static let otherAudioExtensions: Set<String> = [
    "amr", "awb", "3gp", "3ga", "ogg", "oga", "opus", "wma", "aif", "aiff",
    "caf", "m4b", "mp2",
  ]

  /// Name start of a file being copied in; renamed once complete.
  private static let partialPrefix = ".importing-"

  /// How deep into subfolders recordings are looked for.
  private static let maxDepth = 8

  /// How many files still in iCloud are downloaded ahead of the copy.
  private static let fetchAhead = 8

  private enum Outcome { case copied, skipped, failed, full }

  /// A file to import, with its size when it's known without reading it.
  private struct Item {
    let url: URL
    let size: Int64?
  }

  private var destination: URL?
  private var result: FlutterResult?
  private var backgroundTask: UIBackgroundTaskIdentifier = .invalid

  /// Set by Cancel; the copy stops after the file it is on.
  private static let stopLock = NSLock()
  private static var stopRequested = false

  static func cancel() {
    stopLock.lock()
    stopRequested = true
    stopLock.unlock()
  }

  private static var cancelled: Bool {
    stopLock.lock()
    defer { stopLock.unlock() }
    return stopRequested
  }

  /// Shows the Files picker: for a folder (all the recordings in it), or
  /// for single recordings.
  func pick(into destination: URL, folder: Bool, result: @escaping FlutterResult) {
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
    Self.stopLock.lock()
    Self.stopRequested = false
    Self.stopLock.unlock()
    Self.removePartialCopies(in: destination)
    let picker = UIDocumentPickerViewController(
      forOpeningContentTypes: folder ? [.folder] : [.audio], asCopy: false)
    picker.allowsMultipleSelection = !folder
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

  private static func isOtherAudio(_ url: URL) -> Bool {
    !url.lastPathComponent.hasPrefix(".")
      && otherAudioExtensions.contains(url.pathExtension.lowercased())
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
    var items: [Item] = []
    var ignored = 0
    for url in urls {
      if isFolder(url) {
        let found = files(under: url)
        items += found.items
        ignored += found.ignored
      } else if isAudio(url) {
        items.append(Item(url: url, size: fileSize(url)))
      } else {
        ignored += 1
      }
    }
    // What is here already is skipped before anything is read, so files in
    // iCloud aren't downloaded again when an import is run a second time.
    let ours = destination.resolvingSymlinksInPath().path
    var skipped = 0
    var todo: [Item] = []
    for item in items {
      if item.url.resolvingSymlinksInPath().path.hasPrefix(ours + "/") {
        skipped += 1  // the app's own folder (a folder above it was picked)
      } else if let size = item.size,
        hasCopy(named: item.url.lastPathComponent, size: size, in: destination)
      {
        skipped += 1
      } else {
        todo.append(item)
      }
    }
    var copied = 0
    var failed = 0
    var full = 0
    var stopped = false
    var lastReport = Date.distantPast
    let alreadyHere = skipped
    report(alreadyHere, items.count)
    for (i, item) in todo.enumerated() {
      if cancelled {
        stopped = true
        break
      }
      // Files still in iCloud download a few ahead, while this one copies.
      for next in todo[i..<min(i + fetchAhead, todo.count)] {
        try? FileManager.default.startDownloadingUbiquitousItem(at: next.url)
      }
      autoreleasepool {
        switch copyOne(item.url, into: destination) {
        case .copied: copied += 1
        case .skipped: skipped += 1
        case .failed: failed += 1
        case .full: full += 1
        }
      }
      if Date().timeIntervalSince(lastReport) > 0.25 || i == todo.count - 1 {
        lastReport = Date()
        report(alreadyHere + i + 1, items.count)
      }
    }
    return [
      "copied": copied, "skipped": skipped, "failed": failed + full, "full": full,
      "ignored": ignored, "cancelled": stopped ? 1 : 0,
    ]
  }

  private static func isFolder(_ url: URL) -> Bool {
    (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
  }

  private static func fileSize(_ url: URL) -> Int64? {
    guard let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize else {
      return nil
    }
    return Int64(size)
  }

  /// The recordings in `folder` and its subfolders, including ones that are
  /// only in iCloud so far (some iOS versions list those as ".name.icloud"
  /// placeholders, which know the file's size), and how many other sound
  /// files there are.
  private static func files(under folder: URL) -> (items: [Item], ignored: Int) {
    let fm = FileManager.default
    guard let walk = fm.enumerator(
      at: folder, includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey],
      options: [.skipsPackageDescendants], errorHandler: { _, _ in true })
    else { return ([], 0) }
    var found: [Item] = []
    var ignored = 0
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
          let size = (NSDictionary(contentsOf: item)?["NSURLFileSizeKey"] as? NSNumber)?.int64Value
          found.append(Item(url: real, size: size))
        } else if isOtherAudio(real) {
          ignored += 1
        }
      } else if isAudio(item) {
        found.append(Item(url: item, size: fileSize(item)))
      } else if isOtherAudio(item) {
        ignored += 1
      }
    }
    // In name order: timestamp names then come in the order they were made.
    let sorted = found.sorted {
      $0.url.path.localizedStandardCompare($1.url.path) == .orderedAscending
    }
    return (sorted, ignored)
  }

  /// Whether the folder has the file already: the same name, or a numbered
  /// variant of it ("name (1).mp3"), with the same size.
  private static func hasCopy(named name: String, size: Int64, in destination: URL) -> Bool {
    existingCopy(named: name, size: size, in: destination).found
  }

  /// Looks for the file in the folder ([hasCopy]); if it isn't there, also
  /// gives the first free name for it.
  private static func existingCopy(named name: String, size: Int64?, in destination: URL)
    -> (found: Bool, freeName: URL)
  {
    let fm = FileManager.default
    let base = (name as NSString).deletingPathExtension
    let ext = (name as NSString).pathExtension
    var target = destination.appendingPathComponent(name)
    var n = 1
    while fm.fileExists(atPath: target.path) {
      if let size = size,
        let attributes = try? fm.attributesOfItem(atPath: target.path),
        (attributes[.size] as? NSNumber)?.int64Value == size
      {
        return (true, target)
      }
      target = destination.appendingPathComponent(
        ext.isEmpty ? "\(base) (\(n))" : "\(base) (\(n)).\(ext)")
      n += 1
    }
    return (false, target)
  }

  /// Copies one file, unless the folder already has it.
  private static func copyOne(_ source: URL, into destination: URL) -> Outcome {
    var outcome = Outcome.failed
    var error: NSError?
    // Coordinated, so a file that lives only in iCloud is downloaded first.
    NSFileCoordinator().coordinate(readingItemAt: source, options: [], error: &error) { url in
      let fm = FileManager.default
      let name = url.lastPathComponent
      let ext = (name as NSString).pathExtension
      let there = existingCopy(named: name, size: fileSize(url), in: destination)
      if there.found {
        outcome = .skipped  // imported before
        return
      }
      // Under a hidden name until complete, so a copy cut short never shows
      // up as a recording. On the same volume the copy is usually a clone:
      // instant, and it takes no extra space.
      let partial = destination.appendingPathComponent(
        "\(partialPrefix)\(UUID().uuidString).\(ext)")
      do {
        try fm.copyItem(at: url, to: partial)
        try fm.moveItem(at: partial, to: there.freeName)
        outcome = .copied
      } catch {
        try? fm.removeItem(at: partial)
        if isOutOfSpace(error) { outcome = .full }
        NSLog("Voice Recorder: could not import %@: %@", name, "\(error)")
      }
    }
    if let error = error {
      if isOutOfSpace(error) { outcome = .full }
      NSLog("Voice Recorder: could not read %@: %@", source.lastPathComponent, "\(error)")
    }
    return outcome
  }

  /// Whether `error` (or the one behind it) says the storage is full.
  private static func isOutOfSpace(_ error: Error) -> Bool {
    let e = error as NSError
    if e.domain == NSCocoaErrorDomain && e.code == NSFileWriteOutOfSpaceError { return true }
    if e.domain == NSPOSIXErrorDomain && e.code == Int(ENOSPC) { return true }
    if let underlying = e.userInfo[NSUnderlyingErrorKey] as? Error {
      return isOutOfSpace(underlying)
    }
    return false
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
