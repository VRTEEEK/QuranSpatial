//
//  Lead.swift
//  AskCore
//
//  The optional lead: one or two plain-English sentences introducing the retrieved passages.
//  Written by the on-device model under the DEFAULT guardrails (it produces free text), and
//  shown only if `LeadVerifier` accepts it. The verifier is deterministic and is the integrity
//  gate: no Arabic script, no number that was not retrieved, no content words that are not in the
//  retrieved passages or the framing vocabulary, no negation and no advice. On rejection the
//  passages stand alone.
//
//  Directive 3, stage 3c-2 (2026-10-04), stricter: words from the QUESTION no longer count as
//  allowed, so a false premise cannot be echoed back; any negation is rejected (not, no, never, none,
//  nothing, nobody, neither, nor, cannot, without, n't); advice wording is rejected (should, must,
//  ought, have to, need to) and "should" left the framing vocabulary; allowed numbers are 55 and the
//  ayah number of every retrieved passage on ayah routes, and each Quran passage's surah and ayah on the
//  general route.
//

import Foundation

public protocol LeadWriter: Sendable {
    var name: String { get }
    /// `route`: the general route gets instructions that do not mention an anchor ayah (3c-2).
    func lead(question: String, passages: [Passage], anchorAyah: Int, route: QuestionRoute) async throws -> String
}

public struct LeadVerifier: Sendable {
    public enum Verdict: Equatable, Sendable {
        case accepted
        case rejected(String)
    }

