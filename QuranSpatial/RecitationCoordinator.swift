//
//  RecitationCoordinator.swift
//  QuranSpatial
//
//  Owns the recitation: the player, the timings, the text, and the one piece of position
//  state - `currentSegmentIndex`. Everything else is derived from it.
//
//  Advance uses AVFoundation boundary observers, never a poll on a render loop. But
//  boundary observers do not fire on a seek, so they are an OPTIMISATION and not the source
//  of truth: `syncToCurrentTime()` derives the index from the player's clock and is
//  idempotent, and every path that can move the playhead calls it. That is what keeps
//  jump-to-ayah from being a rewrite later.
//
//  Ask mode (Stage 2, 2026-10-01) adds a second, deliberately separate notion: the PINNED
//  segment. `currentSegmentIndex` stays the audio's truth; `pinnedSegmentIndex` is what the
//  wearer is looking at while the two differ - during the pause and through the resume, which
//  seeks back into the previous ayah's speech-free tail so the anchor is heard from its start.
//  The view and the dissolve driver read `displayedSegmentIndex` and `pinnedProgress`; the
//  reconciliation observer keeps reading the audio's index, so it never fights the pin.
//

import AVFoundation
import Foundation
import Observation
import os

@MainActor
@Observable
final class RecitationCoordinator {

    // MARK: Tunables

    /// How long before an ayah ends the dissolve begins. The dissolve's own duration is the
    /// same value, so the effect completes exactly at the boundary rather than being cut
    /// off by the swap.
    ///
    /// 0.8s: at 90fps that is 72 frames, long enough to read as deliberate rather than as a
    /// cut. The shortest segment in the surah is 3.31s (the intro; the shortest ayah is
    /// 3.79s), so even there the text sits settled for 2.5s first. It is 10% of the 7.68s
    /// median. Expected to change once someone is wearing it - that is why it is here and
    /// not inline.
    static let dissolveLeadTime: TimeInterval = 0.8

    /// A desync alarm, not a poll: recompute the expected segment once a second and correct
    /// if it disagrees. Boundary observers are the fast path; this is what turns a silent
    /// desynchronisation into something we find out about.
    static let reconciliationInterval: TimeInterval = 1.0

    /// Interval between steps of the resume volume ramp. About one 60Hz frame; the ramp is
    /// a pure function of wall-clock time, so a late step lands at the right level anyway.
    static let volumeRampStep: Duration = .milliseconds(16)

    // MARK: State

    private(set) var experiencePhase: ExperiencePhase = .idle
    private(set) var playbackState: PlaybackState = .stopped

    /// Why the transport is `paused`. A property, not an associated value - see the locked
    /// two-enum decision in CLAUDE.md.
    enum PauseReason: String {
        case none, ask, interruption, route, background
    }
    private(set) var pauseReason: PauseReason = .none

    /// The audio's position. The only position memory in the system, derived from the
    /// player's clock. A resume does NOT restart this segment: it seeks to the anchor's
    /// speech-free gap (`resumePlan`), which lies in the previous segment, so for a few
    /// hundred milliseconds this reads one less than what is on screen.
    private(set) var currentSegmentIndex = 0

    /// The Ask anchor while it is held on screen regardless of the clock, or nil. Set on
    /// pause, cleared when the resumed audio passes `anchor.start + Dissolve.inDuration`.
    private(set) var pinnedSegmentIndex: Int?

    /// What the plane shows: the pin while there is one, the audio's segment otherwise.
    var displayedSegmentIndex: Int { pinnedSegmentIndex ?? currentSegmentIndex }

    /// Where and how the next `resume()` brings the audio back. Recorded at pause.
    private(set) var resumePlan: ResumePlan?

    /// Absolute audio time at which the pin lets go.
    private(set) var pinReleaseTime: TimeInterval?

    /// Incremented when a NEW RUN begins - a start from `stopped`/`finished`, or a debug
    /// stop. The frame-stats driver resets on this rather than on a backward segment
    /// index, because an Ask resume is a backward seek that continues the same run.
    private(set) var runTicket = 0

    /// Incremented when a dissolve should begin. Views observe the change rather than a
    /// boolean, so consecutive transitions cannot be coalesced into one.
    private(set) var dissolveTicket = 0

    private(set) var currentText: String?
    private(set) var loadFailure: String?

