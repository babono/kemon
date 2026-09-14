#!/usr/bin/env swift
//
//  make-dmg-background.swift
//
//  Renders the install-window background art for the Melodash DMG, at 1x and
//  2x, using the app's own Orbitron/Poppins faces so the installer reads as
//  part of the product rather than a bare Finder window.
//
//  Run from the repo root:
//      swift scripts/make-dmg-background.swift
//
//  Writes scripts/dmg-assets/background.png and background@2x.png. Those are
//  committed; release.sh consumes them and does not re-render.
//
//  CoreGraphics + CoreText rather than a Python imaging library: it ships with
//  macOS, so building a release needs no extra install.
//

import Foundation
import CoreGraphics
import CoreText
import ImageIO
import UniformTypeIdentifiers

// MARK: - Layout
//
// Point geometry of the DMG window's content area. dmgbuild positions the two
// real Finder icons on top of this art, so ICON_CENTER_Y / *_ICON_X here must
// stay in step with settings in scripts/dmg-settings.py.

let W: CGFloat = 660
let H: CGFloat = 420

let iconCenterY: CGFloat = 250   // from the TOP, matching Finder's convention
let appIconX: CGFloat = 175
let appsIconX: CGFloat = 485

// Finder draws each icon's name below it, and — once a background picture is
// set — always in black, whatever the system appearance. There is no label
// colour control in .DS_Store or Finder's AppleScript dictionary, so on this
// dark art the names would be unreadable. Painting a light plate behind each
// one is the way to keep the cosmic background and still read the labels.
//
// Measured against a real build: with a 128pt icon centred at y=250, the label
// baseline band sits at roughly y=330.
let labelCenterY: CGFloat = 330
let labelFontSize: CGFloat = 13      // matches text_size set on the window
let appLabel = "Melodash"            // Melodash.app with the extension hidden
let appsLabel = "Applications"

// MARK: - Palette (from the app and melodash.app)

let bgTop    = CGColor(red: 0.016, green: 0.027, blue: 0.098, alpha: 1) // #04071a
let bgBottom = CGColor(red: 0.047, green: 0.063, blue: 0.180, alpha: 1) // #0c102e
let cyan     = CGColor(red: 0.239, green: 0.851, blue: 1.000, alpha: 1) // #3dd9ff
let violet    = CGColor(red: 0.608, green: 0.478, blue: 1.000, alpha: 1) // #9b7aff
let subtitle = CGColor(red: 0.725, green: 0.769, blue: 0.925, alpha: 1) // #b9c4ec
let arrowCol = CGColor(red: 0.545, green: 0.592, blue: 0.769, alpha: 1) // #8b97c4

// MARK: - Font loading

let fontDir = URL(fileURLWithPath: "Melodash/Resources/Fonts")

func registerFonts() {
    guard let files = try? FileManager.default.contentsOfDirectory(
        at: fontDir, includingPropertiesForKeys: nil) else {
        FileHandle.standardError.write(
            "warning: \(fontDir.path) not found; falling back to system fonts\n"
                .data(using: .utf8)!)
        return
    }
    for file in files where file.pathExtension.lowercased() == "ttf" {
        CTFontManagerRegisterFontsForURL(file as CFURL, .process, nil)
    }
}

func font(_ name: String, _ size: CGFloat) -> CTFont {
    // Falls back to the system face if a repo font is missing, so the script
    // still produces usable art rather than failing the build.
    let f = CTFontCreateWithName(name as CFString, size, nil)
    return f
}

// MARK: - Drawing helpers