    /// THE THRESHOLD. A content word is an alphabetic token of four or more letters that is not
    /// a function word; it is compared by a light stem. The lead may introduce at most
    /// `maxNovelContentWords` content words that occur in neither the passages nor the fixed framing
    /// vocabulary (the question does NOT count, since 3c-2), and those may be at most `maxNovelFraction` of its content
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
        "about", "what", "which", "from", "with", "have", "will", "would", "could", "your", "their", "them",
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
    /// Any of these in a lead is a rejection: a lead must introduce the passages, never deny or advise.
    public static let negationWords: Set<String> = ["not", "no", "never", "none", "nothing", "nobody", "neither", "nor", "cannot", "without"]
    public static let adviceWords: Set<String> = ["should", "must", "ought"]
    static let advicePhrases = [#"\bhave to\b"#, #"\bhas to\b"#, #"\bhad to\b"#, #"\bneed to\b"#, #"\bneeds to\b"#]

    /// Directive 4, part D (Mo, 5 Oct), from the leads audit: a lead may not speak FOR a source (the Quran,
    /// the verse, Allah) - "The Quran states that paradise…" over a dictionary entry - nor be model meta text.
    static let speaksForSource = [#"\b(the|this) (quran|qur'an|qur’an|koran|verse|ayah|aya|surah|sura) (says|said|states|tells|teaches|mentions|describes|explains|shows|means)\b"#,
                                  #"\b(allah|god) (says|said|tells|states)\b"#, #"\byou are looking at\b"#]
    static let metaStarts = ["here is", "here's", "here’s"]
    /// A lead may not copy this many consecutive words from a passage (it would repeat the translation
    /// inside the AI-summary box).
    public static let maxCopiedRun = 5

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

    public static func verify(lead: String, passages: [Passage], question: String, anchorAyah: Int, route: QuestionRoute = .meaning) -> Verdict {
        let trimmed = lead.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .rejected("empty") }
        if containsArabicScript(trimmed) { return .rejected("contains Arabic script") }
        let wordCount = words(trimmed).count
        guard wordCount <= maxWords else { return .rejected("too long: \(wordCount) words") }
        let sentences = trimmed.components(separatedBy: CharacterSet(charactersIn: ".!?")).filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }.count
        guard sentences <= maxSentences else { return .rejected("too many sentences: \(sentences)") }

        // Shape: no newline, no question, no model preamble.
        if trimmed.contains("\n") { return .rejected("contains a newline") }
        if trimmed.hasSuffix("?") { return .rejected("ends with a question") }
        let lowerAll = trimmed.lowercased()
        if metaStarts.contains(where: { lowerAll.hasPrefix($0) }) || lowerAll.contains("lead-in") || lowerAll.contains("lead in") {
            return .rejected("meta text")
        }
        // Speaking for a source.
        if let hit = speaksForSource.first(where: { lowerAll.range(of: $0, options: .regularExpression) != nil }) {
            return .rejected("speaks for a source: \(hit.hasPrefix("\\b(allah") ? "Allah/God says" : hit.contains("looking") ? "you are looking at" : "the Quran/verse says")")
        }
        // Copying: no run of more than maxCopiedRun consecutive words from any passage.
        let leadWords = words(trimmed.replacingOccurrences(of: "\u{2019}", with: "'"))
        if leadWords.count > maxCopiedRun {
            let runs = Set((0...(leadWords.count - maxCopiedRun - 1)).map { leadWords[$0..<($0 + maxCopiedRun + 1)].joined(separator: " ") })
            for p in passages {
                let pw = words(p.text.replacingOccurrences(of: "\u{2019}", with: "'"))
                guard pw.count > maxCopiedRun else { continue }
                for i in 0...(pw.count - maxCopiedRun - 1) where runs.contains(pw[i..<(i + maxCopiedRun + 1)].joined(separator: " ")) {
                    return .rejected("copies \(maxCopiedRun + 1)+ consecutive words from a passage")
                }
            }
        }
        // Negation and advice: a lead introduces the passages; it never denies or tells the reader what to do.
        let lowerWords = words(trimmed)
        if let neg = lowerWords.first(where: { negationWords.contains($0) || $0.hasSuffix("n't") || $0.hasSuffix("n’t") }) {
            return .rejected("contains a negation: \(neg)")
        }
        if let adv = lowerWords.first(where: { adviceWords.contains($0) }) { return .rejected("contains advice wording: \(adv)") }
        let lower = trimmed.lowercased()
        if let phrase = advicePhrases.first(where: { lower.range(of: $0, options: .regularExpression) != nil }) {
            return .rejected("contains advice wording: \(phrase.replacingOccurrences(of: "\\b", with: ""))")
        }

        // Numbers: 55 and the anchor ayah on ayah routes; on the general route each Quran passage's
        // surah and ayah numbers (Jamhara passages carry 0/0 and allow nothing).
        let allowedNumbers: Set<Int>
        if route == .general {
            allowedNumbers = Set(passages.filter { $0.source == .saheehTranslation || $0.source == .saheehCited }.flatMap { [$0.surah, $0.ayah] })
        } else {
            // Day-2 rule, restored by Directive 4 (A3): 55 plus the ayah number of every retrieved passage
            // (a related answer that shows ayah 52 may say "ayah 52").
            allowedNumbers = Set([55, anchorAyah] + passages.filter { $0.ayah > 0 }.map(\.ayah))
        }
        let numbers = trimmed.components(separatedBy: CharacterSet.decimalDigits.inverted).compactMap { Int($0) }
        if let bad = numbers.first(where: { !allowedNumbers.contains($0) }) {
            return .rejected("mentions a number not retrieved: \(bad)")
        }

        // Content words: must come from the passages or the framing vocabulary. NOT the question:
        // a false premise in the question must not be echoed back as if the sources said it.
        var allowed = Set<String>()
        for p in passages { for w in words(p.text) { allowed.insert(stem(w)) } }
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

    public func lead(question: String, passages: [Passage], anchorAyah: Int, route: QuestionRoute) async throws -> String {
        let context = route == .general
            ? "The reader asked a general question while reading Surah Ar-Rahman."
            : "The reader is looking at ayah \(anchorAyah) of Surah Ar-Rahman (chapter 55) and asked a question."
        let session = LanguageModelSession(instructions: """
            You write a short lead-in for a Quran reading app. \(context) Below the lead, the app will show the \
            passages verbatim with their sources. Write ONE or TWO plain English sentences that introduce those \
            passages for the reader's question - at most TWO sentences, never three. Rules: use only words that \
            appear in the passages, but do not copy a passage out word for word; add no facts, names, numbers or \
            opinions; never say what is not the case and never tell the reader what to do; do not quote or \
            translate the Quran yourself; do not answer the question yourself; no Arabic; no headings, lists or \
            quotation marks. Output only the sentences.
            """)
        var prompt = "Question: \(question)\n\nPassages:\n"
        for p in passages {
            let ref = p.source == .jamharaEnglish ? "" : (p.surah == 55 ? ", ayah \(p.ayah)" : ", Quran \(p.surah):\(p.ayah)")
            prompt += "- (\(p.sourceLine)\(ref)) \(p.text)\n"
        }
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
