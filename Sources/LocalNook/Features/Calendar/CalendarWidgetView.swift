//
//  CalendarWidgetView.swift
//  LocalNook
//
//  Copyright (C) 2026 Krish Kowli
//  Licensed under the GNU General Public License v3.0 or later. See LICENSE.
//

import EventKit
import SwiftUI

struct CalendarWidgetView: View {
    @ObservedObject private var calendar = CalendarManager.shared

    var body: some View {
        Group {
            if calendar.isDenied {
                permissionMessage
            } else if !calendar.hasAccess {
                requestMessage
            } else {
                day
            }
        }
        .onAppear { calendar.activate() }
    }

    private var permissionMessage: some View {
        WidgetMessage(
            symbol: "calendar.badge.exclamationmark",
            title: "Calendar access is off",
            detail: "Turn LocalNook on in System Settings ▸ Privacy & Security ▸ Calendars.",
            actionTitle: "Open Settings"
        ) { Permissions.shared.open(.calendar) }
    }

    private var requestMessage: some View {
        WidgetMessage(
            symbol: "calendar",
            title: "Show your events here",
            detail: "LocalNook reads your calendar on this Mac. Nothing is uploaded anywhere.",
            actionTitle: "Allow access"
        ) { calendar.requestAccess() }
    }

    private var day: some View {
        VStack(spacing: 4) {
            header
            if calendar.events.isEmpty {
                VStack(spacing: 3) {
                    Image(systemName: "checkmark.circle")
                        .font(.system(size: 16, weight: .light))
                        .foregroundStyle(.white.opacity(0.35))
                    Text("Nothing scheduled")
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(0.45))
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView(showsIndicators: false) {
                    VStack(spacing: 3) {
                        ForEach(calendar.events, id: \.eventIdentifier) { event in
                            EventRow(event: event)
                                .onTapGesture { calendar.open(event) }
                        }
                    }
                }
            }
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Button { calendar.step(days: -1) } label: {
                Image(systemName: "chevron.left").font(.system(size: 10, weight: .semibold))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.white.opacity(0.55))

            Text(calendar.dayLabel)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.white.opacity(0.85))
                .frame(minWidth: 130)

            Button { calendar.step(days: 1) } label: {
                Image(systemName: "chevron.right").font(.system(size: 10, weight: .semibold))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.white.opacity(0.55))

            Spacer()

            Button("Today") { calendar.goToToday() }
                .buttonStyle(.plain)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.white.opacity(0.55))
        }
    }
}

private struct EventRow: View {
    let event: EKEvent

    private var tint: Color {
        if let cgColor = event.calendar?.cgColor { return Color(cgColor: cgColor) }
        return .accentColor
    }

    private var timeLabel: String {
        guard let start = event.startDate else { return "" }
        if event.isAllDay { return "All day" }
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        formatter.dateStyle = .none
        return formatter.string(from: start)
    }

    private var isPast: Bool {
        (event.endDate ?? .distantFuture) < Date()
    }

    var body: some View {
        HStack(spacing: 8) {
            RoundedRectangle(cornerRadius: 1.5)
                .fill(tint)
                .frame(width: 3, height: 22)
            VStack(alignment: .leading, spacing: 0) {
                Text(event.title ?? "Untitled")
                    .font(.system(size: 11, weight: .medium))
                    .lineLimit(1)
                if let location = event.location, !location.isEmpty {
                    Text(location)
                        .font(.system(size: 9))
                        .foregroundStyle(.white.opacity(0.4))
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 6)
            Text(timeLabel)
                .font(.system(size: 10, weight: .medium))
                .monospacedDigit()
                .foregroundStyle(.white.opacity(0.55))
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(.white.opacity(0.05))
        }
        .opacity(isPast ? 0.45 : 1)
        .contentShape(Rectangle())
    }
}

/// Shared empty/permission state used by several widgets.
struct WidgetMessage: View {
    let symbol: String
    let title: String
    let detail: String
    var actionTitle: String? = nil
    var action: (() -> Void)? = nil

    var body: some View {
        VStack(spacing: 5) {
            Image(systemName: symbol)
                .font(.system(size: 18, weight: .light))
                .foregroundStyle(.white.opacity(0.4))
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white.opacity(0.8))
            Text(detail)
                .font(.system(size: 10))
                .foregroundStyle(.white.opacity(0.45))
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .buttonStyle(.plain)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.9))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(Capsule().fill(.white.opacity(0.14)))
                    .padding(.top, 2)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.horizontal, 24)
    }
}
