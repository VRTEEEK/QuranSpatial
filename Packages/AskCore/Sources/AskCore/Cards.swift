//
//  Cards.swift
//  AskCore
//
//  Directive 3: the Ask cards at run time. `AskSourceSet` holds the cards with the local-only
//  Jamhara and cited-Saheeh files and says which cards are AVAILABLE (every reference resolves;
//  gap cards always). `Definitional` is the exemption that keeps "What is a fatwa?" away from the
//  safety gate. `CardSelector.keywordFallback` is the deterministic selector (stage 3a; the model
//  selector arrives in 3b). `CardRetriever` turns a card into verbatim passages: the card's Quran
//  passages first, then its Jamhara entries in card order. Nothing here generates text.
//

import Foundation

public struct AskSourceSet: Sendable {
    public let cards: AskCards
    public let jamhara: JamharaTerms?
    public let cited: CitedSaheeh?
    /// Loaded from a corpus: Surah 55 ayat come from it, not from the cited file.
    public init(cards: AskCards, jamhara: JamharaTerms?, cited: CitedSaheeh?) {
        self.cards = cards; self.jamhara = jamhara; self.cited = cited
    }

    /// Repository layout. The cards file is required; the local-only files are optional but, when
    /// present, must pass their hash checks (a corrupted file throws rather than loading partially).
    public static func load(root: URL, expectedRawSHA256: String? = nil) throws -> AskSourceSet {
        let paths = SourceFiles.askSources(root: root)
        return AskSourceSet(cards: try AskCards.load(paths.cards),
                            jamhara: try paths.jamhara.map { try JamharaTerms.load($0) },
                            cited: try paths.cited.map { try CitedSaheeh.load($0, expectedRawSHA256: expectedRawSHA256) })
    }

    /// App bundle layout (resources flattened to the bundle root). Nil when the cards are not bundled.
    public static func load(bundle: Bundle, expectedRawSHA256: String? = nil) throws -> AskSourceSet? {
        let paths = SourceFiles.askSources(in: bundle)
        guard let cardsURL = paths.cards else { return nil }
        return AskSourceSet(cards: try AskCards.load(cardsURL),
                            jamhara: try paths.jamhara.map { try JamharaTerms.load($0) },
                            cited: try paths.cited.map { try CitedSaheeh.load($0, expectedRawSHA256: expectedRawSHA256) })
    }

    /// A card is available only when every jamharaID and quranRef resolves. Gap cards always are.
    public func isAvailable(_ card: AskCard, corpus: Corpus?) -> Bool {
        if card.kind == .gap { return true }
        for id in card.jamharaIDs where jamhara?[id] == nil { return false }
        for ref in card.quranRefs {
            guard let pairs = QuranRef.expand(ref) else { return false }
            for p in pairs {
                if p.surah == 55 { if corpus?[p.ayah]?.translation == nil { return false } }
                else if cited?.passage(surah: p.surah, ayah: p.ayah) == nil { return false }
            }
        }
        return true
    }

    public func availableCards(corpus: Corpus?) -> [AskCard] { cards.cards.filter { isAvailable($0, corpus: corpus) } }
    public func availableCount(corpus: Corpus?) -> Int { availableCards(corpus: corpus).count }
}

/// "what is a fatwa?", "what does tawhid mean", "define dua", "meaning of barzakh" - and nothing
/// longer. TERM is any whole-word keyword of a TERM card. Such a question is never gated and
/// selects that card directly.
public enum Definitional {
    static func normalise(_ question: String) -> String {
        var q = TranscriptCleanup.forMatching(question).lowercased()
        q = q.replacingOccurrences(of: #"[?.!]+$"#, with: "", options: .regularExpression)
        q = q.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        return q.trimmingCharacters(in: .whitespaces)
    }

    static func frames(for keyword: String) -> [String] {
        let k = NSRegularExpression.escapedPattern(for: TranscriptCleanup.forMatching(keyword).lowercased())
        return [
            // "what's" / "whats" / "who's" are common in speech transcripts (3a review, item 4).
            "^(what|who)( is| are| was|'s|s) (a |an |the )?\(k)( in islam)?$",
            "^what does (a |an |the )?\(k) mean( in islam)?$",
            "^define (a |an |the )?\(k)$",
            "^(the )?meaning of (a |an |the )?\(k)( in islam)?$",
        ]
    }

    public static func termCard(for question: String, in cards: AskCards) -> AskCard? {
        let q = normalise(question)
        for card in cards.cards where card.kind == .term {
            for keyword in card.keywords {
                for frame in frames(for: keyword) where q.range(of: frame, options: .regularExpression) != nil { return card }
            }
        }
        return nil
    }
}

public enum CardSelector {
    /// Exact phrasing match (step 7a, moved before the gate by the 3a review): the cleaned, lowercased
    /// question with end punctuation removed equals one of a card's phrasings. Phrasings are
    /// reviewed text, so "Is drinking a sin in Islam?" (a G3 phrasing) is answered from G3 instead
    /// of reaching the gate. Apostrophes are folded on both sides.
    public static func exactMatch(_ question: String, among cards: [AskCard]) -> AskCard? {
        let q = Definitional.normalise(question)
        for card in cards where card.phrasings.contains(where: { Definitional.normalise($0) == q }) { return card }
        return nil
    }

