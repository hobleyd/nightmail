import BackgroundTasks
import Flutter
import UIKit
import workmanager_apple

private let kMailCheckIdentifier = "au.com.sharpblue.nightmail.mailCheck"
private let kMailCheckInterval: TimeInterval = 15 * 60

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    // Wire up the registrant callback so the background isolate can access plugins.
    WorkmanagerPlugin.setPluginRegistrantCallback { registry in
      GeneratedPluginRegistrant.register(with: registry)
    }

    // Register the BGTask handler directly — Apple requires this before
    // didFinishLaunchingWithOptions returns.  We call BGTaskScheduler directly
    // (not WorkmanagerPlugin.registerPeriodicTask) to avoid a double-registration
    // crash: Dart's BackgroundMailService.schedulePeriodicCheck() skips the
    // registration step on iOS and lets this native registration stand.
    BGTaskScheduler.shared.register(
      forTaskWithIdentifier: kMailCheckIdentifier,
      using: nil
    ) { task in
      guard let refreshTask = task as? BGAppRefreshTask else {
        task.setTaskCompleted(success: false)
        return
      }
      WorkmanagerPlugin.handlePeriodicTask(
        identifier: kMailCheckIdentifier,
        task: refreshTask,
        earliestBeginInSeconds: kMailCheckInterval
      )
    }

    // Submit the initial scheduling request.  WorkmanagerPlugin.handlePeriodicTask
    // reschedules automatically after each run; this covers the first-ever launch.
    let request = BGAppRefreshTaskRequest(identifier: kMailCheckIdentifier)
    request.earliestBeginDate = Date(timeIntervalSinceNow: kMailCheckInterval)
    try? BGTaskScheduler.shared.submit(request)

    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
  }
}
