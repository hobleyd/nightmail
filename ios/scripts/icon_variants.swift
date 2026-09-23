// Produces the iOS 18 appearance variants of the app icon from the 1024px
// marketing icon flutter_launcher_icons generates:
//
//   swift ios/scripts/icon_variants.swift ios/Runner/Assets.xcassets/AppIcon.appiconset
//
// * dark   — the artwork as it is. It is a night sky already; Apple's guidance
//            to drop the background applies to icons with a light one.
// * tinted — a grayscale rendering, which the system colours with the user's
//            chosen tint.
//
// Re-run after `flutter pub run flutter_launcher_icons`, which rewrites the
// icon set's Contents.json without these entries (see ios/CLAUDE.md).
import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

let dir = CommandLine.arguments[1]
let srcURL = URL(fileURLWithPath: dir + "/Icon-App-1024x1024@1x.png")
let src = CGImageSourceCreateWithURL(srcURL as CFURL, nil)!
let img = CGImageSourceCreateImageAtIndex(src, 0, nil)!

func write(_ image: CGImage, to name: String) {
  let dest = CGImageDestinationCreateWithURL(
    URL(fileURLWithPath: dir + "/" + name) as CFURL, UTType.png.identifier as CFString, 1, nil)!
  CGImageDestinationAddImage(dest, image, nil)
  CGImageDestinationFinalize(dest)
}

// Dark: the same pixels under a new name, so the catalog entry has a file.
write(img, to: "Icon-App-1024x1024-dark.png")

// Tinted: draw into a gray colour space.
let size = img.width
let gray = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                     space: CGColorSpaceCreateDeviceGray(),
                     bitmapInfo: CGImageAlphaInfo.none.rawValue)!
gray.interpolationQuality = .high
gray.draw(img, in: CGRect(x: 0, y: 0, width: size, height: size))
write(gray.makeImage()!, to: "Icon-App-1024x1024-tinted.png")