    /// Keyword fallback: score = number of matched keywords; ties broken by the longest matched
    /// keyword, then general before term before gap, then file order. Nil when nothing matches.
    public static func keywordFallback(_ question: String, among cards: [AskCard]) -> AskCard? {
        func rank(_ k: AskCard.Kind) -> Int { k == .general ? 0 : (k == .term ? 1 : 2) }
        var best: (card: AskCard, score: Int, longest: Int, order: Int)? = nil
        for (i, card) in cards.enumerated() {
            let matched = card.keywords.filter { AskCards.matchesKeyword($0, in: question) }
            guard !matched.isEmpty else { continue }
            let longest = matched.map(\.count).max() ?? 0
            let candidate = (card, matched.count, longest, i)
            if let b = best {
                if candidate.1 > b.score || (candidate.1 == b.score && (candidate.2 > b.longest || (candidate.2 == b.longest && rank(card.kind) < rank(b.card.kind)))) { best = candidate }
            } else { best = candidate }
        }
        return best?.card
    }
}

extension CardSelector {
    /// Directive 4, part D (Mo, 5 Oct): after the model's pick is unconfirmed or "none", a keyword fallback
    /// is allowed ON THE GENERAL ROUTE ONLY and only on strong evidence - a multi-word keyword matched, or
    /// two or more distinct keywords of the same card. A single one-word match stays not-covered.
    public static func strongKeywordFallback(_ question: String, among cards: [AskCard]) -> AskCard? {
        let strong = cards.filter { card in
            let matched = card.keywords.filter { AskCards.matchesKeyword($0, in: question) }
            return matched.contains { $0.contains(" ") } || Set(matched).count >= 2
        }
        return keywordFallback(question, among: strong)
    }
}

public enum CardRetriever {
    public static let levelCNote = "Scholars hold different views on this. The passages below are general information from the named sources."

    /// The card's passages: Quran passages first (Surah 55 from the corpus, with their existing IDs;
    /// other surahs from the cited file), then Jamhara entries in card order - definition, then the
    /// explanation when it is non-empty. The anchor ayah is NOT included.
    public static func passages(for card: AskCard, sources: AskSourceSet, corpus: Corpus?) -> [Passage] {
        var out: [Passage] = []
        for ref in card.quranRefs {
            for p in QuranRef.expand(ref) ?? [] {
                if p.surah == 55 { if let t = corpus?[p.ayah]?.translation { out.append(t) } }
                else if let e = sources.cited?.passage(surah: p.surah, ayah: p.ayah) {
                    out.append(Passage(id: "\(PassageSource.saheehCited.rawValue):\(p.surah):\(p.ayah)", source: .saheehCited, surah: p.surah, ayah: p.ayah, text: e.text,
                                       sourceLine: "Quran \(p.surah):\(p.ayah) · \(PassageSource.saheehCited.sourceLine)"))
                }
            }
        }
        for id in card.jamharaIDs {
            guard let e = sources.jamhara?[id] else { continue }
            let line = "\(JamharaTerms.sourceLine) · \"\(e.title)\" (entry \(e.id))"
            out.append(Passage(id: "jamhara-en:\(e.id)#definition", source: .jamharaEnglish, surah: 0, ayah: 0, text: e.definition, sourceLine: line))
            if !e.explanation.isEmpty {
                out.append(Passage(id: "jamhara-en:\(e.id)#explanation", source: .jamharaEnglish, surah: 0, ayah: 0, text: e.explanation, sourceLine: line))
            }
        }
        return out
    }
}
