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
    @Published var selectedWidget: WidgetKind = .media
    @Published var isHovering: Bool = false
    /// True while a drag is over the notch, which forces the shelf open.
    @Published var isDragTargeting: Bool = false
    /// Suppresses the panel entirely (fullscreen apps, lock screen).
    @Published var isSuppressed: Bool = false

    @Published var closedSize: CGSize
    let screenID: String?

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
                if suppressed { self.close() }
            }
            .store(in: &cancellables)
    }

    var screen: NSScreen? {
        NSScreen.screen(withStableID: screenID) ?? NSScreen.main
    }

    /// The notch height actually drawn — collapses to zero when suppressed so
    /// fullscreen video is never covered by a black bar.
    var effectiveClosedHeight: CGFloat {
        isSuppressed ? 0 : closedSize.height
    }

    func refreshGeometry() {
        let size = NotchGeometry.closedSize(for: screen)
        if size != closedSize { closedSize = size }
    }

    // MARK: State transitions

    func open() {
        cancelPending()
        guard !isSuppressed, state != .open else { return }
        withAnimation(NotchMotion.expand) { state = .open }
        if settings.hapticFeedback {
            NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
        }
        NotificationCenter.default.post(name: .notchDidOpen, object: self)
    }

    func close() {
        cancelPending()
        guard state != .closed else { return }
        withAnimation(NotchMotion.expand) { state = .closed }
        NotificationCenter.default.post(name: .notchDidClose, object: self)
    }

    func toggle() {
        state == .open ? close() : open()
    }

    /// Schedules an open after the user's configured hover delay.
    func scheduleOpen() {
        closeTask?.cancel(); closeTask = nil
        guard !isSuppressed, settings.openTrigger.allowsHover, state == .closed else { return }
        guard openTask == nil else { return }
        let delay = settings.openDelay
        openTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
            self?.openTask = nil
            self?.open()
        }
    }

    /// Schedules a close after the user's configured grace period, so moving the
    /// pointer briefly outside the panel does not slam it shut.
    func scheduleClose() {
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
            self.close()
        }
    }

    func cancelPending() {
        openTask?.cancel(); openTask = nil
        closeTask?.cancel(); closeTask = nil
    }
}

extension Notification.Name {
    static let notchDidOpen = Notification.Name("LocalNook.notchDidOpen")
    static let notchDidClose = Notification.Name("LocalNook.notchDidClose")
    static let notchGeometryChanged = Notification.Name("LocalNook.notchGeometryChanged")
    static let openSettingsRequested = Notification.Name("LocalNook.openSettings")
}
