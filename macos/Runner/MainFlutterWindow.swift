import Cocoa
@preconcurrency import Contacts
import EventKit
import FlutterMacOS
import UserNotifications
import desktop_multi_window

class MainFlutterWindow: NSWindow, UNUserNotificationCenterDelegate {
  // Each window (main + every desktop_multi_window secondary window) gets its
  // own FlutterEngine and binary messenger, so we must register the contacts
  // channel on every messenger.  Channels must be stored — FlutterMethodChannel
  // unregisters its handler in dealloc, so letting one go out of scope silently
  // removes the handler and causes MissingPluginException.
  private var allChannels: [FlutterMethodChannel] = []
  private var calendarNotifyChannels: [FlutterMethodChannel] = []
  private var draftsRefreshChannels: [FlutterMethodChannel] = []
  private var badgeChannel: FlutterMethodChannel?
  private var mainNotificationChannel: FlutterMethodChannel?
  private var systemEventsChannel: FlutterMethodChannel?
  private var appLifecycleChannel: FlutterMethodChannel?
  private let eventStore = EKEventStore()

  // Cmd-Q sends -[NSApplication terminate:] straight to the app delegate's
  // applicationShouldTerminate(_:) — it does NOT go through this window's
  // windowShouldClose, so AppDelegate needs a way to reach back into the main
  // window's Flutter engine to ask Dart to shut down cleanly first.
  static weak var shared: MainFlutterWindow?

  /// Asks the Dart side to run its graceful-shutdown path (closing the drift
  /// cache database, saving window state) before the process is allowed to
  /// terminate. Calls [completion] once Dart replies, or immediately if the
  /// channel isn't available.
  func notifyWillTerminate(completion: @escaping () -> Void) {
    guard let channel = appLifecycleChannel else {
      completion()
      return
    }
    channel.invokeMethod("applicationWillTerminate", arguments: nil) { _ in
      completion()
    }
  }

  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    let windowFrame = self.frame
    self.contentViewController = flutterViewController
    self.setFrame(windowFrame, display: true)

    RegisterGeneratedPlugins(registry: flutterViewController)
    registerContactsChannel(messenger: flutterViewController.engine.binaryMessenger)
    registerEventKitChannel(messenger: flutterViewController.engine.binaryMessenger)

    // Register the notification channel on the main window only.
    // Reminder popups are always created from the main Flutter engine.
    mainNotificationChannel = FlutterMethodChannel(
      name: "au.com.sharpblue.nightmail/notifications",
      binaryMessenger: flutterViewController.engine.binaryMessenger
    )
    mainNotificationChannel?.setMethodCallHandler { [weak self] call, result in
      guard let self else { result(FlutterMethodNotImplemented); return }
      switch call.method {
      case "requestPermission":
        self.handleNotificationPermission(result: result)
      case "showMailNotification":
        let args = call.arguments as? [String: Any] ?? [:]
        self.handleShowMailNotification(args: args, result: result)
      case "showTaskNotification":
        let args = call.arguments as? [String: Any] ?? [:]
        self.handleShowTaskNotification(args: args, result: result)
      case "showTasksSummaryNotification":
        let args = call.arguments as? [String: Any] ?? [:]
        self.handleShowTasksSummaryNotification(args: args, result: result)
      case "scheduleReminder":
        let args = call.arguments as? [String: Any] ?? [:]
        self.handleScheduleReminder(args: args, result: result)
      case "cancelReminder":
        let args = call.arguments as? [String: Any] ?? [:]
        self.handleCancelReminder(args: args, result: result)
      default:
        result(FlutterMethodNotImplemented)
      }
    }
    if let ch = mainNotificationChannel { allChannels.append(ch) }

    // Set this window as the UNUserNotificationCenter delegate so we receive
    // foreground and tap callbacks.
    UNUserNotificationCenter.current().delegate = self

    // Register the main window's calendar refresh channel for broadcasting eventSaved into Flutter.
    let mainCalendarChannel = FlutterMethodChannel(
      name: "au.com.sharpblue.nightmail/calendar_refresh",
      binaryMessenger: flutterViewController.engine.binaryMessenger
    )
    calendarNotifyChannels.append(mainCalendarChannel)
    allChannels.append(mainCalendarChannel)

