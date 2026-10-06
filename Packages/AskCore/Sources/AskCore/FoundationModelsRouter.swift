//
//  FoundationModelsRouter.swift
//  AskCore
//
//  The on-device Foundation Models router: the model is asked for ONE value of a @Generable
//  enum and nothing else. It never produces text, Arabic or otherwise, and never sees or
//  touches a passage - retrieval and display are deterministic and verbatim.
//

import Foundation

#if canImport(FoundationModels)
import FoundationModels

@available(macOS 26.0, iOS 26.0, visionOS 26.0, *)
@Generable(description: """
    The single best category for a question about the ayah currently on screen. \
    meaning: what the ayah means, says, teaches, refers to, or why it says it. \
    word: one word or phrase - its meaning, translation, or why it is rendered that way. \
    repetition: why this line or question is repeated so many times in the surah, or how often. \
    related: where else this appears, which other ayat are similar, related or connected. \
    ruling: a religious ruling - halal, haram, permissible, obligatory, sinful, what one may or must do. \
    general: a question about a term or a practice in general (what tawhid means, what a fatwa is), not about this ayah. \
    offTopic: not about this ayah, the surah or the Quran at all. \
    unclear: cannot be classified - too short, garbled or ambiguous.
    """)
enum RouteChoice: String, CaseIterable {
    case meaning, word, repetition, related, ruling, general, offTopic, unclear
}

@available(macOS 26.0, iOS 26.0, visionOS 26.0, *)
public struct FoundationModelsRouter: QuestionRouter {
    public let name = "foundation-models"
    public init() {}

    public enum Unavailable: Error, CustomStringConvertible {
        case model(String)
        public var description: String { switch self { case .model(let s): return s } }
    }

    /// A one-line availability report for logs and the CLI.
    public static var availabilityDescription: String {
        switch SystemLanguageModel.default.availability {
        case .available: return "available"
        case .unavailable(let reason): return "unavailable: \(reason)"
        }
    }
    public static var isAvailable: Bool {
        if case .available = SystemLanguageModel.default.availability { return true }
        return false
    }

    public func route(_ question: String, anchorAyah: Int) async throws -> QuestionRoute {
        guard Self.isAvailable else { throw Unavailable.model(Self.availabilityDescription) }
        // PROMPT WORDING IS LOAD-BEARING FOR REFUSALS, and refusals are deterministic. Measured
        // 2026-10-04 over the 63 dev.json questions, same questions, same guardrails:
        //   no general label (the 3a prompt)                                  20 refusals (twice)
        //   general "about the religion, a term ... or a belief"              38 refusals
        //   general "about a term or a practice in general (what tawhid ...)" 21 refusals
        // The 3b draft's "about Islam, Muslims or Islamic terms" / "NOT about Islam at all" doubled
        // the model-alone fallbacks on the dev run (19 -> 40). Hence the wording used below.
        // Classification only, so the model never writes an answer. The default guardrails
        // refused 13 of 30 benign questions about the surah as "sensitive content"
        // (tests/eval/results-foundation-models-default-guardrails.json); the permissive
        // content-transformation guardrails are the documented option for tasks over
        // supplied text, and this task only labels the reader's question.
        let model = SystemLanguageModel(useCase: .general, guardrails: .permissiveContentTransformations)
        let session = LanguageModelSession(model: model, instructions: """
            You are a label picker for a Quran reading app. The reader is looking at ayah \(anchorAyah) \
            of Surah Ar-Rahman (chapter 55 of the Quran) and asks a question. Pick exactly ONE label:
            - meaning: what the ayah means, says, teaches, describes, who or what it refers to, its lesson, \
              why it says what it says. A question about the ayah's OWN content is meaning even if it \
              mentions people, places or other things.
            - word: the reader names ONE word or short phrase from the ayah or its translation and asks \
              what it means, what it refers to, or why it is translated that way.
            - repetition: why or how often this line is repeated in the surah; the refrain coming back.
            - related: ONLY when the reader explicitly asks about OTHER ayat or places: where else this \
              appears, which other verses are similar, how it compares with another verse. Never for a \
              question about this ayah alone.
            - ruling: asks whether something is halal, haram, permissible, obligatory, sinful, or what one may or must do.
            - general: a question about a term or a practice in general (what tawhid means, what a fatwa is), NOT about this ayah.
            - offTopic: NOT about this ayah, the surah or the Quran (weather, sport, programming, geography, jokes, chit-chat).
            - unclear: a fragment with no question in it, garbled, or too ambiguous to label.
            Never answer the question. Output only the label.
            """)
        let response = try await session.respond(to: "Question: \(question)", generating: RouteChoice.self)
        switch response.content {
        case .meaning: return .meaning
        case .word: return .word
        case .repetition: return .repetition
        case .related: return .related
        case .ruling: return .ruling
        case .general: return .general
        case .offTopic: return .offTopic
        case .unclear: return .unclear
        }
    }
}
#endif

/// What this build and this machine offer, for the report line.
public enum FoundationModelsSupport {
    public static var compiledIn: Bool {
        #if canImport(FoundationModels)
        return true
        #else
        return false
        #endif
    }
    public static var availability: String {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, iOS 26.0, visionOS 26.0, *) { return FoundationModelsRouter.availabilityDescription }
        return "unavailable: OS too old"
        #else
        return "unavailable: FoundationModels not in this SDK"
        #endif
    }
    public static func router() -> (any QuestionRouter)? {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, iOS 26.0, visionOS 26.0, *), FoundationModelsRouter.isAvailable { return FoundationModelsRouter() }
        #endif
        return nil
    }
}
