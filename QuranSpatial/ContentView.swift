//
//  ContentView.swift
//  QuranSpatial
//
//  Created by Mohamed ElEryan on 31/08/2026.
//
//  Launch UI, 2026-10-05. Replaces the template's grey panel. Hierarchy, top to bottom:
//  the logo image (which carries the wordmark; no native text), the dominant state-aware
//  immersive action, and a quiet Credits action. The window style is `.plain` (set on the scene) and NOTHING is drawn
//  behind the content - no gradient, no material, no glass on the container (the radial
//  shadow that was here went on 2026-10-05 evening). Only the controls carry glass; the text
//  shadows are what hold legibility over passthrough.
//

import SwiftUI

struct ContentView: View {

    @Environment(AppModel.self) private var appModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var showCredits = false
    /// Drives the one-shot entrance: the chime fires at 0 s and the logo fades in from
    /// 0.11 s over 3.0 s; then Enter fades in at 3.11 s and Credits at 3.31 s (1.2 s each).
    /// Done by 4.5 s and nothing moves after.
    @State private var appeared = false
    /// Fires the chime at the logo's moment; cancelled if the window goes before then.
    @State private var chimeTask: Task<Void, Never>?

    var body: some View {
        VStack(spacing: 0) {
            LaunchIdentity(appeared: appeared, reduceMotion: reduceMotion)

            Spacer().frame(height: 52)

            ToggleImmersiveSpaceButton()
                .launchEntrance(appeared, delay: LaunchChime.enterButtonDelaySeconds, reduceMotion: reduceMotion)

            Spacer().frame(height: 18)

            HStack(spacing: 14) {
                // Attribution has to be reachable by the wearer: the Tanzil terms require
                // the source to be clearly indicated and linked, and a field in a bundled
                // JSON file satisfies neither.
                Button {
                    showCredits = true
                } label: {
                    // Mirrors the primary capsule's icon / label / trailing-arrow shape
                    // from the reference sheet, at secondary weight.
                    HStack(spacing: 14) {
                        Image(systemName: "info.circle")
                            .font(.system(size: 22))
                        Text("Credits")
                            .font(.system(size: 22, weight: .regular, design: .serif))
                        Spacer(minLength: 12)
                        Image(systemName: "arrow.right")
                            .font(.system(size: 18, weight: .medium))
                    }
                    .foregroundStyle(.white.opacity(0.9))
                    .padding(.horizontal, 30)
                    .frame(width: 300, height: 64)
                }
                .buttonStyle(LaunchCapsuleButtonStyle(prominence: .secondary))

                if appModel.immersiveSpaceState == .open {
                    HideImmersiveSpaceButton()
                        .transition(.opacity)
                }
            }
            .launchEntrance(appeared, delay: LaunchChime.creditsButtonDelaySeconds, reduceMotion: reduceMotion)
        }
        .padding(.vertical, 48)
        .padding(.horizontal, 40)
        .animation(.easeInOut(duration: 0.3), value: appModel.immersiveSpaceState)
        .sheet(isPresented: $showCredits) {
            NavigationStack {
                CreditsView()
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Done") { showCredits = false }
                        }
                    }
            }
            .frame(minWidth: 620, idealWidth: 680, minHeight: 640, idealHeight: 720)
        }
        .onAppear {
            appModel.isLaunchWindowOpen = true
            LaunchChime.shared.prepare()
            appeared = true
            // Same instant as the `appeared` flip that schedules the logo fade, so the two
            // clocks start together: play now, fade 110 ms after.
            chimeTask?.cancel()
            chimeTask = Task {
                try? await Task.sleep(for: .seconds(LaunchChime.logoMomentSeconds(reduceMotion: reduceMotion)))
                guard !Task.isCancelled else { return }
                LaunchChime.shared.play()
            }
        }
        .onDisappear {
            appModel.isLaunchWindowOpen = false
            // A chime not yet fired is dropped with the window; one already sounding is
            // left to finish (see LaunchChime).
            chimeTask?.cancel(); chimeTask = nil
            // Replay the entrance next time the window is brought back.
            appeared = false
        }
    }
}

#Preview(windowStyle: .plain) {
    ContentView()
        .environment(AppModel())
}
