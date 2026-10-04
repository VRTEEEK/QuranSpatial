//
//  Lead.swift
//  AskCore
//
//  The optional lead: one or two plain-English sentences introducing the retrieved passages.
//  Written by the on-device model under the DEFAULT guardrails (it produces free text), and
//  shown only if `LeadVerifier` accepts it. The verifier is deterministic and is the integrity
//  gate: no Arabic script, no ayah that was not retrieved, and no content words that are not in
//  the retrieved passages or the question. On rejection the passages stand alone.
//

import Foundation

public protocol LeadWriter: Sendable {
    var name: String { get }
    func lead(question: String, passages: [Passage], anchorAyah: Int) async throws -> String
}

public struct LeadVerifier: Sendable {
    public enum Verdict: Equatable, Sendable {
        case accepted
        case rejected(String)
    }

    /// THE THRESHOLD. A content word is an alphabetic token of four or more letters that is not
    /// a function word; it is compared by a light stem. The lead may introduce at most
    /// `maxNovelContentWords` content words that occur in neither the passages, the question nor
    /// the fixed framing vocabulary, and those may be at most `maxNovelFraction` of its content
    /// words. Two is enough for a connective a model needs and too few to carry a fact;
    /// `LeadVerifierTests` pins both bounds.
    public static let maxNovelContentWords = 2
    public static let maxNovelFraction = 0.15
    public static let maxWords = 60
    public static let maxSentences = 2

    /// Words a lead may use to frame the passages without them counting as new content.
    public static let framingVocabulary: Set<String> = [
        "passage", "passages", "translation", "translations", "translator", "translators", "footnote", "footnotes",
        "meaning", "meanings", "source", "sources", "ayah", "ayat", "aya", "verse", "verses", "surah", "quran", "qur'an",
        "below", "shown", "here", "explain", "explains", "explained", "describe", "describes", "described", "note", "notes",
        "read", "reader", "question", "asked", "asks", "answer", "answers", "english", "saheeh", "international",
        "mukhtasar", "tafsir", "quranpedia", "following", "first", "second", "both", "this", "that", "these", "those",
        "about", "what", "which", "from", "with", "have", "will", "would", "could", "should", "your", "their", "them",
        "they", "there", "also", "into", "than", "then", "very", "more", "most", "some", "such", "only", "just", "like",
        "give", "gives", "given", "offer", "offers", "show", "shows", "state", "states", "says", "said", "tell", "tells",
        "comment", "commentary", "interpretation", "render", "renders", "rendered", "literal", "literally", "phrase",
        "line", "lines", "text", "texts", "reading", "readings", "context", "sense", "refer", "refers", "referring",
        "mention", "mentions", "mentioned", "according", "provide", "provides", "present", "presents", "introduce",
        "introduces", "accompany", "accompanies", "accompanied", "together", "along", "while", "where", "when", "being",
        "does", "done", "make", "makes", "made", "take", "takes", "taken", "come", "comes", "came", "find", "found",
        "look", "looks", "see", "seen", "understand", "understood", "clarify", "clarifies", "address", "addresses",
        // The surah's own name and the divine name, which every lead may use to say what it is about.
        "rahman", "allah", "allah's", "chapter",
    ]
    static let functionWords: Set<String> = ["the", "and", "for", "are", "but", "not", "you", "all", "any", "can", "had", "her", "was", "one", "our", "out", "has", "his", "how", "its", "may", "who", "did", "get", "let", "say", "she", "too", "use", "way", "own", "off", "nor", "yet", "him"]

    nonisolated static func stem(_ w: String) -> String {
        var s = w
        if s.hasSuffix("'s") || s.hasSuffix("’s") { s.removeLast(2) }
        if s.hasSuffix("ies"), s.count > 4 { s.removeLast(3); s += "y" }
        else if s.hasSuffix("ing"), s.count > 5 { s.removeLast(3) }
        else if s.hasSuffix("ed"), s.count > 4 { s.removeLast(2) }
        else if s.hasSuffix("es"), s.count > 4 { s.removeLast(2) }
        else if s.hasSuffix("s"), s.count > 4 { s.removeLast(1) }
        return s
    }