/// Draws `text` centred on `x`, with its baseline at `y` measured from the top.
func drawCentered(_ ctx: CGContext, _ text: String, font: CTFont,
                  color: CGColor, x: CGFloat, topY: CGFloat,
                  tracking: CGFloat = 0) {
    // CoreText attribute names rather than the NSAttributedString.Key
    // constants, which live in AppKit and are unavailable in a Foundation-only
    // command-line script.
    let attrs: CFDictionary = [
        kCTFontAttributeName: font,
        kCTForegroundColorAttributeName: color,
        kCTKernAttributeName: tracking,
    ] as CFDictionary
    guard let attributed = CFAttributedStringCreate(nil, text as CFString, attrs) else { return }
    let line = CTLineCreateWithAttributedString(attributed)
    let bounds = CTLineGetBoundsWithOptions(line, .useOpticalBounds)

    // CoreGraphics origin is bottom-left; the layout above is expressed from
    // the top, so flip here once rather than everywhere.
    ctx.textPosition = CGPoint(x: x - bounds.width / 2 - bounds.origin.x,
                               y: H - topY)
    CTLineDraw(line, ctx)
}

/// A soft radial wash, used for the cyan/violet glows behind the title.
func glow(_ ctx: CGContext, at p: CGPoint, radius: CGFloat,
          color: CGColor, alpha: CGFloat) {
    guard let comps = color.components else { return }
    let space = CGColorSpaceCreateDeviceRGB()
    let inner = CGColor(colorSpace: space,
                        components: [comps[0], comps[1], comps[2], alpha])!
    let outer = CGColor(colorSpace: space,
                        components: [comps[0], comps[1], comps[2], 0])!
    guard let gradient = CGGradient(colorsSpace: space,
                                    colors: [inner, outer] as CFArray,
                                    locations: [0, 1]) else { return }
    ctx.drawRadialGradient(gradient, startCenter: p, startRadius: 0,
                           endCenter: p, endRadius: radius, options: [])
}

/// The arrow between the app icon and the Applications folder.
func drawArrow(_ ctx: CGContext, centerX: CGFloat, topY: CGFloat) {
    let y = H - topY
    let halfLen: CGFloat = 34
    let head: CGFloat = 13

    ctx.saveGState()
    ctx.setStrokeColor(arrowCol)
    ctx.setLineWidth(3.2)
    ctx.setLineCap(.round)
    ctx.setLineJoin(.round)

    ctx.move(to: CGPoint(x: centerX - halfLen, y: y))
    ctx.addLine(to: CGPoint(x: centerX + halfLen, y: y))
    ctx.strokePath()

    ctx.move(to: CGPoint(x: centerX + halfLen - head, y: y + head * 0.82))
    ctx.addLine(to: CGPoint(x: centerX + halfLen, y: y))
    ctx.addLine(to: CGPoint(x: centerX + halfLen - head, y: y - head * 0.82))
    ctx.strokePath()
    ctx.restoreGState()
}

/// Width of `text` as Finder will lay it out, so the plate behind it is sized
/// to the real label rather than a guess.
func labelWidth(_ text: String) -> CGFloat {
    let f = CTFontCreateUIFontForLanguage(.system, labelFontSize, nil)
        ?? CTFontCreateWithName("Helvetica" as CFString, labelFontSize, nil)
    let attrs: CFDictionary = [kCTFontAttributeName: f] as CFDictionary
    guard let s = CFAttributedStringCreate(nil, text as CFString, attrs) else { return 80 }
    return CTLineGetBoundsWithOptions(
        CTLineCreateWithAttributedString(s), .useOpticalBounds).width
}

/// The readable plate behind one icon label.
func drawLabelPlate(_ ctx: CGContext, centerX: CGFloat, text: String) {
    // Generous horizontal padding: Finder's label font is not exactly the one
    // measured here, and a plate that ends flush with the text looks cramped.
    let w = labelWidth(text) + 26
    let h: CGFloat = 25
    let rect = CGRect(x: centerX - w / 2,
                      y: H - labelCenterY - h / 2,
                      width: w, height: h)
    let path = CGPath(roundedRect: rect, cornerWidth: h / 2, cornerHeight: h / 2,
                      transform: nil)

    ctx.saveGState()
    // Near-white, slightly translucent so the starfield still shows through and
    // the plate reads as part of the art rather than a pasted-on box.
    ctx.setFillColor(CGColor(red: 0.925, green: 0.945, blue: 1.0, alpha: 0.93))
    ctx.addPath(path)
    ctx.fillPath()
    // Faint cyan rim, echoing the app's accent and softening the hard edge.
    ctx.setStrokeColor(CGColor(red: 0.239, green: 0.851, blue: 1.0, alpha: 0.30))
    ctx.setLineWidth(1)
    ctx.addPath(path)
    ctx.strokePath()
    ctx.restoreGState()
}

