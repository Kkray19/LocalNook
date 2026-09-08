//
//  make-icon.swift
//  LocalNook — original icon artwork, drawn in code.
//
//  Copyright (C) 2026 Krish Kowli
//  Licensed under the GNU General Public License v3.0 or later.
//
//  Generates AppIcon.icns without needing Xcode's asset-catalog compiler.
//  Run:  swift scripts/make-icon.swift <output.iconset-dir>
//

import AppKit
import Foundation

let arguments = CommandLine.arguments
guard arguments.count > 1 else {
    FileHandle.standardError.write("usage: make-icon.swift <iconset-dir>\n".data(using: .utf8)!)
    exit(1)
}
let outputDirectory = URL(fileURLWithPath: arguments[1])
try? FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)

/// Draws the LocalNook mark: a deep slate squircle with a notch cut from the
/// top edge and a soft light bloom spilling out of it.
func drawIcon(size: CGFloat) -> NSImage {
    let image = NSImage(size: NSSize(width: size, height: size))
    image.lockFocus()
    guard let context = NSGraphicsContext.current?.cgContext else {
        image.unlockFocus()
        return image
    }

    let rect = CGRect(x: 0, y: 0, width: size, height: size)
    // macOS app icons sit inside a rounded square with ~10% margin.
    let inset = size * 0.055
    let body = rect.insetBy(dx: inset, dy: inset)
    let radius = body.width * 0.2237   // Apple's continuous-corner ratio

    let squircle = CGPath(
        roundedRect: body, cornerWidth: radius, cornerHeight: radius, transform: nil
    )

    context.saveGState()
    context.addPath(squircle)
    context.clip()

    // Vertical gradient body.
    let colors = [
        NSColor(calibratedRed: 0.153, green: 0.169, blue: 0.212, alpha: 1).cgColor,
        NSColor(calibratedRed: 0.055, green: 0.063, blue: 0.086, alpha: 1).cgColor,
    ] as CFArray
    if let space = CGColorSpace(name: CGColorSpace.sRGB),
       let gradient = CGGradient(colorsSpace: space, colors: colors, locations: [0, 1]) {
        context.drawLinearGradient(
            gradient,
            start: CGPoint(x: body.midX, y: body.maxY),
            end: CGPoint(x: body.midX, y: body.minY),
            options: []
        )
    }

    // Notch silhouette carved into the top edge.
    let notchWidth = body.width * 0.46
    let notchHeight = body.height * 0.145
    let notchRect = CGRect(
        x: body.midX - notchWidth / 2,
        y: body.maxY - notchHeight,
        width: notchWidth,
        height: notchHeight
    )
    let flare = notchHeight * 0.62
    let notch = CGMutablePath()
    notch.move(to: CGPoint(x: notchRect.minX - flare, y: notchRect.maxY))
    notch.addQuadCurve(
        to: CGPoint(x: notchRect.minX, y: notchRect.maxY - flare),
        control: CGPoint(x: notchRect.minX, y: notchRect.maxY)
    )
    notch.addLine(to: CGPoint(x: notchRect.minX, y: notchRect.minY + flare))
    notch.addQuadCurve(
        to: CGPoint(x: notchRect.minX + flare, y: notchRect.minY),
        control: CGPoint(x: notchRect.minX, y: notchRect.minY)
    )
    notch.addLine(to: CGPoint(x: notchRect.maxX - flare, y: notchRect.minY))
    notch.addQuadCurve(
        to: CGPoint(x: notchRect.maxX, y: notchRect.minY + flare),
        control: CGPoint(x: notchRect.maxX, y: notchRect.minY)
    )
    notch.addLine(to: CGPoint(x: notchRect.maxX, y: notchRect.maxY - flare))
    notch.addQuadCurve(
        to: CGPoint(x: notchRect.maxX + flare, y: notchRect.maxY),
        control: CGPoint(x: notchRect.maxX, y: notchRect.maxY)
    )
    notch.closeSubpath()

    context.addPath(notch)
    context.setFillColor(NSColor.black.withAlphaComponent(0.92).cgColor)
    context.fillPath()

    // Light bloom spilling down out of the notch — the "something is alive in
    // there" cue that gives the mark its identity.
    let bloomColors = [
        NSColor(calibratedRed: 0.42, green: 0.71, blue: 1.0, alpha: 0.85).cgColor,
        NSColor(calibratedRed: 0.42, green: 0.71, blue: 1.0, alpha: 0.0).cgColor,
    ] as CFArray
    if let space = CGColorSpace(name: CGColorSpace.sRGB),
       let bloom = CGGradient(colorsSpace: space, colors: bloomColors, locations: [0, 1]) {
        context.saveGState()
        context.drawRadialGradient(
            bloom,
            startCenter: CGPoint(x: notchRect.midX, y: notchRect.minY),
            startRadius: 0,
            endCenter: CGPoint(x: notchRect.midX, y: notchRect.minY),
            endRadius: body.width * 0.42,
            options: []
        )
        context.restoreGState()
    }

    // Crisp accent bar just below the notch, echoing an expanded panel.
    let barWidth = notchWidth * 0.72
    let barHeight = max(1, size * 0.022)
    let bar = CGRect(
        x: body.midX - barWidth / 2,
        y: notchRect.minY - body.height * 0.16,
        width: barWidth,
        height: barHeight
    )
    context.addPath(CGPath(
        roundedRect: bar, cornerWidth: barHeight / 2, cornerHeight: barHeight / 2, transform: nil
    ))
    context.setFillColor(NSColor.white.withAlphaComponent(0.92).cgColor)
    context.fillPath()

    context.restoreGState()

    // Hairline rim so the icon reads on a dark Dock.
    context.addPath(squircle)
    context.setStrokeColor(NSColor.white.withAlphaComponent(0.10).cgColor)
    context.setLineWidth(max(1, size * 0.004))
    context.strokePath()

    image.unlockFocus()
    return image
}

func writePNG(_ image: NSImage, pixels: Int, to url: URL) throws {
    guard let representation = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
    ) else { return }
    representation.size = NSSize(width: pixels, height: pixels)

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: representation)
    drawIcon(size: CGFloat(pixels)).draw(in: NSRect(x: 0, y: 0, width: pixels, height: pixels))
    NSGraphicsContext.restoreGraphicsState()

    guard let data = representation.representation(using: .png, properties: [:]) else { return }
    try data.write(to: url)
}

let variants: [(name: String, pixels: Int)] = [
    ("icon_16x16", 16), ("icon_16x16@2x", 32),
    ("icon_32x32", 32), ("icon_32x32@2x", 64),
    ("icon_128x128", 128), ("icon_128x128@2x", 256),
    ("icon_256x256", 256), ("icon_256x256@2x", 512),
    ("icon_512x512", 512), ("icon_512x512@2x", 1024),
]

for variant in variants {
    let url = outputDirectory.appendingPathComponent("\(variant.name).png")
    try writePNG(NSImage(), pixels: variant.pixels, to: url)
}
print("wrote \(variants.count) icon variants to \(outputDirectory.path)")