    /// Current audio time, for the dissolve driver. The dissolve is a pure function of
    /// this, never of accumulated frames.
    var currentAudioTime: TimeInterval {
        guard let player else { return 0 }
        let t = CMTimeGetSeconds(player.currentTime())
        return t.isFinite ? t : 0
    }

    /// Whether an index is the last segment, which never dissolves out.
    func isFinalSegment(_ index: Int) -> Bool {
        index == timings?.segments.last?.index
    }

    /// Text for any segment index, for prefetching neighbours.
    func text(forSegmentIndex index: Int) -> String? {
        textFile?.text(forSegmentIndex: index)
    }

    func segment(forIndex index: Int) -> RecitationSegment? {
        timings?.segments.first { $0.index == index }
    }

    var currentSegment: RecitationSegment? {
        timings?.segments.first { $0.index == currentSegmentIndex }
    }

    // MARK: Pin

    /// The dissolve progress the pin was taken at, and when. The recall runs from here.
    private struct PinEntry {
        let progress: Float
        let uptime: TimeInterval
    }
    @ObservationIgnored private var pinEntry: PinEntry?

    /// The dissolve progress the driver must write while the anchor is pinned, or nil when
    /// the clock should be consulted as usual. Read once per frame, so it is a pure
    /// function of the entry snapshot and wall-clock time - nothing is accumulated.
    var pinnedProgress: Float? {
        guard pinnedSegmentIndex != nil, let pinEntry else { return nil }
        return Self.recallProgress(entryProgress: pinEntry.progress,
                                   elapsed: ProcessInfo.processInfo.systemUptime - pinEntry.uptime)
    }

    /// The recall: from wherever the dissolve was at entry back to 0 at the FADE-IN rate
    /// (1 / `Dissolve.inDuration` per second), then held at 0. Decided 2026-09-30: a
    /// user-invoked recall is not a second dissolve, and it applies whether the pin came
    /// from Ask or from a system interruption.
    nonisolated static func recallProgress(entryProgress: Float, elapsed: TimeInterval) -> Float {
        guard elapsed > 0 else { return max(0, entryProgress) }
        return Float(max(0, Double(entryProgress) - elapsed / Dissolve.inDuration))
    }

    /// When the pin for a segment lets go: the first instant the pure function returns 0
    /// for it, so the hand-over from pinned 0 to clock-driven 0 is a no-op.
    nonisolated static func pinReleaseTime(for segment: RecitationSegment) -> TimeInterval {
        segment.start + Dissolve.inDuration
    }

    /// Volume during the resume ramp, as a pure function of time since the ramp began.
    nonisolated static func rampVolume(elapsed: TimeInterval, duration: TimeInterval) -> Float {
        guard duration > 0 else { return 1 }
        return Float(min(1, max(0, elapsed / duration)))
    }

    // MARK: Guts

    /// The audio session: category strategy and interruption/route observation. Owned here
    /// because every path it drives (`pause`, `resume`) and every path that drives it
    /// (`start`, `enterAsk`, `exitAsk`, `debugStop`) is in this file.
    let audioSession = AudioSessionController()

    private var timings: RecitationTimingsFile?
    private var textFile: RecitationTextFile?
    private var preroll: RecitationPrerollFile?
    private var player: AVPlayer?
    private var advanceObserver: Any?
    private var dissolveObserver: Any?
    private var reconciliationObserver: Any?
    private var pinReleaseObserver: Any?
    private var endObserver: NSObjectProtocol?
    @ObservationIgnored private var volumeRamp: Task<Void, Never>?

    private let logger = Logger(subsystem: "com.vrteek.quranspatial", category: "Recitation")

    init() {
        load()
        // Observers only; the session is configured when playback first starts, so the
        // launch snapshot records the untouched default.
        audioSession.attach(transport: self)
    }

