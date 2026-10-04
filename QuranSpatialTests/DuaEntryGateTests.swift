//
//  DuaEntryGateTests.swift
//  QuranSpatialTests
//
//  The one-way entry latch, its dwell, and the re-arm edge.
//

import Testing
import Foundation
@testable import QuranSpatial

struct DuaEntryGateTests {

    private let dwell = DuaEntryGate.acceptanceDwell

    @Test func acceptsOnlyAfterTheDwellHasElapsed() {
        var gate = DuaEntryGate()
        #expect(gate.update(recognizerState: .held, timestamp: 0) == .nothing)
        #expect(gate.update(recognizerState: .held, timestamp: dwell - 0.05) == .nothing)
        #expect(gate.state == .armed)
        #expect(gate.update(recognizerState: .held, timestamp: dwell) == .accept)
        #expect(gate.state == .accepted)
    }

    @Test func acceptsExactlyOnce() {
        var gate = DuaEntryGate()
        gate.update(recognizerState: .held, timestamp: 0)
        #expect(gate.update(recognizerState: .held, timestamp: dwell) == .accept)
        for step in 1...20 {
            #expect(gate.update(recognizerState: .held, timestamp: dwell + Double(step)) == .nothing)
        }
    }

    @Test func aLapseBeforeTheDwellElapsesResetsIt() {
        var gate = DuaEntryGate()
        gate.update(recognizerState: .held, timestamp: 0)
        gate.update(recognizerState: .idle, timestamp: dwell - 0.05)
        // Dwell restarts from here, so the old elapsed time must not count.
        #expect(gate.update(recognizerState: .held, timestamp: dwell) == .nothing)
        #expect(gate.update(recognizerState: .held, timestamp: dwell + dwell - 0.01) == .nothing)
        #expect(gate.update(recognizerState: .held, timestamp: dwell + dwell) == .accept)
    }

    /// After acceptance the gesture is over: hand state must not affect anything, and in
    /// particular releasing must not produce a second event or unlatch the gate.
    @Test func handStateIsIgnoredAfterAcceptance() {
        var gate = DuaEntryGate()
        gate.update(recognizerState: .held, timestamp: 0)
        #expect(gate.update(recognizerState: .held, timestamp: dwell) == .accept)

        for (index, state) in [DuaPostureRecognizer.State.idle, .entering(since: 5), .held, .idle].enumerated() {
            #expect(gate.update(recognizerState: state, timestamp: dwell + Double(index + 1)) == .nothing)
            #expect(gate.state == .accepted)
        }
    }

    /// Hands still near dua when the surah ends must not start it over.
    @Test func doesNotReArmWhileThePoseIsStillHeld() {
        var gate = DuaEntryGate()
        gate.update(recognizerState: .held, timestamp: 0)
        gate.update(recognizerState: .held, timestamp: dwell)
        gate.experienceEnded()
        #expect(gate.state == .awaitingRelease)

        for step in 1...50 {
            #expect(gate.update(recognizerState: .held, timestamp: dwell + Double(step)) == .nothing)
            #expect(gate.state == .awaitingRelease)
        }
    }

    @Test func reArmsOnlyAfterAReleaseEdgeAndThenNeedsTheDwellAgain() {
        var gate = DuaEntryGate()
        gate.update(recognizerState: .held, timestamp: 0)
        gate.update(recognizerState: .held, timestamp: dwell)
        gate.experienceEnded()

        gate.update(recognizerState: .idle, timestamp: 10)
        #expect(gate.state == .armed)

        // Re-armed, but the next acceptance is not free: the dwell applies again.
        #expect(gate.update(recognizerState: .held, timestamp: 11) == .nothing)
        #expect(gate.update(recognizerState: .held, timestamp: 11 + dwell) == .accept)
    }

    @Test func endingAnExperienceThatNeverStartedDoesNothing() {
        var gate = DuaEntryGate()
        gate.experienceEnded()
        #expect(gate.state == .armed)
        gate.update(recognizerState: .held, timestamp: 0)
        #expect(gate.update(recognizerState: .held, timestamp: dwell) == .accept)
    }
}
