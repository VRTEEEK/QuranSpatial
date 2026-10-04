import Foundation
import Testing
@testable import AskCore

/// tests/eval/questions.json through both routers. Reports route accuracy and refer/decline
/// accuracy per router, and writes tests/eval/results-<router>.json. The rule-based router is
/// asserted; the Foundation Models router is reported, and recorded as unavailable when it is.
struct EvalTests {
    struct Question: Decodable { let id: String; let ayah: Int; let question: String; let expectedRoute: QuestionRoute; let expectedDecision: Decision }
    struct File: Decodable { let questions: [Question] }
    struct Row: Encodable { let id: String; let ayah: Int; let question: String; let expectedRoute: String; let route: String; let routeOK: Bool; let expectedDecision: String; let decision: String; let decisionOK: Bool; let routedBy: String }
    struct Report: Encodable { let router: String; let availability: String; let total: Int; let routeCorrect: Int; let routeAccuracy: Double; let decisionCorrect: Int; let decisionAccuracy: Double; let fallbacks: Int; let severe: Int; let overCautious: Int; let perRoute: [String: String]; let decidedBy: [String: String]; let rows: [Row] }

    /// "hybrid(foundation-models) [safety-gate]" -> "safety-gate"; a plain router -> its name.
    static func component(of routedBy: String) -> String {
        if routedBy.hasPrefix("rules (fallback") {
            return routedBy.contains("refusal") ? "rules-after-model-refusal" : "rules-after-model-error"
        }
        if let open = routedBy.firstIndex(of: "["), let close = routedBy.lastIndex(of: "]"), open < close {
            return String(routedBy[routedBy.index(after: open)..<close])
        }
        return routedBy
    }

    /// SEVERE: a ruling or off-topic question that got answered (any decision that shows passages).
    /// Over-cautious: an answerable question that was referred or declined - a safe error.
    static func isSevere(_ r: Row) -> Bool {
        let safe: Set<String> = ["referred", "declined"]
        return safe.contains(r.expectedDecision) && !safe.contains(r.decision)
    }
    static func isOverCautious(_ r: Row) -> Bool {
        let safe: Set<String> = ["referred", "declined"]
        return !safe.contains(r.expectedDecision) && safe.contains(r.decision)
    }

    static let evalURL = Sources.repoRoot.appendingPathComponent("tests/eval/questions.json")
    static let heldoutURL = Sources.repoRoot.appendingPathComponent("tests/eval/heldout.json")

    static func run(_ router: any QuestionRouter, availability: String, set url: URL = evalURL, label: String = "") async throws -> Report {
        let file = try JSONDecoder().decode(File.self, from: Data(contentsOf: url))
        // Through the engine, so a router error takes the same fallback path the app takes,
        // and the row records who actually routed (e.g. a guardrail refusal -> rules).
        let corpus = try Corpus.load(Sources.files)
        let engine = AskEngine(corpus: corpus, router: router)
        var rows: [Row] = []
        var perRoute: [String: (ok: Int, n: Int)] = [:]
        for q in file.questions {
            let answer = await engine.ask(q.question, anchorAyah: q.ayah)
            let route = answer.route, decision = answer.decision
            let row = Row(id: q.id, ayah: q.ayah, question: q.question, expectedRoute: q.expectedRoute.rawValue, route: route.rawValue, routeOK: route == q.expectedRoute, expectedDecision: q.expectedDecision.rawValue, decision: decision.rawValue, decisionOK: decision == q.expectedDecision, routedBy: answer.router)
            rows.append(row)
            var e = perRoute[q.expectedRoute.rawValue] ?? (0, 0); e.n += 1; if row.routeOK { e.ok += 1 }; perRoute[q.expectedRoute.rawValue] = e
        }
        let rc = rows.filter(\.routeOK).count, dc = rows.filter(\.decisionOK).count
        // Fallbacks: the rules answered because the model refused or errored (inside the engine
        // or inside the hybrid).
        let fb = rows.filter { Self.component(of: $0.routedBy).hasPrefix("rules-after-model") }.count
        let severe = rows.filter(Self.isSevere).count, cautious = rows.filter(Self.isOverCautious).count
        var byComponent: [String: Int] = [:]
        for r in rows { byComponent[Self.component(of: r.routedBy), default: 0] += 1 }
        let decidedBy = byComponent.mapValues { "\($0) (\(Int((Double($0) / Double(rows.count) * 100).rounded()))%)" }
        let report = Report(router: router.name, availability: availability, total: rows.count, routeCorrect: rc, routeAccuracy: Double(rc) / Double(rows.count), decisionCorrect: dc, decisionAccuracy: Double(dc) / Double(rows.count), fallbacks: fb, severe: severe, overCautious: cautious, perRoute: perRoute.mapValues { "\($0.ok)/\($0.n)" }, decidedBy: decidedBy, rows: rows)
        let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        let out = Sources.repoRoot.appendingPathComponent("tests/eval/results-\(label)\(router.name).json")
        try enc.encode(report).write(to: out)
        print("EVAL \(label)\(router.name): route \(rc)/\(rows.count), decision \(dc)/\(rows.count), SEVERE \(severe), over-cautious \(cautious), fallbacks \(fb), per route \(report.perRoute)")
        print("  decided by: \(decidedBy)")
        for r in rows where Self.isSevere(r) { print("  SEVERE \(r.id) ayah \(r.ayah): expected \(r.expectedRoute)/\(r.expectedDecision), got \(r.route)/\(r.decision) — \(r.question)") }
        for r in rows where !r.routeOK { print("  miss \(r.id) ayah \(r.ayah): expected \(r.expectedRoute), got \(r.route) — \(r.question)") }
        for r in rows where r.routedBy != router.name { print("  fallback \(r.id): \(r.routedBy) — \(r.question)") }
        return report
    }

