//
//  BrowserAudioMonitor.swift
//  LocalNook
//
//  Copyright (C) 2026 Krish Kowli
//  Licensed under the GNU General Public License v3.0 or later. See LICENSE.
//
//  Which applications are producing audio right now.
//
//  Public CoreAudio, not a private framework: `kAudioHardwarePropertyProcessObjectList`
//  (macOS 14.2+) enumerates audio process objects, and each one reports its pid
//  and whether it is currently outputting. No entitlement, no TCC prompt, no
//  scripting permission — this works the moment the app launches.
//
//  It is the load-bearing piece of browser media support, because it answers the
//  one question a browser will not otherwise tell us without JavaScript: is this
//  tab actually *playing*, or merely open? A "now playing" that shows a paused
//  video as though it were playing is worse than showing nothing.
//
//  ── A detail that has to be handled, not assumed ───────────────────────────
//
//  Chromium browsers do not play audio from the browser process. Measured on
//  this machine with a YouTube video playing:
//
//      Google Chrome Helper   outputting=YES
//      Google Chrome Helper   outputting=no
//      Google Chrome          outputting=no
//
//  So attributing audio by process name alone would conclude Chrome is silent
//  while it is playing. Processes are matched to a browser by executable path —
//  every helper lives inside the parent's bundle — which also covers Safari's
//  `com.apple.WebKit.GPU` and future helper renames.
//

import AppKit
import AudioToolbox
import CoreAudio
import Foundation

nonisolated enum BrowserAudioMonitor {
    /// Whether any process belonging to the running app with `bundleID` is
    /// outputting audio.
    ///
    /// Matched against where the app is *running from*, not where it is
    /// installed. Those differ more often than one would expect: Chrome on this
    /// machine runs under App Translocation, so its helpers live at
    ///
    ///     /private/var/folders/…/AppTranslocation/<uuid>/d/Google Chrome.app/…
    ///
    /// while `NSWorkspace` reports the bundle at `/Applications/Google
    /// Chrome.app`. Prefix-matching the installed path found nothing while a
    /// video was audibly playing, and the widget said "paused". Asking
    /// `NSRunningApplication` for the bundle it actually launched from is
    /// correct for translocated, quarantined and relocated copies alike.
    ///
    /// Returns false when the API is unavailable rather than guessing, so an
    /// older system degrades to "not playing" rather than to a false positive.
    static func isOutputtingAudio(bundleID: String) -> Bool {
        guard !bundleID.isEmpty else { return false }
        let roots = NSRunningApplication
            .runningApplications(withBundleIdentifier: bundleID)
            .compactMap { $0.bundleURL?.path }
        guard !roots.isEmpty else { return false }

        for pid in outputtingProcessIDs() {
            guard let path = executablePath(forPID: pid) else { continue }
            // Helpers live inside the parent bundle, so a prefix match catches
            // them all without naming any of them.
            if roots.contains(where: { path.hasPrefix($0) }) { return true }
        }
        return false
    }

    /// PIDs currently producing output audio.
    static func outputtingProcessIDs() -> [pid_t] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyProcessObjectList,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size
        ) == noErr, size > 0 else { return [] }

        let count = Int(size) / MemoryLayout<AudioObjectID>.size
        var objects = [AudioObjectID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &objects
        ) == noErr else { return [] }

        return objects.compactMap { object in
            guard isRunningOutput(object), let pid = processID(of: object) else { return nil }
            return pid
        }
    }

    private static func isRunningOutput(_ object: AudioObjectID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioProcessPropertyIsRunningOutput,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var running: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, &running) == noErr
        else { return false }
        return running != 0
    }

    private static func processID(of object: AudioObjectID) -> pid_t? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioProcessPropertyPID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var pid: pid_t = 0
        var size = UInt32(MemoryLayout<pid_t>.size)
        guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, &pid) == noErr
        else { return nil }
        return pid
    }

    private static func executablePath(forPID pid: pid_t) -> String? {
        var buffer = [CChar](repeating: 0, count: 4096)
        let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        guard length > 0 else { return nil }
        return String(cString: buffer)
    }
}
