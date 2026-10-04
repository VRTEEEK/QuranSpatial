//
//  EnvironmentReport.swift
//  QuranSpatial
//
//  Writes the grey-box environment's measured geometry to a file, so poly count and draw
//  calls come off the device rather than being estimated from the source. Same pattern, and
//  same reason, as FontIdentityReport and DissolveMaterialReport.
//
//  It reports COUNTED values - the builder walks the hierarchy it just made and sums actual
//  mesh parts and triangle indices. Nothing here is derived from what the geometry was
//  supposed to be.
//

import Foundation
import os

enum EnvironmentReport {

    static let filename = "environment.txt"

    private static let logger = Logger(subsystem: "com.vrteek.quranspatial", category: "Environment")

    /// Builds a THROWAWAY copy of the environment at launch purely to measure it, and
    /// discards it.
    ///
    /// The real environment is built when the ImmersiveSpace opens, which needs someone
    /// wearing the device - so without this, poly count and draw calls could only be
    /// obtained from a headset session. Geometry generation does not need a scene, so the
    /// measurement does not either. The cost is one extra build at launch, of an entity
    /// tree that is released immediately.
    @MainActor
    static func writeFromMeasurementBuild() {
        var stats = GreyBoxEnvironment.BuildStats()
        _ = GreyBoxEnvironment.build(stats: &stats)
        write(stats: stats)
    }

    @MainActor
    static func write(stats: GreyBoxEnvironment.BuildStats) {
        let report = """
        written: \(ISO8601DateFormatter().string(from: Date()))

        --- measured from the built scene ---
        entities:                 \(stats.entities)
        mesh parts (draw calls):  \(stats.meshParts)
        triangles:                \(stats.triangles)
        lights:                   \(stats.lights)

        --- constants as built ---
        platformRadius            \(GreyBoxEnvironment.platformRadius) m
        platformCenterZ           \(GreyBoxEnvironment.platformCenterZ) m
        platformThickness         \(GreyBoxEnvironment.platformThickness) m
        platformTopY              \(GreyBoxEnvironment.platformTopY) m
        waterY                    \(GreyBoxEnvironment.waterY) m
        waterSize                 \(GreyBoxEnvironment.waterSize) m
        pavilionInnerRadius       \(GreyBoxEnvironment.pavilionInnerRadius) m
        pavilionColumnCount       \(GreyBoxEnvironment.pavilionColumnCount)
        pavilionColumnWidth       \(GreyBoxEnvironment.pavilionColumnWidth) m
        pavilionColumnHeight      \(GreyBoxEnvironment.pavilionColumnHeight) m
        pavilionLintelHeight      \(GreyBoxEnvironment.pavilionLintelHeight) m
        mountainDistance          \(GreyBoxEnvironment.mountainDistance) m
        mountainHeight            \(GreyBoxEnvironment.mountainHeight) m
        mountainSegments          \(GreyBoxEnvironment.mountainSegments)
        skyRadius                 \(GreyBoxEnvironment.skyRadius) m
        lanternCount              \(GreyBoxEnvironment.lanternCount)
        lanternRingRadius         \(GreyBoxEnvironment.lanternRingRadius) m
        lanternSize               \(GreyBoxEnvironment.lanternSize) m
        moonlightDirection        \(GreyBoxEnvironment.moonlightDirection)
        moonlightIntensity        \(GreyBoxEnvironment.moonlightIntensity) lux
        lanternIntensity          \(GreyBoxEnvironment.lanternIntensity) lm
        lanternAttenuationRadius  \(GreyBoxEnvironment.lanternAttenuationRadius) m

        --- text plane, for confirmation that it was not touched ---
        firstLineBaselineHeight   \(AyahPlaneGeometry.firstLineBaselineHeightMeters) m
        assumedViewingDistance    \(AyahPlaneGeometry.assumedViewingDistanceMeters) m (plane at z = -that)
        platform front rim at z   \(GreyBoxEnvironment.platformCenterZ - GreyBoxEnvironment.platformRadius) m
        pavilion front gap at z    \(GreyBoxEnvironment.platformCenterZ - GreyBoxEnvironment.pavilionInnerRadius) m
        """
        logger.notice("\(report, privacy: .public)")
        guard let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)
            .first?.appendingPathComponent(filename) else { return }
        try? report.write(to: url, atomically: true, encoding: .utf8)
    }
}
