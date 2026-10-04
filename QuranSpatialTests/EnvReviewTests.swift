//
//  EnvReviewTests.swift
//  QuranSpatialTests
//
//  The review environment's glow cards: hidden on stage-2 (they render as flat rectangles),
//  matched by entity path. Sky, water and the baked meshes are never matched.
//

import Testing
@testable import QuranSpatial

struct EnvReviewTests {

    @Test func theGlowCardsAreHidden() {
        #expect(EnvironmentLighting.envReviewHideGlowCards)
    }

    @Test func glowCardPathsMatchOnlyTheGlowEntities() {
        for path in ["/Environment_Root/Glow/Lantern_08", "/Environment_Root/GlowCards_Merged", "/Environment_Root/Step_Edge_Glow"] {
            #expect(EnvironmentLighting.isGlowCardPath(path), "\(path)")
        }
        for path in ["/Environment_Root/Sky/Night_Sky", "/Environment_Root/Water/Lake_Surface/Water_Mesh",
                     "/Environment_Root/Baked_Lantern_Metal", "/Environment_Root/Hanging_Lanterns_Merged",
                     "/Environment_Root/Baked_Columns", "/Environment_Root/Exterior/Landscape_Merged"] {
            #expect(!EnvironmentLighting.isGlowCardPath(path), "\(path)")
        }
    }

    @Test func stageTwoLoadsTheReviewAsset() {
        #expect(PavilionEnvironment.resourceName == "QuranSpatial_Review")
    }
}
