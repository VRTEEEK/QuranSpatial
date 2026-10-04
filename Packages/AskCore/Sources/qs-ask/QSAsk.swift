//
//  qs-ask - command-line "Ask" for the judges.
//
//    qs-ask --ayah 13 "why does this repeat?" [--router auto|fm|rules] [--repo PATH] [--json-only]
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
        usage: qs-ask --ayah N "question" [--router auto|fm|rules] [--no-lead] [--repo PATH] [--json-only]
          --ayah N      the ayah of Surah 55 on screen (1-78)
          --router      auto (Foundation Models if available, else rules), fm, or rules
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
        case "auto": router = FoundationModelsSupport.router() ?? RuleBasedRouter()
        default: usage()
        }
        FileHandle.standardError.write(Data("qs-ask: router \(router.name); Foundation Models \(FoundationModelsSupport.availability); footnotes \(corpus.footnotesLoaded ? "loaded" : "not loaded")\n".utf8))

        let leadWriter = wantLead ? LeadSupport.writer() : nil
        let answer = await AskEngine(corpus: corpus, router: router, leadWriter: leadWriter).ask(question, anchorAyah: ayah)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        if let data = try? encoder.encode(answer), let s = String(data: data, encoding: .utf8) { print(s) }
        guard !jsonOnly else { return }
        print("\n----")
        print("Ayah \(answer.anchorAyah) · route: \(answer.route.rawValue) · router: \(answer.router) · decision: \(answer.decision.rawValue)")
        if !answer.lead.isEmpty { print("\n\(answer.lead)") }
        for p in answer.passages {
            print("\n[\(p.id)] \(p.text)")
            print("    — \(p.sourceLine)")
        }
        if !answer.note.isEmpty { print("\n\(answer.note)") }
        print("Lead: \(answer.leadStatus)")
        if !answer.citations.isEmpty { print("Cites: \(answer.citations.joined(separator: ", "))") }
    }
}
