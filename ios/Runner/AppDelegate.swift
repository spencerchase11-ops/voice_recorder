import Flutter
import UIKit

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
  static func register(with registrar: FlutterPluginRegistrar) {
    let channel = FlutterMethodChannel(
      name: "com.spencerchase.voicerecorder/native",
      binaryMessenger: registrar.messenger())
    registrar.addMethodCallDelegate(VoiceRecorderNative(), channel: channel)
  }

  func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "freeBytes":
      let args = call.arguments as? [String: Any]
      let path = (args?["location"] as? String) ?? NSHomeDirectory()
      result(Self.freeBytes(at: path))
    case "deviceKind":
      // The hardware, not the idiom: this iPhone-only app also runs on iPads.
      result(UIDevice.current.model.hasPrefix("iPad") ? "iPad" : "iPhone")
    case "openAppSettings":
      if let url = URL(string: UIApplication.openSettingsURLString) {
        UIApplication.shared.open(url)
      }
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
