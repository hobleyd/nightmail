import Cocoa
import FlutterMacOS

@main
class AppDelegate: FlutterAppDelegate {
  // Let the main window control app lifecycle — closing a compose window
  // should not quit the app. MainFlutterWindow calls NSApp.terminate when
  // the main window itself closes.
  override func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
    return false
  }

  override func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
    return true
  }
}
