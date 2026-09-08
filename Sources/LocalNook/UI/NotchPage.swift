//
//  NotchPage.swift
//  LocalNook
//
//  Copyright (C) 2026 Krish Kowli
//  Licensed under the GNU General Public License v3.0 or later. See LICENSE.
//

import SwiftUI

/// Top-level sections of the expanded notch.
///
/// Replaces the previous strip of ten widget icons, which showed one widget at
/// a time and left most of the panel empty. Everyday information now lives
/// together on the Dashboard; the tools that need room keep their own views.
enum NotchPage: String, PrefValue, CaseIterable, Identifiable {
    case dashboard
    case tray
    case tools

    var id: String { rawValue }

    var label: String {
        switch self {
        case .dashboard: "Dashboard"
        case .tray: "Tray"
        case .tools: "Tools"
        }
    }

    var symbol: String {
        switch self {
        case .dashboard: "square.grid.2x2.fill"
        case .tray: "tray.fill"
        case .tools: "wrench.and.screwdriver.fill"
        }
    }
}

/// Widgets that can sit on the Dashboard. The rest live under Tools, where they
/// have room to be useful.
extension WidgetKind {
    var suitsDashboard: Bool {
        switch self {
        case .media, .calendar, .timers, .stats, .sessions: true
        case .shelf, .notes, .todo, .shortcuts: false
        }
    }

    /// Relative width when laid out beside other dashboard sections.
    /// Media carries artwork plus three lines of text, so it needs the most.
    var dashboardWeight: CGFloat {
        switch self {
        case .media: 1.55
        case .calendar: 1.15
        case .sessions: 1.1
        case .stats: 1.1
        case .timers: 0.95
        default: 1
        }
    }

    /// Smallest width at which this section still reads properly.
    var dashboardMinimumWidth: CGFloat {
        switch self {
        case .media: 230
        case .calendar: 190
        case .sessions: 170
        case .stats: 180
        case .timers: 160
        default: 150
        }
    }
}
