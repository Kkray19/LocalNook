//
//  ClosedActivityView.swift
//  LocalNook
//
//  Copyright (C) 2026 Krish Kowli
//  Licensed under the GNU General Public License v3.0 or later. See LICENSE.
//

import SwiftUI

/// Content shown flanking the physical notch while collapsed.
///
/// The camera housing occupies the middle, so this lays out as
/// `[leading] [dead zone the width of the notch] [trailing]`.
struct ClosedActivityView: View {
    let activity: LiveActivity
    let notchWidth: CGFloat

    static let leadingWidth: CGFloat = 118
    static let trailingWidth: CGFloat = 118

    static func totalBodyWidth(notchWidth: CGFloat) -> CGFloat {
        notchWidth + leadingWidth + trailingWidth
    }

    var body: some View {
        HStack(spacing: 0) {
            leading
                .padding(.leading, 10)
                .frame(width: Self.leadingWidth, alignment: .leading)

            // The camera housing.
            Color.clear.frame(width: notchWidth)

            trailing
                .padding(.trailing, 10)
                .frame(width: Self.trailingWidth, alignment: .trailing)
        }
        .foregroundStyle(.white)
    }

    private var leading: some View {
        HStack(spacing: 6) {
            Image(systemName: activity.symbol)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(activity.tint)
                .frame(width: 14)
            Text(activity.leading)
                .font(.system(size: 10, weight: .medium))
                .lineLimit(1)
                .truncationMode(.tail)
                .foregroundStyle(.white.opacity(0.92))
            Spacer(minLength: 0)
        }
    }

    private var trailing: some View {
        HStack(spacing: 6) {
            Spacer(minLength: 0)
            if !activity.trailing.isEmpty {
                Text(activity.trailing)
                    .font(.system(size: 10, weight: .medium))
                    .monospacedDigit()
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .foregroundStyle(.white.opacity(0.65))
            }
            if let progress = activity.progress {
                Circle()
                    .trim(from: 0, to: max(0.02, min(1, progress)))
                    .stroke(activity.tint, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .frame(width: 11, height: 11)
                    .background {
                        Circle().stroke(.white.opacity(0.20), lineWidth: 2)
                            .frame(width: 11, height: 11)
                    }
            }
        }
    }
}
