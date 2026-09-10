//
//  NotchRootView.swift
//  LocalNook
//
//  Copyright (C) 2026 Krish Kowli
//  Licensed under the GNU General Public License v3.0 or later. See LICENSE.
//

import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Root of the panel's SwiftUI hierarchy.
///
/// The hosting panel is a fixed size (always big enough for the open state);
/// this view animates the drawn notch inside it. Resizing the panel every frame
/// causes visible tearing — animating the content does not.
struct NotchRootView: View {
    @ObservedObject var model: NotchViewModel
    @EnvironmentObject var settings: Settings
    @ObservedObject private var activities = LiveActivityCenter.shared
    @ObservedObject private var hud = HUDController.shared

    private var isOpen: Bool { model.state == .open }

    private var topRadius: CGFloat {
        isOpen ? settings.openCornerRadius : settings.closedCornerRadius
    }

    private var bottomRadius: CGFloat {
        isOpen ? settings.openCornerRadius : settings.closedCornerRadius + 4
    }

    /// The activity shown beside the collapsed notch, if any.
    ///
    /// A HUD change (volume, brightness) outranks a standing activity — the
    /// user just pressed a key and expects immediate feedback.
    private var closedActivity: LiveActivity? {
        guard !isOpen, !model.isSuppressed, model.effectiveClosedHeight > 0 else { return nil }
        if let hudState = hud.state { return Self.activity(for: hudState) }
        return activities.current
    }

    private static func activity(for state: HUDState) -> LiveActivity {
        LiveActivity(
            id: "hud.\(state.kind)",
            symbol: state.isMuted ? "speaker.slash.fill" : state.kind.symbol,
            tint: .white,
            leading: state.kind.label,
            trailing: state.isMuted ? "Muted" : "\(Int((state.value * 100).rounded()))%",
            style: .transient,
            progress: state.isMuted ? 0 : state.value,
            priority: 100
        )
    }

    private var bodyWidth: CGFloat {
        if isOpen { return NotchGeometry.openSize.width }
        // Widen the collapsed notch to make room for a live activity.
        if closedActivity != nil {
            return ClosedActivityView.totalBodyWidth(
                notchWidth: model.closedSize.width, expanded: activities.trailingExpanded
            )
        }
        return model.closedSize.width
    }

    /// How far right the collapsed body is drawn, so the gap left for the
    /// camera stays over the camera when the wings differ in width. See
    /// ClosedActivityView — centring it instead is what hid expanded text
    /// under the housing.
    private var bodyOffset: CGFloat {
        guard !isOpen, closedActivity != nil else { return 0 }
        return ClosedActivityView.bodyOffset(expanded: activities.trailingExpanded)
    }

    private var bodyHeight: CGFloat {
        isOpen ? NotchGeometry.openSize.height : model.effectiveClosedHeight
    }

    /// Drop target size. When closed this deliberately stays close to the notch
    /// itself — the panel is far wider than the visible notch, and a drop zone
    /// spanning the whole panel would hijack drags passing near the screen top.
    private var dropTargetSize: CGSize {
        if isOpen { return NotchGeometry.openSize }
        return CGSize(
            width: bodyWidth,
            height: model.effectiveClosedHeight
        )
    }

