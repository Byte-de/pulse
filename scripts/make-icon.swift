#!/usr/bin/env swift
//
//  make-icon.swift — renders the Byte Pulse app icon entirely with CoreGraphics.
//
//  Design: flat acid-orange squircle plate (#FB8E6A) with a baked-in drop
//  shadow (macOS pre-26 icon style), carrying the black Byte "B" mark centered
//  at ~45% of the plate — matching the website touch icon (src/app/icon.svg).
//
//  Usage:
//      swift scripts/make-icon.swift <output-dir>
//
//  Produces in <output-dir>:
//      master-1024.png     1024×1024 master render
//      Pulse.iconset/      all 10 standard iconset PNGs (re-rendered per size,
//                          vector redraw — no upscaling artifacts)
//      AppIcon.icns        via `iconutil -c icns`
//
//  Dependencies: AppKit / CoreGraphics + /usr/bin/iconutil only.
//

import AppKit
import CoreGraphics

// MARK: - CLI plumbing

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("error: \(message)\n".utf8))
    exit(1)
}

guard CommandLine.arguments.count == 2 else {
    FileHandle.standardError.write(Data("usage: swift scripts/make-icon.swift <output-dir>\n".utf8))
    exit(64)
}

let outputDir = URL(fileURLWithPath: CommandLine.arguments[1]).standardizedFileURL

// MARK: - Design constants (1024-pt design space)

let canvas: CGFloat = 1024

/// Squircle plate: standard macOS icon proportions — the shape fills the
/// center ~824/1024 of the canvas with transparent margin around it.
let plateRect = CGRect(x: 100, y: 100, width: 824, height: 824)
let plateCornerRadius: CGFloat = 185

/// Drop shadow (baked in, pre-macOS-26 icon style).
let shadowOffsetY: CGFloat = -12
let shadowBlur: CGFloat = 24
let shadowAlpha: CGFloat = 0.30

/// Plate fill — flat acid-orange (byte.de accent), matching the website icon.
let plateColor: UInt32 = 0xFB8E6A

/// Byte "B" mark: authored in the website icon's 178-pt viewBox and mapped onto
/// the 824-pt plate (centered, ~45% of the plate). y is flipped at draw time
/// because the SVG is y-down while this CGContext is y-up.
let markScale: CGFloat = 824 / 178
let markFillAlpha: CGFloat = 0.85

let srgb = CGColorSpace(name: CGColorSpace.sRGB)!

func rgb(_ hex: UInt32, alpha: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: alpha)
}

func white(_ alpha: CGFloat) -> CGColor {
    CGColor(srgbRed: 1, green: 1, blue: 1, alpha: alpha)
}

// MARK: - Squircle (superellipse-cornered rounded rect, continuous-corner look)

/// Rounded rect whose corners follow a superellipse |x/r|^n + |y/r|^n = 1,
/// approximating Apple's continuous corner curve (n ≈ 4.6), sampled densely.
func squirclePath(in rect: CGRect, cornerRadius: CGFloat,
                  exponent n: CGFloat = 4.6, samplesPerCorner: Int = 48) -> CGPath {
    let r = min(cornerRadius, min(rect.width, rect.height) / 2)
    let path = CGMutablePath()

    // Unit superellipse quadrant: (1,0) at t=0 → (0,1) at t=π/2.
    func q(_ i: Int) -> (u: CGFloat, v: CGFloat) {
        let t = CGFloat(i) / CGFloat(samplesPerCorner) * (.pi / 2)
        return (pow(cos(t), 2 / n), pow(sin(t), 2 / n))
    }

    let bl = CGPoint(x: rect.minX + r, y: rect.minY + r)
    let br = CGPoint(x: rect.maxX - r, y: rect.minY + r)
    let tr = CGPoint(x: rect.maxX - r, y: rect.maxY - r)
    let tl = CGPoint(x: rect.minX + r, y: rect.maxY - r)

    path.move(to: CGPoint(x: bl.x, y: rect.minY))
    path.addLine(to: CGPoint(x: br.x, y: rect.minY))
    for i in 0...samplesPerCorner {  // bottom-right: (0,-r) → (+r,0)
        let (u, v) = q(i); path.addLine(to: CGPoint(x: br.x + v * r, y: br.y - u * r))
    }
    path.addLine(to: CGPoint(x: rect.maxX, y: tr.y))
    for i in 0...samplesPerCorner {  // top-right: (+r,0) → (0,+r)
        let (u, v) = q(i); path.addLine(to: CGPoint(x: tr.x + u * r, y: tr.y + v * r))
    }
    path.addLine(to: CGPoint(x: tl.x, y: rect.maxY))
    for i in 0...samplesPerCorner {  // top-left: (0,+r) → (-r,0)
        let (u, v) = q(i); path.addLine(to: CGPoint(x: tl.x - v * r, y: tl.y + u * r))
    }
    path.addLine(to: CGPoint(x: rect.minX, y: bl.y))
    for i in 0...samplesPerCorner {  // bottom-left: (-r,0) → (0,-r)
        let (u, v) = q(i); path.addLine(to: CGPoint(x: bl.x - u * r, y: bl.y - v * r))
    }
    path.closeSubpath()
    return path
}

