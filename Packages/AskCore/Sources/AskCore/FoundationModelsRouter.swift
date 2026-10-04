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
    offTopic: not about this ayah, the surah or the Quran at all. \
    unclear: cannot be classified - too short, garbled or ambiguous.
    """)
enum RouteChoice: String, CaseIterable {
    case meaning, word, repetition, related, ruling, offTopic, unclear
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
        // Classification only, so the model never writes an answer. The default guardrails
        // refused 13 of 30 benign questions about the surah as "sensitive content"
        // (tests/eval/results-foundation-models-default-guardrails.json); the permissive
        // content-transformation guardrails are the documented option for tasks over
        // supplied text, and this task only labels the reader's question.
        let model = SystemLanguageModel(useCase: .general, guardrails: .permissiveContentTransformations)
        let session = LanguageModelSession(model: model, instructions: """
            You are a label picker for a Quran reading app. The reader is looking at ayah \(anchorAyah) \
            of Surah Ar-Rahman (chapter 55 of the Quran) and asks a question. Pick exactly ONE label:
            - meaning: what the ayah means, says, teaches, describes, who or what it refers to, its lesson.
            - word: about one word or phrase in the ayah or its translation (quoted words, "the word X", why it is translated so).
            - repetition: why or how often this line is repeated in the surah; the refrain.
            - related: where else this appears; other ayat that are similar, related, connected.
            - ruling: asks whether something is halal, haram, permissible, obligatory, sinful, or what one may or must do.
            - offTopic: NOT about this ayah, the surah or the Quran (weather, sport, programming, geography, jokes, chit-chat).
            - unclear: too short, garbled or ambiguous to label.
            Never answer the question. Output only the label.
            """)
        let response = try await session.respond(to: "Question: \(question)", generating: RouteChoice.self)
        switch response.content {
        case .meaning: return .meaning
        case .word: return .word
        case .repetition: return .repetition
        case .related: return .related
        case .ruling: return .ruling
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
