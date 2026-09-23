// Renders assets/logo.png as a rounded tile — the same corner treatment iOS
// gives the app icon — at 1x/2x/3x for the launch screen's LaunchImage set.
//
//   swift ios/scripts/launch_tile.swift assets/logo.png \
//       ios/Runner/Assets.xcassets/LaunchImage.imageset 120
//
// Re-run after changing the logo. A launch screen cannot run code, so the
// rounding has to be baked into the PNGs; the logo itself is a square with
// its starfield background, which on the light launch background would
// otherwise sit as a hard-edged dark square.
import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

let args = CommandLine.arguments
let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: args[1]) as CFURL, nil)!
let img = CGImageSourceCreateImageAtIndex(src, 0, nil)!
let outDir = args[2]
let pointSize = Int(args[3])!
for (scale, name) in [(1, "LaunchImage.png"), (2, "LaunchImage@2x.png"), (3, "LaunchImage@3x.png")] {
  let size = pointSize * scale
  let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
  let rect = CGRect(x: 0, y: 0, width: size, height: size)
  let radius = CGFloat(size) * 0.2237
  ctx.addPath(CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil))
  ctx.clip()
  ctx.interpolationQuality = .high
  ctx.draw(img, in: rect)
  let out = ctx.makeImage()!
  let dest = CGImageDestinationCreateWithURL(URL(fileURLWithPath: outDir + "/" + name) as CFURL,
                                             UTType.png.identifier as CFString, 1, nil)!
  CGImageDestinationAddImage(dest, out, nil)
  CGImageDestinationFinalize(dest)
}
