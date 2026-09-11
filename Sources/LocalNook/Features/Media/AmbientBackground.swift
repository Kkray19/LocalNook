//
//  AmbientBackground.swift
//  LocalNook
//
//  Copyright (C) 2026 Krish Kowli
//  Licensed under the GNU General Public License v3.0 or later. See LICENSE.
//
//  A soft wash of colour behind the open notch, drawn from the playing
//  artwork.
//
//  NotchNook tints the notch to match what is playing. This does the same from
//  scratch: the album art is downsampled to a handful of pixels, an average
//  and a single accent colour are read off them, and the open panel carries a
//  gentle gradient of the two. It is deliberately restrained — a wash, not a
//  spotlight — and off by default is one toggle away.
//
//  The extraction works on raw pixels, not an NSImage, so the part that is
//  easy to get wrong — what colour a picture "is" — is tested against images
//  built pixel by pixel, with no rendering.
//

import CoreGraphics
import Foundation

/// A colour, 0…1 per channel. Its own type rather than SwiftUI.Color so the
/// extraction stays off the main actor and testable without a view.
nonisolated struct AmbientColor: Equatable, Sendable {
    var red: Double
    var green: Double
    var blue: Double

    var brightness: Double { (red * 0.299 + green * 0.587 + blue * 0.114) }

    /// Distance from grey, 0 (grey) … 1 (fully saturated).
    var saturation: Double {
        let hi = max(red, green, blue), lo = min(red, green, blue)
        return hi <= 0 ? 0 : (hi - lo) / hi
    }
}

/// The two colours an ambient wash is drawn from.
nonisolated struct AmbientPalette: Equatable, Sendable {
    var base: AmbientColor
    var accent: AmbientColor
    /// True when there was nothing worth tinting from — silence, or art too
    /// flat and dark to read. The view shows no wash for a default palette.
    var isDefault: Bool

    static let none = AmbientPalette(
        base: AmbientColor(red: 0, green: 0, blue: 0),
        accent: AmbientColor(red: 0, green: 0, blue: 0),
        isDefault: true
    )

    /// Reads a palette from already-downsampled RGBA bytes.
    ///
    /// The base is the average colour; the accent is the most colourful pixel,
    /// which is what stops a mostly-grey cover with one bright detail from
    /// washing the notch grey. A cover with no colour at all — very dark, very
    /// flat — yields the default palette, so black art does not paint a black
    /// wash over a black panel.
    static func extract(fromRGBA bytes: [UInt8], pixelCount: Int) -> AmbientPalette {
        guard pixelCount > 0, bytes.count >= pixelCount * 4 else { return .none }

        var sumR = 0.0, sumG = 0.0, sumB = 0.0
        var accent = AmbientColor(red: 0, green: 0, blue: 0)
        var accentScore = -1.0

        for pixel in 0..<pixelCount {
            let base = pixel * 4
            let r = Double(bytes[base]) / 255
            let g = Double(bytes[base + 1]) / 255
            let b = Double(bytes[base + 2]) / 255
            sumR += r; sumG += g; sumB += b
            let colour = AmbientColor(red: r, green: g, blue: b)
            // A colour that is both saturated and not too dark makes the best
            // accent — a bright pure hue beats a dark muddy one.
            let score = colour.saturation * (0.4 + 0.6 * colour.brightness)
            if score > accentScore { accentScore = score; accent = colour }
        }

        let count = Double(pixelCount)
        let averaged = AmbientColor(red: sumR / count, green: sumG / count, blue: sumB / count)

        // Nothing worth tinting from: the art is dark and flat, so its "colour"
        // is a near-black nobody would call a colour. The accent *score* rather
        // than its raw saturation, because at near-zero brightness a one-bit
        // channel difference reads as fully saturated while being invisible.
        if averaged.brightness < 0.08, accentScore < 0.15 {
            return .none
        }
        // If no pixel had real colour, the accent is just the average again.
        let resolvedAccent = accentScore > 0.05 ? accent : averaged
        return AmbientPalette(base: averaged, accent: resolvedAccent, isDefault: false)
    }

    /// Downsamples an image to `side`×`side` and extracts a palette.
    ///
    /// Tiny on purpose: a 12×12 average is a colour impression, and drawing 144
    /// pixels through a CGContext costs nothing. Returns the default palette
    /// rather than nil for any failure, so the caller has one thing to handle.
    static func from(_ image: CGImage, side: Int = 12) -> AmbientPalette {
        guard side > 0 else { return .none }
        let colourSpace = CGColorSpaceCreateDeviceRGB()
        var bytes = [UInt8](repeating: 0, count: side * side * 4)
        guard let context = CGContext(
            data: &bytes, width: side, height: side, bitsPerComponent: 8,
            bytesPerRow: side * 4, space: colourSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return .none }
        context.draw(image, in: CGRect(x: 0, y: 0, width: side, height: side))
        return extract(fromRGBA: bytes, pixelCount: side * side)
    }
}