    var body: some View {
        ZStack(alignment: .top) {
            // Spacer only — `Color.clear` is hit-testable in SwiftUI, so
            // without this it silently swallows every click across the whole
            // panel, making the top of the screen unusable for other apps.
            Color.clear
                .allowsHitTesting(false)

            dropTarget
            hoverRegion

            notchBody
                .frame(
                    width: NotchShape.totalWidth(forBody: bodyWidth, topRadius: topRadius),
                    height: bodyHeight
                )
                // Before the animation modifiers, so the shift animates with
                // the wing it is compensating for.
                .offset(x: bodyOffset)
                // Opening runs the closing curve backwards; closing is
                // untouched. Evaluated with the new value of `isOpen`, so the
                // direction being animated picks its own curve.
                .animation(isOpen ? NotchMotion.expandOpening : NotchMotion.expand,
                           value: isOpen)
                .animation(NotchMotion.quick, value: model.closedSize)
                .animation(NotchMotion.expand, value: closedActivity?.id)
                .animation(NotchMotion.quick, value: activities.trailingExpanded)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .opacity(model.isSuppressed && !isOpen ? 0 : 1)
        .animation(NotchMotion.content, value: model.isSuppressed)
    }

    /// Pointer tracking for exactly the interactive region.
    ///
    /// Deliberately not `.onHover` on the whole panel: the panel is much wider
    /// than the visible notch, so that would open on any pointer crossing the
    /// top of the screen.
    private var hoverRegion: some View {
        HoverTracker { hovering in
            // The other half of the live-input door the deterministic suite
            // closes; see NotchWindowController.ignoresLiveInput.
            guard !NotchWindowController.shared.ignoresLiveInput else { return }
            guard !model.isSuppressed else { return }
            model.isHovering = hovering
            if hovering {
                model.scheduleOpen()
            } else if !model.isDragTargeting {
                model.scheduleClose()
            }
        }
        .frame(width: hoverSize.width, height: hoverSize.height)
    }

    /// The region that counts as "on the notch".
    private var hoverSize: CGSize {
        if isOpen { return NotchGeometry.openSize }
        // Deliberately the notch *core*, not `bodyWidth`. When a live activity
        // is showing, the drawn body stretches to roughly 445pt; hovering that
        // whole strip would expand the notch whenever the pointer passed near
        // the top of the screen, which is the opposite of what anyone wants.
        // The activity wings are display-only.
        let width = NotchShape.totalWidth(
            forBody: model.closedSize.width, topRadius: topRadius
        )
        // A few points of slop makes the very top screen edge easier to hit.
        return CGSize(width: width, height: max(model.effectiveClosedHeight, 4) + 3)
    }

    /// Invisible catcher that expands the notch when a drag arrives over it.
    private var dropTarget: some View {
        Color.clear
            .frame(width: dropTargetSize.width, height: dropTargetSize.height)
            .contentShape(Rectangle())
            .onDrop(
                of: [.fileURL, .url, .image, .text, .plainText],
                isTargeted: Binding(
                    get: { model.isDragTargeting },
                    set: { handleDragTargeting($0) }
                )
            ) { providers in
                receive(providers)
            }
    }

    /// Auto-expands onto the shelf while something is being dragged over the
    /// notch, and lets it collapse again once the drag leaves.
    private func handleDragTargeting(_ targeting: Bool) {
        guard settings.shelfAutoExpandOnDrag else { return }
        model.isDragTargeting = targeting
        if targeting {
            model.page = .tray
            model.open(source: .drag)
        } else if model.state == .open {
            model.scheduleClose()
        }
    }

    private func receive(_ providers: [NSItemProvider]) -> Bool {
        model.isDragTargeting = false
        model.page = .tray
        model.open(source: .drag)

        var handled = false
        for provider in providers {
            if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                handled = true
                _ = provider.loadObject(ofClass: URL.self) { url, _ in
                    guard let url, url.isFileURL else { return }
                    Task { @MainActor in ShelfStore.shared.add(.fromFile(url)) }
                }
            } else if provider.hasItemConformingToTypeIdentifier(UTType.url.identifier) {
                handled = true
                _ = provider.loadObject(ofClass: URL.self) { url, _ in
                    guard let url else { return }
                    Task { @MainActor in
                        ShelfStore.shared.add(url.isFileURL ? .fromFile(url) : .fromURL(url))
                    }
                }
            } else if provider.canLoadObject(ofClass: NSString.self) {
                handled = true
                _ = provider.loadObject(ofClass: NSString.self) { text, _ in
                    guard let text = text as? String else { return }
                    Task { @MainActor in
                        let board = NSPasteboard(name: .init("com.localnook.drop"))
                        board.clearContents()
                        board.setString(text, forType: .string)
                        _ = ShelfStore.shared.ingestReportingOutcome(board)
                    }
                }
            }
        }
        return handled
    }

    private var notchBody: some View {
        NotchSurface(
            topRadius: topRadius,
            bottomRadius: bottomRadius,
            isOpen: isOpen,
            hasPhysicalNotch: model.displayHasPhysicalNotch
        )
            .overlay(alignment: .top) { content }
            // The content is composed at its final size, so it has to be masked
            // by the silhouette while that silhouette is still growing.
            // Clipping here rather than after the shadow keeps the shadow
            // following the visible edge.
            .clipShape(NotchShape(topRadius: topRadius, bottomRadius: bottomRadius))
            // Restrained: enough to lift the panel off the desktop, not enough
            // to read as a halo. The edge treatment lives in NotchSurface,
            // because only the glass material needs one.
            .shadow(color: .black.opacity(isOpen ? 0.30 : 0), radius: 13, y: 5)
            .contentShape(NotchShape(topRadius: topRadius, bottomRadius: bottomRadius))
            .onTapGesture {
                guard settings.openTrigger.allowsClick else { return }
                model.toggle(source: .trackingArea)
            }
    }

    @ViewBuilder
    private var content: some View {
        if !isOpen, let activity = closedActivity {
            ClosedActivityView(
                activity: activity,
                notchWidth: model.closedSize.width,
                isExpanded: activities.trailingExpanded
            )
                .frame(
                    width: NotchShape.totalWidth(forBody: bodyWidth, topRadius: topRadius),
                    height: bodyHeight
                )
                .transition(.opacity)
        }
        if isOpen {
            ExpandedNotchView(model: model)
                .padding(.horizontal, settings.openCornerRadius + settings.contentPadding)
                .padding(.bottom, settings.contentPadding)
                // Laid out once, at the final size.
                //
                // This frame used to animate along with the shell, which meant
                // the dashboard re-planned itself on every frame of the open:
                // at the collapsed width every section is in overflow, so the
                // panel began as a lone "More" control and sections popped in
                // one at a time as it widened. That is what read as opening
                // from a fixed midpoint rather than growing — the layout was
                // arriving, not expanding.
                //
                // Fixed at the open size, the content is composed once and the
                // growing silhouette reveals it, while the scale below carries
                // it outward from the notch.
                .frame(
                    width: NotchShape.totalWidth(
                        forBody: NotchGeometry.openSize.width,
                        topRadius: settings.openCornerRadius
                    ),
                    height: NotchGeometry.openSize.height
                )
                // Anchored at the top centre, which is the notch itself, so the
                // content expands away from it in every direction rather than
                // sliding down into place.
                .transition(
                    .opacity
                        .combined(with: .scale(scale: 0.90, anchor: .top))
                )
        }
    }
}
