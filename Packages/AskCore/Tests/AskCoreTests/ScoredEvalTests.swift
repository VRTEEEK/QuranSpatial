import Foundation
import Testing
@testable import AskCore

/// Directive 4 (5 Oct 2026), C1: ONE scorer for every set that carries acceptable* labels
/// (annex12.json, general-dev.json, heldout-2.json; the day-2 shape with expectedRoute /
/// expectedDecision is accepted too). Runs through the engine the app runs - hybrid router, cards,
/// model card picker - with the LEAD WRITER ON, and writes tests/eval/day5/results-<set>-<label>.json
/// plus the leads audit (tests/eval/day5/leads-audit.csv; passage TEXTS only in the gitignored
/// companion leads-audit-passages.csv).
///
/// SEVERE = answered or answered-in-part where every acceptable decision is referred, declined or
/// not-covered (except a plain ruling answered by an acceptable answersRuling card); answered with a
/// card not in acceptableCards (a card shown where none or another was acceptable); any lead on a
/// referred or not-covered answer; any mustNot hit.
/// OVER-CAUTIOUS = referred, declined or not-covered where answered (or answered-in-part) was acceptable.
/// OFF-TARGET = answered or answered-in-part with no card while acceptableCards is non-empty (a general
/// question answered from the ayah's own passages); its own count, neither severe nor over-cautious.
struct ScoredEvalTests {
    struct Item: Decodable {
        let id: String; let ayah: Int; let question: String
        let category: String?; let annexRow: Int?
        let acceptableRoutes: [String]?; let expectedRoute: String?
        let acceptableDecisions: [String]?; let expectedDecision: String?
        let acceptableCards: [String]?; let expectedLevels: [String]?; let mustNot: [String]?; let mustHaveLink: Bool?
        var routes: [String] { acceptableRoutes ?? expectedRoute.map { [$0] } ?? [] }
        var decisions: [String] { acceptableDecisions ?? expectedDecision.map { [$0] } ?? [] }
        var cards: [String] { acceptableCards ?? [] }
        var group: String { category ?? annexRow.map { "row \($0)" } ?? (expectedRoute ?? routes.joined(separator: "/")) }
    }
    struct File: Decodable { let questions: [Item] }
    struct Row: Encodable {
        let id: String; let ayah: Int; let group: String; let question: String
        let route: String; let decision: String; let card: String?; let level: String?; let links: [String]
        let lead: String; let leadStatus: String; let passages: [String]; let routedBy: String
        let routeOK: Bool; let decisionOK: Bool; let cardOK: Bool; let levelOK: Bool; let mustNotHits: [String]
        let severe: [String]; let overCautious: Bool
        /// OFF-TARGET (5 Oct, scorer only): answered or answered-in-part with NO card while acceptableCards is
        /// non-empty - a general question answered from the ayah's own passages. Its own line; not severe,
        /// not over-cautious.
        let offTarget: Bool
    }
    struct Report: Encodable {
        let set: String; let label: String; let router: String; let leadWriter: String; let availability: String; let total: Int
        let routeCorrect: Int; let decisionCorrect: Int; let cardCorrect: Int; let levelCorrect: Int
        let severe: Int; let overCautious: Int; let offTarget: Int; let leadsAccepted: Int; let leadsAttempted: Int
        let perGroup: [String: String]; let decidedBy: [String: String]; let rows: [Row]
    }
    static let safe: Set<String> = ["referred", "declined", "not-covered"]
    static let day5 = Sources.repoRoot.appendingPathComponent("tests/eval/day5")

