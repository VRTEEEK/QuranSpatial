//
//  AskSources.swift
//  AskCore
//
//  Day 4 (2026-10-04), Ask expansion part 1: loaders for the card data. Three files, one rule each:
//
//    ask-cards.json              committed, REFERENCES ONLY - ids, titles, levels, keywords, phrasings,
//                                Jamhara ids and Quran refs. Never a word of source text.
//    en-jamhara-terms.json       local only (gitignored, blocked by sync-public). Jamhara English
//                                entries, trim-only extraction, per-entry and file-level SHA-256.
//    en-saheeh-1947-cited.json   local only. The Saheeh ayat the cards cite, by the same deletion-only
//                                rules as the Surah 55 file, own SHA-256.
//
//  The same self-hash discipline as Corpus: a file whose text does not hash to what it claims is
//  refused, not repaired. Nothing here generates, rewrites or normalises any text.
//

import Foundation

public enum AskSourcesError: Error, Equatable, CustomStringConvertible {
    case missing(String)
    case corrupted(file: String, expected: String, actual: String)
    case entryCorrupted(file: String, id: Int, expected: String, actual: String)
    case inconsistent(file: String, detail: String)

    public var description: String {
        switch self {
        case .missing(let f): return "missing file: \(f)"
        case .corrupted(let f, let e, let a): return "\(f): text hashes to \(a), file claims \(e)"
        case .entryCorrupted(let f, let id, let e, let a): return "\(f): entry \(id) hashes to \(a), claims \(e)"
        case .inconsistent(let f, let d): return "\(f): \(d)"
        }
    }
}

// MARK: - Cards (committed, references only)

public struct AskCard: Decodable, Sendable, Equatable, Identifiable {
    public enum Kind: String, Decodable, Sendable { case term, general, gap }
    /// The annex CONTENT levels: A stable, B explanation/doubts, C disputed or sensitive.
    public enum Level: String, Decodable, Sendable { case A, B, C }
    public let id: String
    public let kind: Kind
    public let level: Level
    public let title: String
    public let jamharaIDs: [Int]
    public let quranRefs: [String]
    public let keywords: [String]
    public let phrasings: [String]
    public let answersRuling: Bool
    public let arabicLink: String?
}

public struct AskCardsFile: Decodable, Sendable {
    public let note: String
    public let cardCount: Int
    public let cards: [AskCard]
}

public struct AskCards: Sendable {
    public let cards: [AskCard]
    private let byID: [String: AskCard]

    public static func load(_ url: URL) throws -> AskCards {
        guard let data = try? Data(contentsOf: url) else { throw AskSourcesError.missing(url.lastPathComponent) }
        let file = try JSONDecoder().decode(AskCardsFile.self, from: data)
        let name = url.lastPathComponent
        guard file.cardCount == file.cards.count else {
            throw AskSourcesError.inconsistent(file: name, detail: "cardCount \(file.cardCount) but \(file.cards.count) cards")
        }
        var seen = Set<String>()
        for c in file.cards {
            guard seen.insert(c.id).inserted else { throw AskSourcesError.inconsistent(file: name, detail: "duplicate id \(c.id)") }
            switch c.kind {
            case .gap:
                guard c.arabicLink != nil, c.jamharaIDs.isEmpty, c.quranRefs.isEmpty else {
                    throw AskSourcesError.inconsistent(file: name, detail: "gap card \(c.id) must have an arabicLink and no sources")
                }
            case .term:
                guard c.jamharaIDs.count == 1, c.arabicLink == nil else {
                    throw AskSourcesError.inconsistent(file: name, detail: "term card \(c.id) must reference exactly one Jamhara entry")
                }
            case .general:
                // A general card may carry an Arabic link as further reading (Directive 4, A2).
                guard !(c.jamharaIDs.isEmpty && c.quranRefs.isEmpty) else {
                    throw AskSourcesError.inconsistent(file: name, detail: "general card \(c.id) must reference a source")
                }
            }
            guard !c.keywords.isEmpty, (3...5).contains(c.phrasings.count) else {
                throw AskSourcesError.inconsistent(file: name, detail: "card \(c.id): keywords and 3-5 phrasings required")
            }
            for r in c.quranRefs where QuranRef.expand(r) == nil {
                throw AskSourcesError.inconsistent(file: name, detail: "card \(c.id): bad ref \(r)")
            }
        }
        return AskCards(cards: file.cards, byID: Dictionary(uniqueKeysWithValues: file.cards.map { ($0.id, $0) }))
    }

