// Renders the macOS installer window's background: macos/dmg/background.png.
//
// The PNG is committed, so this is not run by the release workflow — it is the
// source the image was drawn from, and the thing to edit and re-run when the
// window changes:
//
//     swift tool/dmg_background.swift
//
// The geometry has to agree with the `create-dmg` invocation in
// .github/workflows/release.yml, which is what actually positions the icons on
// top of this image. Both are named below and the constants are the same:
// an 800x450 window, 100pt icons centred at (200, 185) and (600, 185). Change
// one without the other and the arrow points somewhere nothing is.
//
// One resolution only, deliberately. create-dmg documents png/gif/jpg and hands
// the file to Finder as-is; a multi-representation TIFF is undocumented there,
// and a background that silently fails to load is a regression nobody sees
// until they mount the disk image. So the design is flat — a gradient, large
// type and one arrow — which is what survives being scaled up on a Retina
// display.

import CoreGraphics
import CoreText
import Foundation
import ImageIO
import UniformTypeIdentifiers

// Must match `--window-size`, `--icon-size` and both `--icon` / `--app-drop-link`
// positions in the workflow. Finder measures from the window's top-left.
let width = 800.0
let height = 450.0
let iconSize = 100.0
let appIconCentre = CGPoint(x: 200, y: 185)
let dropLinkCentre = CGPoint(x: 600, y: 185)

// Drawn from assets/logo.png rather than the app's UI palette: the installer
// window is the first thing anyone sees of NightMail, and the logo is a moon in
// a navy envelope against a starfield. AppColors.accent is the one UI colour
// that belongs here, because it is already that same periwinkle.
let skyTop = CGColor(red: 0.043, green: 0.067, blue: 0.184, alpha: 1)
let skyBottom = CGColor(red: 0.016, green: 0.024, blue: 0.059, alpha: 1)
let accent = CGColor(red: 0.486, green: 0.514, blue: 0.992, alpha: 1)
let moonlight = CGColor(red: 0.682, green: 0.753, blue: 1, alpha: 1)
let titleColour = CGColor(red: 1, green: 1, blue: 1, alpha: 0.95)
let subtitleColour = CGColor(red: 0.60, green: 0.66, blue: 0.85, alpha: 1)

/// A fixed sequence, so re-running this script redraws the same sky rather than
/// a new one — the image is committed, and a rerun should produce no diff.
struct Stars {
    private var state: UInt64 = 0x4E69676874_4D61
    mutating func next() -> Double {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        return Double((state >> 11) & 0xFFFFFFFF) / Double(0xFFFFFFFF)
    }
    mutating func next(_ lower: Double, _ upper: Double) -> Double {
        lower + next() * (upper - lower)
    }
}

/// Finder's y grows downward from the top of the window; CoreGraphics' grows up.
func fromTop(_ y: Double) -> Double { height - y }

guard let space = CGColorSpace(name: CGColorSpace.sRGB),
      let context = CGContext(
        data: nil,
        width: Int(width),
        height: Int(height),
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: space,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
      )
else {
    FileHandle.standardError.write(Data("cannot create a drawing context\n".utf8))
    exit(1)
}

// The night sky, lightest at the top where the moon is.
if let gradient = CGGradient(
    colorsSpace: space,
    colors: [skyTop, skyBottom] as CFArray,
    locations: [0, 1]
) {
    context.drawLinearGradient(
        gradient,
        start: CGPoint(x: 0, y: height),
        end: CGPoint(x: 0, y: 0),
        options: []
    )
}

// Stars. Sparse and mostly faint: this sits *behind* two icons, their labels
// and two lines of type, and a busy sky would compete with all four.
var sky = Stars()
for _ in 0..<150 {
    let x = sky.next(0, width)
    let y = sky.next(0, height)
    // Thin them out across the middle band, where everything else is drawn.
    let distanceFromBand = abs(fromTop(190) - y)
    if distanceFromBand < 110, sky.next() < 0.55 { continue }
    let radius = sky.next(0.4, 1.5)
    let alpha = sky.next(0.18, 0.85) * (radius > 1.1 ? 1 : 0.8)
    context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: alpha))
    context.fillEllipse(in: CGRect(
        x: x - radius, y: y - radius, width: radius * 2, height: radius * 2
    ))
}

// The four-point sparkles the logo has, well away from the icons and the type.
func sparkle(x: Double, fromTopY: Double, arm: Double, alpha: Double) {
    let y = fromTop(fromTopY)
    context.setStrokeColor(CGColor(red: 1, green: 1, blue: 1, alpha: alpha))
    context.setLineWidth(1)
    context.setLineCap(.round)
    context.move(to: CGPoint(x: x - arm, y: y))
    context.addLine(to: CGPoint(x: x + arm, y: y))
    context.move(to: CGPoint(x: x, y: y - arm))
    context.addLine(to: CGPoint(x: x, y: y + arm))
    context.strokePath()
    context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: alpha))
    context.fillEllipse(in: CGRect(x: x - 1.3, y: y - 1.3, width: 2.6, height: 2.6))
}
sparkle(x: 92, fromTopY: 58, arm: 7, alpha: 0.85)
sparkle(x: 723, fromTopY: 92, arm: 5.5, alpha: 0.7)
sparkle(x: 118, fromTopY: 372, arm: 5, alpha: 0.55)
sparkle(x: 668, fromTopY: 388, arm: 6.5, alpha: 0.65)

