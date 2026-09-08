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
nonisolated protocol CaptureSessionDriver: Sendable {
    var session: AVCaptureSession { get }
    func configure(deviceID: String, completion: @escaping @Sendable (String?, Bool) -> Void)
    func stop(completion: @escaping @Sendable () -> Void)
}

nonisolated final class CaptureSessionBox: CaptureSessionDriver, @unchecked Sendable {
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


}

final class MirrorManager: NSObject, ObservableObject {
    static let shared = MirrorManager()

    @Published private(set) var authorization: AVAuthorizationStatus
    @Published private(set) var devices: [AVCaptureDevice] = []
    @Published private(set) var isRunning = false
    @Published private(set) var failureMessage: String?
    /// True once the user has actually asked for the camera in this session.
    /// Guards against any code path starting capture implicitly.
    private(set) var userRequestedCamera = false

    private let box: any CaptureSessionDriver
    private let authorizationStatus: () -> AVAuthorizationStatus
    private(set) var captureDemand = CaptureDemand()
    private var currentDeviceID: String?
    private var previewOwners: Set<UUID> = []
    var session: AVCaptureSession { box.session }
    private var discovery: AVCaptureDevice.DiscoverySession?
    private var observation: NSKeyValueObservation?

    init(box: any CaptureSessionDriver = CaptureSessionBox(),
         authorizationStatus: @escaping () -> AVAuthorizationStatus = { AVCaptureDevice.authorizationStatus(for: .video) }) {
        self.box = box
        self.authorizationStatus = authorizationStatus
        authorization = authorizationStatus()
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
        if let currentID = currentDeviceID,
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

    /// Explicit, user-initiated request to start the camera.
    ///
    /// The Dashboard's Mirror card calls this on press. Nothing else may start
    /// capture: opening the notch or hovering it must never turn the camera on.
    func requestStart(owner: UUID? = nil) {
        userRequestedCamera = true
        activate(owner: owner)
    }

    /// Registers a preview owner and, if the user has asked for the camera,
    /// starts capture.
    ///
    /// The `userRequestedCamera` gate is the single choke point that guarantees
    /// the camera cannot come on implicitly. The Mirror widget can appear for
    /// reasons the user did not intend — the notch opening on hover, a panel
    /// rebuilding after a display change, a preview being rendered — and none of
    /// those may light the camera. Only `requestStart()` sets the gate.
    func activate(owner: UUID? = nil) {
        if let owner { previewOwners.insert(owner) }
        guard userRequestedCamera else { return }
        captureDemand.activate()
        authorization = authorizationStatus()
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

    /// Forgets the user's request, so the next appearance does not auto-start.
    func forgetCameraRequest() {
        userRequestedCamera = false
    }

    func requestAccess() {
        AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
            Task { @MainActor in
                guard let self else { return }
                self.authorization = self.authorizationStatus()
                Permissions.shared.refreshAll()
                if granted, self.captureDemand.isActive {
                    self.rebuildDeviceList()
                    self.start()
                }
            }
        }
    }

    func start() {
        guard captureDemand.isActive, hasAccess, !isRunning else { return }
        if devices.isEmpty { rebuildDeviceList() }
        guard let device = selectedDevice else {
            failureMessage = "No camera found."
            return
        }
        configure(with: device)
    }

    /// The camera must be released the moment the widget goes away, so the
    /// green privacy light never stays on longer than the preview is visible.
    func release(owner: UUID) {
        previewOwners.remove(owner)
        if previewOwners.isEmpty {
            stop()
            // Closing the last preview also withdraws consent for this session,
            // so simply revisiting the widget later does not restart capture.
            userRequestedCamera = false
        }
    }

    func stop() {
        previewOwners.removeAll()
        captureDemand.deactivate()
        isRunning = false
        currentDeviceID = nil
        // Enqueue even while configure/startRunning is still in flight.
        box.stop {}
    }

    func select(_ device: AVCaptureDevice?) {
        guard captureDemand.isActive else { return }
        guard let device else { stop(); failureMessage = "No camera found."; return }
        Settings.shared.mirrorDeviceID = device.uniqueID
        configure(with: device)
    }

    private func configure(with device: AVCaptureDevice) {
        guard captureDemand.isActive else { return }
        let generation = captureDemand.nextConfiguration()
        currentDeviceID = device.uniqueID
        failureMessage = nil
        box.configure(deviceID: device.uniqueID) { [weak self] failure, running in
            MainActor.assumeIsolated {
                guard let self, self.captureDemand.accepts(generation) else { return }
                self.failureMessage = failure
                self.isRunning = running
            }
        }
    }
}
