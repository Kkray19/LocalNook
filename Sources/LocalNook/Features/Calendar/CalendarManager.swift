//
//  CalendarManager.swift
//  LocalNook
//
//  Copyright (C) 2026 Krish Kowli
//  Licensed under the GNU General Public License v3.0 or later. See LICENSE.
//

import AppKit
import Combine
import EventKit
import SwiftUI

/// Reads calendar events through EventKit.
///
/// Access is requested the first time the Calendar widget is shown — never at
/// launch — and everything degrades to an explanatory message if it is refused.
final class CalendarManager: ObservableObject {
    static let shared = CalendarManager()

    @Published private(set) var events: [EKEvent] = []
    @Published private(set) var authorization: EKAuthorizationStatus
    @Published var selectedDate: Date = Calendar.current.startOfDay(for: Date())
    @Published private(set) var isLoading = false

    private let store = EKEventStore()
    private var cancellables = Set<AnyCancellable>()

    private init() {
        authorization = EKEventStore.authorizationStatus(for: .event)

        // The user can change calendars or permissions while we are running.
        NotificationCenter.default.addObserver(
            forName: .EKEventStoreChanged, object: store, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.reload() }
        }
    }

    var hasAccess: Bool {
        authorization == .fullAccess
    }

    var isDenied: Bool {
        authorization == .denied || authorization == .restricted || authorization == .writeOnly
    }

    /// Refreshes events **only** if consent already exists.
    ///
    /// Deliberately never prompts. The Calendar section sits on the Dashboard,
    /// which opens on hover — triggering a system permission dialog because the
    /// pointer brushed the notch would be indefensible. Consent is asked for by
    /// an explicit button instead.
    func refreshIfAuthorized() {
        authorization = EKEventStore.authorizationStatus(for: .event)
        if hasAccess { reload() }
    }

    /// Called when the widget appears. Only prompts if the user has never been asked.
    func activate() {
        authorization = EKEventStore.authorizationStatus(for: .event)
        switch authorization {
        case .notDetermined:
            requestAccess()
        default:
            if hasAccess { reload() }
        }
    }

    func requestAccess() {
        Task { [weak self] in
            guard let self else { return }
            let granted = (try? await store.requestFullAccessToEvents()) ?? false
            self.authorization = EKEventStore.authorizationStatus(for: .event)
            Permissions.shared.refreshAll()
            if granted { self.reload() }
        }
    }

    // MARK: Day navigation

    func step(days: Int) {
        guard let next = Calendar.current.date(byAdding: .day, value: days, to: selectedDate)
        else { return }
        selectedDate = Calendar.current.startOfDay(for: next)
        reload()
    }

    func goToToday() {
        selectedDate = Calendar.current.startOfDay(for: Date())
        reload()
    }

    var dayLabel: String {
        let calendar = Calendar.current
        if calendar.isDateInToday(selectedDate) { return "Today" }
        if calendar.isDateInTomorrow(selectedDate) { return "Tomorrow" }
        if calendar.isDateInYesterday(selectedDate) { return "Yesterday" }
        let formatter = DateFormatter()
        formatter.dateFormat = calendar.isDate(selectedDate, equalTo: Date(), toGranularity: .year)
            ? "EEEE d MMMM"
            : "EEEE d MMMM yyyy"
        return formatter.string(from: selectedDate)
    }

    // MARK: Loading

    func reload() {
        authorization = EKEventStore.authorizationStatus(for: .event)
        guard hasAccess else {
            events = []
            return
        }
        let calendar = Calendar.current
        let start = calendar.startOfDay(for: selectedDate)
        guard let end = calendar.date(byAdding: .day, value: 1, to: start) else { return }

        let calendars = selectedCalendars()
        if calendars?.isEmpty == true { events = []; return }
        let predicate = store.predicateForEvents(
            withStart: start, end: end, calendars: calendars
        )
        events = store.events(matching: predicate)
            .sorted { ($0.startDate ?? .distantPast) < ($1.startDate ?? .distantPast) }
    }

    /// Honours the user's per-calendar choice, falling back to all calendars.
    private func selectedCalendars() -> [EKCalendar]? {
        let settings = Settings.shared
        guard !settings.calendarShowAll else { return nil }
        let ids = Set(settings.enabledCalendarIDs)
        let matching = store.calendars(for: .event).filter { Self.includesCalendar($0.calendarIdentifier, selectedIDs: ids) }
        return matching
    }

    static func includesCalendar(_ id: String, selectedIDs: Set<String>) -> Bool {
        selectedIDs.contains(id)
    }

    var availableCalendars: [EKCalendar] {
        hasAccess ? store.calendars(for: .event) : []
    }

    /// Opens the event in Calendar.app.
    func open(_ event: EKEvent) {
        // Calendar's own URL scheme takes an event identifier.
        if let id = event.calendarItemIdentifier
            .addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
           let url = URL(string: "ical://ekevent/\(id)") {
            NSWorkspace.shared.open(url)
            return
        }
        if let url = URL(string: "ical://") { NSWorkspace.shared.open(url) }
    }

    /// The next event that has not finished yet, for the collapsed notch.
    var upcoming: EKEvent? {
        let now = Date()
        return events.first { ($0.endDate ?? .distantPast) > now }
    }
}
