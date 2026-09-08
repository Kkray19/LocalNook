//
//  AudioDeviceMonitor.swift
//  LocalNook
//
//  Copyright (C) 2026 Krish Kowli
//  Licensed under the GNU General Public License v3.0 or later. See LICENSE.
//
//  Detects the output device changing — AirPods connecting, headphones being
//  unplugged, an external display's speakers taking over.
//
//  Why CoreAudio rather than IOBluetooth: `IOBluetoothDevice.pairedDevices()`
//  aborts the process outright in this environment, and CoreBluetooth would
//  require a Bluetooth permission prompt while only seeing BLE peripherals we
//  actively scan for. The audio-object property listener needs no permission,
//  is event-driven, and covers the case people actually notice.
//
//  Limitation, stated plainly: Bluetooth devices that are not audio outputs
//  (a mouse, a keyboard) do not raise an activity.
//

import Combine
import CoreAudio
import Foundation

final class AudioDeviceMonitor: ObservableObject {
    static let shared = AudioDeviceMonitor()

    @Published private(set) var outputDeviceName: String = ""
    /// True when the current output looks like a wireless headset.
    @Published private(set) var isWireless = false

    private var listenerBlock: AudioObjectPropertyListenerBlock?
    private var address = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDefaultOutputDevice,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )

    private init() {
        refresh(announce: false)
        installListener()
    }

    isolated deinit {
        if let listenerBlock {
            AudioObjectRemovePropertyListenerBlock(
                AudioObjectID(kAudioObjectSystemObject), &address, .main, listenerBlock
            )
        }
    }

    private func installListener() {
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            Task { @MainActor in self?.refresh(announce: true) }
        }
        let status = AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject), &address, .main, block
        )
        if status == noErr { listenerBlock = block }
    }

    private func refresh(announce: Bool) {
        guard let deviceID = defaultOutputDeviceID() else { return }
        let name = deviceName(deviceID)
        let transport = transportType(deviceID)
        let wireless = transport == kAudioDeviceTransportTypeBluetooth
            || transport == kAudioDeviceTransportTypeAirPlay

        let previousName = outputDeviceName
        guard name != previousName else { return }

        outputDeviceName = name
        isWireless = wireless

        guard announce, !previousName.isEmpty else { return }
        NotificationCenter.default.post(
            name: .audioOutputChanged,
            object: AudioOutputChange(name: name, isWireless: wireless)
        )
    }

    private func defaultOutputDeviceID() -> AudioDeviceID? {
        var deviceID = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &deviceID
        )
        return status == noErr && deviceID != 0 ? deviceID : nil
    }

    private func deviceName(_ deviceID: AudioDeviceID) -> String {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioObjectPropertyName,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        // CoreAudio hands back a +1 CFString, so it must come through
        // `Unmanaged` — taking the address of a `CFString` var instead would be
        // forming a raw pointer to an object reference.
        var name: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let status = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &name)
        guard status == noErr, let name else { return "" }
        return name.takeRetainedValue() as String
    }

    private func transportType(_ deviceID: AudioDeviceID) -> UInt32 {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyTransportType,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var transport = UInt32(0)
        var size = UInt32(MemoryLayout<UInt32>.size)
        AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &transport)
        return transport
    }
}

struct AudioOutputChange: Sendable {
    let name: String
    let isWireless: Bool
}

extension Notification.Name {
    static let audioOutputChanged = Notification.Name("LocalNook.audioOutputChanged")
}