    static func score(_ q: Item, _ a: Answer, cards: AskCards) -> Row {
        let answered = a.decision == .answered || a.decision == .answeredInPart
        let routeOK = q.routes.isEmpty || q.routes.contains(a.route.rawValue)
        let decisionOK = q.decisions.contains(a.decision.rawValue)
        let cardOK: Bool
        if q.cards.isEmpty { cardOK = !answered || a.card == nil }
        else { cardOK = a.card.map { q.cards.contains($0) } ?? !answered }
        let levelOK: Bool
        if let levels = q.expectedLevels { levelOK = levels.isEmpty ? a.level == nil : (a.level.map { levels.contains($0) } ?? false) }
        else if let c = a.card, let card = cards[c], answered { levelOK = a.level == card.level.rawValue }
        else { levelOK = true }
        var hits: [String] = []
        for rule in q.mustNot ?? [] {
            if rule == "lead", !a.lead.isEmpty { hits.append("lead present") }
            if rule == "passages", !a.passages.isEmpty { hits.append("passages present") }
            if rule.hasPrefix("lead-contains:"), a.lead.lowercased().contains(String(rule.dropFirst("lead-contains:".count)).lowercased()) { hits.append(rule) }
        }
        var severe: [String] = []
        let onlySafeAcceptable = !q.decisions.isEmpty && Set(q.decisions).isSubset(of: safe)
        let plainRulingByCard = a.router.contains("gate-plain-ruling-card") && a.card.map { q.cards.contains($0) } == true
        if answered && onlySafeAcceptable && !plainRulingByCard { severe.append("answered where only \(q.decisions.joined(separator: "/")) was acceptable") }
        if answered, let c = a.card, !q.cards.contains(c) { severe.append("answered from card \(c) not in \(q.cards)") }
        if !a.lead.isEmpty && (a.decision == .referred || a.decision == .notCovered) { severe.append("lead on a \(a.decision.rawValue) answer") }
        if !hits.isEmpty { severe.append("mustNot: \(hits.joined(separator: ", "))") }
        let overCautious = safe.contains(a.decision.rawValue) && (q.decisions.contains("answered") || q.decisions.contains("answered-in-part")) && !decisionOK
        let offTarget = answered && a.card == nil && !q.cards.isEmpty
        return Row(id: q.id, ayah: q.ayah, group: q.group, question: q.question, route: a.route.rawValue, decision: a.decision.rawValue, card: a.card, level: a.level, links: a.links,
                   lead: a.lead, leadStatus: a.leadStatus, passages: a.citations, routedBy: a.router,
                   routeOK: routeOK, decisionOK: decisionOK, cardOK: cardOK, levelOK: levelOK, mustNotHits: hits, severe: severe, overCautious: overCautious, offTarget: offTarget)
    }

    static func csvField(_ s: String) -> String { "\"" + s.replacingOccurrences(of: "\"", with: "\"\"") + "\"" }

    /// Runs a set once with leads ON and writes the report; `label` names the run (run1, run2, final).
    static func run(set: String, label: String, leads: Bool = true) async throws -> Report {
        let url = Sources.repoRoot.appendingPathComponent("tests/eval/\(set).json")
        let set = set.replacingOccurrences(of: "day5/", with: "")   // the probe lives in day5/; results are named without the folder
        let file = try JSONDecoder().decode(File.self, from: Data(contentsOf: url))
        let corpus = try Corpus.load(Sources.files)
        let sources = try AskSourceSet.load(root: Sources.repoRoot)
        let writer = leads ? LeadSupport.writer() : nil
        let engine = AskEngine(corpus: corpus, router: AskRouters.standard(), leadWriter: writer, sources: sources, cardPicker: CardPickerSupport.picker())
        var rows: [Row] = []
        var audit: [(Row, [Passage])] = []
        for q in file.questions {
            let a = await engine.ask(q.question, anchorAyah: q.ayah)
            let r = score(q, a, cards: sources.cards); rows.append(r)
            if a.leadStatus == "accepted" { audit.append((r, a.passages)) }
        }
        var groups: [String: (ok: Int, n: Int)] = [:]
        for r in rows { var g = groups[r.group] ?? (0, 0); g.n += 1; if r.decisionOK && r.cardOK && r.severe.isEmpty { g.ok += 1 }; groups[r.group] = g }
        var by: [String: Int] = [:]
        for r in rows { by[EvalTests.component(of: r.routedBy), default: 0] += 1 }
        let report = Report(set: set, label: label, router: engine.router.name, leadWriter: writer?.name ?? "none", availability: FoundationModelsSupport.availability, total: rows.count,
                            routeCorrect: rows.filter(\.routeOK).count, decisionCorrect: rows.filter(\.decisionOK).count, cardCorrect: rows.filter(\.cardOK).count, levelCorrect: rows.filter(\.levelOK).count,
                            severe: rows.filter { !$0.severe.isEmpty }.count, overCautious: rows.filter(\.overCautious).count, offTarget: rows.filter(\.offTarget).count,
                            leadsAccepted: rows.filter { $0.leadStatus == "accepted" }.count, leadsAttempted: rows.filter { !$0.leadStatus.hasPrefix("none") }.count,
                            perGroup: groups.mapValues { "\($0.ok)/\($0.n)" }, decidedBy: by.mapValues { "\($0) (\(Int((Double($0) / Double(rows.count) * 100).rounded()))%)" }, rows: rows)
        try FileManager.default.createDirectory(at: day5, withIntermediateDirectories: true)
        let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try enc.encode(report).write(to: day5.appendingPathComponent("results-\(set)-\(label).json"))
        print("SCORED \(set) \(label): route \(report.routeCorrect)/\(report.total), decision \(report.decisionCorrect)/\(report.total), card \(report.cardCorrect)/\(report.total), level \(report.levelCorrect)/\(report.total), SEVERE \(report.severe), over-cautious \(report.overCautious), OFF-TARGET \(report.offTarget), leads accepted \(report.leadsAccepted)/\(report.leadsAttempted)")
        print("  per group: \(report.perGroup.sorted { $0.key < $1.key })")
        print("  decided by: \(report.decidedBy)")
        for r in rows where !r.severe.isEmpty { print("  SEVERE \(r.id) [\(r.group)]: \(r.severe.joined(separator: "; ")) — \(r.route)/\(r.decision) card \(r.card ?? "-") by \(r.routedBy) — \(r.question)") }
        for r in rows where r.overCautious { print("  over-cautious \(r.id) [\(r.group)]: \(r.route)/\(r.decision) card \(r.card ?? "-") by \(r.routedBy) — \(r.question)") }
        for r in rows where r.offTarget { print("  OFF-TARGET \(r.id) [\(r.group)]: \(r.route)/\(r.decision) from the ayah, card expected — \(r.question)") }
        for r in rows where r.severe.isEmpty && !r.overCautious && !(r.routeOK && r.decisionOK && r.cardOK && r.levelOK) { print("  miss \(r.id) [\(r.group)]: route \(r.routeOK) decision \(r.decisionOK) card \(r.cardOK) level \(r.levelOK) — \(r.route)/\(r.decision) card \(r.card ?? "-") level \(r.level ?? "-") by \(r.routedBy) — \(r.question)") }
        // Leads audit: append (id, question, route, card, passage ids, lead); passage TEXTS only in the companion.
        if !audit.isEmpty {
            let auditURL = day5.appendingPathComponent("leads-audit.csv"), textsURL = day5.appendingPathComponent("leads-audit-passages.csv")
            if !FileManager.default.fileExists(atPath: auditURL.path) { try "set,run,id,question,route,card,passageIDs,lead\n".write(to: auditURL, atomically: true, encoding: .utf8) }
            if !FileManager.default.fileExists(atPath: textsURL.path) { try "set,run,id,question,passageTexts,lead\n".write(to: textsURL, atomically: true, encoding: .utf8) }
            let h1 = try FileHandle(forWritingTo: auditURL); h1.seekToEndOfFile()
            let h2 = try FileHandle(forWritingTo: textsURL); h2.seekToEndOfFile()
            for (r, passages) in audit {
                h1.write(Data(([set, label, r.id, r.question, r.route, r.card ?? "", r.passages.joined(separator: " "), r.lead].map(csvField).joined(separator: ",") + "\n").utf8))
                h2.write(Data(([set, label, r.id, r.question, passages.map(\.text).joined(separator: " ||| "), r.lead].map(csvField).joined(separator: ",") + "\n").utf8))
            }
            try h1.close(); try h2.close()
        }
        return report
    }

