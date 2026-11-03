import EventKit
import Flutter
import UIKit
import UserNotifications

class SceneDelegate: FlutterSceneDelegate {
  // FlutterMethodChannel unregisters its handler in dealloc, so it must be kept
  // alive as an instance property or calls silently become MissingPluginException.
  private var badgeChannel: FlutterMethodChannel?
  private var eventKitChannel: FlutterMethodChannel?
  private var shareChannel: FlutterMethodChannel?
  private var didActivateObserver: NSObjectProtocol?
  private let eventStore = EKEventStore()

  override func scene(
    _ scene: UIScene,
    willConnectTo session: UISceneSession,
    options connectionOptions: UIScene.ConnectionOptions
  ) {
    super.scene(scene, willConnectTo: session, options: connectionOptions)

    guard let windowScene = scene as? UIWindowScene,
          let controller = windowScene.windows.first?.rootViewController as? FlutterViewController
    else { return }

    badgeChannel = FlutterMethodChannel(
      name: "au.com.sharpblue.nightmail/badge",
      binaryMessenger: controller.engine.binaryMessenger
    )
    badgeChannel?.setMethodCallHandler { call, result in
      guard call.method == "setBadgeCount" else {
        result(FlutterMethodNotImplemented)
        return
      }
      let count = call.arguments as? Int ?? 0
      if #available(iOS 16.0, *) {
        UNUserNotificationCenter.current().setBadgeCount(count) { _ in }
      } else {
        UIApplication.shared.applicationIconBadgeNumber = count
      }
      result(nil)
    }

    registerShareChannel(controller: controller)

