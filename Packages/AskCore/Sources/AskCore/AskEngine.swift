//
//  AskEngine.swift
//  AskCore
//
//  Retrieval and the answer. The anchor ayah comes first; every passage is verbatim with its
//  source line; the lead is optional, model-written, and VERIFIED before it is shown; the
//  decision is answered / answered-in-part / referred / declined. Ruling questions are referred
//  to a scholar. Off-topic questions are declined. No answer is ever made without a retrieved
//  passage behind it, and nothing is ever generated about the Quran, a translation or a tafsir.
//
//  Day 2 decisions (Mo, 2026-10-04): the repetition route answers in part with what the sources
//  do say and states plainly that they do not explain the repetition; the related route answers
//  only where the similar-ayat dump has data (ayat 11, 52, 68) and says so elsewhere.
//
//  Directive 3, stage 3a (2026-10-04). Order inside ask():
//    1. TranscriptCleanup            gin/jin -> jinn
//    2. Exact phrasing, definitional "Is alcohol haram?" / "what is a fatwa?" -> that card, never the gate
//    3. Safety gate, five categories hadith -> referred bare; personal -> referred with a
//                                    keyword-matched card as general information (level D, no
//                                    lead); qualified ruling -> referred bare; plain ruling ->
//                                    an answersRuling card if one matches, else referred
//    4. The router                   as before, now with a `general` label from the model
//    5. Precedence (stage 3b)        between ayah routes and cards; then card selection on the general
//                                    route: model pick confirmed by the question, else keyword fallback
//    6. Retrieval                    cards -> Quran passages then Jamhara; gap / no card / missing local
//                                    file -> not-covered; repetition carries the Dorar link
//  The Answer carries the card id, the level and any links; `router` carries the decision chain.
//

import Foundation
import os

public enum Decision: String, Codable, Sendable {
    case answered
    case answeredInPart = "answered-in-part"
    case referred
    case declined
    /// Directive 3: a general question the English sources do not cover, a gap card, or a card whose
    /// local source file is not in this build. A safe non-answer, like referred and declined.
    case notCovered = "not-covered"
}

public struct Answer: Codable, Sendable {
    public let question: String
    public let anchorAyah: Int
    public let route: QuestionRoute
    /// Which router produced the route and the decision chain, e.g.
    /// "hybrid(foundation-models) [safety-gate:personal → card-keyword:general-g3-alcohol-forbidden]".
    public let router: String
    public let decision: Decision
    /// A one- or two-sentence plain-English lead introducing the passages, model-written and
    /// verified. Empty when there is no lead writer, when the lead was rejected, or when the
    /// decision is referred or declined.
    public let lead: String
    /// What happened to the lead: "accepted", "rejected: <reason>", "error: <reason>", or
    /// "none: <reason>". Logged as well.
    public let leadStatus: String
    public let passages: [Passage]
    /// Passage IDs actually retrieved, in display order. Empty means referred or declined.
    public let citations: [String]
    /// A fixed, human-written note about what was or was not found. Never model text.
    public let note: String
    /// Directive 3: the Ask card the answer (or the general information) came from, if any.
    public let card: String?
    /// Directive 3: the annex content level A/B/C of that card, or "D" for a personal question.
    public let level: String?
    /// Directive 3: links shown as selectable text (a gap card's Arabic link, Dorar for repetition).
    public let links: [String]
}

public struct Retrieval: Sendable {
    public let passages: [Passage]
    public let note: String
    public let decision: Decision
    public var links: [String] = []
    public init(passages: [Passage], note: String, decision: Decision, links: [String] = []) {
        self.passages = passages; self.note = note; self.decision = decision; self.links = links
    }
}

public struct Retriever: Sendable {
    public let corpus: Corpus
    public init(corpus: Corpus) { self.corpus = corpus }

