#!/usr/bin/env swift
//
//  make-icon.swift — renders the Byte Pulse app icon entirely with CoreGraphics.
//
//  Design: dark near-black squircle plate (#2A2A2E → #1C1C1F vertical gradient)
//  with a soft inner top highlight and a baked-in drop shadow (macOS pre-26
//  icon style), containing three white pill-shaped bars of increasing height
//  (usage-meter bar chart motif), slightly off-center, each with a very subtle
//  white-to-transparent vertical fade.
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

/// Bars (bar-chart / usage-meter motif). Group is shifted 12 pt left of
/// center to optically balance the rising silhouette.
let barWidth: CGFloat = 100
let barXs: [CGFloat] = [288, 450, 612]        // step = width 100 + gap 62
let barHeights: [CGFloat] = [230, 350, 470]   // increasing left → right
let barBaselineY: CGFloat = 290

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

    // 1) Plate: subtle vertical gradient, lighter at the top (#2A2A2E → #1C1C1F).
    let plateGradient = CGGradient(colorsSpace: srgb,
                                   colors: [rgb(0x2A2A2E), rgb(0x1C1C1F)] as CFArray,
                                   locations: [0, 1])!
    ctx.drawLinearGradient(plateGradient,
                           start: CGPoint(x: plateRect.midX, y: plateRect.maxY),
                           end: CGPoint(x: plateRect.midX, y: plateRect.minY),
                           options: [])

    // 2) Soft inner highlight fading down from the top edge.
    let highlight = CGGradient(colorsSpace: srgb,
                               colors: [white(0.12), white(0.0)] as CFArray,
                               locations: [0, 1])!
    ctx.drawLinearGradient(highlight,
                           start: CGPoint(x: plateRect.midX, y: plateRect.maxY),
                           end: CGPoint(x: plateRect.midX, y: plateRect.maxY - 290),
                           options: [])

    // 3) Three white pill bars of increasing height, very subtle fade to the base.
    let barGradient = CGGradient(colorsSpace: srgb,
                                 colors: [white(1.0), white(0.72)] as CFArray,
                                 locations: [0, 1])!
    for (x, height) in zip(barXs, barHeights) {
        let bar = CGRect(x: x, y: barBaselineY, width: barWidth, height: height)
        let pill = CGPath(roundedRect: bar, cornerWidth: barWidth / 2,
                          cornerHeight: barWidth / 2, transform: nil)
        ctx.saveGState()
        ctx.addPath(pill)
        ctx.clip()
        ctx.drawLinearGradient(barGradient,
                               start: CGPoint(x: bar.midX, y: bar.maxY),
                               end: CGPoint(x: bar.midX, y: bar.minY),
                               options: [])
        ctx.restoreGState()
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
