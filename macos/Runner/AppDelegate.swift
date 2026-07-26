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

  // Cmd-Q routes here directly (not through windowShouldClose), so without
  // this override the process would tear down immediately — killing the
  // drift cache database's background isolate mid-query and crashing native
  // sqlite3 (SIGSEGV in sqlite3Close). Hold termination until Dart confirms
  // it has closed the database, with a timeout so a stuck Dart side can
  // never block quitting entirely.
  private var readyToTerminate = false

  override func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
    if readyToTerminate { return .terminateNow }

    guard let mainWindow = MainFlutterWindow.shared else { return .terminateNow }

    var didReply = false
    let replyOnce: () -> Void = {
      if didReply { return }
      didReply = true
      self.readyToTerminate = true
      NSApp.reply(toApplicationShouldTerminate: true)
    }

    mainWindow.notifyWillTerminate(completion: replyOnce)
    // Longer than Dart's internal close() timeout (3s) so this fallback only
    // trips when Dart is genuinely stuck, not while a draining query is still
    // legitimately using its own timeout budget.
    DispatchQueue.main.asyncAfter(deadline: .now() + 5, execute: replyOnce)

    return .terminateLater
  }
}