    public static let repetitionNote = "The sources in this app do not explain why this verse is repeated."
    public static let relatedUnavailableNote = "Related-ayah data is not available for this ayah."
    /// Directive 3 wording.
    public static let rulingNote = "Questions about rulings are referred to a qualified scholar; this companion does not give rulings."
    /// Directive 4 (A1): a refusal to fabricate plus the statement that the sources hold no hadith.
    public static let hadithNote = "This app's sources contain no hadith, so it cannot give or confirm one. Please ask a qualified scholar."
    /// Directive 4 (A2): a sourced card that also carries an Arabic link.
    public static let furtherReadingNote = "Further reading in Arabic is linked below."
    public static let personalNote = "This is about your own situation, so it needs a qualified scholar. Anything shown below is general information only, not a ruling for you."
    public static let generalNotCoveredNote = "This is a general question about Islam that the English sources in this app do not cover. Please consult a qualified scholar or a trusted reference."
    public static let gapNote = "The English sources in this app do not cover this question. An Arabic treatment is linked below."
    public static let unavailableNote = "This build does not include the source text for this answer (local-only files; see tools/fetch-sources.py)."
    /// Appended to the repetition note (3b, step 9); the URL also goes in `links`.
    public static let repetitionDorarLink = "https://dorar.net/tafseer/55/2"
    public static var repetitionNoteWithLink: String { repetitionNote + " An Arabic explanation is in Dorar's tafsir: " + repetitionDorarLink }

    /// Anchor ayah first, always.
    public func retrieve(route: QuestionRoute, anchorAyah: Int) -> Retrieval {
        guard let record = corpus[anchorAyah] else {
            return Retrieval(passages: [], note: "No record for ayah \(anchorAyah) of Surah 55.", decision: .declined)
        }
        var out: [Passage] = []
        switch route {
        case .meaning:
            if let t = record.translation { out.append(t) }
            if let m = record.meaning { out.append(m) }
            return Retrieval(passages: out, note: "", decision: .answered)
        case .unclear:
            if let t = record.translation { out.append(t) }
            if let m = record.meaning { out.append(m) }
            return Retrieval(passages: out, note: "The question could not be classified; the ayah's translation and meaning are shown.", decision: .answered)
        case .word:
            if let t = record.translation { out.append(t) }
            out.append(contentsOf: record.footnotes)
            if let m = record.meaning { out.append(m) }
            let note = record.footnotes.isEmpty
                ? (corpus.footnotesLoaded ? "No translator's footnote on this ayah; the translation and meaning are shown."
                                          : "Translator's footnotes are not loaded in this build; the translation and meaning are shown.")
                : ""
            return Retrieval(passages: out, note: note, decision: .answered)
        case .repetition:
            // What the sources DO say: the ayah's translation, the refrain's Mukhtasar passage,
            // and the Saheeh footnote on "you two". Then the plain statement. Never an explanation.
            if let t = record.translation { out.append(t) }
            if let m = record.meaning { out.append(m) }
            if let f = corpus.refrainFootnote { out.append(f) }
            return Retrieval(passages: out, note: Self.repetitionNoteWithLink, decision: .answeredInPart, links: [Self.repetitionDorarLink])
        case .related:
            if let t = record.translation { out.append(t) }
            let refs = corpus.related?.related(to: anchorAyah) ?? []
            if refs.isEmpty {
                if let m = record.meaning { out.append(m) }
                return Retrieval(passages: out, note: Self.relatedUnavailableNote, decision: .answeredInPart)
            }
            for r in refs { if let t = corpus[r]?.translation { out.append(t) } }
            return Retrieval(passages: out, note: "Related ayat within Surah 55 per the Quranpedia similar-ayat dump: \(refs.map(String.init).joined(separator: ", ")).", decision: .answered)
        case .ruling:
            return Retrieval(passages: [], note: Self.rulingNote, decision: .referred)
        case .general:
            // Without a card there is nothing to show.
            return Retrieval(passages: [], note: Self.generalNotCoveredNote, decision: .notCovered)
        case .offTopic:
            return Retrieval(passages: [], note: "Declined: the question is not about this ayah or Surah Ar-Rahman.", decision: .declined)
        }
    }
}

public struct AskEngine: Sendable {
    public let corpus: Corpus
    public let router: any QuestionRouter
    public let leadWriter: (any LeadWriter)?
    public let fallback: RuleBasedRouter
    /// The Ask cards with their local sources; nil means no cards (the day-3 behaviour).
    public let sources: AskSourceSet?
    /// The model's card picker (3b); nil -> keyword fallback only.
    public let cardPicker: (any CardPicker)?
    public let gate = RulingSafetyGate()
    private static let logger = Logger(subsystem: "com.vrteek.quranspatial", category: "Ask")
    /// Routes on which no lead is requested (see the lead step).
    static let leadSkippedRoutes: Set<QuestionRoute> = [.general, .repetition, .related, .unclear]