    // Register the main window's drafts refresh channel for broadcasting draftChanged into Flutter.
    let mainDraftsChannel = FlutterMethodChannel(
      name: "au.com.sharpblue.nightmail/drafts_refresh",
      binaryMessenger: flutterViewController.engine.binaryMessenger
    )
    draftsRefreshChannels.append(mainDraftsChannel)
    allChannels.append(mainDraftsChannel)

    registerWindowUtilsChannel(messenger: flutterViewController.engine.binaryMessenger) { [weak self] in self }

    // Register contacts + plugins for every secondary window too.
    FlutterMultiWindowPlugin.setOnWindowCreatedCallback { [weak self] controller in
      RegisterGeneratedPlugins(registry: controller)
      self?.registerContactsChannel(messenger: controller.engine.binaryMessenger)
      self?.registerEventKitChannel(messenger: controller.engine.binaryMessenger)
      self?.registerCalendarRefreshRelay(messenger: controller.engine.binaryMessenger)
      self?.registerDraftsRefreshRelay(messenger: controller.engine.binaryMessenger)
      self?.registerNotificationRelay(messenger: controller.engine.binaryMessenger)
      self?.registerWindowUtilsChannel(
        messenger: controller.engine.binaryMessenger,
        windowProvider: { [weak controller] in controller?.view.window }
      )
      self?.registerDesktopDrop(on: controller)
    }

    badgeChannel = FlutterMethodChannel(
      name: "au.com.sharpblue.nightmail/badge",
      binaryMessenger: flutterViewController.engine.binaryMessenger
    )
    badgeChannel?.setMethodCallHandler { call, result in
      if call.method == "setBadgeCount" {
        let count = call.arguments as? Int ?? 0
        NSApp.dockTile.badgeLabel = count > 0 ? "\(count)" : nil
        result(nil)
      } else {
        result(FlutterMethodNotImplemented)
      }
    }

    systemEventsChannel = FlutterMethodChannel(
      name: "au.com.sharpblue.nightmail/system_events",
      binaryMessenger: flutterViewController.engine.binaryMessenger
    )
    NSWorkspace.shared.notificationCenter.addObserver(
      forName: NSWorkspace.didWakeNotification,
      object: nil,
      queue: .main
    ) { [weak self] _ in
      self?.systemEventsChannel?.invokeMethod("systemDidWake", arguments: nil)
    }

    appLifecycleChannel = FlutterMethodChannel(
      name: "au.com.sharpblue.nightmail/app_lifecycle",
      binaryMessenger: flutterViewController.engine.binaryMessenger
    )
    MainFlutterWindow.shared = self

