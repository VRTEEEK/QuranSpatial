//
//  AudioSessionController.swift
//  QuranSpatial
//
//  The only file that configures or observes `AVAudioSession`. Stage 2 (B1/B2):
//
//  * Strategy S1: `.playback` while reciting, `.playAndRecord` only for the recording window
//    of an Ask, back to `.playback` before the audio resumes. Mode `.default`, no options.
//  * Interruptions arrive on TWO paths and funnel into one handler: the visionOS 27
//    `didBecomeInactive` / `resumptionRecommendation` pair when available, and the
//    `interruptionNotification` that the deployment target (26.5) still needs. Each path
//    logs which one fired; an identical event from the other path inside the debounce window
//    is dropped, so a device that posts both does not pause twice.
//  * Policy (decided 2026-09-30): interruption began -> pause; ended WITH a resume
//    recommendation -> resume, but only if it was the interruption that paused us; ended
//    without one -> stay paused. Route lost -> pause; reconnect -> stay paused. Auto-resuming
//    against the system is unbidden recitation.
//  * Every configuration change and the launch default are logged as a snapshot, because
//    what the visionOS 27 default session looks like was an open question (Stage 1b B1).
//
//  It never touches the player. It calls `RecitationCoordinator.pause(reason:)` and
//  `resume()`, and the coordinator calls `configureForPlayback()` / `configureForRecording()`.
//

import AVFAudio
import Foundation
import Observation
import os

@MainActor
@Observable
final class AudioSessionController {

    /// What either notification path boils down to.
    enum InterruptionEvent: Equatable {
        case began(reason: String)
        /// `nil` = the system gave no recommendation either way.
        case ended(resumeRecommended: Bool?)

        nonisolated var isBegan: Bool { if case .began = self { return true } else { return false } }
    }

    enum RouteAction: Equatable { case pause, logOnly }

    enum ResumeDecision: Equatable { case resume, stayPaused, ignore }

    /// Two deliveries of the same began/ended edge closer than this are one event seen
    /// twice (both paths firing). Interruptions themselves are never this close together.
    nonisolated static let debounceWindow: TimeInterval = 0.5

    /// One line for the debug HUD.
    private(set) var statusLine = "not configured"
    private(set) var isConfiguredForRecording = false
    /// The launch default, before anything was configured. Answers Stage 1b's open question.
    private(set) var defaultSnapshot: String?
    private(set) var lastEventDescription: String?

    @ObservationIgnored private weak var transport: RecitationCoordinator?
    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    @ObservationIgnored private var lastEvent: (event: InterruptionEvent, uptime: TimeInterval)?

    private let logger = Logger(subsystem: "com.vrteek.quranspatial", category: "AudioSession")

    // MARK: Pure rules, testable without a session

