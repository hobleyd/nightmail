import BackgroundTasks
import Flutter
import UIKit
import UserNotifications
import workmanager_apple

private let kMailCheckIdentifier = "au.com.sharpblue.nightmail.mailCheck"
private let kMailCheckInterval: TimeInterval = 15 * 60
private let kNotificationTapChannel = "au.com.sharpblue.nightmail/notification_tap"

/// Stands in front of `FlutterAppDelegate` as the `UNUserNotificationCenter`
/// delegate so a tap on one of our notifications is held *here*, in the one
/// object that is alive for as long as the process is, until the Dart side
/// collects it (`NotificationService._takeNativeTap`).
///
/// Why not leave it to flutter_local_notifications: the plugin registers one
/// instance per Flutter engine as an app-lifecycle delegate, and the tap goes
/// to whichever instances exist when it lands. The background mail check
/// (WorkManager's BGAppRefresh task) launches the app headlessly, raises the
/// notification from its own engine, and tears that engine down — so on a
/// phone the usual shape is a process with *no* main engine and a freed plugin
/// instance when the tap arrives. It went nowhere: the main engine, started
/// only when the user then opened the app, reported no launch notification
/// and had no callback to fire. The account never switched and the message
/// never opened; a tap for the account already on screen looked as if it had
/// worked because the Inbox was showing anyway.
///
/// Only a plain tap on a notification carrying a Flutter-side `payload` is
/// taken. Everything else — foreground presentation, the Mark Read / Delete /
/// Dismiss actions — is forwarded to Flutter's own delegate exactly as before,
/// so the plugin's background-isolate handling of those actions is untouched.
private final class NotificationTapRelay: NSObject, UNUserNotificationCenterDelegate {
  weak var flutterDelegate: UNUserNotificationCenterDelegate?
  var channel: FlutterMethodChannel?
  private var pendingPayload: String?

  /// Hands over the held payload, once. Dart pulls (at startup, on resume and
  /// when poked below) rather than being pushed, so however the tap and the
  /// engine's start interleave there is exactly one delivery.
  func takePendingPayload() -> String? {
    defer { pendingPayload = nil }
    return pendingPayload
  }

  func userNotificationCenter(
    _ center: UNUserNotificationCenter,
    willPresent notification: UNNotification,
    withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
  ) {
    if let delegate = flutterDelegate,
      delegate.responds(
        to: #selector(
          UNUserNotificationCenterDelegate.userNotificationCenter(_:willPresent:withCompletionHandler:)))
    {
      delegate.userNotificationCenter!(
        center, willPresent: notification, withCompletionHandler: completionHandler)
    } else {
      completionHandler([.banner, .list, .sound, .badge])
    }
  }

  func userNotificationCenter(
    _ center: UNUserNotificationCenter,
    didReceive response: UNNotificationResponse,
    withCompletionHandler completionHandler: @escaping () -> Void
  ) {
    if response.actionIdentifier == UNNotificationDefaultActionIdentifier,
      let payload = response.notification.request.content.userInfo["payload"] as? String
    {
      pendingPayload = payload
      // A poke, not the payload: a running engine collects it through
      // takePendingTap like every other path. Dropped harmlessly when no
      // engine is listening yet; startup collects it then.
      channel?.invokeMethod("tap", arguments: nil)
      completionHandler()
      return
    }
    if let delegate = flutterDelegate,
      delegate.responds(
        to: #selector(
          UNUserNotificationCenterDelegate.userNotificationCenter(_:didReceive:withCompletionHandler:)))
    {
      delegate.userNotificationCenter!(
        center, didReceive: response, withCompletionHandler: completionHandler)
    } else {
      completionHandler()
    }
  }
}

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  private let notificationTapRelay = NotificationTapRelay()

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

    let launched = super.application(application, didFinishLaunchingWithOptions: launchOptions)

    // After super, which is where FlutterAppDelegate makes itself the
    // delegate; still inside didFinishLaunching, as Apple requires for a tap
    // that launched the app to be delivered at all. The relay keeps Flutter's
    // delegate behind it for everything it does not take.
    notificationTapRelay.flutterDelegate = self
    UNUserNotificationCenter.current().delegate = notificationTapRelay

    return launched
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)

    guard let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "NightMailNotificationTap")
    else { return }
    let channel = FlutterMethodChannel(
      name: kNotificationTapChannel, binaryMessenger: registrar.messenger())
    channel.setMethodCallHandler { [weak self] call, result in
      switch call.method {
      case "takePendingTap":
        result(self?.notificationTapRelay.takePendingPayload())
      default:
        result(FlutterMethodNotImplemented)
      }
    }
    notificationTapRelay.channel = channel
  }
}
