import Cocoa
import Contacts
import FlutterMacOS
import desktop_multi_window

class MainFlutterWindow: NSWindow {
  // Each window (main + every desktop_multi_window secondary window) gets its
  // own FlutterEngine and binary messenger, so we must register the contacts
  // channel on every messenger.  Channels must be stored — FlutterMethodChannel
  // unregisters its handler in dealloc, so letting one go out of scope silently
  // removes the handler and causes MissingPluginException.
  private var allChannels: [FlutterMethodChannel] = []
  private var calendarNotifyChannels: [FlutterMethodChannel] = []
  private var badgeChannel: FlutterMethodChannel?

  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    let windowFrame = self.frame
    self.contentViewController = flutterViewController
    self.setFrame(windowFrame, display: true)

    RegisterGeneratedPlugins(registry: flutterViewController)
    registerContactsChannel(messenger: flutterViewController.engine.binaryMessenger)

    // Register the main window's calendar refresh channel for broadcasting eventSaved into Flutter.
    let mainCalendarChannel = FlutterMethodChannel(
      name: "au.com.sharpblue.nightmail/calendar_refresh",
      binaryMessenger: flutterViewController.engine.binaryMessenger
    )
    calendarNotifyChannels.append(mainCalendarChannel)
    allChannels.append(mainCalendarChannel)

    // Register contacts + plugins for every secondary window too.
    FlutterMultiWindowPlugin.setOnWindowCreatedCallback { [weak self] controller in
      RegisterGeneratedPlugins(registry: controller)
      self?.registerContactsChannel(messenger: controller.engine.binaryMessenger)
      self?.registerCalendarRefreshRelay(messenger: controller.engine.binaryMessenger)
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

    super.awakeFromNib()
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
      // Use the completion-handler form — more reliable on macOS 15 than async/await.
      store.requestAccess(for: .contacts) { granted, error in
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
      }
    }
  }

  private func handleSearch(query: String, result: @escaping FlutterResult) {
    let status = CNContactStore.authorizationStatus(for: .contacts)
    guard status == .authorized else {
      result([])
      return
    }
    DispatchQueue.global(qos: .userInitiated).async {
      let store = CNContactStore()
      let keysToFetch: [CNKeyDescriptor] = [
        CNContactGivenNameKey as CNKeyDescriptor,
        CNContactFamilyNameKey as CNKeyDescriptor,
        CNContactEmailAddressesKey as CNKeyDescriptor,
      ]
      let fetchRequest = CNContactFetchRequest(keysToFetch: keysToFetch)
      let q = query.lowercased()
      var matches: [[String: String]] = []
      try? store.enumerateContacts(with: fetchRequest) { contact, _ in
        let displayName = [contact.givenName, contact.familyName]
          .filter { !$0.isEmpty }
          .joined(separator: " ")
        for email in contact.emailAddresses {
          let address = email.value as String
          if address.lowercased().contains(q) || displayName.lowercased().contains(q) {
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
