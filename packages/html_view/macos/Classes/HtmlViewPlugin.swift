import FlutterMacOS
import AppKit

public class HtmlViewPlugin: NSObject, FlutterPlugin {

  private let messenger: FlutterBinaryMessenger
  private var views: [Int64: WebKitView] = [:]
  private var nextId: Int64 = 1

  init(messenger: FlutterBinaryMessenger) {
    self.messenger = messenger
  }

  public static func register(with registrar: FlutterPluginRegistrar) {
    let messenger = registrar.messenger
    let channel = FlutterMethodChannel(name: "html_view",
                                       binaryMessenger: messenger)
    let instance = HtmlViewPlugin(messenger: messenger)
    registrar.addMethodCallDelegate(instance, channel: channel)
  }

  public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "createView":
      let win = NSApplication.shared.windows.first(where: { $0.isKeyWindow })
             ?? NSApplication.shared.mainWindow
      guard let window = win, let contentView = window.contentView else {
        result(FlutterError(code: "no_window",
                            message: "No key window available", details: nil))
        return
      }
      let id = nextId
      nextId += 1
      let view = WebKitView(id: id, parentView: contentView, messenger: messenger)
      views[id] = view
      result(id)

    case "destroyView":
      if let id = call.arguments as? Int64 {
        views[id]?.dispose()
        views.removeValue(forKey: id)
      }
      result(nil)

    default:
      result(FlutterMethodNotImplemented)
    }
  }
}
