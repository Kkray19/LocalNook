//
//  NotchSurface.swift
//  LocalNook
//
//  Copyright (C) 2026 Krish Kowli
//  Licensed under the GNU General Public License v3.0 or later. See LICENSE.
//
//  The painted surface of the notch: opaque black, or macOS 26 Liquid Glass.
//
//  One rule drives the logic here. On a Mac with a real camera housing, the
//  *collapsed* notch has to be opaque black — it is pretending to be the
//  housing, and a translucent panel sitting on top of an opaque black cutout
//  reads as a smudge rather than an effect. Expanded, the panel has left the
//  housing behind and glass looks the way it should.
//
//  Displays with no housing — every external monitor — have nothing to match,
//  so glass applies there even while collapsed.
//

import SwiftUI

struct NotchSurface: View {
    let topRadius: CGFloat
    let bottomRadius: CGFloat
    let isOpen: Bool
    /// Whether this display has a real camera housing to blend into.
    let hasPhysicalNotch: Bool

    @EnvironmentObject var settings: Settings
    @ObservedObject private var media = MediaManager.shared

    private var shape: NotchShape {
        NotchShape(topRadius: topRadius, bottomRadius: bottomRadius)
    }

    /// Whether glass should be used for the state being drawn right now.
    var usesGlass: Bool {
        Self.usesGlass(settings: settings, isOpen: isOpen, hasPhysicalNotch: hasPhysicalNotch)
    }

    /// The decision on its own, so it can be tested without standing up a view
    /// hierarchy and an environment.
    static func usesGlass(settings: Settings, isOpen: Bool, hasPhysicalNotch: Bool) -> Bool {
        guard settings.usesLiquidGlass else { return false }
        if isOpen { return true }
        // Collapsed over a real camera housing, glass reads as a smudge.
        return settings.glassWhenCollapsed || !hasPhysicalNotch
    }

    /// How opaque the surface is drawn.
    ///
    /// Expanded only, for both materials, and for the same reason: a collapsed
    /// notch sits over the physical camera housing and has to match it exactly.
    /// Letting the desktop through there would draw a translucent rectangle
    /// around the housing, which is the one thing this surface must never do —
    /// so the slider stops at the collapsed state whatever it is set to.
    static func surfaceOpacity(settings: Settings, isOpen: Bool, usesGlass: Bool) -> Double {
        guard isOpen else { return 1 }
        let raw = usesGlass ? settings.glassOpacity : settings.expandedOpacity
        return min(1, max(0.2, raw))
    }

    private var opacity: Double {
        Self.surfaceOpacity(settings: settings, isOpen: isOpen, usesGlass: usesGlass)
    }

    var body: some View {
        paintedSurface
            .overlay { ambientWash }
    }

    /// The colour drawn from the playing artwork, over the open panel only.
    ///
    /// A wash, not a spotlight: a soft top-down gradient of the artwork's
    /// average and its most colourful pixel, capped low so it never competes
    /// with the widgets. Absent when off, when collapsed, or when there is
    /// nothing playing worth reading a colour from — see AmbientPalette.
    @ViewBuilder
    private var ambientWash: some View {
        let palette = media.ambientPalette
        if isOpen, settings.ambientBackground, !palette.isDefault {
            let alpha = min(0.45, max(0, settings.ambientIntensity) * 0.45)
            LinearGradient(
                colors: [
                    color(palette.accent).opacity(alpha),
                    color(palette.base).opacity(alpha * 0.7),
                    .clear
                ],
                startPoint: .top, endPoint: .bottom
            )
            .clipShape(shape)
            .opacity(opacity)
            .allowsHitTesting(false)
            .animation(NotchMotion.content, value: palette)
        }
    }

    private func color(_ c: AmbientColor) -> Color {
        Color(red: c.red, green: c.green, blue: c.blue)
    }

    @ViewBuilder
    private var paintedSurface: some View {
        if #available(macOS 26.0, *), usesGlass {
            glassSurface
                // Glass has no colour of its own, so a hairline is what gives
                // the silhouette an edge against a busy desktop. Solid black
                // needs no such help and reads better without one.
                .overlay {
                    shape.stroke(Color.white.opacity(0.14), lineWidth: 0.5)
                }
                // The whole surface together, so the scrim and the hairline
                // fade with the glass rather than floating on top of a panel
                // that is no longer there.
                .opacity(opacity)
        } else {
            // Deliberately unadorned: no border, no gradient, no glow. The
            // silhouette and the shadow do the work.
            //
            // Transparency applies to the expanded panel only. Collapsed, this
            // is the camera housing's twin and must be indistinguishable from
            // it — see Settings.expandedOpacity.
            shape.fill(Color.black.opacity(opacity))
        }
    }

    @available(macOS 26.0, *)
    private var glassSurface: some View {
        // A dark scrim under the glass. Without it, widget text sits on whatever
        // the desktop happens to be showing and can become unreadable over a
        // bright wallpaper; the glass alone does not guarantee contrast.
        shape
            .fill(Color.black.opacity(settings.glassDimming))
            .glassEffect(glass, in: shape)
    }

    @available(macOS 26.0, *)
    private var glass: Glass {
        switch settings.glassStyle {
        case .regular: .regular
        case .clear: .clear
        }
    }
}
