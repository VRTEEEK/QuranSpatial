import Testing
@testable import AskCore

/// Day 4: the router the app and qs-ask run is the hybrid, with the safety gate in front. These
/// pin the factory's type and that ruling questions are decided by the gate before any model is
/// consulted - the deterministic stage alone, so no model is needed and nothing here is flaky.
struct RouterFactoryTests {
    @Test func standardRouterIsTheHybrid() {
        let r = AskRouters.standard()
        #expect(r is HybridRouter)
        #expect(r is any AttributingRouter)
        #expect(r.name.hasPrefix("hybrid("))
    }

    @Test(arguments: [
        "is alcohol haram",
        "my marriage has these circumstances is it valid",
    ])
    func rulingQuestionsAreDecidedByTheSafetyGate(_ q: String) async throws {
        // The deterministic stage alone: gate, fragment, high-confidence rules. No model.
        let stage = HybridRouter.deterministicStage(q)
        #expect(stage == AttributedRoute(route: .ruling, decidedBy: "safety-gate"), "\(q)")
        // And through the factory's router as the engine calls it. The gate decides before the
        // model stage is reached, so this does not touch Foundation Models whether or not it is
        // available on this machine.
        let r = try #require(AskRouters.standard() as? any AttributingRouter)
        let a = try await r.routeAttributed(q, anchorAyah: 13)
        #expect(a == AttributedRoute(route: .ruling, decidedBy: "safety-gate"), "\(q)")
    }
}
