//
//  ToggleImmersiveSpaceButton.swift
//  QuranSpatial
//
//  Created by Mohamed ElEryan on 31/08/2026.
//
//  Launch UI, 2026-10-05: restyled as the launch window's dominant action. The open/close
//  lifecycle below is the template's, unchanged in substance - the state machine is still
//  driven only by ImmersiveView.onAppear / onDisappear. Two additions:
//
//    1. After the space reports `.opened`, the launch window dismisses itself so it does not
//       hang inside the sky. `ReopenLaunchWindowOnExit` brings it back when the space closes.
//    2. While the space is open the primary action reads "Return to Experience" and only
//       dismisses this window; closing the space is the separate, quieter
//       `HideImmersiveSpaceButton`.
//

import SwiftUI

/// The open/close calls shared by both buttons, so the lifecycle exists in one place.
@MainActor
private struct ImmersiveSpaceLifecycle {
    let appModel: AppModel
    let openImmersiveSpace: OpenImmersiveSpaceAction
    let dismissImmersiveSpace: DismissImmersiveSpaceAction
    let dismissWindow: DismissWindowAction

    func open() async {
        guard appModel.immersiveSpaceState == .closed else { return }
        appModel.immersiveSpaceState = .inTransition
        switch await openImmersiveSpace(id: appModel.immersiveSpaceID) {
            case .opened:
                // Don't set immersiveSpaceState to .open because there
                // may be multiple paths to ImmersiveView.onAppear().
                // Only set .open in ImmersiveView.onAppear().
                //
                // The window goes away only once the space has actually opened, so a
                // failed open leaves the wearer looking at the button they just pressed.
                dismissWindow(id: appModel.launchWindowID)

            case .userCancelled, .error:
                // On error, we need to mark the immersive space
                // as closed because it failed to open.
                fallthrough
            @unknown default:
                // On unknown response, assume space did not open.
                appModel.immersiveSpaceState = .closed
        }
    }

    func close() async {
        guard appModel.immersiveSpaceState == .open else { return }
        appModel.immersiveSpaceState = .inTransition
        await dismissImmersiveSpace()
        // Don't set immersiveSpaceState to .closed because there
        // are multiple paths to ImmersiveView.onDisappear().
        // Only set .closed in ImmersiveView.onDisappear().
    }
}

/// Primary, state-aware: "Enter Immersive Space" when closed, "Return to Experience" when
/// the space is already open (dismisses this window and leaves the space untouched).
struct ToggleImmersiveSpaceButton: View {

    @Environment(AppModel.self) private var appModel

    @Environment(\.dismissImmersiveSpace) private var dismissImmersiveSpace
    @Environment(\.openImmersiveSpace) private var openImmersiveSpace
    @Environment(\.dismissWindow) private var dismissWindow

    private var lifecycle: ImmersiveSpaceLifecycle {
        ImmersiveSpaceLifecycle(appModel: appModel,
                                openImmersiveSpace: openImmersiveSpace,
                                dismissImmersiveSpace: dismissImmersiveSpace,
                                dismissWindow: dismissWindow)
    }

    private var isOpen: Bool { appModel.immersiveSpaceState == .open }
    private var inTransition: Bool { appModel.immersiveSpaceState == .inTransition }

    var body: some View {
        Button {
            Task { @MainActor in
                switch appModel.immersiveSpaceState {
                    case .closed:
                        await lifecycle.open()
                    case .open:
                        dismissWindow(id: appModel.launchWindowID)
                    case .inTransition:
                        // This case should not ever happen because button is disabled for this case.
                        break
                }
            }
        } label: {
            HStack(spacing: 18) {
                Group {
                    if inTransition {
                        ProgressView()
                    } else {
                        Image(systemName: isOpen ? "sparkles" : "book")
                            .font(.system(size: 26, weight: .regular))
                    }
                }
                .frame(width: 34)

                Text(isOpen ? "Return to Experience" : "Enter Immersive Space")
                    .font(.system(size: 26, weight: .medium, design: .serif))
                    .lineLimit(1)
                    .fixedSize()

                Spacer(minLength: 12)

                Image(systemName: "arrow.right")
                    .font(.system(size: 22, weight: .medium))
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 30)
            .frame(width: 460, height: 80)
        }
        .buttonStyle(LaunchCapsuleButtonStyle(prominence: .primary))
        .disabled(inTransition)
        .accessibilityHint(Text(isOpen ? "Hides this window and returns to the recitation."
                                       : "Opens the immersive recitation of Surah Ar-Rahman."))
    }
}

/// Quiet state capsule, shown only while the space is open: closes the space through the
/// same lifecycle path the template button used.
struct HideImmersiveSpaceButton: View {

    @Environment(AppModel.self) private var appModel

    @Environment(\.dismissImmersiveSpace) private var dismissImmersiveSpace
    @Environment(\.openImmersiveSpace) private var openImmersiveSpace
    @Environment(\.dismissWindow) private var dismissWindow

    var body: some View {
        Button {
            Task { @MainActor in
                await ImmersiveSpaceLifecycle(appModel: appModel,
                                              openImmersiveSpace: openImmersiveSpace,
                                              dismissImmersiveSpace: dismissImmersiveSpace,
                                              dismissWindow: dismissWindow).close()
            }
        } label: {
            Text("Hide Immersive Space")
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(.white.opacity(0.85))
                .padding(.horizontal, 26)
                .frame(height: 52)
        }
        .buttonStyle(LaunchCapsuleButtonStyle(prominence: .quiet))
        .disabled(appModel.immersiveSpaceState != .open)
    }
}