    public init(corpus: Corpus, router: any QuestionRouter, leadWriter: (any LeadWriter)? = nil, fallback: RuleBasedRouter = RuleBasedRouter(), sources: AskSourceSet? = nil, cardPicker: (any CardPicker)? = nil) {
        self.corpus = corpus; self.router = router; self.leadWriter = leadWriter; self.fallback = fallback; self.sources = sources; self.cardPicker = cardPicker
    }

    /// Whole milliseconds of a Duration, for the timing log lines.
    static func milliseconds(_ d: Duration) -> Int64 {
        let c = d.components
        return c.seconds * 1000 + c.attoseconds / 1_000_000_000_000_000
    }

    /// The decision a route leads to for a given anchor (related depends on the data).
    public static func decision(for route: QuestionRoute, anchorAyah: Int, corpus: Corpus) -> Decision {
        Retriever(corpus: corpus).retrieve(route: route, anchorAyah: anchorAyah).decision
    }

    public func ask(_ rawQuestion: String) async -> Answer { await ask(rawQuestion, anchorAyah: 1) }

    /// Model card selection with confirmation (3b, step 7b/7c). Returns the card and the chain entry.
    /// `strongFallback`: on the general route only, an unconfirmed or "none" pick may fall back to a card
    /// with strong keyword evidence (Directive 4, part D). The off-topic override never passes it.
    private func selectCard(question: String, among available: [AskCard], strongFallback: Bool = false) async -> (AskCard?, String) {
        guard let picker = cardPicker, !available.isEmpty else {
            let k = CardSelector.keywordFallback(question, among: available)
            return (k, k.map { "card-keyword:\($0.id)" } ?? "card-none")
        }
        do {
            let id = try await picker.pick(question: question, from: available)
            guard id != "none", let card = available.first(where: { $0.id == id }) else {
                if strongFallback, let k = CardSelector.strongKeywordFallback(question, among: available) { return (k, "card-keyword-after-model-none:\(k.id)") }
                return (nil, "card-model-none")
            }
            if CardConfirmation.confirms(card, question: question) { return (card, "card-model:\(card.id)") }
            if strongFallback, let k = CardSelector.strongKeywordFallback(question, among: available) { return (k, "card-keyword-after-model-unconfirmed:\(card.id)->\(k.id)") }
            return (nil, "card-model-unconfirmed:\(card.id)")
        } catch {
            let k = CardSelector.keywordFallback(question, among: available)
            let why = String(describing: error).contains("refusal") ? "refusal" : "error"
            return (k, k.map { "card-keyword-after-model-\(why):\($0.id)" } ?? "card-none-after-model-\(why)")
        }
    }