    private func load() {
        guard let timingsURL = AudioAssetReport.locate(
                AudioAssetReport.timingsResourceName, AudioAssetReport.timingsResourceExtension)?.url,
              let audioURL = AudioAssetReport.locate(
                AudioAssetReport.audioResourceName, AudioAssetReport.audioResourceExtension)?.url,
              let textURL = Bundle.main.url(forResource: "ar-rahman-text", withExtension: "json")
        else {
            loadFailure = "a recitation asset did not resolve from the bundle"
            logger.error("Recitation assets missing; see audio-assets.txt")
            return
        }
        do {
            timings = try JSONDecoder().decode(RecitationTimingsFile.self, from: Data(contentsOf: timingsURL))
            textFile = try JSONDecoder().decode(RecitationTextFile.self, from: Data(contentsOf: textURL))
        } catch {
            loadFailure = "\(error)"
            logger.error("Recitation data failed to decode: \(error.localizedDescription)")
            return
        }
        // The pre-roll table is optional: without it every resume falls back to the segment
        // start with the short fade. Its absence is logged, not fatal.
        do {
            preroll = try RecitationPrerollFile.loadFromBundle()
        } catch {
            preroll = nil
            logger.error("Pre-roll table unavailable, resumes fall back to segment starts: \(error.localizedDescription)")
        }
        player = AVPlayer(url: audioURL)
        currentText = textFile?.text(forSegmentIndex: 0)
        installObservers()
    }

    // MARK: Transport

    /// Entry. Called once per acceptance of the dua posture; the gate guarantees that.
    /// A `paused` transport is not restarted here: that is `resume()`'s job, and acceptance
    /// cannot arrive while the gate is `.accepted` anyway.
    func start() {
        guard let player, loadFailure == nil else { return }
        guard playbackState == .stopped || playbackState == .finished else {
            logger.notice("start() ignored in \(String(describing: self.playbackState), privacy: .public)")
            return
        }
        cancelVolumeRamp()
        audioSession.configureForPlayback()
        player.volume = 1
        runTicket &+= 1
        seek(toSegment: 0)
        player.play()
        playbackState = .playing
        experiencePhase = .reciting
        syncToCurrentTime()
    }

    /// Debug-only abort. Without it, every accidental acceptance during device testing
    /// costs a ten-minute recitation. Not shipped and not user-facing.
    #if DEBUG
    func debugStop() {
        cancelVolumeRamp()
        clearPin()
        resumePlan = nil
        pauseReason = .none
        player?.pause()
        player?.volume = 1
        runTicket &+= 1
        seek(toSegment: 0)
        playbackState = .stopped
        experiencePhase = .idle
        if audioSession.isConfiguredForRecording { audioSession.configureForPlayback() }
        logger.notice("Debug stop: run aborted, returned to idle")
    }
    #endif

    // MARK: Ask

    /// Why `enterAsk()` would be refused right now, or nil if it is allowed. Pure, so the
    /// refusals are testable without a player. Decided 2026-09-30: refused on the intro and
    /// after completion; allowed on ayah 78.
    nonisolated static func askRefusal(phase: ExperiencePhase, displayedSegmentIndex: Int, assetsLoaded: Bool) -> String? {
        guard assetsLoaded else { return "assets not loaded" }
        switch phase {
        case .idle: return "not started"
        case .completed: return "completed"
        case .asking: return "already asking"
        case .reciting: break
        }
        return displayedSegmentIndex == 0 ? "intro" : nil
    }

    /// The one call that enters Ask. Anchors on the DISPLAYED segment - the ayah the wearer
    /// is looking at, which during a still-pinned resume is the anchor rather than the
    /// previous ayah the audio is passing through.
    func enterAsk() {
        let anchor = displayedSegmentIndex
        if let reason = Self.askRefusal(phase: experiencePhase, displayedSegmentIndex: anchor,
                                        assetsLoaded: player != nil && loadFailure == nil) {
            logger.notice("Ask refused: \(reason, privacy: .public)")
            return
        }
        let progressAtEntry = pinnedProgress ?? clockProgress(forSegmentIndex: anchor)
        pause(reason: .ask)
        experiencePhase = .asking
        // S1: the category is switched only once the player is paused, never under
        // playing audio.
        audioSession.configureForRecording()
        logger.notice("Ask: entered t=\(self.currentAudioTime, format: .fixed(precision: 3)) segment \(anchor) progress \(progressAtEntry, format: .fixed(precision: 2))")
    }

    /// The one call that leaves Ask. Resumes at the anchor's speech-free gap.
    func exitAsk() {
        guard experiencePhase == .asking else {
            logger.notice("exitAsk() ignored: phase is \(String(describing: self.experiencePhase), privacy: .public)")
            return
        }
        experiencePhase = .reciting
        // Back to playback BEFORE the audio resumes, so the recitation never plays under
        // the recording category.
        audioSession.configureForPlayback()
        resume()
    }

