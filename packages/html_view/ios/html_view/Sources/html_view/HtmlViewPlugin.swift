import Flutter
import UIKit

public class HtmlViewPlugin: NSObject, FlutterPlugin {

  private let messenger: FlutterBinaryMessenger
  private var views: [Int64: WebKitView] = [:]
  private var nextId: Int64 = 1

  init(messenger: FlutterBinaryMessenger) {
    self.messenger = messenger
  }

  public static func register(with registrar: FlutterPluginRegistrar) {
    let messenger = registrar.messenger()
    let channel = FlutterMethodChannel(name: "html_view",
                                       binaryMessenger: messenger)
    let instance = HtmlViewPlugin(messenger: messenger)
    registrar.addMethodCallDelegate(instance, channel: channel)
  }

  public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "createView":
      // Resolve the key window, avoiding the deprecated keyWindow property.
      let keyWindow = UIApplication.shared.windows.first(where: { $0.isKeyWindow })
      guard let vc = keyWindow?.rootViewController else {
        result(FlutterError(code: "no_root_vc",
                            message: "No root view controller", details: nil))
        return
      }
      let id = nextId
      nextId += 1
      let view = WebKitView(id: id, parentView: vc.view, messenger: messenger)
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
