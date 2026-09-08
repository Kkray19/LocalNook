//
//  MirrorWidgetView.swift
//  LocalNook
//
//  Copyright (C) 2026 Krish Kowli
//  Licensed under the GNU General Public License v3.0 or later. See LICENSE.
//

import AVFoundation
import AppKit
import SwiftUI

struct MirrorWidgetView: View {
    @ObservedObject private var mirror = MirrorManager.shared
    @EnvironmentObject var settings: Settings

    var body: some View {
        Group {
            if mirror.isDenied {
                WidgetMessage(
                    symbol: "web.camera.fill",
                    title: "Camera access is off",
                    detail: "Turn LocalNook on in System Settings ▸ Privacy & Security ▸ Camera.",
                    actionTitle: "Open Settings"
                ) { Permissions.shared.open(.camera) }
            } else if !mirror.hasAccess {
                WidgetMessage(
                    symbol: "web.camera",
                    title: "Use your camera as a mirror",
                    detail: "The preview is shown only. Nothing is recorded, saved or sent anywhere.",
                    actionTitle: "Allow access"
                ) { mirror.requestAccess() }
            } else if let failure = mirror.failureMessage {
                WidgetMessage(symbol: "exclamationmark.triangle", title: "Camera unavailable", detail: failure)
            } else {
                preview
            }
        }
        .onAppear { mirror.activate() }
        // Releasing the camera on disappear keeps the green light honest.
        .onDisappear { mirror.stop() }
    }

    private var preview: some View {
        HStack(spacing: 10) {
            CameraPreview(session: mirror.session)
                .scaleEffect(x: settings.mirrorFlipHorizontally ? -1 : 1, y: 1)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(.white.opacity(0.12), lineWidth: 0.5)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            VStack(alignment: .leading, spacing: 8) {
                Toggle("Mirror", isOn: settings.binding(\.mirrorFlipHorizontally))
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                    .font(.system(size: 10))

                if mirror.devices.count > 1 {
                    Picker("", selection: Binding(
                        get: { mirror.selectedDevice?.uniqueID ?? "" },
                        set: { id in
                            mirror.select(mirror.devices.first { $0.uniqueID == id })
                        }
                    )) {
                        ForEach(mirror.devices, id: \.uniqueID) { device in
                            Text(device.localizedName).tag(device.uniqueID)
                        }
                    }
                    .labelsHidden()
                    .controlSize(.mini)
                    .font(.system(size: 10))
                }

                Spacer()

                Label("Not recording", systemImage: "record.circle.slash")
                    .font(.system(size: 9))
                    .foregroundStyle(.white.opacity(0.4))
            }
            .frame(width: 130, alignment: .leading)
        }
    }
}

/// Wraps `AVCaptureVideoPreviewLayer`, which has no SwiftUI equivalent.
private struct CameraPreview: NSViewRepresentable {
    let session: AVCaptureSession

    func makeNSView(context: Context) -> PreviewView {
        let view = PreviewView()
        view.previewLayer.session = session
        return view
    }

    func updateNSView(_ nsView: PreviewView, context: Context) {
        if nsView.previewLayer.session !== session {
            nsView.previewLayer.session = session
        }
    }

    final class PreviewView: NSView {
        let previewLayer = AVCaptureVideoPreviewLayer()

        override init(frame frameRect: NSRect) {
            super.init(frame: frameRect)
            wantsLayer = true
            previewLayer.videoGravity = .resizeAspectFill
            previewLayer.backgroundColor = NSColor.black.cgColor
            layer = previewLayer
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError("not used") }

        override func layout() {
            super.layout()
            previewLayer.frame = bounds
        }
    }
}
