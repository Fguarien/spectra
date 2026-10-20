#!/usr/bin/env swift
// make-icon.swift — generate Spectra's app icon (a prism splitting white light
// into a spectrum) as a full .iconset. Reproducible, no binary asset committed.
// Usage: swift make-icon.swift <output.iconset-dir>
import AppKit

let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "Spectra.iconset"
try? FileManager.default.createDirectory(atPath: out, withIntermediateDirectories: true)

func draw(_ px: Int) -> Data {
    let s = CGFloat(px)
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px,
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                               isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let ctx = NSGraphicsContext.current!.cgContext

    // macOS Big Sur+ convention: the art sits in a squircle with a transparent
    // margin (~10%), not edge-to-edge — otherwise it reads larger and squarer
    // than every system icon beside it. All drawing is in this inset content box.
    let m = s * 0.095                 // transparent margin
    let c = s - 2 * m                 // content side
    func X(_ f: CGFloat) -> CGFloat { m + c * f }   // x in content space
    func Y(_ f: CGFloat) -> CGFloat { m + c * f }   // y in content space
    func L(_ f: CGFloat) -> CGFloat { c * f }       // length / line width

    // Rounded dark background (squircle-ish corner relative to the content box).
    let r = c * 0.2237
    let bg = CGPath(roundedRect: CGRect(x: m, y: m, width: c, height: c), cornerWidth: r, cornerHeight: r, transform: nil)
    ctx.addPath(bg); ctx.clip()
    let grad = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                          colors: [NSColor(calibratedRed: 0.09, green: 0.10, blue: 0.16, alpha: 1).cgColor,
                                   NSColor(calibratedRed: 0.02, green: 0.02, blue: 0.05, alpha: 1).cgColor] as CFArray,
                          locations: [0, 1])!
    ctx.drawLinearGradient(grad, start: CGPoint(x: m, y: s - m), end: CGPoint(x: s - m, y: m), options: [])

    // Incoming white beam (left third, thin).
    ctx.setStrokeColor(NSColor.white.cgColor)
    ctx.setLineWidth(L(0.03))
    ctx.move(to: CGPoint(x: X(0.06), y: Y(0.5)))
    ctx.addLine(to: CGPoint(x: X(0.40), y: Y(0.5)))
    ctx.strokePath()

    // Spectrum fan on the right (from the prism's right face).
    let origin = CGPoint(x: X(0.52), y: Y(0.5))
    let colors: [NSColor] = [.systemRed, .systemOrange, .systemYellow, .systemGreen, .systemBlue, .systemPurple]
    let spread = L(0.16)
    for (i, col) in colors.enumerated() {
        let dy = (CGFloat(i) - CGFloat(colors.count - 1) / 2) * (spread / CGFloat(colors.count))
        ctx.setStrokeColor(col.cgColor)
        ctx.setLineWidth(L(0.022))
        ctx.move(to: origin)
        ctx.addLine(to: CGPoint(x: X(0.94), y: Y(0.5) + dy * 2.4))
        ctx.strokePath()
    }

    // The prism: a glassy triangle.
    let tri = CGMutablePath()
    tri.move(to: CGPoint(x: X(0.40), y: Y(0.30)))
    tri.addLine(to: CGPoint(x: X(0.40), y: Y(0.70)))
    tri.addLine(to: CGPoint(x: X(0.62), y: Y(0.50)))
    tri.closeSubpath()
    ctx.addPath(tri)
    ctx.setFillColor(NSColor(calibratedWhite: 1, alpha: 0.16).cgColor)
    ctx.fillPath()
    ctx.addPath(tri)
    ctx.setStrokeColor(NSColor(calibratedWhite: 1, alpha: 0.85).cgColor)
    ctx.setLineWidth(L(0.02))
    ctx.strokePath()

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

let sizes: [(String, Int)] = [
    ("icon_16x16", 16), ("icon_16x16@2x", 32),
    ("icon_32x32", 32), ("icon_32x32@2x", 64),
    ("icon_128x128", 128), ("icon_128x128@2x", 256),
    ("icon_256x256", 256), ("icon_256x256@2x", 512),
    ("icon_512x512", 512), ("icon_512x512@2x", 1024),
]
for (name, px) in sizes {
    try! draw(px).write(to: URL(fileURLWithPath: "\(out)/\(name).png"))
}
print("wrote \(sizes.count) icons to \(out)")
