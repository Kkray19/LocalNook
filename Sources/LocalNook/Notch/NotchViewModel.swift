//
//  NotchViewModel.swift
//  LocalNook
//
//  Copyright (C) 2026 Krish Kowli
//  Licensed under the GNU General Public License v3.0 or later. See LICENSE.
//

import AppKit
import Combine
import SwiftUI

enum NotchState: Equatable {
    case closed
    case open
}

/// Per-display state for one notch panel.
///
/// One instance exists per visible panel; with "show on all displays" off there
/// is exactly one.
final class NotchViewModel: ObservableObject {
    @Published private(set) var state: NotchState = .closed
    /// Which top-level page the expanded notch is showing.
    @Published var page: NotchPage = .dashboard
    /// Set when a tool has been opened at full size.
    @Published var focusedTool: WidgetKind?
    /// Which page that happened from, so leaving the tool goes back where the
    /// user came from. A section opened from the Dashboard that returned to the
    /// Tools grid would leave them somewhere they had never been — and, for a
    /// section that is *on* the Dashboard, on a page that does not list it.
    @Published var focusedToolOrigin: NotchPage = .tools
    /// Retained so drag-to-shelf can still target the Tray directly.
    @Published var selectedWidget: WidgetKind = .media
    @Published var isHovering: Bool = false
    /// True while a drag is over the notch, which forces the shelf open.
    @Published var isDragTargeting: Bool = false
    /// Suppresses the panel entirely (fullscreen apps, lock screen).
    @Published var isSuppressed: Bool = false

    @Published var closedSize: CGSize
    let screenID: String?

    /// Set when the notch is closed deliberately while the pointer is still on
    /// it, so hover does not immediately re-open it. Cleared when the pointer
    /// leaves.
    /// Set when a deliberate close happens under a still pointer, so hover does
    /// not bounce the notch straight back open. Readable so a test can assert
    /// that leaving the notch clears it, rather than inferring that from a
    /// subsequent reopen.
    private(set) var hoverReopenBlocked = false
    private var openTask: Task<Void, Never>?
    private var closeTask: Task<Void, Never>?
    private var cancellables = Set<AnyCancellable>()

    private let settings = Settings.shared