    /// The deployment-target path: `AVAudioSession.interruptionNotification`'s userInfo.
    nonisolated static func legacyInterruptionEvent(userInfo: [AnyHashable: Any]?) -> InterruptionEvent? {
        guard let raw = userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: raw) else { return nil }
        switch type {
        case .began:
            let reason = (userInfo?[AVAudioSessionInterruptionReasonKey] as? UInt)
                .map { "reason \($0)" } ?? "reason unknown"
            return .began(reason: reason)
        case .ended:
            guard let options = userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt else {
                return .ended(resumeRecommended: nil)
            }
            return .ended(resumeRecommended: AVAudioSession.InterruptionOptions(rawValue: options).contains(.shouldResume))
        @unknown default:
            return nil
        }
    }

    /// Same edge (began or ended) as the previous event, inside the window.
    nonisolated static func isDuplicate(_ event: InterruptionEvent,
                                        after previous: (event: InterruptionEvent, uptime: TimeInterval)?,
                                        at now: TimeInterval) -> Bool {
        guard let previous else { return false }
        return previous.event.isBegan == event.isBegan && now - previous.uptime < debounceWindow
    }

    /// Decided 2026-09-30: pause on a lost output device; everything else is logged.
    nonisolated static func routeAction(for reason: AVAudioSession.RouteChangeReason) -> RouteAction {
        reason == .oldDeviceUnavailable ? .pause : .logOnly
    }

    /// What an interruption ending does, given how the transport got paused. Only the
    /// interruption's own pause is resumed, and only on a positive recommendation: an Ask
    /// pause outlives any interruption, and "no recommendation" means stay paused.
    nonisolated static func resumeDecision(resumeRecommended: Bool?,
                                           playbackState: PlaybackState,
                                           pauseReason: RecitationCoordinator.PauseReason) -> ResumeDecision {
        // Pattern match rather than `==`: the enum's Equatable conformance is main-actor
        // isolated under the target's default isolation, and this rule is nonisolated.
        guard case .paused = playbackState else { return .ignore }
        guard pauseReason == .interruption else { return .stayPaused }
        return resumeRecommended == true ? .resume : .stayPaused
    }

    // MARK: Wiring

    /// Installs the observers and logs the untouched default session. Called once by the
    /// coordinator; nothing is configured here.
    func attach(transport: RecitationCoordinator) {
        self.transport = transport
        guard observers.isEmpty else { return }
        let snapshot = snapshotString()
        defaultSnapshot = snapshot
        statusLine = "default: \(shortStatus())"
        logger.notice("Audio session default: \(snapshot, privacy: .public)")
        installObservers()
    }

    func configureForPlayback() {
        configure(category: .playback, label: "playback")
    }

    func configureForRecording() {
        configure(category: .playAndRecord, label: "recording")
    }

    private func configure(category: AVAudioSession.Category, label: String) {
        let session = AVAudioSession.sharedInstance()
        let before = snapshotString()
        do {
            try session.setCategory(category, mode: .default, options: [])
            try session.setActive(true)
            isConfiguredForRecording = category == .playAndRecord
            statusLine = "\(label): \(shortStatus())"
        } catch {
            statusLine = "\(label) FAILED: \(error.localizedDescription)"
            logger.error("Audio session \(label, privacy: .public) configuration failed: \(error.localizedDescription, privacy: .public)")
        }
        logger.notice("Audio session \(label, privacy: .public): before [\(before, privacy: .public)] after [\(self.snapshotString(), privacy: .public)]")
    }

    // MARK: Snapshot

    private func snapshotString() -> String {
        let session = AVAudioSession.sharedInstance()
        return "category=\(session.category.rawValue) mode=\(session.mode.rawValue) "
            + "options=\(session.categoryOptions.rawValue) route=[\(Self.describe(session.currentRoute))] "
            + "spatial=\(String(describing: session.intendedSpatialExperience))"
    }

    private func shortStatus() -> String {
        let session = AVAudioSession.sharedInstance()
        return "\(session.category.rawValue) · \(session.currentRoute.outputs.map(\.portType.rawValue).joined(separator: "+"))"
    }

    nonisolated private static func describe(_ route: AVAudioSessionRouteDescription) -> String {
        let inputs = route.inputs.map { "\($0.portType.rawValue):\($0.portName)" }.joined(separator: ",")
        let outputs = route.outputs.map { "\($0.portType.rawValue):\($0.portName)" }.joined(separator: ",")
        return "in(\(inputs)) out(\(outputs))"
    }

    // MARK: Observers

    private func installObservers() {
        let center = NotificationCenter.default
        let session = AVAudioSession.sharedInstance()

        // Deployment-target path. Deprecated from visionOS 27, not removed; the only
        // interruption API that exists on a 26.5 device.
        observers.append(center.addObserver(forName: AVAudioSession.interruptionNotification,
                                            object: session, queue: .main) { [weak self] note in
            let event = Self.legacyInterruptionEvent(userInfo: note.userInfo)
            Task { @MainActor [weak self] in
                guard let self else { return }
                guard let event else {
                    self.logger.error("Interruption notification without a readable type (path=legacy)")
                    return
                }
                self.handle(event, path: "legacy")
            }
        })

        if #available(visionOS 27, *) {
            observers.append(center.addObserver(forName: AVAudioSession.didBecomeInactiveNotification,
                                                object: session, queue: .main) { [weak self] note in
                let context = note.userInfo?[AVAudioSession.deactivationContextKey] as? AVAudioSession.DeactivationContext
                let source = context.map { String(describing: $0.source) } ?? "unknown source"
                let reason = context?.interruptionContext.map { String(describing: $0.reason) } ?? "no interruption context"
                let isSystem = context?.source == .system
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    // The app's own deactivation is not an interruption.
                    guard isSystem else {
                        self.logger.notice("Audio session became inactive by the app (\(source, privacy: .public)), not treated as an interruption")
                        return
                    }
                    self.handle(.began(reason: "\(source), \(reason)"), path: "27")
                }
            })
            observers.append(center.addObserver(forName: AVAudioSession.resumptionRecommendationNotification,
                                                object: session, queue: .main) { [weak self] note in
                let context = note.userInfo?[AVAudioSession.resumptionContextKey] as? AVAudioSession.ResumptionContext
                let recommended: Bool? = context.map { $0.recommendation == .shouldResume }
                Task { @MainActor [weak self] in self?.handle(.ended(resumeRecommended: recommended), path: "27") }
            })
        }

        observers.append(center.addObserver(forName: AVAudioSession.routeChangeNotification,
                                            object: session, queue: .main) { [weak self] note in
            let raw = note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt
            let reason = raw.flatMap(AVAudioSession.RouteChangeReason.init(rawValue:)) ?? .unknown
            let previous = (note.userInfo?[AVAudioSessionRouteChangePreviousRouteKey] as? AVAudioSessionRouteDescription)
                .map(Self.describe) ?? "?"
            let reasonLabel = Self.label(reason)
            Task { @MainActor [weak self] in self?.handleRouteChange(reason: reason, reasonLabel: reasonLabel, previous: previous) }
        })

        observers.append(center.addObserver(forName: AVAudioSession.mediaServicesWereResetNotification,
                                            object: session, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                // Recovery (rebuilding the player) is out of scope for Stage 2; this exists so
                // a mystery stop can be attributed.
                self.lastEventDescription = "media services reset"
                self.logger.fault("MEDIA SERVICES WERE RESET - the player may be dead; no recovery is implemented")
            }
        })
    }

    private func handle(_ event: InterruptionEvent, path: String) {
        let now = ProcessInfo.processInfo.systemUptime
        if Self.isDuplicate(event, after: lastEvent, at: now) {
            logger.notice("Interruption event debounced (path=\(path, privacy: .public)) - already handled from the other path")
            return
        }
        lastEvent = (event, now)

        switch event {
        case .began(let reason):
            lastEventDescription = "interruption began (\(reason))"
            logger.notice("Interruption began (\(reason, privacy: .public), path=\(path, privacy: .public))")
            transport?.pause(reason: .interruption)

        case .ended(let recommended):
            let label = recommended.map { $0 ? "yes" : "no" } ?? "unknown"
            lastEventDescription = "interruption ended (resume=\(label))"
            logger.notice("Interruption ended (resume=\(label, privacy: .public), path=\(path, privacy: .public))")
            guard let transport else { return }
            switch Self.resumeDecision(resumeRecommended: recommended,
                                       playbackState: transport.playbackState,
                                       pauseReason: transport.pauseReason) {
            case .resume:
                transport.resume()
            case .stayPaused:
                logger.notice("Staying paused: recommendation=\(label, privacy: .public), pause reason=\(transport.pauseReason.rawValue, privacy: .public)")
            case .ignore:
                break
            }
        }
    }

    private func handleRouteChange(reason: AVAudioSession.RouteChangeReason, reasonLabel: String, previous: String) {
        let current = Self.describe(AVAudioSession.sharedInstance().currentRoute)
        lastEventDescription = "route change: \(reasonLabel)"
        statusLine = "\(isConfiguredForRecording ? "recording" : "playback"): \(shortStatus())"
        logger.notice("Route change: \(reasonLabel, privacy: .public) previous [\(previous, privacy: .public)] current [\(current, privacy: .public)]")
        if Self.routeAction(for: reason) == .pause {
            transport?.pause(reason: .route)
        }
    }

    nonisolated private static func label(_ reason: AVAudioSession.RouteChangeReason) -> String {
        switch reason {
        case .unknown: "unknown"
        case .newDeviceAvailable: "newDeviceAvailable"
        case .oldDeviceUnavailable: "oldDeviceUnavailable"
        case .categoryChange: "categoryChange"
        case .override: "override"
        case .wakeFromSleep: "wakeFromSleep"
        case .noSuitableRouteForCategory: "noSuitableRouteForCategory"
        case .routeConfigurationChange: "routeConfigurationChange"
        @unknown default: "reason \(reason.rawValue)"
        }
    }
}
