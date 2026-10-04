//
//  DissolveNoiseScaleTests.swift
//  QuranSpatialTests
//
//  The noise scale is the one piece of the dissolve that has to be derived per ayah rather
//  than fixed, and it was wrong once already in a way that looked right: a fixed cell count
//  makes a cell a constant fraction of each ayah's OWN width, so a 894px refrain gets
//  visibly coarser grain than a 1360px ayah while every individual ayah still looks fine.
//  Nothing about a single rendered frame reveals it - only comparing two ayat does.
//

import Testing
import Foundation
@testable import QuranSpatial

struct DissolveNoiseScaleTests {

    /// The rasters actually in the surah: the 31 byte-identical refrains, the widest ayah,
    /// the three-line ayah 33, and the maximum the wrap permits.
    private static let rasters: [(label: String, width: Float, height: Float)] = [
        ("refrain, one line", 894, 276),
        ("ayah 39, widest", 1354, 479),
        ("ayah 33, three lines", 1354, 845),
        ("maximum permitted", 1360, 845),
        ("a narrow short ayah", 500, 276),
    ]

    /// Degrees of visual angle per noise cell, which is what the eye actually judges.
    private static func degreesPerCell(width: Float, height: Float) -> Float {
        let scale = DissolveDriver.noiseScale(forTextureWidth: width, height: height)
        let angularWidth = AyahPlaneGeometry.maxAngularWidthDegrees
            * width / Float(AyahPlaneGeometry.maxTextureWidthPixels)
        return angularWidth / scale.x
    }

    /// THE REGRESSION GUARD. Every ayah must resolve to the same angular cell size, so the
    /// dissolve reads as one material across the whole surah rather than as a per-ayah
    /// effect that happens to be coarser on the short ones.
    @Test func everyRasterSolvesToTheSameAngularCellSize() {
        let reference = Self.degreesPerCell(width: Self.rasters[0].width, height: Self.rasters[0].height)
        for raster in Self.rasters {
            let degrees = Self.degreesPerCell(width: raster.width, height: raster.height)
            #expect(abs(degrees - reference) < 1e-4,
                    "\(raster.label) solves to \(degrees)°/cell, not \(reference)°/cell")
        }
        // And it is the size the constant says it is: 40° across 14 cells.
        let expected = AyahPlaneGeometry.maxAngularWidthDegrees / DissolveDriver.noiseCellsAcrossWidth
        #expect(abs(reference - expected) < 1e-4)
    }

    /// Cells must be square in world space too. Height varies with line count while the
    /// metres-per-pixel scale does not, so the y component has to track the aspect.
    @Test func cellsAreSquareInWorldSpace() {
        for raster in Self.rasters {
            let scale = DissolveDriver.noiseScale(forTextureWidth: raster.width, height: raster.height)
            // Cells per pixel must match on both axes.
            let perPixelX = scale.x / raster.width
            let perPixelY = scale.y / raster.height
            #expect(abs(perPixelX - perPixelY) < 1e-6,
                    "\(raster.label) has non-square cells: \(perPixelX) vs \(perPixelY)")
        }
    }

    /// A taller ayah gets MORE cells vertically, not the same number stretched. Ayah 33
    /// wraps to three lines against the refrain's one, so it must carry proportionally more
    /// noise down the plane.
    @Test func tallerRastersGetProportionallyMoreCells() {
        let oneLine = DissolveDriver.noiseScale(forTextureWidth: 1354, height: 479)
        let threeLines = DissolveDriver.noiseScale(forTextureWidth: 1354, height: 845)
        #expect(threeLines.x == oneLine.x)
        #expect(threeLines.y > oneLine.y)
        #expect(abs(threeLines.y / oneLine.y - 845 / 479) < 1e-4)
    }

    /// The 31 refrains are byte-identical rasters, so they must solve identically - their
    /// dissolves differ only by `Dissolve.noiseOffset`, never by scale.
    @Test func identicalRastersSolveIdentically() {
        let first = DissolveDriver.noiseScale(forTextureWidth: 894, height: 276)
        let second = DissolveDriver.noiseScale(forTextureWidth: 894, height: 276)
        #expect(first == second)
    }
}
