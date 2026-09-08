//
//  NotchTheme.swift
//  LocalNook
//
//  Copyright (C) 2026 Krish Kowli
//  Licensed under the GNU General Public License v3.0 or later. See LICENSE.
//
//  One place for spacing, type and colour so every widget composes on the same
//  grid. These are LocalNook's own starting values, chosen to suit the panel
//  size and the system font — not measurements taken from any other app.
//

import SwiftUI

enum Theme {
    // MARK: Spacing

    /// Gap between the panel edge and its content.
    static let contentInset: CGFloat = 14
    /// Gap between dashboard sections.
    static let sectionGap: CGFloat = 14
    /// Gap between rows inside a section.
    static let rowGap: CGFloat = 6
    /// Gap between an icon and its label.
    static let labelGap: CGFloat = 8

    // MARK: Radii

    static let cardRadius: CGFloat = 10
    static let artworkRadius: CGFloat = 9
    static let chipRadius: CGFloat = 7

    // MARK: Type
    //
    // System font throughout. The scale is deliberately short: a title, a
    // subtitle, a caption. Secondary text stays at 11pt rather than shrinking
    // to the point of illegibility.

    static let title = Font.system(size: 15, weight: .semibold)
    static let sectionTitle = Font.system(size: 11, weight: .semibold)
    static let body = Font.system(size: 12, weight: .regular)
    static let subtitle = Font.system(size: 12, weight: .regular)
    static let caption = Font.system(size: 10.5, weight: .medium)
    /// For numerals that should read as data, not prose.
    static let display = Font.system(size: 26, weight: .bold, design: .rounded)
    static let displaySmall = Font.system(size: 17, weight: .semibold, design: .rounded)

    // MARK: Colour
    //
    // Colour comes from artwork and status, not from chrome. Text uses a short
    // opacity ladder so hierarchy stays consistent across widgets.

    static let primaryText = Color.white
    static let secondaryText = Color.white.opacity(0.62)
    static let tertiaryText = Color.white.opacity(0.42)
    static let quaternaryText = Color.white.opacity(0.28)

    /// Near-black grouping surface. Used only where grouping needs clarifying —
    /// a text editor, a pressable card — never as decoration.
    static let surface = Color.white.opacity(0.07)
    static let surfaceHover = Color.white.opacity(0.12)
    static let surfaceActive = Color.white.opacity(0.17)

    /// Hairline between dashboard sections. Deliberately faint: it should
    /// separate without reading as a border.
    static let divider = Color.white.opacity(0.10)

    static let accent = Color(red: 0.20, green: 0.55, blue: 1.0)
    static let weekend = Color(red: 1.0, green: 0.42, blue: 0.42)
    static let positive = Color(red: 0.30, green: 0.82, blue: 0.45)
    static let warning = Color(red: 1.0, green: 0.65, blue: 0.25)
}

/// A faint vertical rule between dashboard sections.
struct SectionDivider: View {
    var body: some View {
        Rectangle()
            .fill(Theme.divider)
            .frame(width: 1)
            .padding(.vertical, 4)
    }
}

/// Shared empty/permission state, sized for a dashboard column.
struct CompactMessage: View {
    let symbol: String
    let title: String
    var detail: String? = nil
    var actionTitle: String? = nil
    var action: (() -> Void)? = nil

    var body: some View {
        VStack(spacing: 4) {
            Image(systemName: symbol)
                .font(.system(size: 15, weight: .light))
                .foregroundStyle(Theme.tertiaryText)
            Text(title)
                .font(Theme.caption)
                .foregroundStyle(Theme.secondaryText)
                .multilineTextAlignment(.center)
            if let detail {
                Text(detail)
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.quaternaryText)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .buttonStyle(.plain)
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(Theme.primaryText)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 3.5)
                    .background(Capsule().fill(Theme.surfaceHover))
                    .padding(.top, 1)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
