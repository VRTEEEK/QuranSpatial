//
//  AppModel.swift
//  QuranSpatial
//
//  Created by Mohamed ElEryan on 31/08/2026.
//

import SwiftUI

/// Maintains app-wide state
@MainActor
@Observable
class AppModel {
    let immersiveSpaceID = "ImmersiveSpace"
    enum ImmersiveSpaceState {
        case closed
        case inTransition
        case open
    }
    var immersiveSpaceState = ImmersiveSpaceState.closed

    /// The launch window's scene id. The window is dismissed once the immersive space has
    /// opened (so it does not float inside the sky) and reopened when the space closes.
    let launchWindowID = "LaunchWindow"
    /// Tracked from the launch view's own appear/disappear, so the space's exit path can
    /// reopen the window without ever creating a second copy of it.
    var isLaunchWindowOpen = false
}
