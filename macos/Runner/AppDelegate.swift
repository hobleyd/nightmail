import Cocoa
import DesktopUpdaterKit
import FlutterMacOS

@main
class AppDelegate: FlutterAppDelegate {
  // Replaces the `main()` that `@main` would otherwise synthesise, only to
  // run desktop_updater's restart wait *before* NSApplicationMain.
  //
  // After an in-app update the outgoing app spawns this executable as a
  // restart child, which waits for the old app to exit and the bundle to be
  // replaced, then turns itself into `/usr/bin/open` of the bundle. The plugin
  // runs that wait from its `register(with:)`, which comes after
  // NSApplication has checked this process in with LaunchServices as
  // NightMail. `open`, in the same pid, then found NightMail "already
  // running", brought that pid forward and exited — the update installed and
  // the app never came back (desktop_updater 3.2.x; see
  // lib/infrastructure/update/CLAUDE.md). Waiting here, before AppKit exists,
  // means nothing is registered when `open` runs. The env vars are consumed,
  // so the plugin's own call later returns at once.
  //
  // Takes effect from the update *after* the one that installs this build:
  // the restart child is always the outgoing app's executable.
  static func main() {
    guard MacApplicationRestarter.awaitRestartParentExitIfRequested() else {
      // What the plugin does on the same failure.
      _exit(78)
    }
    _ = NSApplicationMain(CommandLine.argc, CommandLine.unsafeArgv)
  }

  // Let the main window control app lifecycle — closing a compose window
  // should not quit the app. MainFlutterWindow calls NSApp.terminate when
  // the main window itself closes.
  override func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
    return false
  }

  override func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
    return true
  }

  // Wired from MainMenu.xib's "About NightMail" item in place of the default
  // orderFrontStandardAboutPanel: — routes to Settings > About instead, which
  // shows the actual app version/update status rather than an empty
  // auto-generated panel.
  @IBAction func showAboutPanel(_ sender: Any?) {
    guard let mainWindow = MainFlutterWindow.shared else { return }
    mainWindow.makeKeyAndOrderFront(nil)
    mainWindow.showAboutFromMenu()
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
