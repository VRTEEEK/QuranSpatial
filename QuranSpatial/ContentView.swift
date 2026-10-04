//
//  ContentView.swift
//  QuranSpatial
//
//  Created by Mohamed ElEryan on 31/08/2026.
//

import SwiftUI
import RealityKit
import RealityKitContent

struct ContentView: View {

    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                // The starter template's grid-material sphere (Scene.usda) was removed on
                // 2026-09-04 along with the two in the immersive scene. Nothing of ours
                // referenced it.
                ToggleImmersiveSpaceButton()

                // Attribution has to be reachable by the wearer: the Tanzil terms require
                // the source to be clearly indicated and linked, and a field in a bundled
                // JSON file satisfies neither.
                NavigationLink("Credits") { CreditsView() }
            }
            .padding()
        }
    }
}

#Preview(windowStyle: .automatic) {
    ContentView()
        .environment(AppModel())
}