/// A soft round glow, used to put the app icon inside the same halo the moon
/// in the logo has.
func glow(centre: CGPoint, radius: Double, colour: CGColor, alpha: Double) {
    guard let gradient = CGGradient(
        colorsSpace: space,
        colors: [
            colour.copy(alpha: alpha)!,
            colour.copy(alpha: alpha * 0.34)!,
            colour.copy(alpha: 0)!,
        ] as CFArray,
        locations: [0, 0.42, 1]
    ) else { return }
    context.drawRadialGradient(
        gradient,
        startCenter: centre,
        startRadius: 0,
        endCenter: centre,
        endRadius: radius,
        options: []
    )
}

// The app icon is the moon, so it gets the moon's halo. The drop link gets a
// weaker one of the accent, or the right-hand half of the window reads as unlit.
glow(
    centre: CGPoint(x: appIconCentre.x, y: fromTop(appIconCentre.y)),
    radius: 190,
    colour: moonlight,
    alpha: 0.15
)
glow(
    centre: CGPoint(x: dropLinkCentre.x, y: fromTop(dropLinkCentre.y)),
    radius: 150,
    colour: accent,
    alpha: 0.09
)

/// Draws one line of system text centred on [centreX], at [baselineFromTop].
func drawCentred(
    _ string: String,
    size: Double,
    weight: CGFloat,
    colour: CGColor,
    centreX: Double,
    baselineFromTop: Double,
    tracking: Double = 0
) {
    let font = CTFontCreateUIFontForLanguage(.system, size, nil)
        .flatMap { base -> CTFont? in
            let traits: [CFString: Any] = [
                kCTFontWeightTrait: weight,
            ]
            let descriptor = CTFontDescriptorCreateCopyWithAttributes(
                CTFontCopyFontDescriptor(base),
                [kCTFontTraitsAttribute: traits] as CFDictionary
            )
            return CTFontCreateWithFontDescriptor(descriptor, size, nil)
        } ?? CTFontCreateWithName("Helvetica" as CFString, size, nil)

    let attributed = NSAttributedString(
        string: string,
        attributes: [
            kCTFontAttributeName as NSAttributedString.Key: font,
            kCTForegroundColorAttributeName as NSAttributedString.Key: colour,
            kCTKernAttributeName as NSAttributedString.Key: tracking,
        ]
    )
    let line = CTLineCreateWithAttributedString(attributed)
    let bounds = CTLineGetBoundsWithOptions(line, .useOpticalBounds)
    context.textPosition = CGPoint(
        x: centreX - bounds.width / 2,
        y: fromTop(baselineFromTop)
    )
    CTLineDraw(line, context)
}

drawCentred(
    "NightMail",
    size: 31,
    weight: 0.3,
    colour: titleColour,
    centreX: width / 2,
    baselineFromTop: 74,
    tracking: 0.4
)

drawCentred(
    "Drag NightMail into your Applications folder",
    size: 13,
    weight: 0,
    colour: subtitleColour,
    centreX: width / 2,
    baselineFromTop: 104
)

// The arrow sits on the icons' own centre line and stops well clear of both,
// so it reads as pointing from one to the other rather than touching either.
let arrowY = fromTop(appIconCentre.y)
let arrowStart = appIconCentre.x + iconSize / 2 + 50
let arrowEnd = dropLinkCentre.x - iconSize / 2 - 50
let headLength = 17.0
let headHalfHeight = 8.0

context.setStrokeColor(accent.copy(alpha: 0.62)!)
context.setLineWidth(2)
context.setLineCap(.round)
context.move(to: CGPoint(x: arrowStart, y: arrowY))
context.addLine(to: CGPoint(x: arrowEnd - headLength + 2, y: arrowY))
context.strokePath()

context.setFillColor(accent.copy(alpha: 0.62)!)
context.move(to: CGPoint(x: arrowEnd, y: arrowY))
context.addLine(to: CGPoint(x: arrowEnd - headLength, y: arrowY + headHalfHeight))
context.addLine(to: CGPoint(x: arrowEnd - headLength, y: arrowY - headHalfHeight))
context.closePath()
context.fillPath()

let output = URL(fileURLWithPath: "macos/dmg/background.png")
try? FileManager.default.createDirectory(
    at: output.deletingLastPathComponent(),
    withIntermediateDirectories: true
)

guard let image = context.makeImage(),
      let destination = CGImageDestinationCreateWithURL(
        output as CFURL,
        UTType.png.identifier as CFString,
        1,
        nil
      )
else {
    FileHandle.standardError.write(Data("cannot encode the image\n".utf8))
    exit(1)
}
CGImageDestinationAddImage(destination, image, nil)
guard CGImageDestinationFinalize(destination) else {
    FileHandle.standardError.write(Data("cannot write \(output.path)\n".utf8))
    exit(1)
}
print("wrote \(output.path) (\(Int(width))x\(Int(height)))")
