//
//  Glyph.swift
//  LocalNook
//
//  Copyright (C) 2026 Krish Kowli
//  Licensed under the GNU General Public License v3.0 or later. See LICENSE.
//
//  Original LocalNook artwork, drawn in code so the app ships no binary image
//  assets and needs no Xcode asset-catalog compiler.
//

import AppKit

extension NSImage {
    /// The LocalNook mark: a notch silhouette with a dot beneath it.
    ///
    /// Drawn as a template image so it adapts to light/dark menu bars.
    static func localNookGlyph(pointSize: CGFloat) -> NSImage {
        let width = pointSize * 1.25
        let height = pointSize
        let image = NSImage(size: NSSize(width: width, height: height), flipped: false) { rect in
            let notchWidth = rect.width * 0.62
            let notchHeight = rect.height * 0.44
            let notch = NSRect(
                x: rect.midX - notchWidth / 2,
                y: rect.maxY - notchHeight,
                width: notchWidth,
                height: notchHeight
            )

            let path = NSBezierPath()
            let radius = notchHeight * 0.42
            path.move(to: NSPoint(x: notch.minX - radius, y: notch.maxY))
            path.curve(
                to: NSPoint(x: notch.minX, y: notch.maxY - radius),
                controlPoint1: NSPoint(x: notch.minX, y: notch.maxY),
                controlPoint2: NSPoint(x: notch.minX, y: notch.maxY)
            )
            path.line(to: NSPoint(x: notch.minX, y: notch.minY + radius))
            path.curve(
                to: NSPoint(x: notch.minX + radius, y: notch.minY),
                controlPoint1: NSPoint(x: notch.minX, y: notch.minY),
                controlPoint2: NSPoint(x: notch.minX, y: notch.minY)
            )
            path.line(to: NSPoint(x: notch.maxX - radius, y: notch.minY))
            path.curve(
                to: NSPoint(x: notch.maxX, y: notch.minY + radius),
                controlPoint1: NSPoint(x: notch.maxX, y: notch.minY),
                controlPoint2: NSPoint(x: notch.maxX, y: notch.minY)
            )
            path.line(to: NSPoint(x: notch.maxX, y: notch.maxY - radius))
            path.curve(
                to: NSPoint(x: notch.maxX + radius, y: notch.maxY),
                controlPoint1: NSPoint(x: notch.maxX, y: notch.maxY),
                controlPoint2: NSPoint(x: notch.maxX, y: notch.maxY)
            )
            path.close()
            NSColor.black.setFill()
            path.fill()

            let dotSize = rect.height * 0.20
            let dot = NSBezierPath(ovalIn: NSRect(
                x: rect.midX - dotSize / 2,
                y: notch.minY - dotSize - rect.height * 0.10,
                width: dotSize,
                height: dotSize
            ))
            dot.fill()
            return true
        }
        image.isTemplate = true
        return image
    }
}
