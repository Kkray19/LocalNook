//
//  BrowserMediaProvider.swift
//  LocalNook
//
//  Copyright (C) 2026 Krish Kowli
//  Licensed under the GNU General Public License v3.0 or later. See LICENSE.
//
//  A MediaProvider backed by a browser's scripting dictionary. See BrowserMedia
//  for what is and is not possible, and why.
//

import AppKit
import Foundation

nonisolated final class BrowserMediaProvider: MediaProvider, @unchecked Sendable {
    let browser: MediaBrowser

    /// Whether page access has been observed to work. Nil until tried once.
    ///
    /// Cached because the probe is a failed Apple Event, which is cheap but not
    /// free, and because the answer only changes when the user flips a menu
    /// item. Re-probed whenever a fetch finds a media tab but has no page data,
    /// so switching the toggle on is picked up without a relaunch.
    private var pageAccess: Bool?
    /// Guards `pageAccess`. A serial queue rather than a lock, because the
    /// state is read and written on both sides of an await and NSLock must not
    /// be held across one.
    private let stateQueue = DispatchQueue(label: "com.localnook.browsermedia")

    init(browser: MediaBrowser) {
        self.browser = browser
    }

    var id: String { "browser.\(browser.rawValue)" }
    var displayName: String { browser.displayName }
    var bundleID: String { browser.bundleID }

    /// Installed, running, and switched on by the user.
    ///
    /// The setting is checked here rather than at the call site so that no code
    /// path can reach a browser without consent: reading tabs needs Automation
    /// permission, and a permission prompt must never be the consequence of
    /// merely opening the dashboard.
    var isAvailable: Bool {
        guard Self.browserMediaEnabled() else { return false }
        return MediaScriptBridge.isInstalled(bundleID: browser.bundleID)
            && MediaScriptBridge.isRunning(bundleID: browser.bundleID)
    }

    /// Reads the stored preference directly rather than through `Settings`.
    ///
    /// `Settings` is main-actor isolated and this provider is not: `fetch()` is
    /// nonisolated and async, so it runs off the main actor, and reaching for
    /// main-actor state from there with `assumeIsolated` traps at runtime. The
    /// preference is a single Bool under a known key, so it is read from the
    /// same defaults store `@Pref` writes to — which is also the disposable
    /// suite during a self-test, so isolation is preserved.
    private static func browserMediaEnabled() -> Bool {
        AppInfo.defaults.bool(forKey: "media.browserEnabled")
    }



    // MARK: Reading

    func fetch() async -> NowPlaying? {
        guard isAvailable else { return nil }

        guard let tab = await firstMediaTab() else { return nil }

        // Audio output is the only authoritative playing/paused signal without
        // page access, and it stays authoritative *with* it — a tab can be
        // playing while muted, in which case the page knows and CoreAudio does
        // not, so the page's own answer wins when there is one.
        let emittingAudio = BrowserAudioMonitor.isOutputtingAudio(bundleID: browser.bundleID)
        let isPlaying = tab.isPaused.map { !$0 } ?? emittingAudio

        var capabilities: MediaCapabilities = .playbackState
        var duration = 0.0
        var position = 0.0
        var durationUnknown = true

        if let tabDuration = tab.duration, let tabPosition = tab.position {
            capabilities.insert(.position)
            capabilities.formUnion([.playPause, .seek])
            position = tabPosition
            if tabDuration > 0, tabDuration.isFinite, !tab.isLive {
                duration = tabDuration
                durationUnknown = false
            }
        }

        let advert = BrowserMediaParser.looksLikeAdvertisement(tab.title)

        return NowPlaying(
            sourceID: id,
            sourceName: browser.displayName,
            state: isPlaying ? .playing : .paused,
            title: tab.title,
            // The site, not a guessed artist. A YouTube title is not reliably
            // "Artist - Track", and splitting on a hyphen would invent an
            // attribution that is wrong more often than it is right.
            artist: advert ? "Advertisement · \(tab.site)" : tab.site,
            album: "",
            duration: duration,
            position: position,
            positionSampledAt: Date(),
            artworkKey: "",
            capabilities: capabilities,
            durationIsUnknown: durationUnknown
        )
    }

    /// Browsers have no artwork to give: page access reaches the media element,
    /// not the site's own thumbnail, and fetching one would mean a network
    /// request to a third party.
    func artwork(for snapshot: NowPlaying) async -> NSImage? { nil }

    // MARK: Controls

    func playPause() async {
        guard hasPageAccess else { return }
        _ = await runPageScript("var v=document.querySelector('video,audio'); if(v){v.paused?v.play():v.pause();} '';")
    }

    /// Skipping is not offered: a browser has no notion of a queue that a page
    /// script can safely act on, and clicking a site's own "next" button would
    /// mean guessing at its markup. `MediaCapabilities.skip` is never set, so
    /// the UI never shows the control.
    func next() async {}
    func previous() async {}

    func seek(to seconds: Double) async {
        guard hasPageAccess else { return }
        _ = await runPageScript("var v=document.querySelector('video,audio'); if(v){v.currentTime=\(seconds);} '';")
    }

    // MARK: Tabs

    private func firstMediaTab() async -> BrowserMediaTab? {
        let result = await MediaScriptBridge.shared.run(tabListingScript)
        guard result.errorNumber == nil else { return nil }

        // Lines alternate title, URL — a delimiter inside a page title would
        // otherwise split it in the middle.
        var candidates: [BrowserMediaTab] = []
        var index = 0
        while index + 1 < result.lines.count {
            let title = result.lines[index]
            let url = result.lines[index + 1]
            index += 2
            guard let site = BrowserMediaParser.site(forURL: url) else { continue }
            candidates.append(BrowserMediaTab(
                title: BrowserMediaParser.cleanTitle(title, site: site),
                url: url,
                site: site
            ))
        }
        guard var tab = candidates.first else { return nil }

        if let page = await pageState(forURL: tab.url) {
            tab.position = page.position
            tab.duration = page.duration
            tab.isPaused = page.isPaused
            tab.isLive = page.isLive
        }
        return tab
    }

    private var tabListingScript: String {
        switch browser {
        case .chrome:
            """
            set out to {}
            tell application "Google Chrome"
              repeat with w in windows
                repeat with t in tabs of w
                  set end of out to (title of t)
                  set end of out to (URL of t)
                end repeat
              end repeat
            end tell
            set AppleScript's text item delimiters to linefeed
            return out as text
            """
        case .safari:
            """
            set out to {}
            tell application "Safari"
              repeat with w in windows
                repeat with t in tabs of w
                  set end of out to (name of t)
                  set end of out to (URL of t)
                end repeat
              end repeat
            end tell
            set AppleScript's text item delimiters to linefeed
            return out as text
            """
        }
    }

    // MARK: Page access

    private var hasPageAccess: Bool {
        stateQueue.sync { pageAccess == true }
    }

    private struct PageState {
        var position: Double
        var duration: Double?
        var isPaused: Bool
        var isLive: Bool
    }

    /// Reads the page's own media element, when the user has allowed it.
    private func pageState(forURL url: String) async -> PageState? {
        if stateQueue.sync(execute: { pageAccess }) == false { return nil }

        let script = """
        var v=document.querySelector('video,audio');
        if(!v){''}else{
        var d=(isFinite(v.duration)&&v.duration>0)?v.duration:-1;
        [(v.paused?1:0),Math.floor(v.currentTime*1000)/1000,d].join('|')}
        """
        let result = await runPageScript(script)

        guard result.errorNumber == nil else {
            // Any failure here means page access is off or was revoked. Recorded
            // rather than retried on every poll.
            stateQueue.sync { pageAccess = false }
            return nil
        }
        stateQueue.sync { pageAccess = true }

        let parts = (result.lines.first ?? "").split(separator: "|").map(String.init)
        guard parts.count == 3,
              let paused = Int(parts[0]),
              let position = Double(parts[1]),
              let duration = Double(parts[2])
        else { return nil }

        // -1 is the page telling us the duration is not a finite number: a
        // livestream, or metadata that has not arrived yet. Either way there is
        // no honest progress bar to draw.
        let isLive = duration <= 0
        return PageState(
            position: position,
            duration: isLive ? nil : duration,
            isPaused: paused == 1,
            isLive: isLive
        )
    }

    private func runPageScript(_ javaScript: String) async -> ScriptResult {
        let escaped = appleScriptEscaped(javaScript)
        let source: String
        switch browser {
        case .chrome:
            source = """
            tell application "Google Chrome"
              set target to missing value
              repeat with w in windows
                repeat with t in tabs of w
                  if (URL of t contains "youtube.com") or (URL of t contains "spotify.com") \
            or (URL of t contains "soundcloud.com") or (URL of t contains "twitch.tv") \
            or (URL of t contains "vimeo.com") or (URL of t contains "bandcamp.com") \
            or (URL of t contains "music.apple.com") then
                    set target to t
                    exit repeat
                  end if
                end repeat
                if target is not missing value then exit repeat
              end repeat
              if target is missing value then return ""
              return (execute target javascript "\(escaped)") as text
            end tell
            """
        case .safari:
            source = """
            tell application "Safari"
              set target to missing value
              repeat with w in windows
                repeat with t in tabs of w
                  if (URL of t contains "youtube.com") or (URL of t contains "spotify.com") \
            or (URL of t contains "soundcloud.com") or (URL of t contains "twitch.tv") \
            or (URL of t contains "vimeo.com") or (URL of t contains "bandcamp.com") \
            or (URL of t contains "music.apple.com") then
                    set target to t
                    exit repeat
                  end if
                end repeat
                if target is not missing value then exit repeat
              end repeat
              if target is missing value then return ""
              return (do JavaScript "\(escaped)" in target) as text
            end tell
            """
        }
        return await MediaScriptBridge.shared.run(source)
    }

    /// Whether page access is known to be unavailable, so the UI can say what
    /// to switch on rather than silently offering less.
    var pageAccessIsOff: Bool {
        stateQueue.sync { pageAccess == false }
    }
}
