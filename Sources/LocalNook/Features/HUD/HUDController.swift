//
//  HUDController.swift
//  LocalNook
//
//  Copyright (C) 2026 Krish Kowli
//  Licensed under the GNU General Public License v3.0 or later. See LICENSE.
//
//  Optional notch-integrated volume and brightness indicators. OFF by default.
//
//  Scope, stated honestly: LocalNook *shows* its own indicator when the level
//  changes. It does not suppress the built-in macOS HUD — doing that requires
//  either a private OSD entitlement or an event tap that swallows the media
//  keys, and neither is worth the fragility or the Accessibility prompt for a
//  cosmetic feature. With the setting on you may briefly see both indicators.
//
//  Reading the levels uses public APIs only: CoreAudio for volume, IOKit
//  display services for brightness. No Accessibility permission is required for
//  what is implemented here.
//

import Combine
import CoreAudio
import Foundation
import SwiftUI

struct HUDState: Equatable {
    enum Kind: Equatable {
        case volume, brightness, keyboardBrightness

        var symbol: String {
            switch self {
            case .volume: "speaker.wave.2.fill"
            case .brightness: "sun.max.fill"
            case .keyboardBrightness: "keyboard"
            }
        }

        var label: String {
            switch self {
            case .volume: "Volume"
            case .brightness: "Brightness"
            case .keyboardBrightness: "Keyboard"
            }
        }
    }

    var kind: Kind
    var value: Double
    var isMuted: Bool
}

final class HUDController: ObservableObject {
    static let shared = HUDController()

    @Published private(set) var state: HUDState?

    private var volumeListener: AudioObjectPropertyListenerBlock?
    private var muteListener: AudioObjectPropertyListenerBlock?
    private var dismissTask: Task<Void, Never>?
    private var cancellables = Set<AnyCancellable>()
    private var lastVolume: Double = -1

    private init() {}

    func start() {
        // Only wire up listeners for the HUDs the user has actually enabled.
        Settings.shared.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] in self?.syncListeners() }
            .store(in: &cancellables)
        syncListeners()
    }

    private func syncListeners() {
        if Settings.shared.hudVolume {
            installVolumeListener()
        } else {
            removeVolumeListener()
        }
    }

    // MARK: Volume

    private var defaultOutputDevice: AudioDeviceID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var deviceID = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &deviceID
        )
        return status == noErr && deviceID != 0 ? deviceID : nil
    }

    private func installVolumeListener() {
        guard volumeListener == nil, let device = defaultOutputDevice else { return }
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyVolumeScalar,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            Task { @MainActor in self?.reportVolume() }
        }
        if AudioObjectAddPropertyListenerBlock(device, &address, .main, block) == noErr {
            volumeListener = block
            lastVolume = currentVolume() ?? -1
        }
    }

    private func removeVolumeListener() {
        guard let volumeListener, let device = defaultOutputDevice else {
            self.volumeListener = nil
            return
        }
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyVolumeScalar,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        AudioObjectRemovePropertyListenerBlock(device, &address, .main, volumeListener)
        self.volumeListener = nil
    }

    /// Reads the device's main output volume.
    ///
    /// Uses `kAudioDevicePropertyVolumeScalar` on the main element. Some devices
    /// expose per-channel volume only and have no main element; those simply
    /// return `nil` and no HUD is shown, rather than reporting a wrong level.
    private func currentVolume() -> Double? {
        guard let device = defaultOutputDevice else { return nil }
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyVolumeScalar,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        var volume = Float32(0)
        var size = UInt32(MemoryLayout<Float32>.size)
        let status = AudioObjectGetPropertyData(device, &address, 0, nil, &size, &volume)
        return status == noErr ? Double(volume) : nil
    }

    private func isMuted() -> Bool {
        guard let device = defaultOutputDevice else { return false }
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyMute,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        var muted = UInt32(0)
        var size = UInt32(MemoryLayout<UInt32>.size)
        let status = AudioObjectGetPropertyData(device, &address, 0, nil, &size, &muted)
        return status == noErr && muted == 1
    }

    private func reportVolume() {
        guard Settings.shared.hudVolume, let volume = currentVolume() else { return }
        guard abs(volume - lastVolume) > 0.001 else { return }
        lastVolume = volume
        present(HUDState(kind: .volume, value: volume, isMuted: isMuted()))
    }

    // MARK: Presentation

    private func present(_ newState: HUDState) {
        withAnimation(NotchMotion.quick) { state = newState }
        dismissTask?.cancel()
        dismissTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(1400))
            guard !Task.isCancelled else { return }
            withAnimation(NotchMotion.quick) { self?.state = nil }
        }
    }
}
