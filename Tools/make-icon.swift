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

    // Rounded dark background.
    let r = s * 0.22
    let bg = CGPath(roundedRect: CGRect(x: 0, y: 0, width: s, height: s), cornerWidth: r, cornerHeight: r, transform: nil)
    ctx.addPath(bg); ctx.clip()
    let grad = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                          colors: [NSColor(calibratedRed: 0.09, green: 0.10, blue: 0.16, alpha: 1).cgColor,
                                   NSColor(calibratedRed: 0.02, green: 0.02, blue: 0.05, alpha: 1).cgColor] as CFArray,
                          locations: [0, 1])!
    ctx.drawLinearGradient(grad, start: CGPoint(x: 0, y: s), end: CGPoint(x: s, y: 0), options: [])

    // Incoming white beam (left third, thin).
    ctx.setStrokeColor(NSColor.white.cgColor)
    ctx.setLineWidth(s * 0.03)
    ctx.move(to: CGPoint(x: s * 0.06, y: s * 0.5))
    ctx.addLine(to: CGPoint(x: s * 0.40, y: s * 0.5))
    ctx.strokePath()

    // Spectrum fan on the right (from the prism's right face).
    let origin = CGPoint(x: s * 0.52, y: s * 0.5)
    let colors: [NSColor] = [.systemRed, .systemOrange, .systemYellow, .systemGreen, .systemBlue, .systemPurple]
    let spread = s * 0.16
    for (i, c) in colors.enumerated() {
        let dy = (CGFloat(i) - CGFloat(colors.count - 1) / 2) * (spread / CGFloat(colors.count))
        ctx.setStrokeColor(c.cgColor)
        ctx.setLineWidth(s * 0.022)
        ctx.move(to: origin)
        ctx.addLine(to: CGPoint(x: s * 0.94, y: s * 0.5 + dy * 2.4))
        ctx.strokePath()
    }

    // The prism: a glassy triangle.
    let tri = CGMutablePath()
    tri.move(to: CGPoint(x: s * 0.40, y: s * 0.30))
    tri.addLine(to: CGPoint(x: s * 0.40, y: s * 0.70))
    tri.addLine(to: CGPoint(x: s * 0.62, y: s * 0.50))
    tri.closeSubpath()
    ctx.addPath(tri)
    ctx.setFillColor(NSColor(calibratedWhite: 1, alpha: 0.16).cgColor)
    ctx.fillPath()
    ctx.addPath(tri)
    ctx.setStrokeColor(NSColor(calibratedWhite: 1, alpha: 0.85).cgColor)
    ctx.setLineWidth(s * 0.02)
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