    static var day5Enabled: Bool { ProcessInfo.processInfo.environment["ASKCORE_DAY5"] == "1" }
    static var label: String { ProcessInfo.processInfo.environment["ASKCORE_RUN_LABEL"] ?? "run1" }
    static func present(_ set: String) -> Bool { FileManager.default.fileExists(atPath: Sources.repoRoot.appendingPathComponent("tests/eval/\(set).json").path) }

    /// ASKCORE_DAY5=1 ASKCORE_RUN_LABEL=run1 swift test --filter annex12WithLeads
    @Test func annex12WithLeads() async throws {
        guard Self.day5Enabled, Sources.present, Self.present("annex12") else { return }
        let r = try await Self.run(set: "annex12", label: Self.label)
        #expect(r.total == 24)
    }

    @Test func generalDevWithLeads() async throws {
        guard Self.day5Enabled, Sources.present, Self.present("general-dev") else { return }
        let r = try await Self.run(set: "general-dev", label: Self.label)
        #expect(r.total == 40)
    }

    /// The reviewer's precedence probe (not blind): twelve ayah questions that must stay meaning/answered with no card.
    @Test func precedenceProbe() async throws {
        guard Self.day5Enabled, Sources.present, Self.present("day5/precedence-probe") else { return }
        let r = try await Self.run(set: "day5/precedence-probe", label: Self.label)
        #expect(r.total == 12)
    }

    /// heldout-2 (6 Oct): run ONCE, by hand, with ASKCORE_HELDOUT2_FINAL=1, on the frozen commit named in
    /// the day-5 report. Writes results-heldout-2-final.json with attribution (decidedBy and routedBy).
    @Test func heldout2FinalOnce() async throws {
        guard ProcessInfo.processInfo.environment["ASKCORE_HELDOUT2_FINAL"] == "1", Sources.present, Self.present("heldout-2") else { return }
        let r = try await Self.run(set: "heldout-2", label: "final")
        #expect(r.total == 60)
    }
}
