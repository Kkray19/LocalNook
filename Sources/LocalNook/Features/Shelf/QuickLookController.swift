//
//  QuickLookController.swift
//  LocalNook
//
//  Copyright (C) 2026 Krish Kowli
//  Licensed under the GNU General Public License v3.0 or later. See LICENSE.
//

import AppKit
import QuickLookUI

/// Drives the shared Quick Look panel for shelf items.
///
/// The notch panel is non-activating and cannot own the Quick Look panel, so
/// LocalNook briefly becomes a regular app while the preview is on screen and
/// steps back to accessory when it closes.
final class QuickLookController: NSObject, QLPreviewPanelDataSource, QLPreviewPanelDelegate {
    static let shared = QuickLookController()

    private var urls: [URL] = []

    private override init() { super.init() }

    func preview(_ urls: [URL]) {
        let existing = urls.filter { FileManager.default.fileExists(atPath: $0.path) }
        guard !existing.isEmpty, let panel = QLPreviewPanel.shared() else { return }
        self.urls = existing

        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        panel.dataSource = self
        panel.delegate = self
        panel.makeKeyAndOrderFront(nil)
        panel.reloadData()
    }

    // MARK: QLPreviewPanelDataSource

    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int { urls.count }

    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> (any QLPreviewItem)! {
        guard urls.indices.contains(index) else { return nil }
        return urls[index] as NSURL
    }

    // MARK: QLPreviewPanelDelegate

    func previewPanelDidClose(_ panel: QLPreviewPanel!) {
        urls = []
        NSApp.setActivationPolicy(.accessory)
    }
}
