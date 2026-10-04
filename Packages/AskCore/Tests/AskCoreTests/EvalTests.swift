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
    struct Report: Encodable { let router: String; let availability: String; let total: Int; let routeCorrect: Int; let routeAccuracy: Double; let decisionCorrect: Int; let decisionAccuracy: Double; let fallbacks: Int; let perRoute: [String: String]; let rows: [Row] }

    static let evalURL = Sources.repoRoot.appendingPathComponent("tests/eval/questions.json")

    static func run(_ router: any QuestionRouter, availability: String) async throws -> Report {
        let file = try JSONDecoder().decode(File.self, from: Data(contentsOf: evalURL))
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
        let fb = rows.filter { $0.routedBy != router.name }.count
        let report = Report(router: router.name, availability: availability, total: rows.count, routeCorrect: rc, routeAccuracy: Double(rc) / Double(rows.count), decisionCorrect: dc, decisionAccuracy: Double(dc) / Double(rows.count), fallbacks: fb, perRoute: perRoute.mapValues { "\($0.ok)/\($0.n)" }, rows: rows)
        let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        let out = Sources.repoRoot.appendingPathComponent("tests/eval/results-\(router.name).json")
        try enc.encode(report).write(to: out)
        print("EVAL \(router.name): route \(rc)/\(rows.count), decision \(dc)/\(rows.count), fallbacks \(fb), per route \(report.perRoute)")
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
        for q in file.questions { #expect(AskEngine.decision(for: q.expectedRoute) == q.expectedDecision) }
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
            try enc.encode(Report(router: "foundation-models", availability: availability, total: 0, routeCorrect: 0, routeAccuracy: 0, decisionCorrect: 0, decisionAccuracy: 0, fallbacks: 0, perRoute: [:], rows: [])).write(to: Sources.repoRoot.appendingPathComponent("tests/eval/results-foundation-models.json"))
            withKnownIssue("Foundation Models \(availability)") { Issue.record("Foundation Models router not available on this machine") }
            return
        }
        guard Sources.present else { withKnownIssue("sources absent") { Issue.record("local source files not present") }; return }
        let r = try await Self.run(fm, availability: availability)
        // Reported, not gated: the on-device model's accuracy is a finding for the day's report.
        #expect(r.total == 30)
    }
}
