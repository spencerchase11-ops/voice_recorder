import Flutter
import UIKit

class SceneDelegate: FlutterSceneDelegate {
  // The home-screen "Record" quick action, when it launches the app...
  override func scene(
    _ scene: UIScene,
    willConnectTo session: UISceneSession,
    options connectionOptions: UIScene.ConnectionOptions
  ) {
    if let shortcut = connectionOptions.shortcutItem {
      VoiceRecorderNative.handle(shortcut: shortcut)
    }
    super.scene(scene, willConnectTo: session, options: connectionOptions)
  }

  // ...and when the app is already running.
  override func windowScene(
    _ windowScene: UIWindowScene,
    performActionFor shortcutItem: UIApplicationShortcutItem,
    completionHandler: @escaping (Bool) -> Void
  ) {
    if VoiceRecorderNative.handle(shortcut: shortcutItem) {
      // The recording starts on the Recorder screen. A sheet left open over
      // the app (the Files picker, the share sheet) would hide it, and what
      // starting it may ask, so it is closed.
      let root = (window ?? windowScene.windows.first)?.rootViewController
      if let sheet = root?.presentedViewController {
        sheet.dismiss(animated: false) { RecordingImporter.pickerClosed() }
      }
      completionHandler(true)
    } else {
      super.windowScene(
        windowScene, performActionFor: shortcutItem, completionHandler: completionHandler)
    }
  }
}