    eventKitChannel = FlutterMethodChannel(
      name: "au.com.sharpblue.nightmail/eventkit",
      binaryMessenger: controller.engine.binaryMessenger
    )
    eventKitChannel?.setMethodCallHandler { [weak self] call, result in
      guard let self else { result(FlutterMethodNotImplemented); return }
      switch call.method {
      case "requestPermission":
        self.handleEventKitRequestPermission(result: result)
      case "getEvents":
        let args = call.arguments as? [String: Any] ?? [:]
        let startMs = (args["startMs"] as? NSNumber)?.int64Value ?? 0
        let endMs = (args["endMs"] as? NSNumber)?.int64Value ?? 0
        self.handleGetEvents(startMs: startMs, endMs: endMs, result: result)
      case "createEvent":
        let args = call.arguments as? [String: Any] ?? [:]
        self.handleCreateEvent(args: args, result: result)
      case "updateEvent":
        let args = call.arguments as? [String: Any] ?? [:]
        self.handleUpdateEvent(args: args, result: result)
      case "deleteEvent":
        let id = (call.arguments as? [String: Any])?["id"] as? String ?? ""
        self.handleDeleteEvent(id: id, result: result)
      case "deleteEventByUID":
        let uid = (call.arguments as? [String: Any])?["uid"] as? String ?? ""
        self.handleDeleteEventByUID(uid: uid, result: result)
      default:
        result(FlutterMethodNotImplemented)
      }
    }
  }

  // MARK: - EventKit channel
  //
  // Mirrors macos/Runner/MainFlutterWindow.swift's registerEventKitChannel —
  // no shared Swift target exists between the macOS and iOS runners in this
  // project, so this is a deliberate duplication, not a refactor. The only
  // difference is omitting NSApp.activate(ignoringOtherApps:) in the
  // permission handler, which has no iOS equivalent/need.

  private func handleEventKitRequestPermission(result: @escaping FlutterResult) {
    let status = EKEventStore.authorizationStatus(for: .event)
    switch status {
    case .authorized:
      result("granted")
      return
    case .denied, .restricted:
      result("permanentlyDenied")
      return
    default:
      break
    }

    if #available(iOS 17.0, *) {
      eventStore.requestFullAccessToEvents { granted, _ in
        DispatchQueue.main.async { result(granted ? "granted" : "denied") }
      }
    } else {
      eventStore.requestAccess(to: .event) { granted, _ in
        DispatchQueue.main.async { result(granted ? "granted" : "denied") }
      }
    }
  }

  private func handleGetEvents(startMs: Int64, endMs: Int64, result: @escaping FlutterResult) {
    guard EKEventStore.authorizationStatus(for: .event) == .authorized else {
      result([])
      return
    }
    DispatchQueue.global(qos: .userInitiated).async { [weak self] in
      guard let self else { result([]); return }
      let start = Date(timeIntervalSince1970: Double(startMs) / 1000.0)
      let end   = Date(timeIntervalSince1970: Double(endMs)   / 1000.0)
      let predicate = self.eventStore.predicateForEvents(
        withStart: start, end: end,
        calendars: self.eventStore.calendars(for: .event)
      )
      let events = self.eventStore.events(matching: predicate)
      let maps: [[String: Any]] = events.compactMap { e in
        guard let eid = e.eventIdentifier else { return nil }
        var m: [String: Any] = [
          "id":      eid,
          "title":   e.title ?? "",
          "startMs": Int64(e.startDate.timeIntervalSince1970 * 1000),
          "endMs":   Int64(e.endDate.timeIntervalSince1970   * 1000),
          "isAllDay": e.isAllDay,
        ]
        if let loc = e.location, !loc.isEmpty  { m["location"] = loc }
        if let notes = e.notes, !notes.isEmpty { m["notes"]    = notes }
        if let minutes = self.reminderMinutes(for: e) { m["reminderMinutes"] = minutes }
        return m
      }
      DispatchQueue.main.async { result(maps) }
    }
  }

  private func handleCreateEvent(args: [String: Any], result: @escaping FlutterResult) {
    guard EKEventStore.authorizationStatus(for: .event) == .authorized else {
      result(FlutterError(code: "PERMISSION_DENIED", message: "Calendar access not granted", details: nil))
      return
    }
    guard let defaultCalendar = eventStore.defaultCalendarForNewEvents else {
      result(FlutterError(code: "NO_CALENDAR", message: "No default calendar found", details: nil))
      return
    }
    let event = EKEvent(eventStore: eventStore)
    event.title    = args["title"]    as? String ?? ""
    event.isAllDay = args["isAllDay"] as? Bool   ?? false
    event.location = args["location"] as? String
    event.notes    = args["notes"]    as? String
    let startMs = (args["startMs"] as? NSNumber)?.int64Value ?? 0
    let endMs   = (args["endMs"]   as? NSNumber)?.int64Value ?? 0
    event.startDate = Date(timeIntervalSince1970: Double(startMs) / 1000.0)
    event.endDate   = Date(timeIntervalSince1970: Double(endMs)   / 1000.0)
    event.calendar  = defaultCalendar
    do {
      try eventStore.save(event, span: .thisEvent)
      result(self.eventMap(event))
    } catch {
      result(FlutterError(code: "SAVE_ERROR", message: error.localizedDescription, details: nil))
    }
  }

  private func handleUpdateEvent(args: [String: Any], result: @escaping FlutterResult) {
    let id = args["id"] as? String ?? ""
    guard let event = eventStore.event(withIdentifier: id) else {
      result(FlutterError(code: "NOT_FOUND", message: "Event not found: \(id)", details: nil))
      return
    }
    event.title    = args["title"]    as? String ?? event.title
    event.isAllDay = args["isAllDay"] as? Bool   ?? event.isAllDay
    event.location = args["location"] as? String
    event.notes    = args["notes"]    as? String
    if let startMs = (args["startMs"] as? NSNumber)?.int64Value {
      event.startDate = Date(timeIntervalSince1970: Double(startMs) / 1000.0)
    }
    if let endMs = (args["endMs"] as? NSNumber)?.int64Value {
      event.endDate = Date(timeIntervalSince1970: Double(endMs) / 1000.0)
    }
    do {
      try eventStore.save(event, span: .thisEvent)
      result(self.eventMap(event))
    } catch {
      result(FlutterError(code: "SAVE_ERROR", message: error.localizedDescription, details: nil))
    }
  }

  private func handleDeleteEvent(id: String, result: @escaping FlutterResult) {
    guard let event = eventStore.event(withIdentifier: id) else {
      result(nil)  // already gone
      return
    }
    do {
      try eventStore.remove(event, span: .thisEvent)
      result(nil)
    } catch {
      result(FlutterError(code: "DELETE_ERROR", message: error.localizedDescription, details: nil))
    }
  }

  private func handleDeleteEventByUID(uid: String, result: @escaping FlutterResult) {
    let items = eventStore.calendarItems(withExternalIdentifier: uid)
    var deleted = false
    for item in items {
      guard let event = item as? EKEvent else { continue }
      do {
        try eventStore.remove(event, span: .thisEvent)
        deleted = true
      } catch {}
    }
    if !deleted {
      // Event not in local store — treat as already removed.
    }
    result(nil)
  }

  private func eventMap(_ e: EKEvent) -> [String: Any] {
    var m: [String: Any] = [
      "id":       e.eventIdentifier as Any,
      "title":    e.title           as Any,
      "startMs":  Int64(e.startDate.timeIntervalSince1970 * 1000),
      "endMs":    Int64(e.endDate.timeIntervalSince1970   * 1000),
      "isAllDay": e.isAllDay,
    ]
    if let loc   = e.location, !loc.isEmpty   { m["location"] = loc }
    if let notes = e.notes,    !notes.isEmpty { m["notes"]    = notes }
    if let minutes = reminderMinutes(for: e)  { m["reminderMinutes"] = minutes }
    return m
  }

  /// Minutes before start of the earliest-firing alarm on [e], if any.
  /// EKAlarm.relativeOffset is negative for "before start", in seconds.
  private func reminderMinutes(for e: EKEvent) -> Int? {
    guard let alarms = e.alarms, !alarms.isEmpty else { return nil }
    let minutesValues = alarms.compactMap { alarm -> Int? in
      let offset = alarm.relativeOffset
      guard offset < 0 else { return nil }
      return Int((-offset / 60.0).rounded())
    }
    return minutesValues.max()
  }

  // MARK: - Share channel
  //
  // ShareExtension/ShareViewController.swift leaves what was shared in the App
  // Group container as share/pending.json and opens nightmail-share://. Dart
  // pulls it with takePendingShare; this side only pings shareReceived when one
  // may be waiting — on that URL, and whenever the app comes to the foreground,
  // which catches a share whose open-the-app step did not happen. See
  // docs/claude/share-target.md.

  private static let appGroupId = "group.au.com.sharpblue.nightmail"
  private static let shareScheme = "nightmail-share"

  private func registerShareChannel(controller: FlutterViewController) {
    shareChannel = FlutterMethodChannel(
      name: "au.com.sharpblue.nightmail/share_intent",
      binaryMessenger: controller.engine.binaryMessenger
    )
    shareChannel?.setMethodCallHandler { call, result in
      guard call.method == "takePendingShare" else {
        result(FlutterMethodNotImplemented)
        return
      }
      result(Self.takePendingShare())
    }
    didActivateObserver = NotificationCenter.default.addObserver(
      forName: UIScene.didActivateNotification, object: nil, queue: .main
    ) { [weak self] _ in
      if Self.pendingShareURL.map({ FileManager.default.fileExists(atPath: $0.path) }) == true {
        self?.shareChannel?.invokeMethod("shareReceived", arguments: nil)
      }
    }
  }

  override func scene(_ scene: UIScene, openURLContexts URLContexts: Set<UIOpenURLContext>) {
    if URLContexts.contains(where: { $0.url.scheme == Self.shareScheme }) {
      shareChannel?.invokeMethod("shareReceived", arguments: nil)
      return
    }
    super.scene(scene, openURLContexts: URLContexts)
  }

  private static var pendingShareURL: URL? {
    FileManager.default
      .containerURL(forSecurityApplicationGroupIdentifier: appGroupId)?
      .appendingPathComponent("share/pending.json")
  }

  /// The waiting share as the map Dart's SharedContent.fromMap reads, removed
  /// as it is taken. The files it names stay for Dart to read and delete.
  private static func takePendingShare() -> Any? {
    guard let url = pendingShareURL, let data = try? Data(contentsOf: url) else { return nil }
    try? FileManager.default.removeItem(at: url)
    return try? JSONSerialization.jsonObject(with: data)
  }
}
