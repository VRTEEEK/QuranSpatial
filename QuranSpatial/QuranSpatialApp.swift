//
//  QuranSpatialApp.swift
//  QuranSpatial
//
//  Created by Mohamed ElEryan on 31/08/2026.
//

import SwiftUI

@main
struct QuranSpatialApp: App {

    @State private var appModel = AppModel()

    init() {
        // On-device confirmation that the bundled ship font actually registered, plus the
        // mark-stacking probes. Pull both with
        // `devicectl device copy from ... --source Documents`.
        FontIdentityReport.write()
        StackedClusterProbe.writePNGs()
        // Async because reading the audio's real duration is, and a mismatched
        // audio/timings pair is exactly what this is meant to catch.
        Task { await AudioAssetReport.write() }
        // The dissolve material's load result, verbatim. At launch rather than when the
        // ImmersiveSpace opens, because loading a material is asset loading and needs no
        // immersive space - which means the failure can be read without anyone wearing the
        // device.
        Task { await DissolveMaterialReport.write() }
        // Measured, not estimated: builds the grey-box environment once at launch, counts
        // it, and throws it away - so poly count and draw calls do not require a headset.
        Task { @MainActor in EnvironmentReport.writeFromMeasurementBuild() }
        // Stage 2: loads night_pavilion.usdc once at launch and measures it. Orientation,
        // draw calls, triangles and load duration need no ImmersiveSpace; only
        // time-to-first-frame does, and that is filled in from the view.
        Task { @MainActor in await PavilionEnvironment.runLaunchMeasurement() }
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(appModel)
        }

        ImmersiveSpace(id: appModel.immersiveSpaceID) {
            ImmersiveView()
                .environment(appModel)
                .onAppear {
                    appModel.immersiveSpaceState = .open
                }
                .onDisappear {
                    appModel.immersiveSpaceState = .closed
                }
        }
        // FULL immersion, changed 2026-09-06 with the environment: the grey-box night sky,
        // water and mountains only read as a place if passthrough is replaced. Hand tracking
        // is unaffected - it works in both styles, and still requires an open ImmersiveSpace.
        .immersionStyle(selection: .constant(.full), in: .full)
        // A .full space hides the passthrough upper limbs by DEFAULT, which is why the
        // wearer's own hands were invisible. This is a rendering choice only: hand TRACKING
        // was never affected, so the dua recognizer saw hands the whole time the wearer
        // could not. The gesture is performed by raising both hands, and a wearer who
        // cannot see their hands cannot tell whether they are posed correctly or out of
        // frame - the feedback the recognizer depends on was missing, not the data.
        .upperLimbVisibility(.visible)
     }
}