    /// Halts the audio and pins what is on screen. Used by Ask entry and by the audio
    /// session controller (interruption, route loss, background). Idempotent for the pin:
    /// pausing while already pinned keeps the anchor and the recall where they are.
    func pause(reason: PauseReason) {
        guard let player, playbackState == .playing || playbackState == .paused else {
            logger.notice("pause(\(reason.rawValue, privacy: .public)) ignored in \(String(describing: self.playbackState), privacy: .public)")
            return
        }
        // Already paused: the first reason stands. A system interruption during an Ask must
        // not relabel the pause as an interruption, or the interruption ending would resume
        // the Ask. The pin, the plan and the recall are already in place.
        if playbackState == .paused {
            logger.notice("pause(\(reason.rawValue, privacy: .public)) while already paused for \(self.pauseReason.rawValue, privacy: .public) - no change")
            return
        }
        cancelVolumeRamp()
        removePinReleaseObserver()
        let anchor = displayedSegmentIndex
        pin(segmentIndex: anchor)
        player.pause()
        playbackState = .paused
        pauseReason = reason
        if let segment = segment(forIndex: anchor) {
            resumePlan = RecitationPreroll.plan(for: segment, preroll: preroll?.segment(forIndex: anchor))
        }
        logger.notice("Paused: \(reason.rawValue, privacy: .public), segment \(anchor) pinned, resume target \(self.resumePlan?.targetTime ?? -1, format: .fixed(precision: 3))")
    }

    /// Brings the audio back: zero-tolerance seek to the plan's target, volume 0, play,
    /// then a stepped ramp to 1 that ends before the anchor's first word. The pin holds
    /// through the previous ayah's tail and lets go at `anchor.start + inDuration`.
    func resume() {
        guard let player, playbackState == .paused else {
            logger.notice("resume() ignored in \(String(describing: self.playbackState), privacy: .public)")
            return
        }
        guard let anchor = pinnedSegmentIndex, let segment = segment(forIndex: anchor), let plan = resumePlan else {
            logger.error("resume() with no pin or plan - nothing to resume to")
            return
        }
        cancelVolumeRamp()
        player.volume = 0
        let release = Self.pinReleaseTime(for: segment)
        pinReleaseTime = release
        installPinReleaseObserver(at: release)
        logger.notice("Resume: target \(plan.targetTime, format: .fixed(precision: 3)) (\(plan.measured ? "gap start" : "segment start, unmeasured", privacy: .public) of \(anchor)), fade \(plan.fadeSeconds, format: .fixed(precision: 3)) s, pin release \(release, format: .fixed(precision: 3))")
        seek(toTime: plan.targetTime, label: "resume") { [weak self] _ in
            guard let self, let player = self.player else { return }
            // A debug stop or another pause during the seek wins; do not start playing
            // under it.
            guard self.playbackState == .paused, self.pinnedSegmentIndex == anchor else {
                self.logger.notice("Resume abandoned: state changed while seeking")
                return
            }
            player.play()
            self.playbackState = .playing
            self.pauseReason = .none
            self.startVolumeRamp(seconds: plan.fadeSeconds)
        }
    }

    private func clockProgress(forSegmentIndex index: Int) -> Float {
        guard let segment = segment(forIndex: index) else { return 0 }
        return Dissolve.progress(atAudioTime: currentAudioTime, segment: segment, isFinalSegment: isFinalSegment(index))
    }

    private func pin(segmentIndex index: Int) {
        let progress = pinnedProgress ?? clockProgress(forSegmentIndex: index)
        pinnedSegmentIndex = index
        pinEntry = PinEntry(progress: progress, uptime: ProcessInfo.processInfo.systemUptime)
    }

    /// Lets the clock drive the display again. Syncs FIRST, so the displayed index is
    /// derived from the clock before the pin lets go - if the segment-start observer did
    /// not fire after the backward seek, this is what stops the plane flashing to the
    /// previous ayah for a second.
    private func releasePin() {
        guard pinnedSegmentIndex != nil else { return }
        syncToCurrentTime()
        let released = pinnedSegmentIndex
        clearPin()
        logger.notice("Pin released at \(self.currentAudioTime, format: .fixed(precision: 3)), segment \(released ?? -1), audio at \(self.currentSegmentIndex)")
    }

    private func releasePinIfDue() {
        guard pinnedSegmentIndex != nil, playbackState == .playing, let pinReleaseTime,
              currentAudioTime >= pinReleaseTime - 0.01 else { return }
        releasePin()
    }

