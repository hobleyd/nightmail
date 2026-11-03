import UIKit
import UniformTypeIdentifiers

/// NightMail's entry in the share sheet.
///
/// Shows no UI of its own: it copies what was shared into the App Group
/// container, writes a `pending.json` describing it, and opens NightMail, whose
/// `SceneDelegate` hands that to Dart on the `share_intent` channel. If opening
/// the app does not happen, the share still waits in the container and opens the
/// next time NightMail comes to the foreground. See docs/claude/share-target.md.
///
/// Deliberately has no Flutter dependency, so the extension stays small and
/// links nothing it could not use.
class ShareViewController: UIViewController {
  /// Also in Runner/SceneDelegate.swift and both targets' entitlements.
  static let appGroupId = "group.au.com.sharpblue.nightmail"
  /// Registered in Runner/Info.plist's CFBundleURLTypes.
  static let openURL = URL(string: "nightmail-share://share")!

  private var handled = false

  override func viewDidLoad() {
    super.viewDidLoad()
    view.backgroundColor = .clear
  }

  override func viewDidAppear(_ animated: Bool) {
    super.viewDidAppear(animated)
    guard !handled else { return }
    handled = true
    collectShare { [weak self] in self?.finish(opened: $0) }
  }

  // MARK: - Collecting

  private func collectShare(completion: @escaping (Bool) -> Void) {
    guard let container = FileManager.default.containerURL(
      forSecurityApplicationGroupIdentifier: Self.appGroupId)
    else {
      completion(false)
      return
    }
    let shareDir = container.appendingPathComponent("share", isDirectory: true)
    // Copies from a share that was never opened; Dart deletes each copy it reads.
    try? FileManager.default.removeItem(at: shareDir)
    let filesDir = shareDir.appendingPathComponent(UUID().uuidString, isDirectory: true)

    let items = extensionContext?.inputItems as? [NSExtensionItem] ?? []
    var subject = ""
    var texts: [String] = []
    var files: [[String: String]] = []
    let lock = NSLock()
    let group = DispatchGroup()

    for item in items {
      if subject.isEmpty, let title = item.attributedTitle?.string {
        subject = title
      }
      for (index, provider) in (item.attachments ?? []).enumerated() {
        group.enter()
        load(provider, index: index, into: filesDir) { text, file in
          lock.lock()
          if let text, !text.isEmpty { texts.append(text) }
          if let file { files.append(file) }
          lock.unlock()
          group.leave()
        }
      }
    }

    group.notify(queue: .main) {
      let payload: [String: Any] = [
        "subject": subject,
        "text": texts.joined(separator: "\n\n"),
        "files": files,
      ]
      do {
        try FileManager.default.createDirectory(at: shareDir, withIntermediateDirectories: true)
        let data = try JSONSerialization.data(withJSONObject: payload)
        try data.write(to: shareDir.appendingPathComponent("pending.json"), options: .atomic)
        completion(true)
      } catch {
        NSLog("NightMail share: could not write the share: \(error)")
        completion(false)
      }
    }
  }

  /// One attachment, as either text (a link or plain text) or a file copied
  /// into [dir]. Calls [done] exactly once.
  private func load(
    _ provider: NSItemProvider,
    index: Int,
    into dir: URL,
    done: @escaping (String?, [String: String]?) -> Void
  ) {
    let url = UTType.url.identifier
    let fileURL = UTType.fileURL.identifier
    let text = UTType.plainText.identifier

    // A web link. A file URL also conforms to public.url, so it is excluded
    // here and copied as a file below.
    if provider.hasItemConformingToTypeIdentifier(url),
       !provider.hasItemConformingToTypeIdentifier(fileURL) {
      provider.loadItem(forTypeIdentifier: url) { item, _ in
        done((item as? URL)?.absoluteString, nil)
      }
      return
    }
    if provider.hasItemConformingToTypeIdentifier(text),
       !provider.hasItemConformingToTypeIdentifier(fileURL) {
      provider.loadItem(forTypeIdentifier: text) { item, _ in
        done(item as? String, nil)
      }
      return
    }

    // Everything else is a file: the most specific registered type that is
    // data, so an image keeps its own format rather than being re-encoded.
    let fileType = provider.registeredTypeIdentifiers.first {
      UTType($0)?.conforms(to: .data) == true
    } ?? UTType.data.identifier
    provider.loadFileRepresentation(forTypeIdentifier: fileType) { source, error in
      // [source] is deleted when this returns, so copy it now.
      guard let source else {
        NSLog("NightMail share: could not load attachment: \(String(describing: error))")
        done(nil, nil)
        return
      }
      let name = provider.suggestedName.flatMap { suggested -> String? in
        // suggestedName often omits the extension the file itself carries.
        let ext = source.pathExtension
        if ext.isEmpty || suggested.lowercased().hasSuffix(".\(ext.lowercased())") {
          return suggested
        }
        return "\(suggested).\(ext)"
      } ?? source.lastPathComponent
      let safeName = name.replacingOccurrences(of: "/", with: "_")
      // Two shared files can carry the same name.
      let destDir = dir.appendingPathComponent(String(index), isDirectory: true)
      let dest = destDir.appendingPathComponent(safeName)
      do {
        try FileManager.default.createDirectory(at: destDir, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: source, to: dest)
      } catch {
        NSLog("NightMail share: could not copy attachment: \(error)")
        done(nil, nil)
        return
      }
      var file = ["path": dest.path, "name": safeName]
      if let mime = UTType(filenameExtension: dest.pathExtension)?.preferredMIMEType
        ?? UTType(fileType)?.preferredMIMEType {
        file["mimeType"] = mime
      }
      done(nil, file)
    }
  }

  // MARK: - Handing over

  private func finish(opened: Bool) {
    if opened { openHostApp() }
    extensionContext?.completeRequest(returningItems: nil)
  }

  /// An extension has no `UIApplication.shared`; the application object is
  /// still in the responder chain, which is the established way for a share
  /// extension to bring its app forward.
  private func openHostApp() {
    var responder: UIResponder? = self
    while let current = responder {
      if let application = current as? UIApplication {
        application.open(Self.openURL, options: [:], completionHandler: nil)
        return
      }
      responder = current.next
    }
  }
}
