//
//  AudioInterruptionTests.swift
//  QuranSpatialTests
//
//  The audio-session rules that can be tested without a session: how the deployment-target
//  notification is read, the debounce between the two paths, the route policy, and what an
//  interruption ending is allowed to do. The visionOS 27 path cannot be tested here - its
//  context objects are `init NS_UNAVAILABLE` - so it is covered only on device (T2).
//

import AVFAudio
import Foundation
import Testing
@testable import QuranSpatial

struct AudioInterruptionTests {

    private typealias Controller = AudioSessionController

    // MARK: Legacy notification parsing

    @Test func beganIsReadFromTheTypeKey() {
        let info: [AnyHashable: Any] = [AVAudioSessionInterruptionTypeKey: AVAudioSession.InterruptionType.began.rawValue]
        #expect(Controller.legacyInterruptionEvent(userInfo: info) == .began(reason: "reason unknown"))
    }

    @Test func beganCarriesTheReasonWhenPresent() {
        let info: [AnyHashable: Any] = [
            AVAudioSessionInterruptionTypeKey: AVAudioSession.InterruptionType.began.rawValue,
            AVAudioSessionInterruptionReasonKey: UInt(2),
        ]
        #expect(Controller.legacyInterruptionEvent(userInfo: info) == .began(reason: "reason 2"))
    }

    @Test func endedWithShouldResumeIsRecommended() {
        let info: [AnyHashable: Any] = [
            AVAudioSessionInterruptionTypeKey: AVAudioSession.InterruptionType.ended.rawValue,
            AVAudioSessionInterruptionOptionKey: AVAudioSession.InterruptionOptions.shouldResume.rawValue,
        ]
        #expect(Controller.legacyInterruptionEvent(userInfo: info) == .ended(resumeRecommended: true))
    }

    @Test func endedWithEmptyOptionsIsNotRecommended() {
        let info: [AnyHashable: Any] = [
            AVAudioSessionInterruptionTypeKey: AVAudioSession.InterruptionType.ended.rawValue,
            AVAudioSessionInterruptionOptionKey: UInt(0),
        ]
        #expect(Controller.legacyInterruptionEvent(userInfo: info) == .ended(resumeRecommended: false))
    }

    /// No option key at all is "unknown", which the policy treats like "no".
    @Test func endedWithoutAnOptionKeyIsUnknown() {
        let info: [AnyHashable: Any] = [AVAudioSessionInterruptionTypeKey: AVAudioSession.InterruptionType.ended.rawValue]
        #expect(Controller.legacyInterruptionEvent(userInfo: info) == .ended(resumeRecommended: nil))
    }

    @Test func unreadableUserInfoIsRejectedNotGuessed() {
        #expect(Controller.legacyInterruptionEvent(userInfo: nil) == nil)
        #expect(Controller.legacyInterruptionEvent(userInfo: [:]) == nil)
        #expect(Controller.legacyInterruptionEvent(userInfo: [AVAudioSessionInterruptionTypeKey: "began"]) == nil)
        #expect(Controller.legacyInterruptionEvent(userInfo: [AVAudioSessionInterruptionTypeKey: UInt(99)]) == nil)
    }

    // MARK: Debounce between the two paths

    @Test func theSameEdgeFromTheOtherPathInsideTheWindowIsADuplicate() {
        let began = Controller.InterruptionEvent.began(reason: "a")
        let previous = (event: began, uptime: 100.0)
        #expect(Controller.isDuplicate(.began(reason: "b"), after: previous, at: 100.1))
        #expect(Controller.isDuplicate(.began(reason: "b"), after: previous, at: 100.0 + Controller.debounceWindow - 0.001))
    }

    @Test func aDifferentEdgeOrALaterEventIsNotADuplicate() {
        let began = Controller.InterruptionEvent.began(reason: "a")
        let previous = (event: began, uptime: 100.0)
        #expect(!Controller.isDuplicate(.ended(resumeRecommended: true), after: previous, at: 100.1))
        #expect(!Controller.isDuplicate(.began(reason: "a"), after: previous, at: 100.0 + Controller.debounceWindow))
        #expect(!Controller.isDuplicate(.began(reason: "a"), after: nil, at: 0))
    }

    // MARK: Route policy

    @Test func onlyALostOutputDevicePauses() {
        #expect(Controller.routeAction(for: .oldDeviceUnavailable) == .pause)
        for reason: AVAudioSession.RouteChangeReason in [.unknown, .newDeviceAvailable, .categoryChange, .override,
                                                         .wakeFromSleep, .noSuitableRouteForCategory, .routeConfigurationChange] {
            #expect(Controller.routeAction(for: reason) == .logOnly, "\(reason)")
        }
    }

    // MARK: What an interruption ending may do

    @Test func onlyTheInterruptionsOwnPauseIsResumedAndOnlyOnAYes() {
        typealias R = RecitationCoordinator.PauseReason
        #expect(Controller.resumeDecision(resumeRecommended: true, playbackState: .paused, pauseReason: .interruption) == .resume)
        #expect(Controller.resumeDecision(resumeRecommended: false, playbackState: .paused, pauseReason: .interruption) == .stayPaused)
        #expect(Controller.resumeDecision(resumeRecommended: nil, playbackState: .paused, pauseReason: .interruption) == .stayPaused)
        // An Ask outlives any interruption.
        #expect(Controller.resumeDecision(resumeRecommended: true, playbackState: .paused, pauseReason: .ask) == .stayPaused)
        // A route or background pause is not the interruption's to end either.
        #expect(Controller.resumeDecision(resumeRecommended: true, playbackState: .paused, pauseReason: .route) == .stayPaused)
        #expect(Controller.resumeDecision(resumeRecommended: true, playbackState: .paused, pauseReason: .background) == .stayPaused)
        // Nothing to do unless paused.
        for state: PlaybackState in [.stopped, .playing, .finished] {
            #expect(Controller.resumeDecision(resumeRecommended: true, playbackState: state, pauseReason: .interruption) == .ignore)
        }
    }
}
