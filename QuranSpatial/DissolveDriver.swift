//
//  DissolveDriver.swift
//  QuranSpatial
//
//  The per-frame half of the dissolve. `Dissolve` decides WHAT the effect should be at a
//  given audio time; this puts that number on the material, once per frame, and measures
//  what it cost.
//
//  There is one clock and it is the audio player's. Every frame asks
//  `Dissolve.progress(atAudioTime:)` afresh and throws the answer away again - nothing is
//  integrated, nothing is carried forward, no frame's value depends on the previous frame's.
//  A seek, the 1Hz reconciliation, a dropped frame or a first frame arriving in the middle
//  of an ayah all land at the correct phase, because there is no phase to land wrong.
//  `SceneEvents.Update` supplies the tick; its `deltaTime` is used ONLY for the frame
//  measurement, never for the effect.
//

import Foundation
import Observation
import RealityKit
import RealityKitContent
import os

@MainActor
@Observable
final class DissolveDriver {

    // MARK: Starting values
    //
    // Chosen to be defensible rather than pretty - none has been seen in a headset yet.
    // Each records which direction is safe to move it, because for two of them the two
    // directions fail very differently.

    /// Noise cells across the plane's WIDTH. The vertical count is derived per ayah from
    /// the texture's aspect so a cell is square in world space (see the material).
    ///
    /// 14 against a 40 degree plane is a cell of about 2.9 degrees of visual angle - a
    /// little over the 2.2 degree em (`AyahPlaneGeometry.textAngularEmDeg`, since Stage
    /// 11d; it was 3.0 when this was chosen), so the burn breaks the text up at roughly the
    /// scale of a letter. Much finer and it reads as the glyphs going grey rather than
    /// dissolving; much coarser and whole words leave at once.
    static let noiseCellsAcrossWidth: Float = 14

    /// Width of the soft burn edge, in noise units, over a noise field centred on 0.5.
    ///
    /// 0.12 is about a tenth of the sweep. Toward 0 the edge becomes a hard cut-out and the
    /// effect stops looking like a dissolve; toward 0.5 the whole plane simply fades
    /// uniformly - which is the opacity ramp CLAUDE.md forbids, arrived at by the back door.
    /// **If this needs raising past about 0.3, the effect has stopped being a dissolve and
    /// that is a decision, not a tweak.**
    static let edgeWidth: Float = 0.12

    /// Where the material lives in the compiled bundle.
    static let materialPath = "/Root/DissolveMaterial"
    static let materialResource = "Materials/DissolveMaterial"

    // MARK: Observed state
    //
    // Only fields that change at most once per ayah are observed. The per-frame fields below
    // are `@ObservationIgnored` deliberately: a SwiftUI dependency on a value written 90
    // times a second would re-render the debug HUD every frame and corrupt the very
    // measurement this type exists to take.

    /// Everything needed to identify a load failure without another device round-trip:
    /// what was attempted, what came back, and what was underneath it.
    struct MaterialFailure: Equatable {
        /// The material name passed to `ShaderGraphMaterial(named:)`.
        let materialName: String
        /// The scene passed as `from:`, which is matched against the compiled manifest's
        /// scene name - not against the source file's path, which is not the same string.
        let scenePath: String
        let localizedDescription: String
        /// `NSUnderlyingErrorKey`, when there is one. `materialNameNotFound` carries an
        /// empty userInfo, and knowing that it is empty is itself diagnostic.
        let underlying: String?
        /// The enum case and its associated values - usually the only informative one.
        let debugDescription: String

        var multilineDescription: String {
            var lines = [
                "material: \(materialName)",
                "scene:    \(scenePath)",
                "error:    \(debugDescription)",
                "detail:   \(localizedDescription)",
            ]
            lines.append("underlying: \(underlying ?? "none")")
            return lines.joined(separator: "\n")
        }
    }