// MARK: - Drawing

/// The Byte "B" mark as a CGPath in the website icon's 178-pt design space
/// (y-down). Transcribed verbatim from usage-tracker-website/src/app/icon.svg.
func byteMarkPath() -> CGPath {
    let p = CGMutablePath()
    p.move(to: CGPoint(x: 108.597, y: 49.0))
    p.addCurve(to: CGPoint(x: 113.738, y: 49.2947), control1: CGPoint(x: 111.206, y: 49.0), control2: CGPoint(x: 112.511, y: 49.0))
    p.addCurve(to: CGPoint(x: 116.822, y: 50.5718), control1: CGPoint(x: 114.827, y: 49.556), control2: CGPoint(x: 115.867, y: 49.987))
    p.addCurve(to: CGPoint(x: 120.665, y: 53.9987), control1: CGPoint(x: 117.898, y: 51.2315), control2: CGPoint(x: 118.821, y: 52.1539))
    p.addLine(to: CGPoint(x: 124.001, y: 57.3346))
    p.addCurve(to: CGPoint(x: 127.428, y: 61.1783), control1: CGPoint(x: 125.846, y: 59.1794), control2: CGPoint(x: 126.769, y: 60.1018))
    p.addCurve(to: CGPoint(x: 128.705, y: 64.2615), control1: CGPoint(x: 128.013, y: 62.1327), control2: CGPoint(x: 128.444, y: 63.1731))
    p.addCurve(to: CGPoint(x: 129.0, y: 69.4026), control1: CGPoint(x: 129.0, y: 65.4891), control2: CGPoint(x: 129.0, y: 66.7936))
    p.addLine(to: CGPoint(x: 129.0, y: 75.6667))
    p.addLine(to: CGPoint(x: 129.0, y: 77.8))
    p.addCurve(to: CGPoint(x: 128.419, y: 83.4213), control1: CGPoint(x: 129.0, y: 80.7869), control2: CGPoint(x: 129.0, y: 82.2804))
    p.addCurve(to: CGPoint(x: 126.088, y: 85.752), control1: CGPoint(x: 127.907, y: 84.4248), control2: CGPoint(x: 127.091, y: 85.2407))
    p.addCurve(to: CGPoint(x: 120.467, y: 86.3333), control1: CGPoint(x: 124.947, y: 86.3333), control2: CGPoint(x: 123.454, y: 86.3333))
    p.addLine(to: CGPoint(x: 113.8, y: 86.3333))
    p.addCurve(to: CGPoint(x: 112.395, y: 86.4787), control1: CGPoint(x: 113.053, y: 86.3333), control2: CGPoint(x: 112.68, y: 86.3333))
    p.addCurve(to: CGPoint(x: 111.812, y: 87.0613), control1: CGPoint(x: 112.144, y: 86.6065), control2: CGPoint(x: 111.94, y: 86.8105))
    p.addCurve(to: CGPoint(x: 111.667, y: 88.4667), control1: CGPoint(x: 111.667, y: 87.3466), control2: CGPoint(x: 111.667, y: 87.7199))
    p.addLine(to: CGPoint(x: 111.667, y: 89.5333))
    p.addCurve(to: CGPoint(x: 111.812, y: 90.9387), control1: CGPoint(x: 111.667, y: 90.2801), control2: CGPoint(x: 111.667, y: 90.6534))
    p.addCurve(to: CGPoint(x: 112.395, y: 91.5213), control1: CGPoint(x: 111.94, y: 91.1895), control2: CGPoint(x: 112.144, y: 91.3935))
    p.addCurve(to: CGPoint(x: 113.8, y: 91.6667), control1: CGPoint(x: 112.68, y: 91.6667), control2: CGPoint(x: 113.053, y: 91.6667))
    p.addLine(to: CGPoint(x: 120.467, y: 91.6667))
    p.addCurve(to: CGPoint(x: 126.088, y: 92.248), control1: CGPoint(x: 123.454, y: 91.6667), control2: CGPoint(x: 124.947, y: 91.6667))
    p.addCurve(to: CGPoint(x: 128.419, y: 94.5787), control1: CGPoint(x: 127.091, y: 92.7593), control2: CGPoint(x: 127.907, y: 93.5752))
    p.addCurve(to: CGPoint(x: 129.0, y: 100.2), control1: CGPoint(x: 129.0, y: 95.7196), control2: CGPoint(x: 129.0, y: 97.2131))
    p.addLine(to: CGPoint(x: 129.0, y: 102.333))
    p.addLine(to: CGPoint(x: 129.0, y: 108.597))
    p.addCurve(to: CGPoint(x: 128.705, y: 113.738), control1: CGPoint(x: 129.0, y: 111.206), control2: CGPoint(x: 129.0, y: 112.511))
    p.addCurve(to: CGPoint(x: 127.428, y: 116.822), control1: CGPoint(x: 128.444, y: 114.827), control2: CGPoint(x: 128.013, y: 115.867))
    p.addCurve(to: CGPoint(x: 124.001, y: 120.665), control1: CGPoint(x: 126.769, y: 117.898), control2: CGPoint(x: 125.846, y: 118.821))
    p.addLine(to: CGPoint(x: 120.665, y: 124.001))
    p.addCurve(to: CGPoint(x: 116.822, y: 127.428), control1: CGPoint(x: 118.821, y: 125.846), control2: CGPoint(x: 117.898, y: 126.769))
    p.addCurve(to: CGPoint(x: 113.738, y: 128.705), control1: CGPoint(x: 115.867, y: 128.013), control2: CGPoint(x: 114.827, y: 128.444))
    p.addCurve(to: CGPoint(x: 108.597, y: 129.0), control1: CGPoint(x: 112.511, y: 129.0), control2: CGPoint(x: 111.206, y: 129.0))
    p.addLine(to: CGPoint(x: 62.3333, y: 129.0))
    p.addCurve(to: CGPoint(x: 57.5857, y: 128.795), control1: CGPoint(x: 59.8552, y: 129.0), control2: CGPoint(x: 58.6161, y: 129.0))
    p.addCurve(to: CGPoint(x: 49.205, y: 120.414), control1: CGPoint(x: 53.3543, y: 127.953), control2: CGPoint(x: 50.0466, y: 124.646))
    p.addCurve(to: CGPoint(x: 49.0, y: 115.667), control1: CGPoint(x: 49.0, y: 119.384), control2: CGPoint(x: 49.0, y: 118.145))
    p.addLine(to: CGPoint(x: 49.0, y: 62.3333))
    p.addCurve(to: CGPoint(x: 49.205, y: 57.5857), control1: CGPoint(x: 49.0, y: 59.8552), control2: CGPoint(x: 49.0, y: 58.6161))
    p.addCurve(to: CGPoint(x: 57.5857, y: 49.205), control1: CGPoint(x: 50.0466, y: 53.3543), control2: CGPoint(x: 53.3543, y: 50.0466))
    p.addCurve(to: CGPoint(x: 62.3333, y: 49.0), control1: CGPoint(x: 58.6161, y: 49.0), control2: CGPoint(x: 59.8552, y: 49.0))
    p.addLine(to: CGPoint(x: 108.597, y: 49.0))
    p.closeSubpath()
    return p
}