    super.awakeFromNib()
  }

  // MARK: - UNUserNotificationCenter

  private func handleNotificationPermission(result: @escaping FlutterResult) {
    UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { granted, _ in
      DispatchQueue.main.async { result(granted ? "granted" : "denied") }
    }
  }

  private func handleShowMailNotification(args: [String: Any], result: @escaping FlutterResult) {
    let id        = args["id"]        as? String ?? ""
    let title     = args["title"]     as? String ?? ""
    let body      = args["body"]      as? String ?? ""
    let emailId   = args["emailId"]   as? String ?? id
    let accountId = args["accountId"] as? String ?? ""

    let content       = UNMutableNotificationContent()
    content.title     = title
    content.body      = body
    content.sound     = .default
    content.userInfo  = ["type": "email", "emailId": emailId, "accountId": accountId]

    // Use a time-interval trigger of 0.1s — UNUserNotificationCenter requires
    // a trigger; immediate display is not supported.
    let trigger = UNTimeIntervalNotificationTrigger(timeInterval: 0.1, repeats: false)
    let request = UNNotificationRequest(
      identifier: "new_email_\(emailId)",
      content: content,
      trigger: trigger
    )
    UNUserNotificationCenter.current().add(request) { _ in
      DispatchQueue.main.async { result(nil) }
    }
  }

  private func handleShowTaskNotification(args: [String: Any], result: @escaping FlutterResult) {
    let id        = args["id"]        as? String ?? ""
    let title     = args["title"]     as? String ?? ""
    let body      = args["body"]      as? String ?? ""
    let taskId    = args["taskId"]    as? String ?? ""
    let listId    = args["listId"]    as? String ?? ""
    let accountId = args["accountId"] as? String ?? ""

    let content       = UNMutableNotificationContent()
    content.title     = title
    content.body      = body
    content.sound     = .default
    content.userInfo  = [
      "type": "task", "taskId": taskId, "listId": listId, "accountId": accountId,
    ]

    let trigger = UNTimeIntervalNotificationTrigger(timeInterval: 0.1, repeats: false)
    let request = UNNotificationRequest(
      identifier: "task_reminder_\(id)",
      content: content,
      trigger: trigger
    )
    UNUserNotificationCenter.current().add(request) { _ in
      DispatchQueue.main.async { result(nil) }
    }
  }

  private func handleShowTasksSummaryNotification(args: [String: Any], result: @escaping FlutterResult) {
    let id        = args["id"]        as? String ?? ""
    let title     = args["title"]     as? String ?? ""
    let body      = args["body"]      as? String ?? ""
    let accountId = args["accountId"] as? String ?? ""

    let content       = UNMutableNotificationContent()
    content.title     = title
    content.body      = body
    content.sound     = .default
    content.userInfo  = ["type": "tasksSummary", "accountId": accountId]

    let trigger = UNTimeIntervalNotificationTrigger(timeInterval: 0.1, repeats: false)
    let request = UNNotificationRequest(
      identifier: "tasks_summary_\(id)",
      content: content,
      trigger: trigger
    )
    UNUserNotificationCenter.current().add(request) { _ in
      DispatchQueue.main.async { result(nil) }
    }
  }

  /// Schedules a calendar reminder ("event", the default) or a task due alert
  /// ("task", passed as `kind`). The two differ only in the userInfo they
  /// carry — which decides the tap route — and in the identifier namespace, so
  /// a cancel for one kind can never remove the other's pending request.
  private func handleScheduleReminder(args: [String: Any], result: @escaping FlutterResult) {
    let id        = args["id"]       as? String ?? ""
    let kind      = args["kind"]     as? String ?? "event"
    let title     = args["title"]    as? String ?? ""
    let body      = args["body"]     as? String ?? ""
    let triggerMs = (args["triggerMs"] as? NSNumber)?.int64Value ?? 0

    let triggerDate = Date(timeIntervalSince1970: Double(triggerMs) / 1000.0)
    let interval    = triggerDate.timeIntervalSinceNow
    guard interval > 0 else { result(nil); return }

    let content       = UNMutableNotificationContent()
    content.title     = title
    content.body      = body
    content.sound     = .default

    var userInfo: [String: Any]
    if kind == "task" {
      userInfo = [
        "type": "task",
        "taskId": args["taskId"] as? String ?? "",
        "listId": args["listId"] as? String ?? "",
        "accountId": args["accountId"] as? String ?? "",
      ]
    } else {
      userInfo = [
        "type": "reminder",
        "eventId": args["eventId"] as? String ?? id,
        "eventTitle": title,
      ]
      if let iso = args["startIso"] as? String { userInfo["startIso"] = iso }
      // A reminder is one alert in a series counting down to the start. The
      // countdown travels with the request so the in-app popup can show it,
      // and `popup` marks the alerts that warrant opening that popup at all
      // (the first and the last) rather than only a banner. Defaults to true
      // for a request scheduled before those keys existed.
      if let mins = args["minutesUntilStart"] as? NSNumber {
        userInfo["minutesUntilStart"] = mins.intValue
      }
      userInfo["popup"] = (args["popup"] as? Bool) ?? true
    }
    content.userInfo  = userInfo

    let trigger = UNTimeIntervalNotificationTrigger(timeInterval: interval, repeats: false)
    let request = UNNotificationRequest(
      identifier: "\(kind)_reminder_\(id)",
      content: content,
      trigger: trigger
    )

    UNUserNotificationCenter.current().add(request) { error in
      DispatchQueue.main.async {
        if let e = error {
          result(FlutterError(code: "SCHEDULE_ERROR", message: e.localizedDescription, details: nil))
        } else {
          result(nil)
        }
      }
    }
  }

  /// Removes pending alerts by id. A calendar reminder is a *series* — the
  /// lead-time alert plus a countdown to the start — so `ids` cancels the whole
  /// set in one call; `id` is the single-alert form task reminders use.
  private func handleCancelReminder(args: [String: Any], result: @escaping FlutterResult) {
    let kind = args["kind"] as? String ?? "event"
    let ids  = (args["ids"] as? [String]) ?? [args["id"] as? String ?? ""]
    UNUserNotificationCenter.current().removePendingNotificationRequests(
      withIdentifiers: ids.map { "\(kind)_reminder_\($0)" }
    )
    result(nil)
  }

  // Called when a notification is delivered while the app is in the foreground.
  func userNotificationCenter(
    _ center: UNUserNotificationCenter,
    willPresent notification: UNNotification,
    withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
  ) {
    let userInfo = notification.request.content.userInfo
    let type = userInfo["type"] as? String

    if type == "reminder", (userInfo["popup"] as? Bool) ?? true {
      // For calendar reminders fired in-app, show the existing popup so the
      // user can dismiss it without leaving what they're doing. Only the first
      // and last alert of a series carry `popup` — the countdown between them
      // stays a banner, so a meeting cannot pile up a stack of these windows.
      let eventId    = userInfo["eventId"]    as? String ?? ""
      let eventTitle = userInfo["eventTitle"] as? String ?? ""
      let startIso   = userInfo["startIso"]   as? String
      var args: [String: Any] = ["eventId": eventId, "eventTitle": eventTitle]
      if let iso = startIso { args["startIso"] = iso }
      if let mins = userInfo["minutesUntilStart"] as? Int {
        args["minutesUntilStart"] = mins
      }
      mainNotificationChannel?.invokeMethod("showReminderPopup", arguments: args)
    }

    if #available(macOS 11.0, *) {
      completionHandler([.banner, .sound])
    } else {
      completionHandler([.alert, .sound])
    }
  }

  // Called when the user taps a delivered notification (app was in background or closed).
  func userNotificationCenter(
    _ center: UNUserNotificationCenter,
    didReceive response: UNNotificationResponse,
    withCompletionHandler completionHandler: @escaping () -> Void
  ) {
    NSApp.activate(ignoringOtherApps: true)
    let userInfo = response.notification.request.content.userInfo
    let type = userInfo["type"] as? String

    if type == "email" {
      let emailId   = userInfo["emailId"]   as? String ?? ""
      let accountId = userInfo["accountId"] as? String ?? ""
      mainNotificationChannel?.invokeMethod(
        "openEmail",
        arguments: ["emailId": emailId, "accountId": accountId]
      )
    } else if type == "task" {
      let taskId    = userInfo["taskId"]    as? String ?? ""
      let listId    = userInfo["listId"]    as? String ?? ""
      let accountId = userInfo["accountId"] as? String ?? ""
      mainNotificationChannel?.invokeMethod(
        "openTask",
        arguments: ["taskId": taskId, "listId": listId, "accountId": accountId]
      )
    } else if type == "tasksSummary" {
      let accountId = userInfo["accountId"] as? String ?? ""
      mainNotificationChannel?.invokeMethod(
        "openTasks",
        arguments: ["accountId": accountId]
      )
    } else {
      // Calendar reminder tap (or legacy notification without a type).
      let eventId  = userInfo["eventId"]  as? String ?? ""
      let startIso = userInfo["startIso"] as? String
      var args: [String: Any] = ["eventId": eventId]
      if let iso = startIso { args["startIso"] = iso }
      mainNotificationChannel?.invokeMethod("openCalendarEvent", arguments: args)
    }
    completionHandler()
  }

  // MARK: - Calendar refresh relay

  private func registerCalendarRefreshRelay(messenger: FlutterBinaryMessenger) {
    let channel = FlutterMethodChannel(
      name: "au.com.sharpblue.nightmail/calendar_refresh",
      binaryMessenger: messenger
    )
    channel.setMethodCallHandler { [weak self] call, result in
      if call.method == "notifyEventSaved" {
        // Broadcast eventSaved to all registered Flutter engines.
        self?.calendarNotifyChannels.forEach { $0.invokeMethod("eventSaved", arguments: nil) }
        result(nil)
      } else {
        result(FlutterMethodNotImplemented)
      }
    }
    calendarNotifyChannels.append(channel)
    allChannels.append(channel)
  }

  // MARK: - Drafts refresh relay

  private func registerDraftsRefreshRelay(messenger: FlutterBinaryMessenger) {
    let channel = FlutterMethodChannel(
      name: "au.com.sharpblue.nightmail/drafts_refresh",
      binaryMessenger: messenger
    )
    channel.setMethodCallHandler { [weak self] call, result in
      if call.method == "notifyDraftChanged" {
        // Broadcast draftChanged to all registered Flutter engines.
        self?.draftsRefreshChannels.forEach { $0.invokeMethod("draftChanged", arguments: nil) }
        result(nil)
      } else {
        result(FlutterMethodNotImplemented)
      }
    }
    draftsRefreshChannels.append(channel)
    allChannels.append(channel)
  }

  // MARK: - Notification relay for secondary windows

  /// Registers a notifications channel on a secondary window's messenger so that
  /// scheduleReminder / cancelReminder calls from those windows reach the same Swift
  /// handlers.  showReminderPopup is always *invoked* from mainNotificationChannel,
  /// never handled here.
  private func registerNotificationRelay(messenger: FlutterBinaryMessenger) {
    let channel = FlutterMethodChannel(
      name: "au.com.sharpblue.nightmail/notifications",
      binaryMessenger: messenger
    )
    channel.setMethodCallHandler { [weak self] call, result in
      guard let self else { result(FlutterMethodNotImplemented); return }
      switch call.method {
      case "showMailNotification":
        let args = call.arguments as? [String: Any] ?? [:]
        self.handleShowMailNotification(args: args, result: result)
      case "showTaskNotification":
        let args = call.arguments as? [String: Any] ?? [:]
        self.handleShowTaskNotification(args: args, result: result)
      case "showTasksSummaryNotification":
        let args = call.arguments as? [String: Any] ?? [:]
        self.handleShowTasksSummaryNotification(args: args, result: result)
      case "scheduleReminder":
        let args = call.arguments as? [String: Any] ?? [:]
        self.handleScheduleReminder(args: args, result: result)
      case "cancelReminder":
        let args = call.arguments as? [String: Any] ?? [:]
        self.handleCancelReminder(args: args, result: result)
      default:
        result(FlutterMethodNotImplemented)
      }
    }
    allChannels.append(channel)
  }

  // MARK: - EventKit channel

  private func registerEventKitChannel(messenger: FlutterBinaryMessenger) {
    let channel = FlutterMethodChannel(
      name: "au.com.sharpblue.nightmail/eventkit",
      binaryMessenger: messenger
    )
    channel.setMethodCallHandler { [weak self] call, result in
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
      case "deleteEventSeries":
        let id = (call.arguments as? [String: Any])?["id"] as? String ?? ""
        self.handleDeleteEventSeries(id: id, result: result)
      case "deleteEventByUID":
        let uid = (call.arguments as? [String: Any])?["uid"] as? String ?? ""
        self.handleDeleteEventByUID(uid: uid, result: result)
      default:
        result(FlutterMethodNotImplemented)
      }
    }
    allChannels.append(channel)
  }

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

    if #available(macOS 14.0, *) {
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

  private func handleDeleteEventSeries(id: String, result: @escaping FlutterResult) {
    guard let event = eventStore.event(withIdentifier: id) else {
      result(nil)  // already gone
      return
    }
    do {
      try eventStore.remove(event, span: .futureEvents)
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

  // MARK: - Contacts channel

  private func registerContactsChannel(messenger: FlutterBinaryMessenger) {
    let channel = FlutterMethodChannel(
      name: "au.com.sharpblue.nightmail/contacts",
      binaryMessenger: messenger
    )
    channel.setMethodCallHandler { [weak self] call, result in
      guard let self else { result(FlutterMethodNotImplemented); return }
      switch call.method {
      case "requestPermission":
        self.handleRequestPermission(result: result)
      case "search":
        let query = (call.arguments as? [String: Any])?["query"] as? String ?? ""
        self.handleSearch(query: query, result: result)
      case "fetchAll":
        self.handleFetchAll(result: result)
      default:
        result(FlutterMethodNotImplemented)
      }
    }
    allChannels.append(channel)
  }

  private func handleRequestPermission(result: @escaping FlutterResult) {
    Task { @MainActor in
      let current = CNContactStore.authorizationStatus(for: .contacts)
      NSLog("[NightMail] CNContactStore status raw=%d", current.rawValue)

      switch current {
      case .authorized:
        result("granted")
        return
      case .denied:
        result("permanentlyDenied")
        return
      case .restricted:
        result("permanentlyDenied")
        return
      default:
        break
      }

      // Bring the app to the front so macOS can show the permission dialog.
      NSApp.activate(ignoringOtherApps: true)

      let store = CNContactStore()
      // Named completionHandler: label selects the completion-handler overload without a cast.
      // The async/await form throws CNError.authorizationDenied on macOS 15 for notDetermined apps.
      store.requestAccess(for: .contacts, completionHandler: { granted, error in
        DispatchQueue.main.async {
          let after = CNContactStore.authorizationStatus(for: .contacts)
          if let e = error as? NSError {
            NSLog("[NightMail] CNContactStore requestAccess error: domain=%@ code=%d desc=%@",
                  e.domain, e.code, e.localizedDescription)
          }
          NSLog("[NightMail] CNContactStore after requestAccess: granted=%d raw=%d",
                granted ? 1 : 0, after.rawValue)
          result(granted ? "granted" : "denied")
        }
      })
    }
  }

  // MARK: - Window utilities channel

  private func registerWindowUtilsChannel(
    messenger: FlutterBinaryMessenger,
    windowProvider: @escaping () -> NSWindow?
  ) {
    let channel = FlutterMethodChannel(
      name: "au.com.sharpblue.nightmail/window_utils",
      binaryMessenger: messenger
    )
    channel.setMethodCallHandler { call, result in
      if call.method == "getMyScreenInfo" {
        let screen = windowProvider()?.screen ?? NSScreen.screens.first
        let frame = screen?.visibleFrame ?? .zero
        guard !NSScreen.screens.isEmpty else { result(nil); return }
        let mainScreenHeight = NSScreen.screens[0].frame.height
        result([
          "x": frame.origin.x,
          "y": frame.origin.y,
          "width": frame.size.width,
          "height": frame.size.height,
          "mainScreenHeight": mainScreenHeight,
        ])
      } else {
        result(FlutterMethodNotImplemented)
      }
    }
    allChannels.append(channel)
  }

  // MARK: - desktop_drop secondary window fix

  private func registerDesktopDrop(on viewController: FlutterViewController) {
    let channel = FlutterMethodChannel(
      name: "desktop_drop",
      binaryMessenger: viewController.engine.binaryMessenger
    )
    let overlay = SecondaryWindowDropOverlay(frame: viewController.view.bounds, channel: channel)
    overlay.autoresizingMask = [.width, .height]
    viewController.view.addSubview(overlay)
  }

  private func handleSearch(query: String, result: @escaping FlutterResult) {
    // Substring filter applied during enumeration, matching the Dart-side
    // fallback path. Only reached before the contact cache has been populated
    // or when compose has no account selected; the typeahead normally reads
    // the cache that fetchAll fills.
    let q = query.lowercased()
    enumerateContacts(result: result) { displayName, address in
      address.lowercased().contains(q) || displayName.lowercased().contains(q)
    }
  }

  /// Returns the whole address book for the daily contact-cache refresh, so
  /// the typeahead never has to walk CNContactStore on a keystroke.
  private func handleFetchAll(result: @escaping FlutterResult) {
    enumerateContacts(result: result) { _, _ in true }
  }

  /// Walks CNContactStore off the main thread, emitting one `(name, address)`
  /// entry per email address that passes `include`. Replies on the main
  /// thread, as FlutterResult requires.
  private func enumerateContacts(
    result: @escaping FlutterResult,
    include: @escaping (String, String) -> Bool
  ) {
    guard CNContactStore.authorizationStatus(for: .contacts) == .authorized else {
      result([])
      return
    }
    DispatchQueue.global(qos: .userInitiated).async {
      let store = CNContactStore()
      let keysToFetch: [CNKeyDescriptor] = [
        CNContactGivenNameKey as CNKeyDescriptor,
        CNContactFamilyNameKey as CNKeyDescriptor,
        CNContactOrganizationNameKey as CNKeyDescriptor,
        CNContactEmailAddressesKey as CNKeyDescriptor,
      ]
      let fetchRequest = CNContactFetchRequest(keysToFetch: keysToFetch)
      var matches: [[String: String]] = []
      try? store.enumerateContacts(with: fetchRequest) { contact, _ in
        // Company entries in the address book have no given/family name, so
        // fall back to the organisation rather than showing a bare address.
        var displayName = [contact.givenName, contact.familyName]
          .filter { !$0.isEmpty }
          .joined(separator: " ")
        if displayName.isEmpty {
          displayName = contact.organizationName
        }
        for email in contact.emailAddresses {
          let address = email.value as String
          if include(displayName, address) {
            matches.append(["address": address, "name": displayName])
          }
        }
      }
      DispatchQueue.main.async {
        result(matches)
      }
    }
  }
}

// desktop_drop's DesktopDropPlugin.register(with:) always installs its drag overlay on
// app.mainFlutterWindow, so secondary desktop_multi_window windows never receive drop
// events.  This NSView replicates the plugin's DropTarget and is installed manually on
// each secondary FlutterViewController's view by registerDesktopDrop(on:).
private class SecondaryWindowDropOverlay: NSView {
  private let channel: FlutterMethodChannel

  private lazy var destinationURL: URL = {
    let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("Drops")
    try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true, attributes: nil)
    return url
  }()

  private lazy var workQueue: OperationQueue = {
    let q = OperationQueue()
    q.qualityOfService = .userInitiated
    return q
  }()

  init(frame: NSRect, channel: FlutterMethodChannel) {
    self.channel = channel
    super.init(frame: frame)
    registerForDraggedTypes(
      NSFilePromiseReceiver.readableDraggedTypes.map { NSPasteboard.PasteboardType($0) }
      + [.fileURL]
    )
  }

  required init?(coder: NSCoder) { fatalError() }

  override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
    channel.invokeMethod("entered", arguments: flutterPoint(sender.draggingLocation))
    return .copy
  }

  override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
    channel.invokeMethod("updated", arguments: flutterPoint(sender.draggingLocation))
    return .copy
  }

  override func draggingExited(_ sender: NSDraggingInfo?) {
    channel.invokeMethod("exited", arguments: nil)
  }

  override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
    var urls = [String]()
    let searchOptions: [NSPasteboard.ReadingOptionKey: Any] = [.urlReadingFileURLsOnly: true]
    let group = DispatchGroup()

    sender.enumerateDraggingItems(
      options: [], for: nil,
      classes: [NSFilePromiseReceiver.self, NSURL.self],
      searchOptions: searchOptions
    ) { item, _, _ in
      switch item.item {
      case let receiver as NSFilePromiseReceiver:
        group.enter()
        receiver.receivePromisedFiles(
          atDestination: self.destinationURL, options: [:],
          operationQueue: self.workQueue
        ) { fileURL, error in
          if error == nil { urls.append(fileURL.path) }
          group.leave()
        }
      case let url as URL:
        urls.append(url.path)
      default:
        break
      }
    }

    group.notify(queue: .main) {
      self.channel.invokeMethod("performOperation", arguments: urls)
    }
    return true
  }

  private func flutterPoint(_ location: NSPoint) -> [CGFloat] {
    [location.x, bounds.height - location.y]
  }
}
