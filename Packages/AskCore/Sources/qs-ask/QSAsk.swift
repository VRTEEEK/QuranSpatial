//
//  qs-ask - command-line "Ask" for the judges.
//
//    qs-ask --ayah 13 "why does this repeat?" [--router auto|hybrid|fm|rules] [--repo PATH] [--json-only]
//
//  Prints the answer as JSON, then as readable text. Exit 0 on an answer of any decision,
//  2 on a usage error, 3 when the source files are missing.
//

import AskCore
import Foundation

@main
struct QSAsk {
    static func usage() -> Never {
        FileHandle.standardError.write(Data("""
        usage: qs-ask --ayah N "question" [--router auto|hybrid|fm|rules] [--no-lead] [--repo PATH] [--json-only]
          --ayah N      the ayah of Surah 55 on screen (1-78)
          --router      auto (default; the router the app runs: safety gate, then high-confidence rules, then
                        Foundation Models if available, else rules), hybrid (alias of auto), fm (model alone),
                        or rules (rules alone) - fm and rules are for comparison only
          --no-lead     do not ask the model for a lead (default: a lead when Foundation Models is available)
          --repo PATH   repository root (default: found by walking up from the current directory)
          --json-only   print only the JSON

        """.utf8))
        exit(2)
    }

    static func main() async {
        var args = Array(CommandLine.arguments.dropFirst())
        var ayah: Int? = nil, routerChoice = "auto", repo: String? = nil, jsonOnly = false, wantLead = true
        var question: String? = nil
        while !args.isEmpty {
            let a = args.removeFirst()
            switch a {
            case "--ayah": guard let v = args.first, let n = Int(v) else { usage() }; args.removeFirst(); ayah = n
            case "--router": guard let v = args.first else { usage() }; args.removeFirst(); routerChoice = v
            case "--repo": guard let v = args.first else { usage() }; args.removeFirst(); repo = v
            case "--json-only": jsonOnly = true
            case "--no-lead": wantLead = false
            case "-h", "--help": usage()
            default: if question == nil { question = a } else { question! += " " + a }
            }
        }
        guard let ayah, (1...78).contains(ayah), let question, !question.isEmpty else { usage() }

        let files: SourceFiles?
        if let repo { files = SourceFiles.inRepository(root: URL(fileURLWithPath: repo)) } else { files = SourceFiles.locateRepository() }
        guard let files else {
            FileHandle.standardError.write(Data("qs-ask: repository not found; pass --repo PATH\n".utf8)); exit(3)
        }
        let corpus: Corpus
        do { corpus = try Corpus.load(files) } catch {
            FileHandle.standardError.write(Data("qs-ask: sources not loaded: \(error)\nRun tools/fetch-sources.py first.\n".utf8)); exit(3)
        }

        let router: any QuestionRouter
        switch routerChoice {
        case "rules": router = RuleBasedRouter()
        case "fm":
            guard let fm = FoundationModelsSupport.router() else {
                FileHandle.standardError.write(Data("qs-ask: Foundation Models \(FoundationModelsSupport.availability)\n".utf8)); exit(3)
            }
            router = fm
        case "auto", "hybrid": router = AskRouters.standard()
        default: usage()
        }
        FileHandle.standardError.write(Data("qs-ask: router \(router.name); Foundation Models \(FoundationModelsSupport.availability); footnotes \(corpus.footnotesLoaded ? "loaded" : "not loaded")\n".utf8))

        // The Ask cards and their local-only sources (Directive 3). Missing local files make
        // cards unavailable, not the engine.
        let root = files.translation.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let sources: AskSourceSet?
        do { sources = try AskSourceSet.load(root: root, expectedRawSHA256: (try? Corpus.loadExtracted(files.translation))?.rawSHA256) } catch {
            FileHandle.standardError.write(Data("qs-ask: Ask cards not loaded: \(error)\n".utf8)); sources = nil
        }
        if let sources { FileHandle.standardError.write(Data("qs-ask: Ask cards \(sources.availableCount(corpus: corpus)) of \(sources.cards.count) available\n".utf8)) }

        let leadWriter = wantLead ? LeadSupport.writer() : nil
        // The model card picker follows the router choice: fm/auto/hybrid use it when available; rules does not.
        let picker: (any CardPicker)? = routerChoice == "rules" ? nil : CardPickerSupport.picker()
        let answer = await AskEngine(corpus: corpus, router: router, leadWriter: leadWriter, sources: sources, cardPicker: picker).ask(question, anchorAyah: ayah)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        if let data = try? encoder.encode(answer), let s = String(data: data, encoding: .utf8) { print(s) }
        guard !jsonOnly else { return }
        print("\n----")
        print("Ayah \(answer.anchorAyah) · route: \(answer.route.rawValue) · decision: \(answer.decision.rawValue)" + (answer.card.map { " · card: \($0)" } ?? "") + (answer.level.map { " · level: \($0)" } ?? ""))
        print("Decided by: \(answer.router)")
        if !answer.lead.isEmpty { print("\n\(answer.lead)") }
        for p in answer.passages {
            print("\n[\(p.id)] \(p.text)")
            print("    — \(p.sourceLine)")
        }
        if !answer.note.isEmpty { print("\n\(answer.note)") }
        for link in answer.links { print("Link: \(link)") }
        print("Lead: \(answer.leadStatus)")
        if !answer.citations.isEmpty { print("Cites: \(answer.citations.joined(separator: ", "))") }
    }
}