    nonisolated static func words(_ text: String) -> [String] {
        text.lowercased()
            .components(separatedBy: CharacterSet.letters.union(CharacterSet(charactersIn: "'’")).inverted)
            .filter { !$0.isEmpty }
    }

    nonisolated static func contentWords(_ text: String) -> [String] {
        words(text).filter { $0.count >= 4 && !functionWords.contains($0) }
    }

    nonisolated public static func containsArabicScript(_ text: String) -> Bool {
        text.unicodeScalars.contains { s in
            (0x0600...0x06FF).contains(s.value) || (0x0750...0x077F).contains(s.value) || (0x08A0...0x08FF).contains(s.value)
                || (0xFB50...0xFDFF).contains(s.value) || (0xFE70...0xFEFF).contains(s.value)
        }
    }

    public static func verify(lead: String, passages: [Passage], question: String, anchorAyah: Int) -> Verdict {
        let trimmed = lead.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .rejected("empty") }
        if containsArabicScript(trimmed) { return .rejected("contains Arabic script") }
        let wordCount = words(trimmed).count
        guard wordCount <= maxWords else { return .rejected("too long: \(wordCount) words") }
        let sentences = trimmed.components(separatedBy: CharacterSet(charactersIn: ".!?")).filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }.count
        guard sentences <= maxSentences else { return .rejected("too many sentences: \(sentences)") }

        // Numbers: only the surah number and retrieved ayah numbers may appear.
        let allowedNumbers = Set([55] + passages.map(\.ayah))
        let numbers = trimmed.components(separatedBy: CharacterSet.decimalDigits.inverted).compactMap { Int($0) }
        if let bad = numbers.first(where: { !allowedNumbers.contains($0) }) {
            return .rejected("mentions a number not retrieved: \(bad)")
        }

        // Content words: must come from the passages, the question or the framing vocabulary.
        var allowed = Set<String>()
        for p in passages { for w in words(p.text) { allowed.insert(stem(w)) } }
        for w in words(question) { allowed.insert(stem(w)) }
        for w in framingVocabulary { allowed.insert(stem(w)) }
        let content = contentWords(trimmed)
        let novel = Array(Set(content.filter { !allowed.contains(stem($0)) })).sorted()
        if !content.isEmpty {
            let fraction = Double(novel.count) / Double(content.count)
            if novel.count > maxNovelContentWords || fraction > maxNovelFraction {
                return .rejected("introduces content not in the passages: \(novel.joined(separator: ", "))")
            }
        }
        return .accepted
    }
}

#if canImport(FoundationModels)
import FoundationModels

/// Default guardrails: this produces free text. The prompt carries the passages so the model has
/// nothing to add; the verifier is what makes that a guarantee.
@available(macOS 26.0, iOS 26.0, visionOS 26.0, *)
public struct FoundationModelsLeadWriter: LeadWriter {
    public let name = "foundation-models"
    public init() {}

    public func lead(question: String, passages: [Passage], anchorAyah: Int) async throws -> String {
        let session = LanguageModelSession(instructions: """
            You write a short lead-in for a Quran reading app. The reader is looking at ayah \(anchorAyah) of \
            Surah Ar-Rahman (chapter 55) and asked a question. Below the lead, the app will show the passages \
            verbatim with their sources. Write ONE or TWO plain English sentences that introduce those passages \
            for the reader's question. Rules: use only words that appear in the passages or the question; add no \
            facts, names, numbers or opinions; do not quote or translate the Quran yourself; do not answer the \
            question yourself; no Arabic; no headings, lists or quotation marks. Output only the sentences.
            """)
        var prompt = "Question: \(question)\n\nPassages:\n"
        for p in passages { prompt += "- (\(p.sourceLine), ayah \(p.ayah)) \(p.text)\n" }
        let response = try await session.respond(to: prompt)
        return response.content.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
#endif

public enum LeadSupport {
    public static func writer() -> (any LeadWriter)? {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, iOS 26.0, visionOS 26.0, *), FoundationModelsRouter.isAvailable { return FoundationModelsLeadWriter() }
        #endif
        return nil
    }
}