    public func ask(_ rawQuestion: String, anchorAyah: Int) async -> Answer {
        // 1. Transcript clean-up, shared by the app and qs-ask.
        let question = TranscriptCleanup.clean(rawQuestion)
        let clock = ContinuousClock()
        let routeStart = clock.now
        var chain: [String] = []
        var route: QuestionRoute? = nil
        var routerName = router.name
        var selectedCard: AskCard? = nil      // the card the answer comes from
        var unavailableCard: AskCard? = nil   // a chosen card whose local source is not in this build
        var infoCard: AskCard? = nil          // general information attached to a personal question
        var termCardForWord: AskCard? = nil   // a term card appended after a word-route answer
        var gated: GateCategory = .none
        let allCards = sources?.cards.cards ?? []
        let available = sources?.availableCards(corpus: corpus) ?? []
        func choose(_ card: AskCard, _ stage: String) {
            chain.append("\(stage):\(card.id)")
            if sources?.isAvailable(card, corpus: corpus) == true { selectedCard = card } else { unavailableCard = card }
            route = .general
        }

        // 2. Exact phrasing match, then the definitional exemption: both before the gate.
        if let card = CardSelector.exactMatch(question, among: allCards) {
            choose(card, "card-exact")
        } else if let s = sources, let card = Definitional.termCard(for: question, in: s.cards) {
            choose(card, "card-definitional")
        } else {
            // 3. The safety gate, five categories.
            gated = gate.classify(question)
            if gated != .none {
                route = .ruling; chain.append("safety-gate:\(gated.rawValue)")
                switch gated {
                case .plainRuling:
                    if let card = CardSelector.keywordFallback(question, among: available.filter(\.answersRuling)) {
                        route = .general; selectedCard = card; chain.append("gate-plain-ruling-card:\(card.id)")
                    }
                case .personal:
                    // General information only from cards marked answersRuling (3a review, item 2).
                    if let card = CardSelector.keywordFallback(question, among: available.filter(\.answersRuling)) {
                        infoCard = card; chain.append("card-keyword:\(card.id)")
                    }
                default: break
                }
            }
        }

        // 4. The router, for everything the deterministic stages did not decide.
        var routedByRouter = false
        if route == nil {
            do {
                if let attributing = router as? any AttributingRouter {
                    let a = try await attributing.routeAttributed(question, anchorAyah: anchorAyah)
                    route = a.route; chain.append(a.decidedBy)
                } else {
                    route = try await router.route(question, anchorAyah: anchorAyah)
                }
            } catch {
                route = (try? await fallback.route(question, anchorAyah: anchorAyah)) ?? .unclear
                routerName = "\(fallback.name) (fallback: \(router.name) failed: \(error))"
            }
            routedByRouter = true
        }

        // 5. Precedence between the ayah routes and the cards (step 8), then card selection on
        //    the general route.
        let selectStart = clock.now
        if routedByRouter, let s = sources, let routed = route {
            let K = available.filter { c in c.keywords.contains { AskCards.matchesKeyword($0, in: question) } }
            let anchorTexts = [corpus[anchorAyah]?.translation?.text, corpus[anchorAyah]?.meaning?.text].compactMap { $0 }
            switch Precedence.apply(route: routed, question: question, matched: K, anchorTexts: anchorTexts) {
            case .keep: break
            case .toMeaning: route = .meaning; chain.append("precedence:anchor-cue->meaning")
            case .toGeneral: route = .general; chain.append("precedence:card-keywords->general")
            case .wordPlusTerm(let id): termCardForWord = s.cards[id]; chain.append("precedence:word+term:\(id)")
            case .offTopicNeedsConfirmedCard:
                // Keywords alone never override off-topic, and neither does the model alone: only a
                // model pick with STRONG keyword evidence does (F2: a multi-word keyword, or 2+ distinct
                // keywords of the picked card; a single keyword never overturns off-topic). The model is
                // asked only when some card has that evidence in the question.
                let confirmable = available.filter { CardConfirmation.confirmsStrongly($0, question: question) }
                if cardPicker != nil, !confirmable.isEmpty {
                    let (card, stage) = await selectCard(question: question, among: available)
                    if let card, stage.hasPrefix("card-model:"), CardConfirmation.confirmsStrongly(card, question: question) {
                        route = .general; selectedCard = card; chain.append("precedence:off-topic->general"); chain.append(stage)
                    } else { chain.append(stage + "(off-topic kept)") }
                }
            }
            if route == .general, selectedCard == nil, unavailableCard == nil {
                let (card, stage) = await selectCard(question: question, among: available, strongFallback: true)
                chain.append(stage)
                selectedCard = card
            }
        }
        let selectMs = Self.milliseconds(selectStart.duration(to: clock.now))
        let finalRoute = route ?? .unclear
        if !chain.isEmpty, !routerName.hasPrefix(fallback.name + " (fallback") { routerName = "\(router.name) [\(chain.joined(separator: " → "))]" }
        let routeMs = Self.milliseconds(routeStart.duration(to: clock.now))
        Self.logger.notice("Ask routed by \(routerName, privacy: .public): \(finalRoute.rawValue, privacy: .public) for ayah \(anchorAyah) in \(routeMs) ms (card selection \(selectMs) ms)")

        // 6. Retrieval.
        var level: String? = nil
        var links: [String] = []
        let r: Retrieval
        if let card = selectedCard, let s = sources {
            level = card.level.rawValue
            if card.kind == .gap {
                links = [card.arabicLink].compactMap { $0 }
                r = Retrieval(passages: [], note: Retriever.gapNote, decision: .notCovered, links: links)
            } else {
                let passages = CardRetriever.passages(for: card, sources: s, corpus: corpus)
                links = [card.arabicLink].compactMap { $0 }
                var notes: [String] = []
                if card.level == .C { notes.append(CardRetriever.levelCNote) }
                if !links.isEmpty { notes.append(Retriever.furtherReadingNote) }
                r = Retrieval(passages: passages, note: notes.joined(separator: " "),
                              decision: passages.isEmpty ? .notCovered : .answered, links: links)
            }
        } else if let card = unavailableCard {
            level = card.level.rawValue
            r = Retrieval(passages: [], note: Retriever.unavailableNote, decision: .notCovered)
        } else {
            switch gated {
            case .hadithRequest:
                r = Retrieval(passages: [], note: Retriever.hadithNote, decision: .referred)
            case .personal:
                level = "D"
                let passages = (infoCard.flatMap { c in sources.map { CardRetriever.passages(for: c, sources: $0, corpus: corpus) } }) ?? []
                r = Retrieval(passages: passages, note: passages.isEmpty ? Retriever.rulingNote : Retriever.personalNote, decision: .referred)
            case .qualifiedRuling, .plainRuling:
                r = Retrieval(passages: [], note: Retriever.rulingNote, decision: .referred)
            case .none:
                var base = Retriever(corpus: corpus).retrieve(route: finalRoute, anchorAyah: anchorAyah)
                if let term = termCardForWord, let s = sources, base.decision == .answered {
                    // Word route about a term the ayah itself contains: the ayah passages, then the term card's.
                    base = Retrieval(passages: base.passages + CardRetriever.passages(for: term, sources: s, corpus: corpus).filter { $0.source == .jamharaEnglish },
                                     note: base.note, decision: base.decision, links: base.links)
                    level = term.level.rawValue
                }
                r = base
                links = base.links
            }
        }
        var decision = r.decision
        if (decision == .answered || decision == .answeredInPart) && r.passages.isEmpty { decision = .declined }
        let answersWithPassages = decision == .answered || decision == .answeredInPart
        // Referred-with-general-information shows passages too, but never a lead.
        let showsPassages = answersWithPassages || (decision == .referred && !r.passages.isEmpty)

        var lead = ""
        var leadStatus = "none: no lead writer"
        // Headset test 5 Oct: the lead was 2-6 s of every wait and is rejected on these routes
        // almost every time (0/36 accepted on the general route that day), so it is not asked for.
        // Kept for meaning and word, the routes that explain the ayah on screen.
        if answersWithPassages, leadWriter != nil, Self.leadSkippedRoutes.contains(finalRoute) {
            leadStatus = "none: skipped"
            Self.logger.notice("Lead skipped on the \(finalRoute.rawValue, privacy: .public) route")
            Self.logger.notice("Ask timing: route \(routeMs) ms, card selection \(selectMs) ms, lead 0 ms (skipped)")
        } else if answersWithPassages, let writer = leadWriter {
            let leadStart = clock.now
            do {
                let candidate = try await writer.lead(question: question, passages: r.passages, anchorAyah: anchorAyah, route: finalRoute)
                switch LeadVerifier.verify(lead: candidate, passages: r.passages, question: question, anchorAyah: anchorAyah, route: finalRoute) {
                case .accepted: lead = candidate; leadStatus = "accepted"
                case .rejected(let reason): leadStatus = "rejected: \(reason)"
                }
            } catch {
                leadStatus = "error: \(error)"
            }
            let leadMs = Self.milliseconds(leadStart.duration(to: clock.now))
            Self.logger.notice("Lead by \(writer.name, privacy: .public): \(leadStatus, privacy: .public) in \(leadMs) ms")
            Self.logger.notice("Ask timing: route \(routeMs) ms, card selection \(selectMs) ms, lead \(leadMs) ms")
        } else if !answersWithPassages {
            leadStatus = "none: \(decision.rawValue)"
        }

        return Answer(question: question, anchorAyah: anchorAyah, route: finalRoute, router: routerName,
                      decision: decision, lead: lead, leadStatus: leadStatus,
                      passages: showsPassages ? r.passages : [],
                      citations: showsPassages ? r.passages.map(\.id) : [], note: r.note,
                      card: selectedCard?.id ?? unavailableCard?.id ?? infoCard?.id ?? termCardForWord?.id, level: level, links: links)
    }
}