    public subscript(id: String) -> AskCard? { byID[id] }
    public var count: Int { cards.count }

    /// THE KEYWORD RULE, as the cards file states it: a keyword matches only as whole words - a word
    /// boundary on both sides, case-insensitive - so "eye" never matches "eyes" (held-out h34). A
    /// multi-word keyword matches as a whole-word phrase. Speech-recogniser spellings are not handled
    /// here; they belong to transcript clean-up.
    public static func matchesKeyword(_ keyword: String, in question: String) -> Bool {
        // Both sides pass through TranscriptCleanup.forMatching: U+2019 folded to U+0027, gin/jin -> jinn.
        let k = TranscriptCleanup.forMatching(keyword)
        let pattern = #"(?<![\p{L}\p{N}])"# + NSRegularExpression.escapedPattern(for: k) + #"(?![\p{L}\p{N}])"#
        return TranscriptCleanup.forMatching(question).range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil
    }

    /// Cards whose keywords match the question, in file order. Nothing is ranked here.
    public func cardsMatching(_ question: String) -> [AskCard] {
        cards.filter { c in c.keywords.contains { Self.matchesKeyword($0, in: question) } }
    }
}

/// "55:1", "112:1-4" -> the (surah, ayah) pairs. Nil for anything else.
public enum QuranRef {
    public static func expand(_ ref: String) -> [(surah: Int, ayah: Int)]? {
        let parts = ref.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 2, let surah = Int(parts[0]), (1...114).contains(surah) else { return nil }
        let range = parts[1].split(separator: "-", omittingEmptySubsequences: false)
        guard let lo = Int(range[0]), lo >= 1 else { return nil }
        let hi: Int
        if range.count == 1 { hi = lo } else if range.count == 2, let h = Int(range[1]), h >= lo { hi = h } else { return nil }
        return (lo...hi).map { (surah, $0) }
    }
}

// MARK: - Jamhara (local only)

public struct JamharaEntry: Decodable, Sendable, Equatable {
    public let id: Int
    public let url: String
    public let retrievedAt: String
    public let rawSHA256: String
    public let title: String
    public let definitionHeading: String
    public let definition: String
    public let explanation: String
    public let textSHA256: String

    /// The hashed string: title, definition, explanation, newline-joined (explanation may be empty).
    public var joinedText: String { title + "\n" + definition + "\n" + explanation }
    public var computedTextSHA256: String { Corpus.sha256Hex(joinedText) }
}

public struct JamharaTermsFile: Decodable, Sendable {
    public let source: String
    public let urlPattern: String
    public let extractionRules: [String]
    public let textSHA256: String
    public let entries: [JamharaEntry]
    public var computedTextSHA256: String { Corpus.sha256Hex(entries.map(\.joinedText).joined(separator: "\n")) }
}

public struct JamharaTerms: Sendable {
    public static let sourceLine = "Jamhara (موسوعة المصطلحات الإسلامية), English, islamic-content.com"
    public let file: JamharaTermsFile
    private let byID: [Int: JamharaEntry]

    public static func load(_ url: URL) throws -> JamharaTerms {
        guard let data = try? Data(contentsOf: url) else { throw AskSourcesError.missing(url.lastPathComponent) }
        let file = try JSONDecoder().decode(JamharaTermsFile.self, from: data)
        let name = url.lastPathComponent
        for e in file.entries where e.computedTextSHA256 != e.textSHA256 {
            throw AskSourcesError.entryCorrupted(file: name, id: e.id, expected: e.textSHA256, actual: e.computedTextSHA256)
        }
        guard file.computedTextSHA256 == file.textSHA256 else {
            throw AskSourcesError.corrupted(file: name, expected: file.textSHA256, actual: file.computedTextSHA256)
        }
        var byID: [Int: JamharaEntry] = [:]
        for e in file.entries {
            guard byID.updateValue(e, forKey: e.id) == nil else { throw AskSourcesError.inconsistent(file: name, detail: "duplicate entry \(e.id)") }
            guard !e.title.isEmpty, !e.definition.isEmpty else { throw AskSourcesError.inconsistent(file: name, detail: "entry \(e.id) has an empty field") }
        }
        return JamharaTerms(file: file, byID: byID)
    }

