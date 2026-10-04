import Testing
@testable import AskCore

/// The gate is biased to refer. These pin what it must catch and what it must leave alone.
struct SafetyGateTests {
    let gate = RulingSafetyGate()

    @Test(arguments: [
        "is it haram to skip this ayah when reciting",
        "am i allowed to read this without wudu",
        "is it permissible to write this on a wall",
        "can i recite this surah while lying down",
        "my boss asked me to short the scale a little is that a sin",
        "i missed fajr today what should i do",
        "do i have to prostrate here",
        "is it ok to listen to this while driving",
        "whats the ruling on fasting while travelling",
        "is interest on my mortgage covered by the balance verse",
    ])
    func refersRulingAndPersonalSituations(_ q: String) {
        #expect(gate.looksLikeRuling(q), "\(q)")
    }

    @Test(arguments: [
        "what does this ayah mean",
        "why does this verse repeat so many times",
        "what is the word for balance here",
        "where else are the two gardens mentioned",
        "um the the",
        "what is the weather in riyadh",
    ])
    func leavesOrdinaryQuestionsAlone(_ q: String) {
        #expect(!gate.looksLikeRuling(q), "\(q)")
    }

    @Test func gatedRouterReturnsRulingBeforeTheInnerRouterIsAsked() async throws {
        let r = SafetyGatedRouter(RuleBasedRouter())
        #expect(r.name == "safety+rules")
        #expect(try await r.route("my wife says i have to pray this is that right", anchorAyah: 13) == .ruling)
        #expect(try await r.route("what does this ayah mean", anchorAyah: 13) == .meaning)
    }

    @Test func hybridUsesHighConfidenceRulesThenTheModelThenRules() async throws {
        let h = HybridRouter(model: nil)
        #expect(h.name == "hybrid(no-model)")
        #expect(HybridRouter.highConfidenceRoute("why does this keep repeating") == .repetition)
        #expect(HybridRouter.highConfidenceRoute("where else does this come up") == .related)
        #expect(HybridRouter.highConfidenceRoute("what does the word deny mean") == .word)
        #expect(HybridRouter.highConfidenceRoute("can you make the text bigger") == .offTopic)
        #expect(HybridRouter.highConfidenceRoute("what is this ayah about") == nil)
        // An off-topic cue inside an on-topic question is not decided by the rules.
        #expect(HybridRouter.highConfidenceRoute("is this verse about a game between jinn and men") == nil)
        #expect(try await h.route("is it haram to do this", anchorAyah: 13) == .ruling)
        #expect(try await h.route("what is this ayah about", anchorAyah: 13) == .meaning)
    }
}
