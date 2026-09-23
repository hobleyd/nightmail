import WebKit
import Flutter

private let kJsBridge = """
(function() {
  function makeChannel(name) {
    return { postMessage: function(v) {
      window.webkit.messageHandlers.HtmlView.postMessage(
        name + '\\x00' + (v !== undefined ? String(v) : '')
      );
    }};
  }
  window['onContentChanged'] = makeChannel('onContentChanged');
  window['onLinkRequest']    = makeChannel('onLinkRequest');
  window['onImagePasted']    = makeChannel('onImagePasted');
  document.addEventListener('DOMContentLoaded', function() {
    window.webkit.messageHandlers.HtmlView.postMessage('pageLoaded\\x00');
  });
})();
"""

class WebKitView: NSObject, WKScriptMessageHandler, FlutterStreamHandler, WKNavigationDelegate {

  private let id: Int64
  private let webView: WKWebView
  private weak var parentView: UIView?
  private let channel: FlutterMethodChannel
  private let eventChannel: FlutterEventChannel
  private var eventSink: FlutterEventSink?

  // Logical-pixel position/size — UIKit uses points (same origin as Flutter).
  private var posX: CGFloat = 0
  private var posY: CGFloat = 0
  private var width: CGFloat = 0
  private var height: CGFloat = 0

  init(id: Int64, parentView: UIView, messenger: FlutterBinaryMessenger) {
    self.id = id
    self.parentView = parentView

    let config = WKWebViewConfiguration()
    let contentController = WKUserContentController()

    let script = WKUserScript(source: kJsBridge,
                               injectionTime: .atDocumentStart,
                               forMainFrameOnly: true)
    contentController.addUserScript(script)
    config.userContentController = contentController

    webView = WKWebView(frame: .zero, configuration: config)

    channel = FlutterMethodChannel(name: "html_view/\(id)",
                                   binaryMessenger: messenger)
    eventChannel = FlutterEventChannel(name: "html_view/\(id)_events",
                                       binaryMessenger: messenger)

    super.init()

    webView.navigationDelegate = self
    contentController.add(self, name: "HtmlView")
    parentView.addSubview(webView)

    channel.setMethodCallHandler { [weak self] call, result in
      self?.handleMethod(call, result: result)
    }
    eventChannel.setStreamHandler(self)
  }

  // MARK: - WKNavigationDelegate

  func webView(_ webView: WKWebView,
               decidePolicyFor navigationAction: WKNavigationAction,
               decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
    if let url = navigationAction.request.url {
      let scheme = url.scheme?.lowercased() ?? ""
      if scheme == "http" || scheme == "https" || scheme == "mailto" {
        emitEvent(type: "onLinkOpened", value: url.absoluteString)
        decisionHandler(.cancel)
        return
      }
    }
    decisionHandler(.allow)
  }

  // MARK: - WKScriptMessageHandler

  func userContentController(_ userContentController: WKUserContentController,
                             didReceive message: WKScriptMessage) {
    guard let body = message.body as? String else { return }
    guard let sep = body.firstIndex(of: "\0") else { return }
    let type  = String(body[body.startIndex..<sep])
    let value = String(body[body.index(after: sep)...])
    emitEvent(type: type, value: value)
  }

  // MARK: - FlutterStreamHandler

  func onListen(withArguments arguments: Any?,
                eventSink events: @escaping FlutterEventSink) -> FlutterError? {
    eventSink = events
    return nil
  }

  func onCancel(withArguments arguments: Any?) -> FlutterError? {
    eventSink = nil
    return nil
  }

  // MARK: - Method handling

  private func handleMethod(_ call: FlutterMethodCall,
                             result: @escaping FlutterResult) {
    switch call.method {
    case "loadHtml":
      guard let html = call.arguments as? String else {
        result(FlutterError(code: "bad_args", message: nil, details: nil)); return
      }
      webView.loadHTMLString(html, baseURL: nil)
      result(nil)

    case "loadUrl":
      guard let urlStr = call.arguments as? String,
            let url = URL(string: urlStr) else {
        result(FlutterError(code: "bad_args", message: nil, details: nil)); return
      }
      if url.isFileURL {
        webView.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
      } else {
        webView.load(URLRequest(url: url))
      }
      result(nil)

    case "loadAsset":
      guard let key = call.arguments as? String else {
        result(FlutterError(code: "bad_args", message: nil, details: nil)); return
      }
      loadAsset(key: key, result: result)

    case "eval":
      guard let js = call.arguments as? String else {
        result(FlutterError(code: "bad_args", message: nil, details: nil)); return
      }
      webView.evaluateJavaScript(js) { value, error in
        if let error = error {
          result(FlutterError(code: "eval_failed",
                              message: error.localizedDescription, details: nil))
        } else {
          result(value.map { "\($0)" } ?? "null")
        }
      }

    case "setPosition":
      guard let list = call.arguments as? [Double], list.count == 3 else {
        result(FlutterError(code: "bad_args", message: nil, details: nil)); return
      }
      // UIKit uses points (same as Flutter logical pixels — no DPR multiply).
      posX = CGFloat(list[0])
      posY = CGFloat(list[1])
      updateFrame()
      result(nil)

    case "setSize":
      guard let list = call.arguments as? [Double], list.count == 3 else {
        result(FlutterError(code: "bad_args", message: nil, details: nil)); return
      }
      width  = CGFloat(list[0])
      height = CGFloat(list[1])
      updateFrame()
      result(nil)

    case "setVisible":
      guard let visible = call.arguments as? Bool else {
        result(FlutterError(code: "bad_args", message: nil, details: nil)); return
      }
      webView.isHidden = !visible
      result(nil)

    default:
      result(FlutterMethodNotImplemented)
    }
  }

  private func loadAsset(key: String, result: @escaping FlutterResult) {
    guard let bundlePath = Bundle.main.resourcePath else {
      result(FlutterError(code: "no_bundle", message: nil, details: nil)); return
    }
    let fullPath = "\(bundlePath)/flutter_assets/\(key)"
    let fileURL  = URL(fileURLWithPath: fullPath)
    let accessURL = URL(fileURLWithPath: "\(bundlePath)/flutter_assets")
    webView.loadFileURL(fileURL, allowingReadAccessTo: accessURL)
    result(nil)
  }

  // MARK: - Layout

  private func updateFrame() {
    // UIKit: origin top-left, same as Flutter — direct mapping.
    webView.frame = CGRect(x: posX, y: posY,
                           width: max(1, width), height: max(1, height))
  }

  // MARK: - Events

  private func emitEvent(type: String, value: String) {
    eventSink?(["type": type, "value": value])
  }

  func dispose() {
    channel.setMethodCallHandler(nil)
    eventChannel.setStreamHandler(nil)
    webView.configuration.userContentController.removeScriptMessageHandler(forName: "HtmlView")
    webView.removeFromSuperview()
  }
}