    public subscript(id: Int) -> JamharaEntry? { byID[id] }
    public var count: Int { file.entries.count }
}

// MARK: - Cited Saheeh ayat (local only)

public struct CitedSaheehFile: Decodable, Sendable {
    public struct Entry: Decodable, Sendable, Equatable { public let surah: Int; public let ayah: Int; public let text: String }
    public let edition: String
    public let sourceBook: Int
    public let sourceURL: String
    public let rawSHA256: String
    public let extractionRules: [String]
    public let refs: [String]
    public let textSHA256: String
    public let ayat: [Entry]
    public var computedTextSHA256: String { Corpus.sha256Hex(ayat.map(\.text).joined(separator: "\n")) }
}

public struct CitedSaheeh: Sendable {
    public let file: CitedSaheehFile
    private let byRef: [String: CitedSaheehFile.Entry]

    /// `expectedRawSHA256`: when given (the Surah 55 translation's recorded raw hash), the cited file
    /// must come from the same raw Quranpedia file.
    public static func load(_ url: URL, expectedRawSHA256: String? = nil) throws -> CitedSaheeh {
        guard let data = try? Data(contentsOf: url) else { throw AskSourcesError.missing(url.lastPathComponent) }
        let file = try JSONDecoder().decode(CitedSaheehFile.self, from: data)
        let name = url.lastPathComponent
        guard file.computedTextSHA256 == file.textSHA256 else {
            throw AskSourcesError.corrupted(file: name, expected: file.textSHA256, actual: file.computedTextSHA256)
        }
        if let expected = expectedRawSHA256, expected != file.rawSHA256 {
            throw AskSourcesError.inconsistent(file: name, detail: "rawSHA256 \(file.rawSHA256) differs from the Surah 55 translation's \(expected)")
        }
        var byRef: [String: CitedSaheehFile.Entry] = [:]
        for a in file.ayat {
            guard byRef.updateValue(a, forKey: "\(a.surah):\(a.ayah)") == nil else { throw AskSourcesError.inconsistent(file: name, detail: "duplicate \(a.surah):\(a.ayah)") }
        }
        // Every ayah named by `refs` must be present, and nothing else.
        let wanted = Set(file.refs.flatMap { QuranRef.expand($0) ?? [] }.map { "\($0.surah):\($0.ayah)" })
        guard wanted == Set(byRef.keys) else { throw AskSourcesError.inconsistent(file: name, detail: "ayat do not match refs") }
        return CitedSaheeh(file: file, byRef: byRef)
    }

    public func passage(surah: Int, ayah: Int) -> Passage? {
        byRef["\(surah):\(ayah)"].map { Passage(source: .saheehTranslation, surah: $0.surah, ayah: $0.ayah, text: $0.text) }
    }
    /// The passages for a card ref such as "112:1-4", in ayah order; nil if any ayah is missing.
    public func passages(for ref: String) -> [Passage]? {
        guard let pairs = QuranRef.expand(ref) else { return nil }
        var out: [Passage] = []
        for p in pairs { guard let passage = passage(surah: p.surah, ayah: p.ayah) else { return nil }; out.append(passage) }
        return out
    }
    public var count: Int { file.ayat.count }
}

// MARK: - Where the files are

public extension SourceFiles {
    /// The three Ask-card files in the repository layout. The local-only ones are nil when absent.
    static func askSources(root: URL) -> (cards: URL, jamhara: URL?, cited: URL?) {
        let res = root.appendingPathComponent("QuranSpatial/Resources")
        let j = res.appendingPathComponent("en-jamhara-terms.json"), c = res.appendingPathComponent("en-saheeh-1947-cited.json")
        return (res.appendingPathComponent("ask-cards.json"),
                FileManager.default.fileExists(atPath: j.path) ? j : nil,
                FileManager.default.fileExists(atPath: c.path) ? c : nil)
    }
    static func askSources(in bundle: Bundle) -> (cards: URL?, jamhara: URL?, cited: URL?) {
        (bundle.url(forResource: "ask-cards", withExtension: "json"),
         bundle.url(forResource: "en-jamhara-terms", withExtension: "json"),
         bundle.url(forResource: "en-saheeh-1947-cited", withExtension: "json"))
    }
}