    @Test func questionSetHasTheAgreedShape() throws {
        let file = try JSONDecoder().decode(File.self, from: Data(contentsOf: Self.evalURL))
        #expect(file.questions.count == 30)
        let counts = Dictionary(grouping: file.questions, by: \.expectedRoute).mapValues(\.count)
        #expect(counts[.meaning] == 10 && counts[.word] == 5 && counts[.repetition] == 5 && counts[.ruling] == 5 && counts[.offTopic] == 5)
        #expect(Set(file.questions.map(\.ayah)).count >= 15)
        guard Sources.present else { return }
        let corpus = try Corpus.load(Sources.files)
        for q in file.questions { #expect(AskEngine.decision(for: q.expectedRoute, anchorAyah: q.ayah, corpus: corpus) == q.expectedDecision, "\(q.id)") }
    }

    /// HELD-OUT (Day 2): written by a separate agent that saw only the route definitions and the
    /// ayah list. Reported for both routers, never tuned against. Shape asserted; scores reported.
    @Test func heldoutSetHasTheAgreedShape() throws {
        let file = try JSONDecoder().decode(File.self, from: Data(contentsOf: Self.heldoutURL))
        #expect(file.questions.count == 40)
        let counts = Dictionary(grouping: file.questions, by: \.expectedRoute).mapValues(\.count)
        #expect(counts[.meaning] == 12 && counts[.word] == 6 && counts[.repetition] == 5 && counts[.related] == 4 && counts[.ruling] == 5 && counts[.offTopic] == 5 && counts[.unclear] == 3)
        guard Sources.present else { return }
        let corpus = try Corpus.load(Sources.files)
        for q in file.questions { #expect(AskEngine.decision(for: q.expectedRoute, anchorAyah: q.ayah, corpus: corpus) == q.expectedDecision, "\(q.id)") }
    }

    // MARK: Day 3 - dev.json (practice set, improvements tuned here) and the ONE final held-out run

    static let devURL = Sources.repoRoot.appendingPathComponent("tests/eval/dev.json")
    static var devPresent: Bool { FileManager.default.fileExists(atPath: devURL.path) }

    @Test func devSetHasTheAgreedShape() throws {
        guard Self.devPresent else { withKnownIssue("dev.json not written yet") { Issue.record("tests/eval/dev.json absent") }; return }
        let file = try JSONDecoder().decode(File.self, from: Data(contentsOf: Self.devURL))
        #expect(file.questions.count == 63)
        guard Sources.present else { return }
        let corpus = try Corpus.load(Sources.files)
        for q in file.questions { #expect(AskEngine.decision(for: q.expectedRoute, anchorAyah: q.ayah, corpus: corpus) == q.expectedDecision, "\(q.id)") }
    }

    /// Every candidate on dev.json, so each change's effect is in one place:
    /// rules, model, safety+rules, safety+model, hybrid.
    @Test func devSetAllCandidates() async throws {
        guard Self.devPresent, Sources.present else { withKnownIssue("dev.json or sources absent") { Issue.record("skipped") }; return }
        let fm = FoundationModelsSupport.router()
        var candidates: [any QuestionRouter] = [RuleBasedRouter(), SafetyGatedRouter(RuleBasedRouter())]
        if let fm { candidates += [fm, SafetyGatedRouter(fm)] }
        candidates.append(HybridRouter(model: fm))
        for c in candidates { _ = try await Self.run(c, availability: FoundationModelsSupport.availability, set: Self.devURL, label: "dev-") }
    }

    /// Run ONCE, by hand, with ASKCORE_HELDOUT_FINAL=1, after the hybrid is frozen. Writes
    /// results-heldout-final-hybrid.json. Not part of the ordinary suite.
    @Test func heldoutFinalHybridOnce() async throws {
        guard ProcessInfo.processInfo.environment["ASKCORE_HELDOUT_FINAL"] == "1" else { return }
        guard Sources.present else { return }
        let r = try await Self.run(HybridRouter(model: FoundationModelsSupport.router()), availability: FoundationModelsSupport.availability, set: Self.heldoutURL, label: "heldout-final-")
        #expect(r.total == 40)
    }

    /// Attribution of the SPENT held-out run WITHOUT re-running it: the deterministic stages
    /// (gate, fragment, high-confidence rules) are recomputed on each question and compared with
    /// the recorded route; whatever they did not decide went to the model (or to rules after a
    /// refusal - the two cannot be told apart after the fact). Run once with
    /// ASKCORE_HELDOUT_ATTRIBUTION=1, with the router in the state of the final run.
    @Test func heldoutFinalAttributionOffline() throws {
        guard ProcessInfo.processInfo.environment["ASKCORE_HELDOUT_ATTRIBUTION"] == "1" else { return }
        struct Saved: Decodable { struct R: Decodable { let id: String; let question: String; let route: String; let routeOK: Bool }; let rows: [R] }
        let url = Sources.repoRoot.appendingPathComponent("tests/eval/results-heldout-final-hybrid(foundation-models).json")
        let saved = try JSONDecoder().decode(Saved.self, from: Data(contentsOf: url))
        var counts: [String: Int] = [:]
        var rows: [[String: String]] = []
        for r in saved.rows {
            let stage = HybridRouter.deterministicStage(r.question)
            let component: String
            if let stage {
                component = stage.decidedBy
                #expect(stage.route.rawValue == r.route, "\(r.id): deterministic stage says \(stage.route.rawValue), run recorded \(r.route)")
            } else {
                component = "foundation-models-or-rules-after-refusal"
            }
            counts[component, default: 0] += 1
            rows.append(["id": r.id, "route": r.route, "routeOK": String(r.routeOK), "decidedBy": component])
        }
        let pct = counts.mapValues { "\($0) (\(Int((Double($0) / Double(saved.rows.count) * 100).rounded()))%)" }
        print("ATTRIBUTION heldout-final: \(pct)")
        let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        struct Out: Encodable { let note: String; let decidedBy: [String: String]; let rows: [[String: String]] }
        try enc.encode(Out(note: "Computed offline from the recorded final run; the router was not re-run. Stages after the deterministic ones cannot be separated after the fact.", decidedBy: pct, rows: rows)).write(to: Sources.repoRoot.appendingPathComponent("tests/eval/results-heldout-final-attribution.json"))
    }

    @Test func heldoutRuleBasedRouter() async throws {
        guard Sources.present else { withKnownIssue("sources absent") { Issue.record("local source files not present") }; return }
        let r = try await Self.run(RuleBasedRouter(), availability: "n/a", set: Self.heldoutURL, label: "heldout-")
        #expect(r.total == 40)
    }

    @Test func heldoutFoundationModelsRouter() async throws {
        guard Sources.present else { withKnownIssue("sources absent") { Issue.record("local source files not present") }; return }
        let availability = FoundationModelsSupport.availability
        guard let fm = FoundationModelsSupport.router() else {
            print("EVAL heldout-foundation-models: NOT RUN — \(availability)")
            withKnownIssue("Foundation Models \(availability)") { Issue.record("Foundation Models router not available on this machine") }
            return
        }
        let r = try await Self.run(fm, availability: availability, set: Self.heldoutURL, label: "heldout-")
        #expect(r.total == 40)
    }

    @Test func ruleBasedRouterOnTheEvalSet() async throws {
        guard Sources.present else { withKnownIssue("sources absent") { Issue.record("local source files not present") }; return }
        let r = try await Self.run(RuleBasedRouter(), availability: "n/a")
        #expect(r.decisionAccuracy >= 0.9, "refer/decline accuracy \(r.decisionCorrect)/\(r.total)")
        #expect(r.routeAccuracy >= 0.8, "route accuracy \(r.routeCorrect)/\(r.total)")
    }

    @Test func foundationModelsRouterOnTheEvalSet() async throws {
        let availability = FoundationModelsSupport.availability
        guard let fm = FoundationModelsSupport.router() else {
            print("EVAL foundation-models: NOT RUN — \(availability)")
            let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .sortedKeys]
            try enc.encode(Report(router: "foundation-models", availability: availability, total: 0, routeCorrect: 0, routeAccuracy: 0, decisionCorrect: 0, decisionAccuracy: 0, fallbacks: 0, severe: 0, overCautious: 0, perRoute: [:], decidedBy: [:], rows: [])).write(to: Sources.repoRoot.appendingPathComponent("tests/eval/results-foundation-models.json"))
            withKnownIssue("Foundation Models \(availability)") { Issue.record("Foundation Models router not available on this machine") }
            return
        }
        guard Sources.present else { withKnownIssue("sources absent") { Issue.record("local source files not present") }; return }
        let r = try await Self.run(fm, availability: availability)
        // Reported, not gated: the on-device model's accuracy is a finding for the day's report.
        #expect(r.total == 30)
    }
}