    init(screenID: String?) {
        self.screenID = screenID
        self.closedSize = NotchGeometry.closedSize(for: NSScreen.screen(withStableID: screenID))

        // Geometry settings changing should immediately reshape the closed notch.
        settings.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] in self?.refreshGeometry() }
            .store(in: &cancellables)

        // Collapse out of the way when this display goes full screen.
        FullscreenDetector.shared.$coveredScreenIDs
            .map { covered in screenID.map(covered.contains) ?? false }
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self] suppressed in
                guard let self else { return }
                withAnimation(NotchMotion.content) { self.isSuppressed = suppressed }
                if suppressed { self.close(source: .systemState) }
            }
            .store(in: &cancellables)
    }

    /// Whether this panel's display has a real camera housing. Drives whether a
    /// collapsed notch may be drawn in glass — see NotchSurface.
    var displayHasPhysicalNotch: Bool {
        screen?.hasPhysicalNotch ?? false
    }

    var screen: NSScreen? {
        NSScreen.screen(withStableID: screenID) ?? NSScreen.main
    }

    /// The notch height actually drawn — collapses to zero when suppressed so
    /// fullscreen video is never covered by a black bar.
    var effectiveClosedHeight: CGFloat {
        isSuppressed ? 0 : closedSize.height
    }

    /// Where a live activity's wings begin: outside the camera housing, however
    /// narrow the collapsed notch has been set. See NotchGeometry.activityDeadZone.
    var activityDeadZoneWidth: CGFloat {
        let housing = screen.flatMap { $0.hasPhysicalNotch ? $0.physicalNotchWidth : nil }
        return NotchGeometry.activityDeadZone(closedWidth: closedSize.width, physicalWidth: housing)
    }

    func refreshGeometry() {
        let size = NotchGeometry.closedSize(for: screen)
        if size != closedSize { closedSize = size }
    }

    // MARK: State transitions

    /// Window number of the panel drawing this notch, for transition logging.
    var loggedWindowNumber: Int = 0

    /// Called synchronously just before an open animates, so the controller can
    /// give the panel its full canvas first. A closure rather than a
    /// notification because the ordering is the entire point: this has to run
    /// inside `open()`, not a runloop turn later. Nil for a detached model.
    var willOpen: ((NotchViewModel) -> Void)?

    /// Opens one widget at full size, remembering where from.
    func focus(_ tool: WidgetKind, from page: NotchPage) {
        focusedToolOrigin = page
        focusedTool = tool
        self.page = .tools
    }

    func open(source: NotchTransitionSource = .programmatic) {
        cancelPending()
        guard !isSuppressed, state != .open else { return }
        // Widen the window *before* animating into it.
        //
        // Closing already works this way, in the other direction: the wide
        // canvas outlives the closing animation by 550ms, so the whole close is
        // drawn on a canvas that never changes. Opening had no such
        // arrangement — the panel is only a notch wide while collapsed, and the
        // controller widened it from a `receive(on:)` plus a `Task`, which is
        // one or two runloop turns *after* the animation had already started.
        // Measured on a screen recording: the drawn shell jumped 200pt to the
        // left on the first frame, then grew rightward with its left edge
        // already at its final position. That is not a growth from the notch,
        // it is the panel being clipped by a window that had not caught up.
        //
        // Posting synchronously here puts the resize in the same commit as the
        // first animation frame.
        willOpen?(self)
        // `expandOpening`, not `expand`: the opening is the closing read
        // backwards, landing on a settle. `close()` keeps `expand` unchanged.
        withAnimation(NotchMotion.expandOpening) { state = .open }
        NotchTransitionLog.record(
            opened: true, source: source, displayID: screenID, windowNumber: loggedWindowNumber
        )
        if settings.hapticFeedback {
            NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
        }
        NotificationCenter.default.post(name: .notchDidOpen, object: self)
    }

    /// Clears the latch that keeps hover from re-opening a deliberately closed notch.
    func allowHoverToReopen() {
        hoverReopenBlocked = false
    }

    func close(source: NotchTransitionSource = .programmatic) {
        cancelPending()
        guard state != .closed else { return }
        // If the pointer is still sitting on the notch, do not bounce straight
        // back open — wait until it leaves.
        hoverReopenBlocked = isHovering
        withAnimation(NotchMotion.expand) { state = .closed }
        // A closed notch owns no interaction. Without this a stale claim would
        // survive into the next open and pin it from the start.
        releaseAllInteractions()
        isDragTargeting = false
        NotchTransitionLog.record(
            opened: false, source: source, displayID: screenID, windowNumber: loggedWindowNumber
        )
        NotificationCenter.default.post(name: .notchDidClose, object: self)
    }

    func toggle(source: NotchTransitionSource = .programmatic) {
        state == .open ? close(source: source) : open(source: source)
    }

    /// Schedules an open after the user's configured hover delay.
    func scheduleOpen(source: NotchTransitionSource = .trackingArea) {
        closeTask?.cancel(); closeTask = nil
        guard !isSuppressed, settings.openTrigger.allowsHover, state == .closed,
              !hoverReopenBlocked else { return }
        guard openTask == nil else { return }
        let delay = settings.openDelay
        openTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
            self?.openTask = nil
            self?.open(source: source)
        }
    }

    /// Schedules a close after the user's configured grace period, so moving the
    /// pointer briefly outside the panel does not slam it shut.
    func scheduleClose(source: NotchTransitionSource = .trackingArea) {
        guard state == .open else {
            openTask?.cancel(); openTask = nil
            return
        }
        openTask?.cancel(); openTask = nil
        closeTask?.cancel()
        let delay = settings.closeDelay
        closeTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
            guard let self, !self.isDragTargeting else { return }
            self.closeTask = nil
            self.close(source: source)
        }
    }

    /// The drawing panel's hover report — honoured only while the notch is open.
    ///
    /// Collapsed, hover belongs to the catcher: the small window over the
    /// notch, whose frame never moves. The drawing panel is inert then, but its
    /// tracker still runs a manual containment check every time its tracking
    /// area is rebuilt, and a live activity resizing the panel rebuilds it on
    /// every frame of an animation. The window's origin jumps at once while
    /// SwiftUI animates the tracker back to the centre, so for a third of a
    /// second the tracker's rectangle sweeps across the menu bar — measured at
    /// 750..919 and then 536..701 while the notch core was 671..840.
    ///
    /// That broke hover two ways. A sweep passing over a pointer resting on an
    /// activity's wing reported "inside" and opened the notch. A sweep that
    /// did not include the pointer reported "outside", and `scheduleClose`
    /// cancels a pending open while collapsed — so it could throw away an open
    /// the catcher had just scheduled. Neither report was about the pointer; both
    /// were about an animation. So collapsed, they are ignored entirely: the
    /// catcher opens, and this keeps the notch open and closes it.
    func drawingPanelHoverChanged(_ hovering: Bool) {
        guard state == .open, !isSuppressed else { return }
        isHovering = hovering
        if hovering {
            // Already open: this only cancels a close that was about to fire.
            scheduleOpen()
        } else if !isDragTargeting {
            scheduleClose()
        }
    }

    /// True when a close is scheduled but has not fired. Lets tests assert what
    /// the fallback decided without waiting on the close delay.
    var hasPendingClose: Bool { closeTask != nil }

    // MARK: Interaction ownership

    /// Outstanding reasons this particular notch must stay open.
    @Published private(set) var claims: Set<NotchInteractionClaim> = []

    /// True while anything is holding this notch open. Scoped to this notch —
    /// interaction on one display never pins another.
    var isInteracting: Bool { !claims.isEmpty }

    var activeInteractions: Set<NotchInteraction> { Set(claims.map(\.kind)) }

    func claimInteraction(_ kind: NotchInteraction, owner: UUID) {
        claims.insert(NotchInteractionClaim(kind: kind, owner: owner))
    }

    /// Ends one owner's claim. Safe to call when none is held.
    func releaseInteraction(_ kind: NotchInteraction, owner: UUID) {
        claims.remove(NotchInteractionClaim(kind: kind, owner: owner))
    }

    /// Ends every claim of a kind, used when its underlying condition is gone.
    func releaseInteractions(of kind: NotchInteraction) {
        claims = claims.filter { $0.kind != kind }
    }

    func releaseAllInteractions() {
        claims.removeAll()
    }

    /// Acts on a swipe over the notch: down opens a closed notch, up closes an
    /// open one. Anything else — up on a closed notch, down on an open one — is
    /// deliberately nothing, so a stripe of scrolling cannot flap the panel.
    func handleSwipe(_ direction: SwipeDirection) {
        guard settings.swipeToToggle, !isSuppressed else { return }
        let effective: SwipeDirection = settings.swipeInverted
            ? (direction == .down ? .up : .down)
            : direction
        switch (effective, state) {
        case (.down, .closed):
            allowHoverToReopen()
            open(source: .gesture)
        case (.up, .open):
            close(source: .gesture)
        default:
            break
        }
    }

    func cancelPending() {
        openTask?.cancel(); openTask = nil
        closeTask?.cancel(); closeTask = nil
    }

    /// This notch is going away — its display was removed, or the controller
    /// stopped. Everything it owns is released.
    ///
    /// Cancelling the pending work is not enough on its own: a claim is held
    /// until someone gives it back, and after retirement nobody will. Leaving
    /// one behind means the model reports itself as permanently interacting,
    /// which is exactly the state the fallback refuses to close.
    func retire() {
        cancelPending()
        releaseAllInteractions()
        isDragTargeting = false
        state = .closed
    }
}

extension Notification.Name {
    static let notchDidOpen = Notification.Name("LocalNook.notchDidOpen")
    static let notchDidClose = Notification.Name("LocalNook.notchDidClose")
    static let notchGeometryChanged = Notification.Name("LocalNook.notchGeometryChanged")
    static let openSettingsRequested = Notification.Name("LocalNook.openSettings")
}