    /// Set when the material fails to load or to accept a parameter. Non-nil means the
    /// plane is running the fallback, with no dissolve at all.
    private(set) var loadFailure: MaterialFailure?

    /// Human-readable report for the segment that just ended. Updated once per ayah.
    private(set) var latestSegmentReport: String?

    var isMaterialLoaded: Bool { template != nil }

    // MARK: Per-frame state, unobserved

    /// Per-axis noise scale for a raster of the given pixel size.
    ///
    /// Derived from the raster's width relative to the WIDEST possible plane, never from a
    /// fixed constant. Every ayah shares one metres-per-pixel scale but not one width, so a
    /// fixed cell count would make a cell a constant fraction of each ayah's own width -
    /// and a 894px refrain would come out with grain 1.5x coarser than a 1360px ayah. The
    /// y component then follows the raster's aspect, which keeps a cell square.
    ///
    /// The consequence worth stating: angular cell size is identical for every segment in
    /// the surah, which is what makes the dissolve read as one material rather than as a
    /// per-ayah effect.
    ///
    /// `nonisolated`: a pure function over constants, so the tests can call it without the
    /// main actor (the target's default isolation is MainActor, which had made this
    /// uncallable from `DissolveNoiseScaleTests`).
    nonisolated static func noiseScale(forTextureWidth width: Float, height: Float) -> SIMD2<Float> {
        let cellsAcross = noiseCellsAcrossWidth * width / Float(AyahPlaneGeometry.maxTextureWidthPixels)
        return SIMD2<Float>(cellsAcross, cellsAcross * height / width)
    }

    @ObservationIgnored private var template: ShaderGraphMaterial?
    /// The material currently on the plane, texture and seed already bound.
    @ObservationIgnored private var bound: ShaderGraphMaterial?
    /// Which segment `bound` carries the texture for. **Not necessarily the coordinator's
    /// current segment** - a texture that has not finished rasterizing leaves this behind by
    /// a frame or two, and progress must follow what is actually on screen, not what the
    /// audio has moved on to.
    @ObservationIgnored private var boundIndex: Int?
    @ObservationIgnored private var lastAppliedProgress: Float = .nan

    /// What was last written to the material this frame, or nil when no shader material is
    /// bound (fallback or not yet loaded). Read once per frame by the English layer's
    /// visibility rule; not observed, so it costs nothing to SwiftUI.
    var currentProgress: Float? { lastAppliedProgress.isNaN ? nil : lastAppliedProgress }

    @ObservationIgnored private(set) var sessionStats = FrameStats()
    @ObservationIgnored private(set) var segmentStats = FrameStats()
    @ObservationIgnored private var statsSegmentIndex: Int?
    @ObservationIgnored private var hasSeenAFrame = false
    @ObservationIgnored private var worstThermalState: ProcessInfo.ThermalState = .nominal
    /// Thermal state is sampled once a second, not once a frame. It changes on the order of
    /// minutes, and this driver's own per-frame cost is part of what is being measured -
    /// paying for a property read 90 times a second to watch a value that moves that slowly
    /// would put the instrument into its own reading.
    @ObservationIgnored private var framesSinceThermalCheck = 0
    @ObservationIgnored private let statsLog = FrameStatsLog()
    /// True once a run's table has been started, so `beginRun` happens on the first
    /// recorded frame rather than on every segment change.
    @ObservationIgnored private var runIsOpen = false
    /// The coordinator's `runTicket` this driver last saw. A change means a new run began -
    /// the explicit signal that replaced "the segment index went backwards", which an Ask
    /// resume (a deliberate backward seek into the previous ayah's tail) would have tripped.
    @ObservationIgnored private var lastRunTicket: Int?
    static let thermalCheckInterval = 90

    private static func failure(from error: Error, materialName: String, scenePath: String) -> MaterialFailure {
        let nsError = error as NSError
        let underlying = (nsError.userInfo[NSUnderlyingErrorKey] as? Error).map { String(describing: $0) }
        return MaterialFailure(
            materialName: materialName,
            scenePath: scenePath,
            localizedDescription: error.localizedDescription,
            underlying: underlying,
            debugDescription: "\(String(describing: error))  [\(nsError.domain) \(nsError.code)]"
        )
    }

