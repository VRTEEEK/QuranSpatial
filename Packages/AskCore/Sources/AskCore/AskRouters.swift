//
//  AskRouters.swift
//  AskCore
//
//  Day 4 (2026-10-04): the ONE router the app and qs-ask run. Until this file existed, the app
//  (AskSession) and qs-ask `--router auto` built `FoundationModelsSupport.router() ??
//  RuleBasedRouter()` - the model alone, with no safety gate in front of it - while the hybrid
//  (gate first) was only ever constructed in the tests. One factory, used by both, so the router
//  that is evaluated is the router that ships.
//

import Foundation

public enum AskRouters {
    /// The safety gate first; then high-confidence rules; then the on-device model where it is
    /// available; rules when the model refuses, errors or is absent. With no model this is
    /// `hybrid(no-model)`, which already falls back to rules on its own.
    public static func standard() -> any QuestionRouter {
        HybridRouter(model: FoundationModelsSupport.router())
    }
}
