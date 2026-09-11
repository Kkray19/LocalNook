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
///
/// ── Compact, because the wings sit on the menu bar ─────────────────────────
///
/// macOS reserves only the notch itself. Either side of it belongs to the
/// frontmost app's menus and to the status items, and no app can push those
/// aside — or even learn where they are without Accessibility, which LocalNook
/// never requests. Wings wide enough for words therefore cover menus: at 118pt
/// a side they reached 110pt into the menu bar each way and hid Chrome's Help
/// menu. So a wing holds a symbol — the maker's badge on the left; the spinner,
/// a progress ring or a status dot on the right — and everything worded is
/// revealed by resting the pointer on the right wing.
///
/// ── The camera gap stays over the camera ──────────────────────────────────
///
/// When the right wing expands and the left does not, the body is no longer
/// symmetric about the notch. It used to be centred anyway, which slid the
/// reserved gap left by half the difference — 91pt at the old widths — and
/// drew the first stretch of the expanded text under the camera housing,
/// where nobody could read it. The body is now drawn offset by that
/// half-difference (`bodyOffset`), and the collapsed window is sized
/// symmetrically about the notch (`canvasWidth`) so the offset body is never
/// clipped by its own window.
struct ClosedActivityView: View {
    let activity: LiveActivity
    let notchWidth: CGFloat
    /// The pointer is resting on the trailing indicator, so it shows what it
    /// stands for instead of just that something is happening.
    var isExpanded = false

    /// Room for one symbol and its padding, and no more. See above.
    static let leadingWidth: CGFloat = 32
    static let trailingWidth: CGFloat = 32
    /// Room for one session's name and step, or an activity's words. Wide,
    /// but only while the pointer is on it — covering a menu is acceptable
    /// for as long as you are deliberately looking at the notch, not longer.
    static let expandedTrailingWidth: CGFloat = 300

    static func trailingWidth(expanded: Bool) -> CGFloat {
        expanded ? expandedTrailingWidth : trailingWidth
    }

    /// The drawn body: both wings and the dead zone between them.
    static func totalBodyWidth(notchWidth: CGFloat, expanded: Bool = false) -> CGFloat {
        notchWidth + leadingWidth + trailingWidth(expanded: expanded)
    }

    /// How far right of centre the body is drawn, so that its dead zone sits
    /// over the camera whatever the two wings' widths.
    static func bodyOffset(expanded: Bool) -> CGFloat {
        (trailingWidth(expanded: expanded) - leadingWidth) / 2
    }

    /// The collapsed window's width. Symmetric about the notch, so a body
    /// offset to one side still fits inside it.
    static func canvasWidth(notchWidth: CGFloat, expanded: Bool = false) -> CGFloat {
        notchWidth + 2 * max(leadingWidth, trailingWidth(expanded: expanded))
    }

    /// Where the dead zone's centre lands, relative to the screen's centre.
    /// Zero is the only right answer; this exists so it can be asserted.
    static func deadZoneCentre(notchWidth: CGFloat, expanded: Bool) -> CGFloat {
        -totalBodyWidth(notchWidth: notchWidth, expanded: expanded) / 2
            + bodyOffset(expanded: expanded) + leadingWidth + notchWidth / 2
    }

    /// Whether resting on the right wing has anything to reveal.
    ///
    /// With compact wings every worded part of an activity is hidden, so any
    /// words count — a song, a timer and an agent's details alike. Only an
    /// activity with no words at all has nothing to expand into.
    static func canExpand(_ activity: LiveActivity) -> Bool {
        !activity.details.isEmpty || !activity.leading.isEmpty || !activity.trailing.isEmpty
    }

    var body: some View {
        HStack(spacing: 0) {
            leading
                .frame(width: Self.leadingWidth)

            // The camera housing.
            Color.clear.frame(width: notchWidth)

            trailing
                .padding(.trailing, 10)
                .frame(width: Self.trailingWidth(expanded: isExpanded), alignment: .trailing)
        }
        .foregroundStyle(.white)
        // The words the wings no longer show are still what VoiceOver reads.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            [activity.leading, activity.trailing].filter { !$0.isEmpty }.joined(separator: ", ")
        )
    }

    private var leading: some View {
        Image(systemName: activity.symbol)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(activity.tint)
            .frame(width: 14)
    }

    private var trailing: some View {
        HStack(spacing: 6) {
            Spacer(minLength: 0)
            if isExpanded {
                revealed.transition(.opacity)
            }
            indicator
        }
    }

    /// What the indicator stands for. Shown because the pointer is resting on
    /// it, not because the notch happens to be visible.
    @ViewBuilder
    private var revealed: some View {
        if let line = activity.details.first {
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
        } else {
            HStack(spacing: 5) {
                if !activity.leading.isEmpty {
                    Text(activity.leading)
                        .font(.system(size: 10, weight: .semibold))
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .foregroundStyle(.white.opacity(0.92))
                }
                if !activity.trailing.isEmpty {
                    Text(activity.trailing)
                        .font(.system(size: 10, weight: .medium))
                        .monospacedDigit()
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .foregroundStyle(.white.opacity(0.65))
                }
            }
        }
    }

    /// Always a symbol, never a word: spinning while an agent is working, a
    /// ring where there is a quantity, and otherwise a steady dot in the
    /// activity's colour — "something is here" without claiming anything is
    /// in progress.
    @ViewBuilder
    private var indicator: some View {
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
        } else {
            Circle()
                .fill(activity.tint.opacity(0.9))
                .frame(width: 6, height: 6)
                .frame(width: 11, height: 11)
        }
    }
}

/// A turning arc: something is working, without saying what about.
///
/// Stops turning under Reduce Motion, where it becomes a plain ring — the
/// indicator still says "busy", it just does not spin to say it.
///
/// Drawn by the render server rather than by SwiftUI: a `.repeatForever` here
/// kept the whole panel re-laying out at the display's refresh rate for as long
/// as any agent was working, which was most of the time. See
/// RenderServerAnimation.
struct BusyIndicator: View {
    var tint: Color

    var body: some View {
        SpinningArc(tint: tint, animated: NotchMotion.isAnimated)
            .frame(width: 11, height: 11)
    }
}
