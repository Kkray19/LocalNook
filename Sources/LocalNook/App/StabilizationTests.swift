import AppKit
import AVFoundation
import EventKit
import Foundation

/// Behavioral regressions use temporary files and synthetic metadata, never user data.
enum StabilizationTests {
    static func run() {
        let check = SelfTest.check
        print("\nStabilization regressions")
        let root = AppInfo.testDirectory.appendingPathComponent("regressions")
        try! FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let corrupt = root.appendingPathComponent("notes.json")
        let original = Data("{broken json 👋".utf8)
        try! original.write(to: corrupt)
        let broken = NotesStore(storeURL: corrupt)
        let n = broken.addNote()
        broken.updateNote(n.id, body: "New content")
        broken.save()
        check("corrupt notes preserved byte-for-byte after an edit", (try? Data(contentsOf: corrupt)) == original, "")
        check("corruption exposes a recovery error", broken.persistenceError != nil, "")
        let notesURL = root.appendingPathComponent("good-notes.json")
        let notes = NotesStore(storeURL: notesURL)
        let note = notes.addNote()
        let body = "Unicode 👋 नमस्ते\n" + String(repeating: "Long note\n", count: 10000)
        notes.updateNote(note.id, body: body)
        notes.addTodo("Task 👋")
        notes.toggleFavourite(notes.todos[0].id)
        notes.save() // Same synchronous flush called by applicationWillTerminate.
        let restored = NotesStore(storeURL: notesURL)
        check("immediate quit flush preserves long unicode note", restored.notes.first?.body == body, "")
        check("todo favorite persists through reload", restored.todos.first?.isFavourite == true, "")
        restored.toggleDone(restored.todos[0].id); restored.archiveCompleted(); restored.save()
        check("todo archive persists", NotesStore(storeURL: notesURL).todos.first?.isArchived == true, "")
        let shelfURL = root.appendingPathComponent("bad-shelf.json")
        try! original.write(to: shelfURL)
        let shelf = ShelfStore(storeURL: shelfURL)
        shelf.add(.fromURL(URL(string: "https://example.com")!))
        check("corrupt shelf preserved after mutation", (try? Data(contentsOf: shelfURL)) == original, "")
        let userFile = root.appendingPathComponent("external.txt")
        try! Data("keep".utf8).write(to: userFile)
        let forged = ShelfItem(id: UUID(), kind: .text, name: "external", path: userFile.path,
                               payload: nil, addedAt: Date(), isOwned: true)
        let safeShelf = ShelfStore(storeURL: root.appendingPathComponent("shelf.json"))
        safeShelf.add(forged); safeShelf.remove(forged.id)
        check("forged ownership cannot delete an external file", FileManager.default.fileExists(atPath: userFile.path), "")
        safeShelf.add(.fromFile(userFile)); try! FileManager.default.removeItem(at: userFile)
        check("missing shelf reference is safely detected", safeShelf.items.first?.stillExists == false, "")
        let reloadedShelf = ShelfStore(storeURL: root.appendingPathComponent("shelf.json"))
        check("missing shelf file does not survive reload as actionable", reloadedShelf.items.isEmpty, "")

        let model = NotchViewModel(screenID: NSScreen.main?.stableID)
        Settings.shared.hapticFeedback = false
        Settings.shared.closeDelay = 0.05
        model.open(); model.scheduleClose(); model.scheduleOpen()
        SelfTest.pumpEvents(for: 0.12)
        check("hover reentry cancels pending close while already open", model.state == .open, "")
        for _ in 0..<100 { model.open(); model.scheduleClose(); model.close(); model.scheduleOpen(); model.close() }
        SelfTest.pumpEvents(for: 0.2)
        check("100 interrupted open-close cycles settle closed", model.state == .closed, "")
        model.isSuppressed = true; model.open()
        check("suppressed notch rejects open", model.state == .closed, "")
        let area = HoverTracker.TrackingView(frame: CGRect(x: 0, y: 0, width: 100, height: 30))
        area.updateTrackingAreas(); area.frame.size = CGSize(width: 400, height: 190); area.updateTrackingAreas()
        check("tracking area rebuild keeps one current area", area.trackingAreas.count == 1, "")
        check("tracking stays active without app activation", area.trackingAreas[0].options.contains(.activeAlways), "")
        for _ in 0..<300 { HoverTracker.record("test") }
        check("hover diagnostics remain bounded", HoverTracker.diagnostics.count <= 200, "")
        let controller = NotchWindowController.shared
        controller.start(); controller.perform(.open)
        SelfTest.pumpEvents(for: 0.1)
        controller.perform(.close)
        // The shrink is deliberately deferred until the closing animation has
        // finished, so wait for the condition rather than guessing a duration —
        // a fixed pump fails under load for no real reason.
        let hasShrunk = { controller.panelFrames.allSatisfy { $0.width < 500 && $0.height < 60 } }
        SelfTest.waitUntil(hasShrunk, timeout: 3.0)
        check("closed panel relinquishes expanded transparent canvas", hasShrunk(), "")
        controller.stop()
        let size = NotchGeometry.windowSize(for: NSScreen.main)
        // Stated as intent rather than a fixed number, so it keeps meaning if
        // the dashboard's content width changes.
        check("default panel removes unnecessary side gutters",
              size.width <= NotchGeometry.openSize.width + 100,
              "panel \(Int(size.width))pt for \(Int(NotchGeometry.openSize.width))pt of content")
        check("fullscreen on another equal-size monitor does not suppress this one",
              !FullscreenDetector.covers(CGRect(x: 1512, y: 0, width: 1512, height: 982),
                                        screen: CGRect(x: 0, y: 0, width: 1512, height: 982)), "")
        var demand = CaptureDemand(); demand.activate()
        let pending = demand.nextConfiguration(); demand.deactivate()
        check("camera completion after close is rejected", !demand.accepts(pending), "")
        demand.activate(); let first = demand.nextConfiguration(); let second = demand.nextConfiguration()
        check("camera switch discards older configuration", !demand.accepts(first) && demand.accepts(second), "")

        let fake = FakeCaptureDriver()
        let mirror = MirrorManager(box: fake, authorizationStatus: { .authorized })
        // Appearing is not consent. The Mirror widget can appear because the
        // notch opened on hover or a panel rebuilt after a display change, and
        // none of those may light the camera.
        mirror.activate()
        check("merely appearing does not start the camera", fake.configureCount == 0,
              "capture began without the user asking")
        mirror.requestStart()
        check("camera startup requested through driver", fake.configureCount == 1, "")
        mirror.stop()
        fake.completeStartup()
        check("closing during camera startup enqueues stop", fake.stopCount == 1, "")
        check("late camera callback cannot mark closed mirror running", !mirror.isRunning, "")
        let sharedDriver = FakeCaptureDriver()
        let sharedMirror = MirrorManager(box: sharedDriver, authorizationStatus: { .authorized })
        let ownerA = UUID(), ownerB = UUID()
        sharedMirror.requestStart(owner: ownerA); sharedMirror.activate(owner: ownerB)
        sharedMirror.release(owner: ownerA)
        check("closing one mirror leaves the other preview active", sharedDriver.stopCount == 0, "")
        sharedMirror.release(owner: ownerB)
        check("last mirror lease stops capture", sharedDriver.stopCount == 1, "")
        let deniedDriver = FakeCaptureDriver()
        let deniedMirror = MirrorManager(box: deniedDriver, authorizationStatus: { .denied })
        deniedMirror.activate()
        check("denied camera never configures capture", deniedMirror.isDenied && deniedDriver.configureCount == 0, "")
        check("calendar select-none includes no calendar", !CalendarManager.includesCalendar("a", selectedIDs: []), "")
        check("calendar selection excludes stale identifiers", !CalendarManager.includesCalendar("b", selectedIDs: ["a"]), "")
        check("live activity shoulders center the camera dead zone",
              ClosedActivityView.leadingWidth == ClosedActivityView.trailingWidth, "")
        LiveActivityCenter.shared.start()
        let activityTimer = TimerManager.shared
        activityTimer.setMode(.countdown); activityTimer.reset(); activityTimer.start()
        SelfTest.pumpEvents(for: 0.05)
        check("timer start appears as a live activity", LiveActivityCenter.shared.current?.id == "timer.running", "")
        activityTimer.pause(); SelfTest.pumpEvents(for: 0.05)
        check("timer pause removes standing live activity", LiveActivityCenter.shared.current?.id != "timer.running", "")
        activityTimer.reset()
                var now = Date(timeIntervalSince1970: 1000)
        let timer = TimerManager(now: { now })
        timer.start(); now += 120; timer.refreshDisplayed()
        check("timer uses elapsed time across missed ticks", abs(timer.displayed - 180) < 0.01, "")
        timer.pause(); now += 3600; timer.refreshDisplayed()
        check("paused timer does not count sleep", abs(timer.displayed - 180) < 0.01, "")
        timer.start(); now += 180; timer.refreshDisplayed()
        check("countdown completes once after wake", !timer.isRunning && timer.displayed == 0, "")
        timer.setMode(.stopwatch); timer.start(); now += 7200; timer.refreshDisplayed()
        check("stopwatch counts two hours without ticks", timer.displayed == 7200, "")
        timer.reset(); timer.setMode(.pomodoro); timer.start(); now += 1500; timer.refreshDisplayed()
        check("pomodoro advances to break after missing ticks", timer.pomodoroPhase == .shortBreak && !timer.isRunning, "")
        var track = NowPlaying.idle; track.state = .paused; track.position = -50; track.duration = 100
        check("negative paused media position clamps", track.interpolatedPosition == 0, "")
        track.position = 150
        check("paused position cannot exceed duration", track.interpolatedPosition == 100, "")
        track.position = .nan
        check("invalid media position stays finite", track.interpolatedPosition.isFinite, "")

        // Run actual processes: argv fidelity, concurrent output, failure and timeout.
        var completed = false
        Task {
            let payload = await MediaScriptBridge.shared.run("return {\"playing\", \"line1\" & linefeed & \"line2\", \"artist\", \"album\", 200000, -5}")
            let parsed = parseStandard(payload, sourceID: "spotify", sourceName: "Spotify", positionScale: 0.001)
            check("typed media metadata preserves newline titles", parsed?.title == "line1\nline2", "")
            check("Spotify milliseconds convert and negative position clamps", parsed?.duration == 200 && parsed?.position == 0, "")
            let hostile = "quotes '\" ; $(echo bad) 👋"
            let echo = await ProcessRunner.run("/usr/bin/printf", ["%s", hostile])
            check("process preserves hostile unicode argv literally", echo.standardOutput == hostile, "")
            let noisy = await ProcessRunner.run("/usr/bin/awk", ["BEGIN {for(i=0;i<20000;i++){print \"output\"; print \"error\" > \"/dev/stderr\"}}"])
            check("large stdout and stderr do not deadlock", noisy.exitCode == 0 && noisy.standardError.count > 65536, "")
            let timeout = await ProcessRunner.run("/bin/sleep", ["10"], timeout: .milliseconds(50))
            check("hung process times out", timeout.exitCode == -2, "")
            let missing = await ProcessRunner.run("/nonexistent/localnook-tool", [])
            check("missing executable fails gracefully", missing.exitCode == -1, "")
            let sessions = root.appendingPathComponent("sessions/2026/09/08")
            try! FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
            let file = sessions.appendingPathComponent("malformed.jsonl")
            try! Data([0xff, 0x00, 0xfe]).write(to: file)
            let result = await SessionMonitor.scan(agents: [.codex], roots: [.codex: root.appendingPathComponent("sessions")])
            check("nested malformed transcript uses only file metadata", result.count == 1 && result[0].byteSize == 3, "")
            try! FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-8 * 86400)], ofItemAtPath: file.path)
            let stale = await SessionMonitor.scan(agents: [.codex], roots: [.codex: root.appendingPathComponent("sessions")])
            check("stale transcript is excluded", stale.isEmpty, "")
            let absent = await SessionMonitor.scan(agents: [.codex], roots: [.codex: root.appendingPathComponent("absent")])
            check("missing session folder is safe", absent.isEmpty, "")
            completed = true
        }
        let deadline = Date().addingTimeInterval(15)
        while !completed && Date() < deadline { SelfTest.pumpEvents(for: 0.05) }
        check("asynchronous regressions finish", completed, "")
    }
}

nonisolated final class FakeCaptureDriver: CaptureSessionDriver, @unchecked Sendable {
    let session = AVCaptureSession()
    // This fixture is driven exclusively on the main actor.
    var configureCount = 0
    var stopCount = 0
    private var completion: (@Sendable (String?, Bool) -> Void)?
    func configure(deviceID: String, completion: @escaping @Sendable (String?, Bool) -> Void) {
        configureCount += 1
        self.completion = completion
    }
    func stop(completion: @escaping @Sendable () -> Void) { stopCount += 1; completion() }
    func completeStartup() { completion?(nil, true) }
}