    private let logger = Logger(subsystem: "com.vrteek.quranspatial", category: "Dissolve")

    // MARK: Loading

    /// Loads the authored graph once and pins the two parameters that never vary per ayah.
    ///
    /// A failure here is loud and is NOT papered over. The fallback in `ImmersiveView` is
    /// the plain unlit material the app had before the dissolve existed - hard cuts, plainly
    /// visible as such. It is deliberately not an opacity ramp: a stand-in fade is exactly
    /// the thing that quietly becomes permanent.
    func load() async {
        do {
            var material = try await ShaderGraphMaterial(
                named: Self.materialPath, from: Self.materialResource, in: realityKitContentBundle
            )
            try material.setParameter(name: "edgeWidth", value: .float(Self.edgeWidth))

            template = material
            loadFailure = nil
            let names = material.parameterNames.sorted().joined(separator: ", ")
            logger.notice("Dissolve material loaded. Parameters: \(names, privacy: .public)")
        } catch {
            template = nil
            loadFailure = Self.failure(from: error, materialName: Self.materialPath, scenePath: Self.materialResource)
            // `fault`, not `error`: this must survive release logging so it can be read
            // from Console.app without a debug build. `.public` so it is not redacted.
            logger.fault(
                """
                DISSOLVE MATERIAL FAILED TO LOAD
                \(self.loadFailure?.multilineDescription ?? "<none>", privacy: .public)
                Falling back to UnlitMaterial - text will hard-cut between ayat, with no dissolve.
                """
            )
        }
    }

    // MARK: Per-ayah binding

    /// Binds one ayah's texture and its noise seed, and returns the material to put on the
    /// plane. `nil` when the graph did not load, which is the caller's cue to fall back.
    ///
    /// `texturePixelSize` is needed because the noise scale is per-axis: see
    /// `noiseCellsAcrossWidth`.
    func material(forSegmentIndex index: Int,
                  texture: TextureResource,
                  texturePixelSize: CGSize) -> ShaderGraphMaterial? {
        guard var material = template else { return nil }
        let width = Float(texturePixelSize.width)
        let height = Float(texturePixelSize.height)
        guard width > 0, height > 0 else { return nil }
        let scale = Self.noiseScale(forTextureWidth: width, height: height)
        do {
            try material.setParameter(name: "textTexture", value: .textureResource(texture))
            try material.setParameter(name: "noiseScale", value: .simd2Float(scale))
            try material.setParameter(name: "noiseOffset",
                                      value: .simd2Float(Dissolve.noiseOffset(forSegmentIndex: index)))
            // Bound fully dissolved. An ayah's first frame is the start of its fade IN, and
            // the pure function agrees - progress is 1 at elapsed 0 - so this is what the
            // next tick would set anyway. Setting it here means a texture that arrives
            // mid-frame is never visible at full opacity for even one frame.
            try material.setParameter(name: "progress", value: .float(1))
        } catch {
            loadFailure = Self.failure(from: error, materialName: Self.materialPath,
                                       scenePath: "parameter bind, segment \(index)")
            logger.fault(
                """
                DISSOLVE PARAMETER BIND FAILED
                \(self.loadFailure?.multilineDescription ?? "<none>", privacy: .public)
                """
            )
            return nil
        }
        bound = material
        boundIndex = index
        lastAppliedProgress = 1
        return material
    }

    /// Called when the caller could not use a shader material for this segment, so the
    /// driver stops trying to drive one.
    func unbind() {
        bound = nil
        boundIndex = nil
        lastAppliedProgress = .nan
    }

    // MARK: The tick

