//
//  MirrorManager.swift
//  LocalNook
//
//  Copyright (C) 2026 Krish Kowli
//  Licensed under the GNU General Public License v3.0 or later. See LICENSE.
//
//  A live camera preview. LocalNook never records, writes or transmits video —
//  the capture session has a preview layer and no file or data output attached.
//

import AVFoundation
import Combine
import SwiftUI

/// Owns the capture session and the serial queue it must be configured on.
///
/// `AVCaptureSession` is not `Sendable` and its configuration calls block, so
/// it lives entirely inside this nonisolated box: the main actor never touches
/// the session directly, it only posts work to the box's queue.
nonisolated final class CaptureSessionBox: @unchecked Sendable {
    let session = AVCaptureSession()
    private let queue = DispatchQueue(label: "com.localnook.capture", qos: .userInitiated)

    /// Swaps the input to the camera with `deviceID` and starts the session.
    ///
    /// Takes an identifier rather than an `AVCaptureDevice` because the device
    /// is not `Sendable`; it is re-resolved on the capture queue instead.
    /// - Parameter completion: delivered on the main queue with an error
    ///   message, or `nil` on success.
    func configure(deviceID: String, completion: @escaping @Sendable (String?, Bool) -> Void) {
        queue.async { [self] in
            guard let device = AVCaptureDevice(uniqueID: deviceID) else {
                DispatchQueue.main.async { completion("That camera is no longer connected.", false) }
                return
            }
            let session = self.session
            session.beginConfiguration()
            session.sessionPreset = .high
            for existing in session.inputs { session.removeInput(existing) }

            var failure: String?
            do {
                let input = try AVCaptureDeviceInput(device: device)
                if session.canAddInput(input) {
                    session.addInput(input)
                } else {
                    failure = "This camera is unavailable."
                }
            } catch {
                failure = "Could not open the camera: \(error.localizedDescription)"
            }
            session.commitConfiguration()

            if failure == nil, !session.isRunning { session.startRunning() }
            let running = session.isRunning
            DispatchQueue.main.async { completion(failure, running) }
        }
    }

    func stop(completion: @escaping @Sendable () -> Void) {
        queue.async { [self] in
            let session = self.session
            if session.isRunning { session.stopRunning() }
            DispatchQueue.main.async { completion() }
        }
    }

    /// Identifier of the device currently feeding the session.
    var currentDeviceID: String? {
        (session.inputs.compactMap { $0 as? AVCaptureDeviceInput }.first)?.device.uniqueID
    }
}

final class MirrorManager: NSObject, ObservableObject {
    static let shared = MirrorManager()

    @Published private(set) var authorization: AVAuthorizationStatus
    @Published private(set) var devices: [AVCaptureDevice] = []
    @Published private(set) var isRunning = false
    @Published private(set) var failureMessage: String?

    private let box = CaptureSessionBox()
    var session: AVCaptureSession { box.session }
    private var discovery: AVCaptureDevice.DiscoverySession?
    private var observation: NSKeyValueObservation?

    private override init() {
        authorization = AVCaptureDevice.authorizationStatus(for: .video)
        super.init()
        observeDeviceChanges()
    }

    deinit { observation?.invalidate() }

    var hasAccess: Bool { authorization == .authorized }
    var isDenied: Bool { authorization == .denied || authorization == .restricted }

    // MARK: Devices

    /// Includes Continuity Camera (an iPhone acting as a webcam) alongside the
    /// built-in and any USB cameras.
    private func rebuildDeviceList() {
        let types: [AVCaptureDevice.DeviceType] = [
            .builtInWideAngleCamera,
            .external,
            .continuityCamera,
        ]
        let session = AVCaptureDevice.DiscoverySession(
            deviceTypes: types, mediaType: .video, position: .unspecified
        )
        discovery = session
        devices = session.devices
    }

    private func observeDeviceChanges() {
        // Cameras come and go — a USB webcam unplugged, an iPhone waking up.
        NotificationCenter.default.addObserver(
            forName: AVCaptureDevice.wasConnectedNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.handleDeviceListChanged() }
        }
        NotificationCenter.default.addObserver(
            forName: AVCaptureDevice.wasDisconnectedNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.handleDeviceListChanged() }
        }
    }

    private func handleDeviceListChanged() {
        rebuildDeviceList()
        // If the camera in use vanished, fall back to whatever is left.
        if let currentID = box.currentDeviceID,
           !devices.contains(where: { $0.uniqueID == currentID }),
           isRunning {
            select(devices.first)
        }
    }

    var selectedDevice: AVCaptureDevice? {
        if let id = Settings.shared.mirrorDeviceID,
           let match = devices.first(where: { $0.uniqueID == id }) {
            return match
        }
        return devices.first
    }

    // MARK: Lifecycle

    /// Called when the Mirror widget appears. Prompts only if never asked.
    func activate() {
        authorization = AVCaptureDevice.authorizationStatus(for: .video)
        switch authorization {
        case .notDetermined:
            requestAccess()
        case .authorized:
            rebuildDeviceList()
            start()
        default:
            break
        }
    }

    func requestAccess() {
        AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
            Task { @MainActor in
                guard let self else { return }
                self.authorization = AVCaptureDevice.authorizationStatus(for: .video)
                Permissions.shared.refreshAll()
                if granted {
                    self.rebuildDeviceList()
                    self.start()
                }
            }
        }
    }

    func start() {
        guard hasAccess, !isRunning else { return }
        if devices.isEmpty { rebuildDeviceList() }
        guard let device = selectedDevice else {
            failureMessage = "No camera found."
            return
        }
        configure(with: device)
    }

    /// The camera must be released the moment the widget goes away, so the
    /// green privacy light never stays on longer than the preview is visible.
    func stop() {
        guard isRunning else { return }
        isRunning = false
        box.stop {}
    }

    func select(_ device: AVCaptureDevice?) {
        guard let device else { return }
        Settings.shared.mirrorDeviceID = device.uniqueID
        configure(with: device)
    }

    private func configure(with device: AVCaptureDevice) {
        failureMessage = nil
        box.configure(deviceID: device.uniqueID) { [weak self] failure, running in
            MainActor.assumeIsolated {
                self?.failureMessage = failure
                self?.isRunning = running
            }
        }
    }
}