/// Draws the full icon into `ctx`, natively at `pixelSize` (vector redraw —
/// crisp at every size, no resampling).
func drawIcon(into ctx: CGContext, pixelSize: Int) {
    let s = CGFloat(pixelSize) / canvas
    ctx.saveGState()
    ctx.scaleBy(x: s, y: s)
    ctx.setShouldAntialias(true)
    ctx.setAllowsAntialiasing(true)

    let plate = squirclePath(in: plateRect, cornerRadius: plateCornerRadius)

    // Shadow offset/blur live in device space, so pre-scale them; the
    // transparency layer makes the whole icon cast one clean composite shadow.
    ctx.setShadow(offset: CGSize(width: 0, height: shadowOffsetY * s),
                  blur: shadowBlur * s,
                  color: CGColor(srgbRed: 0, green: 0, blue: 0, alpha: shadowAlpha))
    ctx.beginTransparencyLayer(auxiliaryInfo: nil)

    ctx.saveGState()
    ctx.addPath(plate)
    ctx.clip()

    // 1) Flat acid-orange plate.
    ctx.setFillColor(rgb(plateColor))
    ctx.fill(CGRect(x: 0, y: 0, width: canvas, height: canvas))

    // 2) Byte "B" mark: 178-pt SVG space → 824-pt plate, y flipped (SVG y-down).
    var t = CGAffineTransform(a: markScale, b: 0, c: 0, d: -markScale,
                              tx: plateRect.minX, ty: plateRect.maxY)
    if let mark = byteMarkPath().copy(using: &t) {
        ctx.addPath(mark)
        ctx.setFillColor(CGColor(srgbRed: 0, green: 0, blue: 0, alpha: markFillAlpha))
        ctx.fillPath()
    }

    ctx.restoreGState()           // plate clip
    ctx.endTransparencyLayer()    // composite + shadow
    ctx.restoreGState()
}

