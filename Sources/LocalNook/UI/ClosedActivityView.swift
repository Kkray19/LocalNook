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
    /// The pointer is resting on the trailing indicator, so it shows what it
    /// stands for instead of just that something is happening.
    var isExpanded = false

    static let leadingWidth: CGFloat = 118
    static let trailingWidth: CGFloat = 118
    /// Room for one session's name and step. Wide, but only while the pointer
    /// is on it — the collapsed default is deliberately the narrow one.
    static let expandedTrailingWidth: CGFloat = 300

    static func totalBodyWidth(notchWidth: CGFloat, expanded: Bool = false) -> CGFloat {
        notchWidth + leadingWidth + (expanded ? expandedTrailingWidth : trailingWidth)
    }

    /// Whether the trailing side has anything to expand into.
    static func canExpand(_ activity: LiveActivity) -> Bool {
        activity.isBusy && !activity.details.isEmpty
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
                .frame(
                    width: isExpanded ? Self.expandedTrailingWidth : Self.trailingWidth,
                    alignment: .trailing
                )
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

    @ViewBuilder
    private var trailing: some View {
        HStack(spacing: 6) {
            Spacer(minLength: 0)

            if isExpanded, let line = activity.details.first {
                // What the spinner stands for. Shown because the pointer is
                // resting on it, not because the notch happens to be visible.
                HStack(spacing: 5) {
                    Image(systemName: line.symbol)
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(activity.tint)
                    Text(line.name)
                        .font(.system(size: 10, weight: .semibold))
                        .lineLimit(1)
                        .foregroundStyle(.white.opacity(0.92))
                    Text(line.step)
                        .font(.system(size: 10))
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .foregroundStyle(.white.opacity(0.62))
                    if activity.details.count > 1 {
                        Text("+\(activity.details.count - 1)")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.45))
                    }
                }
                .transition(.opacity)
            } else if !activity.trailing.isEmpty {
                Text(activity.trailing)
                    .font(.system(size: 10, weight: .medium))
                    .monospacedDigit()
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .foregroundStyle(.white.opacity(0.65))
            }

            if activity.isBusy {
                BusyIndicator(tint: activity.tint)
            } else if let progress = activity.progress {
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

/// A turning arc: something is working, without saying what about.
///
/// Stops turning under Reduce Motion, where it becomes a plain ring — the
/// indicator still says "busy", it just does not spin to say it.
struct BusyIndicator: View {
    var tint: Color

    @LNState private var turning = false

    var body: some View {
        Circle()
            .trim(from: 0, to: 0.72)
            .stroke(tint, style: StrokeStyle(lineWidth: 2, lineCap: .round))
            .frame(width: 11, height: 11)
            .rotationEffect(.degrees(turning ? 360 : 0))
            .onAppear {
                guard NotchMotion.isAnimated else { return }
                withAnimation(.linear(duration: 0.9).repeatForever(autoreverses: false)) {
                    turning = true
                }
            }
            .background {
                Circle().stroke(.white.opacity(0.16), lineWidth: 2).frame(width: 11, height: 11)
            }
    }
}