    /// One frame. Called from `SceneEvents.Update`.
    func tick(deltaSeconds: Double, recitation: RecitationCoordinator, entity: ModelEntity) {
        recordFrame(deltaSeconds: deltaSeconds, recitation: recitation)
        pushProgress(recitation: recitation, entity: entity)
    }

    private func pushProgress(recitation: RecitationCoordinator, entity: ModelEntity) {
        guard var material = bound,
              let index = boundIndex,
              let segment = recitation.segment(forIndex: index)
        else { return }

        // An Ask pin overrides the clock. While the anchor is pinned the coordinator supplies
        // the value - the recall ramp from wherever the dissolve was at entry down to 0, then
        // 0 held until the pin is released at anchor.start + inDuration, where the pure
        // function below also returns 0. That equality is why the hand-over is invisible.
        // The pinned value is itself a pure function of wall-clock time, not an accumulator.
        let progress: Float
        if let pinned = recitation.pinnedProgress {
            progress = pinned
        } else {
            progress = Dissolve.progress(
                atAudioTime: recitation.currentAudioTime,
                segment: segment,
                isFinalSegment: recitation.isFinalSegment(index)
            )
        }

        // Settled text holds progress at exactly 0 for seconds at a time, and idle holds it
        // at exactly 1 - both are constants out of the pure function, not near-misses, so an
        // equality test really does skip them. This is the only reason the driver is not
        // writing a ModelComponent on all ~68,000 frames of a full run. It is an
        // optimisation and nothing else: the value written is always the one the clock just
        // produced, never a carried-forward one.
        guard progress != lastAppliedProgress else { return }

        do {
            try material.setParameter(name: "progress", value: .float(progress))
        } catch {
            loadFailure = Self.failure(from: error, materialName: Self.materialPath,
                                       scenePath: "progress set")
            logger.fault(
                """
                DISSOLVE PROGRESS SET FAILED
                \(self.loadFailure?.multilineDescription ?? "<none>", privacy: .public)
                """
            )
            return
        }
        bound = material
        entity.model?.materials = [material]
        lastAppliedProgress = progress
    }

    // MARK: Measurement

    private func recordFrame(deltaSeconds: Double, recitation: RecitationCoordinator) {
        // The first update after the immersive space opens carries the cost of opening it,
        // not the cost of a frame. Dropped once, and only ever the once.
        guard hasSeenAFrame else {
            hasSeenAFrame = true
            return
        }
        // Only frames during playback count. The criteria are about a session; idle frames
        // would pad the denominator and quietly flatter the dropped-frame percentage.
        //
        // The exception is an isolation measurement, where the text and the dissolve are
        // deliberately not in the scene and playback therefore never starts - the frames ARE
        // the measurement. This reads PlaybackState but does not change it.
        guard recitation.playbackState == .playing || PavilionEnvironment.isolateForMeasurement else { return }

        // A new run is announced by the coordinator's ticket, never inferred from the segment
        // index: an Ask resume seeks backwards into the previous ayah on purpose and must
        // continue the same run. Two runs merged into one session total would understate a
        // thermal problem in the second by averaging it with a cold first, so the ticket
        // change resets the session - after the previous run's last row was already written
        // by `flushCurrentSegment` or `reportSession`.
        if lastRunTicket != recitation.runTicket {
            lastRunTicket = recitation.runTicket
            if runIsOpen {
                resetSession()
                segmentStats = FrameStats()
                statsSegmentIndex = nil
            }
        }

        if !runIsOpen {
            runIsOpen = true
            let note = PavilionEnvironment.isolateForMeasurement
                ? "ISOLATION RUN: pavilion USD only - no text plane, no dissolve, no grey-box. Rows accumulate under 'ayah 0' because playback never starts; the row is written on flush."
                : "noise cells across width: \(Self.noiseCellsAcrossWidth), edge width: \(Self.edgeWidth)"
            statsLog.beginRun(note: note)
        }

        // The DISPLAYED segment: during an Ask pin the audio is in the previous ayah's tail
        // while the anchor is on screen, and the frames belong to what is being drawn.
        let index = recitation.displayedSegmentIndex
        if let current = statsSegmentIndex, current != index {
            reportSegment(current)
            segmentStats = FrameStats()
        }
        statsSegmentIndex = index

        segmentStats.record(frameSeconds: deltaSeconds)
        sessionStats.record(frameSeconds: deltaSeconds)

        framesSinceThermalCheck += 1
        if framesSinceThermalCheck >= Self.thermalCheckInterval {
            framesSinceThermalCheck = 0
            let thermal = ProcessInfo.processInfo.thermalState
            if thermal.severity > worstThermalState.severity {
                worstThermalState = thermal
                logger.error("Thermal state rose to \(thermal.label, privacy: .public) during segment \(index)")
            }
        }
    }