func renderIcon(pixelSize: Int) -> CGImage {
    guard let ctx = CGContext(data: nil, width: pixelSize, height: pixelSize,
                              bitsPerComponent: 8, bytesPerRow: 0, space: srgb,
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    else { fail("could not create \(pixelSize)px CGContext") }
    ctx.clear(CGRect(x: 0, y: 0, width: pixelSize, height: pixelSize))
    drawIcon(into: ctx, pixelSize: pixelSize)
    guard let image = ctx.makeImage() else { fail("could not snapshot \(pixelSize)px image") }
    return image
}

func pngData(_ image: CGImage, pointSize: Int) -> Data {
    let rep = NSBitmapImageRep(cgImage: image)
    rep.size = NSSize(width: pointSize, height: pointSize)   // 144 dpi for @2x entries
    guard let data = rep.representation(using: .png, properties: [:])
    else { fail("PNG encoding failed") }
    return data
}

// MARK: - Output

let iconsetEntries: [(file: String, px: Int, pt: Int)] = [
    ("icon_16x16.png", 16, 16),
    ("icon_16x16@2x.png", 32, 16),
    ("icon_32x32.png", 32, 32),
    ("icon_32x32@2x.png", 64, 32),
    ("icon_128x128.png", 128, 128),
    ("icon_128x128@2x.png", 256, 128),
    ("icon_256x256.png", 256, 256),
    ("icon_256x256@2x.png", 512, 256),
    ("icon_512x512.png", 512, 512),
    ("icon_512x512@2x.png", 1024, 512),
]

let fm = FileManager.default
let iconsetURL = outputDir.appendingPathComponent("Pulse.iconset", isDirectory: true)
let masterURL = outputDir.appendingPathComponent("master-1024.png")
let icnsURL = outputDir.appendingPathComponent("AppIcon.icns")

do {
    if fm.fileExists(atPath: iconsetURL.path) { try fm.removeItem(at: iconsetURL) }
    try fm.createDirectory(at: iconsetURL, withIntermediateDirectories: true)
} catch {
    fail("could not prepare output directory \(outputDir.path): \(error.localizedDescription)")
}

var renderCache: [Int: CGImage] = [:]
func image(at px: Int) -> CGImage {
    if let cached = renderCache[px] { return cached }
    let rendered = renderIcon(pixelSize: px)
    renderCache[px] = rendered
    return rendered
}

do {
    try pngData(image(at: 1024), pointSize: 1024).write(to: masterURL)
    print("✓ master-1024.png (1024×1024)")

    for entry in iconsetEntries {
        let url = iconsetURL.appendingPathComponent(entry.file)
        try pngData(image(at: entry.px), pointSize: entry.pt).write(to: url)
    }
    print("✓ Pulse.iconset (\(iconsetEntries.count) sizes: 16…1024 px)")
} catch {
    fail("could not write PNGs: \(error.localizedDescription)")
}

// MARK: - iconutil → .icns

let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", iconsetURL.path, "-o", icnsURL.path]
do {
    try iconutil.run()
    iconutil.waitUntilExit()
} catch {
    fail("could not launch iconutil: \(error.localizedDescription)")
}
guard iconutil.terminationStatus == 0 else {
    fail("iconutil exited with status \(iconutil.terminationStatus)")
}
guard let attrs = try? fm.attributesOfItem(atPath: icnsURL.path),
      let bytes = attrs[.size] as? Int, bytes > 1024 else {
    fail("AppIcon.icns missing or implausibly small")
}
print("✓ AppIcon.icns (\(bytes / 1024) KB) → \(icnsURL.path)")