/// Sparse starfield, echoing the app's cosmic backdrop. Seeded so repeated
/// runs produce an identical PNG and don't show up as noise in git diffs.
func drawStars(_ ctx: CGContext) {
    var seed: UInt64 = 0x5EED_1234
    func rnd() -> CGFloat {
        seed = seed &* 6364136223846793005 &+ 1442695040888963407
        return CGFloat((seed >> 33) % 10000) / 10000
    }
    for _ in 0..<90 {
        let x = rnd() * W
        let y = rnd() * H
        // Keep the starfield out of the text and icon bands.
        if y > H - 150 && y < H - 40 { continue }
        let r = 0.5 + rnd() * 1.3
        let a = 0.12 + rnd() * 0.5
        ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: a))
        ctx.fillEllipse(in: CGRect(x: x, y: y, width: r, height: r))
    }
}

// MARK: - Render

func render(scale: CGFloat, to url: URL) {
    let pxW = Int(W * scale)
    let pxH = Int(H * scale)
    let space = CGColorSpaceCreateDeviceRGB()

    guard let ctx = CGContext(data: nil, width: pxW, height: pxH,
                              bitsPerComponent: 8, bytesPerRow: 0,
                              space: space,
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    else {
        FileHandle.standardError.write("error: could not create context\n".data(using: .utf8)!)
        exit(1)
    }

    ctx.scaleBy(x: scale, y: scale)
    ctx.setAllowsAntialiasing(true)
    ctx.interpolationQuality = .high

    // Base vertical gradient.
    if let g = CGGradient(colorsSpace: space,
                          colors: [bgBottom, bgTop] as CFArray,
                          locations: [0, 1]) {
        ctx.drawLinearGradient(g, start: CGPoint(x: 0, y: 0),
                               end: CGPoint(x: 0, y: H), options: [])
    }

    drawStars(ctx)
    glow(ctx, at: CGPoint(x: W * 0.22, y: H * 0.86), radius: 250, color: cyan, alpha: 0.13)
    glow(ctx, at: CGPoint(x: W * 0.80, y: H * 0.88), radius: 250, color: violet, alpha: 0.13)

    drawCentered(ctx, "INSTALL MELODASH",
                 font: font("Orbitron-Black", 27), color: .white,
                 x: W / 2, topY: 74, tracking: 1.6)

    drawCentered(ctx, "Drag Melodash to Applications",
                 font: font("Poppins-Medium", 14.5), color: subtitle,
                 x: W / 2, topY: 108)

    drawArrow(ctx, centerX: (appIconX + appsIconX) / 2, topY: iconCenterY)

    drawLabelPlate(ctx, centerX: appIconX, text: appLabel)
    drawLabelPlate(ctx, centerX: appsIconX, text: appsLabel)

    guard let image = ctx.makeImage(),
          let dest = CGImageDestinationCreateWithURL(
            url as CFURL, UTType.png.identifier as CFString, 1, nil)
    else {
        FileHandle.standardError.write("error: could not encode PNG\n".data(using: .utf8)!)
        exit(1)
    }
    CGImageDestinationAddImage(dest, image, nil)
    guard CGImageDestinationFinalize(dest) else {
        FileHandle.standardError.write("error: could not write \(url.path)\n".data(using: .utf8)!)
        exit(1)
    }
    print("wrote \(url.path) (\(pxW)x\(pxH))")
}

registerFonts()

let outDir = URL(fileURLWithPath: "scripts/dmg-assets")
try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

render(scale: 1, to: outDir.appendingPathComponent("background.png"))
render(scale: 2, to: outDir.appendingPathComponent("background@2x.png"))