    private func clearPin() {
        removePinReleaseObserver()
        pinnedSegmentIndex = nil
        pinEntry = nil
        pinReleaseTime = nil
    }

    private func installPinReleaseObserver(at time: TimeInterval) {
        guard let player else { return }
        removePinReleaseObserver()
        let times = [NSValue(time: CMTime(seconds: time, preferredTimescale: 600))]
        pinReleaseObserver = player.addBoundaryTimeObserver(forTimes: times, queue: .main) { [weak self] in
            Task { @MainActor in self?.releasePinIfDue() }
        }
    }

    private func removePinReleaseObserver() {
        if let pinReleaseObserver { player?.removeTimeObserver(pinReleaseObserver) }
        pinReleaseObserver = nil
    }

    // MARK: Volume ramp

    /// Steps `player.volume` from 0 to 1 over `seconds` on the main actor. Tied to the
    /// resume EVENT, not to a time in the recording - an `AVAudioMix` ramp would re-apply
    /// every time playback crossed that time again. There is exactly one writer of
    /// `player.volume`: this, `start()` and `debugStop()`, and the latter two cancel it.
    private func startVolumeRamp(seconds: TimeInterval) {
        cancelVolumeRamp()
        guard let player else { return }
        let began = ProcessInfo.processInfo.systemUptime
        player.volume = 0
        volumeRamp = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                guard let self, let player = self.player else { return }
                let volume = Self.rampVolume(elapsed: ProcessInfo.processInfo.systemUptime - began, duration: seconds)
                player.volume = volume
                if volume >= 1 {
                    self.logger.notice("Volume ramp complete at \(self.currentAudioTime, format: .fixed(precision: 3))")
                    return
                }
                try? await Task.sleep(for: Self.volumeRampStep)
            }
        }
    }

    private func cancelVolumeRamp() {
        volumeRamp?.cancel()
        volumeRamp = nil
    }

    // MARK: Seeking

    func seek(toSegment index: Int) {
        guard let segment = timings?.segments.first(where: { $0.index == index }) else { return }
        seek(toTime: segment.start, label: "segment \(index)")
    }

    /// Zero-tolerance seek. Every landing is logged with its delta from the target, because
    /// whether an MP3 seek lands on the requested sample is a device question and the
    /// resume path depends on the answer. Syncs the index from the clock before calling
    /// back.
    func seek(toTime seconds: TimeInterval, label: String, completion: ((TimeInterval) -> Void)? = nil) {
        guard let player else { return }
        player.seek(to: CMTime(seconds: seconds, preferredTimescale: 600),
                    toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] finished in
            Task { @MainActor in
                guard let self, let player = self.player else { return }
                let landed = CMTimeGetSeconds(player.currentTime())
                let deltaMs = (landed - seconds) * 1000
                self.logger.notice("Seek (\(label, privacy: .public)) landed \(landed, format: .fixed(precision: 3)) (target \(seconds, format: .fixed(precision: 3)), Δ \(deltaMs, format: .fixed(precision: 1)) ms, finished \(finished))")
                self.syncToCurrentTime()
                completion?(landed)
            }
        }
    }

    // MARK: Observers

    private func installObservers() {
        guard let player, let timings else { return }
        let queue = DispatchQueue.main

        let starts = timings.segments.map { NSValue(time: CMTime(seconds: $0.start, preferredTimescale: 600)) }
        advanceObserver = player.addBoundaryTimeObserver(forTimes: starts, queue: queue) { [weak self] in
            Task { @MainActor in self?.syncToCurrentTime() }
        }

        // Every segment gets a dissolve. The old guard dropped it for segments shorter than
        // the lead time, which was wrong twice over: it measured only the outgoing dissolve
        // and ignored the incoming one, and its failure mode was to hard-cut - exactly the
        // thing the effect exists to avoid. The predicate now lives in
        // `Dissolve.durationScale`, as `duration > inDuration + minimumSettled + outDuration`,
        // and a segment that fails it has BOTH dissolves compressed proportionally rather
        // than losing them. No segment in this surah fails it.
        let finalIndex = timings.segments.last?.index
        let dissolves = timings.segments.compactMap { segment -> NSValue? in
            guard let start = Dissolve.outgoingStart(of: segment,
                                                     isFinalSegment: segment.index == finalIndex)
            else { return nil }
            return NSValue(time: CMTime(seconds: start, preferredTimescale: 600))
        }
        if !dissolves.isEmpty {
            dissolveObserver = player.addBoundaryTimeObserver(forTimes: dissolves, queue: queue) { [weak self] in
                Task { @MainActor in self?.beginDissolve() }
            }
        }

        reconciliationObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: Self.reconciliationInterval, preferredTimescale: 600),
            queue: queue
        ) { [weak self] _ in
            Task { @MainActor in self?.reconcile() }
        }

        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime, object: player.currentItem, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.handleEndOfSurah() }
        }
    }

    // MARK: Position

    /// The source of truth. Derives the segment from the player's clock and applies it
    /// idempotently, so it is safe to call from anywhere and required after any seek.
    func syncToCurrentTime() {
        guard let player, let timings else { return }
        let seconds = CMTimeGetSeconds(player.currentTime())
        guard seconds.isFinite else { return }
        let index = Self.segmentIndex(at: seconds, in: timings.segments)
        apply(segmentIndex: index)
    }

    private func reconcile() {
        guard let player, let timings, playbackState == .playing else { return }
        let seconds = CMTimeGetSeconds(player.currentTime())
        guard seconds.isFinite else { return }
        let expected = Self.segmentIndex(at: seconds, in: timings.segments)
        if expected != currentSegmentIndex {
            logger.error("Segment desync: showing \(self.currentSegmentIndex), audio is at \(expected). Correcting.")
            apply(segmentIndex: expected)
        }
        // Backstop for the one-shot release observer: a pin whose release time has passed
        // lets go here at the latest, one reconciliation tick later.
        releasePinIfDue()
    }

    private func apply(segmentIndex index: Int) {
        guard index != currentSegmentIndex || currentText == nil else { return }
        currentSegmentIndex = index
        currentText = textFile?.text(forSegmentIndex: index)
    }

    private func beginDissolve() {
        dissolveTicket &+= 1
    }

    /// End of surah, defined explicitly.
    ///
    /// Audio: stops of its own accord at the end of the file; `playbackState` becomes
    /// `.finished` and is not rewound - a rewind here would be indistinguishable from a
    /// fresh run in the logs.
    /// Text: ayah 78 STAYS on screen. Clearing it would leave an empty plane hanging in
    /// space with nothing to explain it, and there is no dissolve yet to retire it with.
    /// Phase: `.completed`, which is deliberately distinct from `.idle` so "finished" and
    /// "never started" cannot be confused.
    /// Re-arm: NOT immediate. The entry gate moves to `.awaitingRelease` and will not
    /// accept again until the pose has fallen below the exit bounds at least once - hands
    /// still near dua at ayah 78 must not start the surah over.
    private func handleEndOfSurah() {
        cancelVolumeRamp()
        clearPin()
        resumePlan = nil
        pauseReason = .none
        playbackState = .finished
        experiencePhase = .completed
        logger.notice("Surah complete at segment \(self.currentSegmentIndex)")
    }

    /// Binary search, so this stays cheap enough to call on every seek and every
    /// reconciliation tick. `nonisolated` because it is a pure lookup over immutable data -
    /// which also makes it testable without standing up the coordinator.
    nonisolated static func segmentIndex(at seconds: Double, in segments: [RecitationSegment]) -> Int {
        guard let first = segments.first, let last = segments.last else { return 0 }
        if seconds <= first.start { return first.index }
        if seconds >= last.end { return last.index }
        var low = 0, high = segments.count - 1
        while low <= high {
            let mid = (low + high) / 2
            let segment = segments[mid]
            if seconds < segment.start { high = mid - 1 }
            else if seconds >= segment.end { low = mid + 1 }
            else { return segment.index }
        }
        return segments[min(max(low, 0), segments.count - 1)].index
    }

    /// `deinit` is nonisolated and cannot touch main-actor state, so the observer is
    /// released explicitly. The coordinator lives for the app's lifetime today; this exists
    /// so that stops being true safely.
    func tearDown() {
        cancelVolumeRamp()
        removePinReleaseObserver()
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        endObserver = nil
        if let advanceObserver { player?.removeTimeObserver(advanceObserver) }
        if let dissolveObserver { player?.removeTimeObserver(dissolveObserver) }
        if let reconciliationObserver { player?.removeTimeObserver(reconciliationObserver) }
        advanceObserver = nil
        dissolveObserver = nil
        reconciliationObserver = nil
    }
}
