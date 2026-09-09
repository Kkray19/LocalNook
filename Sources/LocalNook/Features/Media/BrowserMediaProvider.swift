//
//  BrowserMediaProvider.swift
//  LocalNook
//
//  Copyright (C) 2026 Krish Kowli
//  Licensed under the GNU General Public License v3.0 or later. See LICENSE.
//
//  A MediaProvider backed by a browser's scripting dictionary.
//
//  This file gathers observations; it decides nothing. What may honestly be
//  claimed from them lives in BrowserPlaybackResolver, which is a pure function
//  and therefore testable without a browser, without audio, and without
//  permission. See BrowserMedia.swift for what each tier can and cannot know.
//

import AppKit
import Foundation

nonisolated final class BrowserMediaProvider: MediaProvider, @unchecked Sendable {
    let browser: MediaBrowser

    /// Everything mutable across polls, behind one queue.
    ///
    /// A serial queue rather than a lock, because this state is read and
    /// written on both sides of an await and NSLock must not be held across one.
    private struct State {
        /// Whether page access has been observed to work. Nil until tried.
        var pageAccess: Bool?
        /// When the last failed page-access probe happened, so a user who
        /// switches the browser's menu item on is picked up without relaunching
        /// LocalNook — but not by retrying a failing Apple Event every second.
        var lastPageProbe: Date?
        /// The tab currently on screen, so two equally playing tabs do not swap
        /// the widget back and forth.
        var incumbentTabKey: String?
        var audioHold = BrowserAudioHold()
    }
    private var state = State()
    private let stateQueue = DispatchQueue(label: "com.localnook.browsermedia")

    /// How long to wait before retrying page access after it failed.
    private static let pageProbeInterval: TimeInterval = 30
    /// Most tabs to run a page script in per poll. A person with forty tabs
    /// open should not pay for all of them once a second.
    private static let maxScriptedTabs = 8

    init(browser: MediaBrowser) {
        self.browser = browser
    }

    var id: String { "browser.\(browser.rawValue)" }
    var displayName: String { browser.displayName }
    var bundleID: String { browser.bundleID }

    // MARK: Availability

    /// Installed, running, switched on, and permitted.
    ///
    /// The permission check is read-only and cannot prompt, which is what makes
    /// it safe to consult on every poll. Before it existed, the only way to
    /// discover consent was to send an event and see what happened — and that
    /// is exactly the thing that must not happen because a dashboard opened.
    var isAvailable: Bool {
        guard Self.browserMediaEnabled(), isInstalledAndRunning else { return false }
        return AutomationPermission.status(forBundleID: browser.bundleID).isGranted
    }

    private var isInstalledAndRunning: Bool {
        MediaScriptBridge.isInstalled(bundleID: browser.bundleID)
            && MediaScriptBridge.isRunning(bundleID: browser.bundleID)
    }

    /// Switched on and running, but not permitted yet — so the UI can offer to
    /// connect it instead of silently showing nothing.
    var connectionStatus: AutomationPermission.Status? {
        guard Self.browserMediaEnabled(), isInstalledAndRunning else { return nil }
        let status = AutomationPermission.status(forBundleID: browser.bundleID)
        return status.isGranted ? nil : status
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
        guard isAvailable else { forget(); return nil }

        var tabs = await mediaTabs()
        guard !tabs.isEmpty else {
            // No player open. Whatever the browser may be making a noise about,
            // it is not something this app claims to know.
            forget()
            return nil
        }

        if shouldTryPageAccess {
            let pages = await pageStates()
            recordPageAccess(pages.reachable)
            for index in tabs.indices {
                tabs[index].page = pages.byKey[tabs[index].key]
            }
        }

        // Debounced so a track boundary or a buffer stall does not blink the
        // widget out and back.
        let audible = observeAudio(
            BrowserAudioMonitor.isOutputtingAudio(bundleID: browser.bundleID)
        )

        guard let resolution = BrowserPlaybackResolver.resolve(
            tabs: tabs,
            audioActive: audible,
            browserName: browser.displayName,
            incumbentTabKey: incumbentTabKey
        ) else {
            setIncumbent(nil)
            return nil
        }
        setIncumbent(resolution.tabKey.isEmpty ? nil : resolution.tabKey)

        return NowPlaying(
            sourceID: id,
            sourceName: browser.displayName,
            state: resolution.state,
            title: resolution.title,
            artist: resolution.subtitle,
            album: "",
            duration: resolution.duration,
            position: resolution.position,
            positionSampledAt: Date(),
            artworkKey: "",
            capabilities: resolution.capabilities,
            durationIsUnknown: resolution.durationIsUnknown,
            sourceIsAmbiguous: resolution.isAmbiguous
        )
    }

    /// No artwork, for now.
    ///
    /// Not because a browser inherently cannot supply any — that would be an
    /// overstatement. A page has plausible local sources (its own `<video>`
    /// poster, an Open Graph image element, `navigator.mediaSession` metadata),
    /// and some of those are reachable through page access. None of them has
    /// been verified to work here, and most of what they hand back is a URL,
    /// which would mean a network request that this app deliberately does not
    /// make. So artwork is deferred rather than declared impossible, and the
    /// widget draws its locally generated placeholder in the meantime.
    func artwork(for snapshot: NowPlaying) async -> NSImage? { nil }

    // MARK: Controls

    /// Only ever reachable when page access supplied a definite state, because
    /// `.playPause` is not in the capabilities otherwise and the UI draws no
    /// button. Guarded again here so a future caller cannot bypass that.
    func playPause() async {
        guard hasPageAccess, let key = incumbentTabKey else { return }
        _ = await runPageScript(
            "var v=document.querySelector('video,audio');"
            + "if(v){v.paused?v.play():v.pause();} ''",
            inTabKey: key
        )
    }

    /// Skipping is not offered: a browser has no notion of a queue that a page
    /// script can safely act on, and clicking a site's own "next" button would
    /// mean guessing at its markup. `MediaCapabilities.skip` is never set, so
    /// the UI never shows the control.
    func next() async {}
    func previous() async {}

    func seek(to seconds: Double) async {
        guard hasPageAccess, let key = incumbentTabKey else { return }
        _ = await runPageScript(
            "var v=document.querySelector('video,audio');"
            + "if(v){v.currentTime=\(seconds);} ''",
            inTabKey: key
        )
    }

    // MARK: State

    private var incumbentTabKey: String? {
        stateQueue.sync { state.incumbentTabKey }
    }

    private func setIncumbent(_ key: String?) {
        stateQueue.sync { state.incumbentTabKey = key }
    }

    private func observeAudio(_ active: Bool) -> Bool {
        stateQueue.sync { state.audioHold.observe(active) }
    }

    /// Drops everything remembered. Called whenever the browser stops being a
    /// source at all — quit, switched off, permission revoked, last player tab
    /// closed — so nothing survives into a situation it was not measured in.
    private func forget() {
        stateQueue.sync {
            state.incumbentTabKey = nil
            state.audioHold.reset()
        }
    }

    private var hasPageAccess: Bool {
        stateQueue.sync { state.pageAccess == true }
    }

    /// True while page access is unknown, working, or due for a retry.
    private var shouldTryPageAccess: Bool {
        stateQueue.sync {
            guard state.pageAccess == false else { return true }
            guard let last = state.lastPageProbe else { return true }
            return Date().timeIntervalSince(last) >= Self.pageProbeInterval
        }
    }

    private func recordPageAccess(_ reachable: Bool) {
        stateQueue.sync {
            state.pageAccess = reachable
            state.lastPageProbe = Date()
        }
    }

    /// Whether page access is known to be unavailable, so the UI can say what
    /// to switch on rather than silently offering less.
    var pageAccessIsOff: Bool {
        stateQueue.sync { state.pageAccess == false }
    }

    // MARK: Tabs

    private func mediaTabs() async -> [BrowserMediaTab] {
        let result = await MediaScriptBridge.shared.run(tabListingScript)
        guard result.errorNumber == nil else { return [] }

        var tabs: [BrowserMediaTab] = []
        var seen = Set<String>()
        for line in result.lines where !line.isEmpty {
            // key <tab> url <tab> title. The title comes last and is the only
            // field that can contain anything, so it is never split.
            let fields = line.split(separator: "\t", maxSplits: 2,
                                    omittingEmptySubsequences: false).map(String.init)
            guard fields.count == 3 else { continue }
            let (key, url, rawTitle) = (fields[0], fields[1], fields[2])
            guard let site = BrowserMediaParser.site(forURL: url) else { continue }
            guard seen.insert(key).inserted else { continue }
            tabs.append(BrowserMediaTab(
                key: key,
                title: BrowserMediaParser.cleanTitle(rawTitle, site: site),
                url: url,
                site: site
            ))
        }
        return tabs
    }

    /// Reads every media tab's own media element, when the user has allowed it.
    ///
    /// Every tab, not the first one: with two players open, which is playing is
    /// precisely the question, and asking only the first answers a different
    /// one. A tab whose player sits in a cross-origin frame, or which has no
    /// media element at all, simply returns nothing for that tab — recorded as
    /// "not known", never as "not playing".
    private func pageStates() async -> (byKey: [String: PageMedia], reachable: Bool) {
        let result = await MediaScriptBridge.shared.run(pageStateScript)
        guard result.errorNumber == nil else { return ([:], false) }

        var byKey: [String: PageMedia] = [:]
        var sawAnswer = false
        for line in result.lines where !line.isEmpty {
            let fields = line.split(separator: "\t", maxSplits: 1,
                                    omittingEmptySubsequences: false).map(String.init)
            guard fields.count == 2 else { continue }
            // The script marks a refused or failed `execute` rather than
            // swallowing it, so "page access is off" stays distinguishable from
            // "this page has no video".
            if fields[1].hasPrefix("ERR") { continue }
            sawAnswer = true
            if let page = BrowserMediaParser.parsePageMedia(fields[1]) {
                byKey[fields[0]] = page
            }
        }
        return (byKey, sawAnswer)
    }

    // MARK: Diagnostics

    /// What the provider observed, in counts and flags only.
    ///
    /// Never a title, a URL, or a site name. What someone is watching is not
    /// diagnostic information, and a probe that leaks it into a terminal
    /// scrollback or a bug report would be a worse problem than the one it
    /// solves. Everything here is a number or a boolean for that reason.
    func diagnostics() async -> String {
        let permission = AutomationPermission.status(forBundleID: browser.bundleID)
        let usable = Self.browserMediaEnabled() && isInstalledAndRunning && permission.isGranted
        guard usable else {
            return "  not available (enabled=\(Self.browserMediaEnabled())"
                + " running=\(isInstalledAndRunning) automation=\(permission.label))"
        }
        let tabs = await mediaTabs()
        let pages = await pageStates()
        let audio = BrowserAudioMonitor.isOutputtingAudio(bundleID: browser.bundleID)
        var lines = [
            "  automation=\(permission.label) mediaTabs=\(tabs.count)"
                + " pageAccess=\(pages.reachable) pagesRead=\(pages.byKey.count)"
                + " browserAudio=\(audio)",
        ]
        var merged = tabs
        for index in merged.indices { merged[index].page = pages.byKey[merged[index].key] }
        let resolution = BrowserPlaybackResolver.resolve(
            tabs: merged, audioActive: audio,
            browserName: browser.displayName, incumbentTabKey: nil
        )
        if let resolution {
            lines.append("  resolved state=\(resolution.state.rawValue)"
                + " ambiguous=\(resolution.isAmbiguous)"
                + " titleLength=\(resolution.title.count)"
                + " durationUnknown=\(resolution.durationIsUnknown)")
        } else {
            lines.append("  resolved to nothing (no evidence of playback)")
        }
        return lines.joined(separator: "\n")
    }

    // MARK: Scripts

    /// Collapses newlines and tabs in a title so one tab is always one line.
    private var flattenHandler: String {
        """
        on flat(s)
          set AppleScript's text item delimiters to {return, linefeed, tab}
          set parts to text items of (s as text)
          set AppleScript's text item delimiters to " "
          set r to parts as text
          set AppleScript's text item delimiters to ""
          return r
        end flat
        """
    }

    /// A coarse pre-filter, so the page script does not run JavaScript in tabs
    /// that are obviously not players. `BrowserMediaParser.site(forURL:)` is
    /// the authoritative filter; this one only has to avoid being narrower.
    private var playerHandler: String {
        """
        on isPlayer(u)
          repeat with h in {"youtube.com", "spotify.com", "soundcloud.com", \
        "music.apple.com", "twitch.tv", "vimeo.com", "bandcamp.com"}
            if u contains h then return true
          end repeat
          return false
        end isPlayer
        """
    }

    /// The tab's stable identity, as AppleScript. Chrome has a real tab id;
    /// Safari has none, so its URL stands in — which is why moving a Safari tab
    /// keeps stickiness but opening the same URL twice does not distinguish it.
    private var keyExpression: String {
        browser == .chrome ? "(id of t as text)" : "(URL of t as text)"
    }

    private var appTell: String {
        browser == .chrome ? "Google Chrome" : "Safari"
    }

    private var titleProperty: String {
        browser == .chrome ? "title of t" : "name of t"
    }

    private var tabListingScript: String {
        """
        \(flattenHandler)
        set out to {}
        tell application "\(appTell)"
          repeat with w in windows
            repeat with t in tabs of w
              set end of out to (\(keyExpression) & tab & (URL of t as text) \
        & tab & my flat(\(titleProperty)))
            end repeat
          end repeat
        end tell
        set AppleScript's text item delimiters to linefeed
        return out as text
        """
    }

    /// Runs the media-element probe in every player tab, capped.
    private var pageStateScript: String {
        let probe = appleScriptEscaped(Self.pageProbeJavaScript)
        let execute = browser == .chrome
            ? "(execute t javascript \"\(probe)\") as text"
            : "(do JavaScript \"\(probe)\" in t) as text"
        return """
        \(playerHandler)
        set out to {}
        set n to 0
        tell application "\(appTell)"
          repeat with w in windows
            repeat with t in tabs of w
              if n < \(Self.maxScriptedTabs) and my isPlayer(URL of t as text) then
                set n to n + 1
                set r to ""
                try
                  set r to \(execute)
                on error errText number errNum
                  set r to "ERR" & (errNum as text)
                end try
                set end of out to (\(keyExpression) & tab & r)
              end if
            end repeat
          end repeat
        end tell
        set AppleScript's text item delimiters to linefeed
        return out as text
        """
    }

    /// Picks the media element that is actually playing, when a page has more
    /// than one — an autoplaying preview beside the real player is common — and
    /// otherwise the one that has been played. Returns "" when there is none to
    /// find, which the caller reads as "not known".
    private static let pageProbeJavaScript = """
    var vs=document.querySelectorAll('video,audio');var b=null;\
    for(var i=0;i<vs.length;i++){var v=vs[i];\
    if(!v.paused&&!v.ended){b=v;break;}\
    if(!b&&(v.currentTime>0||(isFinite(v.duration)&&v.duration>0)))b=v;}\
    if(!b){''}else{var d=(isFinite(b.duration)&&b.duration>0)?b.duration:-1;\
    [(b.paused?1:0),(b.ended?1:0),(b.muted?1:0),\
    Math.floor(b.currentTime*1000)/1000,d].join('|')}
    """

    /// Runs a script in one identified tab, so a control acts on the tab the
    /// widget is describing rather than on whichever player happens to be first.
    private func runPageScript(_ javaScript: String, inTabKey key: String) async -> ScriptResult {
        let probe = appleScriptEscaped(javaScript)
        let execute = browser == .chrome
            ? "(execute t javascript \"\(probe)\") as text"
            : "(do JavaScript \"\(probe)\" in t) as text"
        let source = """
        tell application "\(appTell)"
          repeat with w in windows
            repeat with t in tabs of w
              if \(keyExpression) is "\(appleScriptEscaped(key))" then
                return \(execute)
              end if
            end repeat
          end repeat
        end tell
        return ""
        """
        return await MediaScriptBridge.shared.run(source)
    }
}
