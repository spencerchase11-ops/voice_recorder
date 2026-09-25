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
      completionHandler(true)
    } else {
      super.windowScene(
        windowScene, performActionFor: shortcutItem, completionHandler: completionHandler)
    }
  }
}
