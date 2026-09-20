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
    // didFinishLaunchingWithOptions returns. Must go through
    // WorkmanagerPlugin.registerPeriodicTask, not a raw
    // BGTaskScheduler.shared.register call: Flutter's UIScene fallback path
    // (FlutterViewController.awakeFromNib) forwards didFinishLaunchingWithOptions
    // to plugins again *after* this method returns, and WorkmanagerPlugin's own
    // handler re-registers every identifier persisted in UserDefaults
    // (including this one — handlePeriodicTask persists it on every
    // background run). A raw call here isn't tracked in the plugin's
    // registeredLaunchHandlers dedup set, so that later call re-registers the
    // same identifier post-launch, which throws an uncatchable
    // NSInternalInconsistencyException — crashed nearly every cold launch
    // after the first background run (TestFlight crash
    // 30B5C563-C88F-4A20-8493-552AA4ED13AF). Going through the plugin API
    // seeds its dedup set so the later call becomes a no-op.
    WorkmanagerPlugin.registerPeriodicTask(
      withIdentifier: kMailCheckIdentifier,
      earliestBeginInSeconds: NSNumber(value: kMailCheckInterval)
    )

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
