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
  private var badgeChannel: FlutterMethodChannel?

  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    let windowFrame = self.frame
    self.contentViewController = flutterViewController
    self.setFrame(windowFrame, display: true)

    RegisterGeneratedPlugins(registry: flutterViewController)
    registerContactsChannel(messenger: flutterViewController.engine.binaryMessenger)

    // Register contacts + plugins for every secondary window too.
    FlutterMultiWindowPlugin.setOnWindowCreatedCallback { [weak self] controller in
      RegisterGeneratedPlugins(registry: controller)
      self?.registerContactsChannel(messenger: controller.engine.binaryMessenger)
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
    let store = CNContactStore()
    let current = CNContactStore.authorizationStatus(for: .contacts)
    NSLog("[NightMail] CNContactStore status raw=%d name=%@",
          current.rawValue, statusName(current))
    switch current {
    case .authorized:
      result("granted")
    case .denied:
      result("permanentlyDenied")
    case .restricted:
      // .restricted = system-level block (Screen Time, MDM, or macOS refusing
      // to prompt for this process).  Try requestAccess anyway — on some macOS
      // versions it can still show a dialog even when the status reads restricted.
      store.requestAccess(for: .contacts) { _, _ in
        DispatchQueue.main.async {
          let after = CNContactStore.authorizationStatus(for: .contacts)
          NSLog("[NightMail] CNContactStore after requestAccess: raw=%d name=%@",
                after.rawValue, self.statusName(after))
          result(after == .authorized ? "granted" : "permanentlyDenied")
        }
      }
    default:
      store.requestAccess(for: .contacts) { _, _ in
        DispatchQueue.main.async {
          let after = CNContactStore.authorizationStatus(for: .contacts)
          NSLog("[NightMail] CNContactStore after requestAccess: raw=%d name=%@",
                after.rawValue, self.statusName(after))
          result(after == .authorized ? "granted" : "denied")
        }
      }
    }
  }

  private func statusName(_ s: CNAuthorizationStatus) -> String {
    switch s {
    case .notDetermined: return "notDetermined"
    case .restricted:    return "restricted"
    case .denied:        return "denied"
    case .authorized:    return "authorized"
    @unknown default:    return "unknown(\(s.rawValue))"
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
