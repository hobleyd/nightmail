import Cocoa
import Contacts
import FlutterMacOS
import desktop_multi_window

class MainFlutterWindow: NSWindow {
  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    let windowFrame = self.frame
    self.contentViewController = flutterViewController
    self.setFrame(windowFrame, display: true)

    RegisterGeneratedPlugins(registry: flutterViewController)

    // Register all plugins in any secondary window created by desktop_multi_window.
    FlutterMultiWindowPlugin.setOnWindowCreatedCallback { controller in
      RegisterGeneratedPlugins(registry: controller)
    }

    registerContactsChannel(messenger: flutterViewController.engine.binaryMessenger)

    let badgeChannel = FlutterMethodChannel(
      name: "au.com.sharpblue.nightmail/badge",
      binaryMessenger: flutterViewController.engine.binaryMessenger
    )
    badgeChannel.setMethodCallHandler { call, result in
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
    channel.setMethodCallHandler { call, result in
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
  }

  private func handleRequestPermission(result: @escaping FlutterResult) {
    let store = CNContactStore()
    let current = CNContactStore.authorizationStatus(for: .contacts)
    if current == .authorized {
      result("granted")
      return
    }
    store.requestAccess(for: .contacts) { _, _ in
      DispatchQueue.main.async {
        let status = CNContactStore.authorizationStatus(for: .contacts)
        result(status == .authorized ? "granted" : "denied")
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