    private func resetSession() {
        sessionStats = FrameStats()
        runIsOpen = false
        worstThermalState = ProcessInfo.processInfo.thermalState
        framesSinceThermalCheck = 0
        logger.notice("New run: frame stats reset, thermal starting at \(self.worstThermalState.label, privacy: .public)")
    }

    /// Logged as each ayah ends, so a single full run yields a per-ayah table without anyone
    /// having to drive the app to a particular ayah by hand.
    private func reportSegment(_ index: Int, partial: Bool = false) {
        let stats = segmentStats
        let mark = partial ? " [PARTIAL - run ended mid-ayah]" : ""
        let report = "ayah \(index): \(stats.summary), thermal \(worstThermalState.label)\(mark)"
        latestSegmentReport = report
        statsLog.append(report)
        if stats.passesFrameBars {
            logger.notice("\(report, privacy: .public)")
        } else {
            let hitches = stats.recordedHitchesSeconds
                .map { String(format: "%.1fms", $0 * 1000) }.joined(separator: ", ")
            logger.error("\(report, privacy: .public) | hitches: \(hitches, privacy: .public)")
        }
    }

    /// Flushes the ayah currently in progress, so a run stopped part-way through one still
    /// reports it rather than discarding it. Without this, aborting during the 34s ayah 33
    /// - which is exactly when someone would abort - loses the segment most worth measuring.
    ///
    /// Idempotent: the in-progress stats are cleared after flushing, so a background
    /// followed by a terminate does not write the same partial row twice.
    func flushCurrentSegment(reason: String) {
        guard runIsOpen, let index = statsSegmentIndex, segmentStats.hasEvidence else { return }
        logger.notice("Flushing frame stats: \(reason, privacy: .public)")
        reportSegment(index, partial: true)
        segmentStats = FrameStats()
        statsLog.append("run interrupted: \(reason)")
        statsLog.append("SESSION so far: \(sessionStats.summary), worst thermal \(worstThermalState.label)")
    }

    /// Whole-run report. Called when the surah completes.
    func reportSession() {
        if let index = statsSegmentIndex { reportSegment(index) }
        let verdict = sessionStats.passesFrameBars && FrameStats.thermalPassesBar(worstThermalState) ? "PASS" : "FAIL"
        logger.notice(
            "SESSION \(verdict, privacy: .public): \(self.sessionStats.summary, privacy: .public), worst thermal \(self.worstThermalState.label, privacy: .public)"
        )
        statsLog.append("")
        statsLog.append("SESSION \(verdict): \(sessionStats.summary), worst thermal \(worstThermalState.label)")
    }
}

extension ProcessInfo.ThermalState {
    /// Ordered so "worst seen" is meaningful; the enum's raw values already ascend but the
    /// ordering is worth stating rather than assuming.
    var severity: Int {
        switch self {
        case .nominal: 0
        case .fair: 1
        case .serious: 2
        case .critical: 3
        @unknown default: 4
        }
    }

    var label: String {
        switch self {
        case .nominal: "nominal"
        case .fair: "fair"
        case .serious: "serious"
        case .critical: "critical"
        @unknown default: "unknown"
        }
    }
}
