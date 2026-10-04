//
//  Corpus.swift
//  AskCore
//
//  Records keyed by ayah for Surah 55, built from the SAME local files the app bundles, with
//  the SAME hash checks: the extracted text must hash to the file's own `textSHA256`, and the
//  raw Quranpedia file (for the Saheeh footnotes) must hash to the `rawSHA256` the extracted
//  file records. Nothing here generates, rewrites or normalises any text: every passage is a
//  verbatim slice of a source field, and the footnote extraction is deletion-only, by the rules
//  recorded in the extracted file.
//

import CryptoKit
import Foundation

/// Where a passage comes from. The raw value is the stable prefix of every passage ID.
public enum PassageSource: String, Codable, Sendable, CaseIterable {
    case saheehTranslation = "saheeh-1947"
    case saheehFootnote = "saheeh-1947-footnote"
    case mukhtasar = "mukhtasar-27824"

    /// The attribution line shown with every passage from this source.
    public var sourceLine: String {
        switch self {
        case .saheehTranslation: return "Saheeh International, via Quranpedia, book 1947"
        case .saheehFootnote: return "Saheeh International (translator's footnote), via Quranpedia, book 1947"
        case .mukhtasar: return "Al-Mukhtasar fi Tafsir al-Quran (English), via Quranpedia, book 27824"
        }
    }
}

/// One verbatim passage with a citable ID, e.g. `mukhtasar-27824:55:13`.
public struct Passage: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    public let source: PassageSource
    public let surah: Int
    public let ayah: Int
    public let text: String
    public var sourceLine: String { source.sourceLine }

    public init(source: PassageSource, surah: Int = 55, ayah: Int, text: String, suffix: String = "") {
        self.source = source
        self.surah = surah
        self.ayah = ayah
        self.text = text
        self.id = "\(source.rawValue):\(surah):\(ayah)\(suffix)"
    }
}

public struct AyahRecord: Sendable {
    public let ayah: Int
    public let translation: Passage?
    public let footnotes: [Passage]
    public let meaning: Passage?
}

/// The extracted file's shape - identical to the app's `RecitationTranslationFile`.
public struct ExtractedTextFile: Decodable, Sendable {
    public struct Entry: Decodable, Sendable { public let ayah: Int; public let text: String }
    public let edition: String
    public let sourceBook: Int
    public let sourceURL: String
    public let rawSHA256: String
    public let extractionRules: [String]
    public let textSHA256: String
    public let ayat: [Entry]

    public var computedTextSHA256: String { Corpus.sha256Hex(ayat.map(\.text).joined(separator: "\n")) }
    public var textIsIntact: Bool { computedTextSHA256 == textSHA256 }
}

public enum CorpusError: Error, Equatable, CustomStringConvertible {
    case missing(String)
    case corrupted(file: String, expected: String, actual: String)
    case rawMismatch(file: String, expected: String, actual: String)
    case extractionDisagrees(ayah: Int)

    public var description: String {
        switch self {
        case .missing(let f): return "missing source file: \(f)"
        case .corrupted(let f, let e, let a): return "\(f): text hashes to \(a), file claims \(e)"
        case .rawMismatch(let f, let e, let a): return "\(f): raw file hashes to \(a), extracted file records \(e)"
        case .extractionDisagrees(let ayah): return "raw 1947 ayah \(ayah) does not extract to the bundled text"
        }
    }
}

public struct Corpus: Sendable {
    public let surah = 55
    public let records: [Int: AyahRecord]
    public let related: RelatedIndex?
    /// Which optional inputs were present when loading, for the report.
    public let footnotesLoaded: Bool

    public static func sha256Hex(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }
    public static func sha256Hex(data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    public static func loadExtracted(_ url: URL) throws -> ExtractedTextFile {
        guard let data = try? Data(contentsOf: url) else { throw CorpusError.missing(url.lastPathComponent) }
        let file = try JSONDecoder().decode(ExtractedTextFile.self, from: data)
        guard file.textIsIntact else {
            throw CorpusError.corrupted(file: url.lastPathComponent, expected: file.textSHA256, actual: file.computedTextSHA256)
        }
        return file
    }

    /// Loads the corpus. `translation` and `meaning` are required; `rawTranslation` (the raw
    /// Quranpedia 1947 file) adds the footnotes and is verified against the extracted file's
    /// recorded raw hash AND re-extracted to confirm the bundled text; `related` adds the
    /// refs-only similar-ayat index.
    public static func load(_ files: SourceFiles) throws -> Corpus {
        let translation = try loadExtracted(files.translation)
        let meaning = try loadExtracted(files.meaning)

        var footnotes: [Int: [Passage]] = [:]
        var footnotesLoaded = false
        if let rawURL = files.rawTranslation, let raw = try? Data(contentsOf: rawURL) {
            let actual = sha256Hex(data: raw)
            guard actual == translation.rawSHA256 else {
                throw CorpusError.rawMismatch(file: rawURL.lastPathComponent, expected: translation.rawSHA256, actual: actual)
            }
            footnotes = try SaheehFootnotes.extract(rawData: raw, verifyingAgainst: translation)
            footnotesLoaded = true
        }

        var related: RelatedIndex? = nil
        if let relURL = files.related, let data = try? Data(contentsOf: relURL) {
            related = try JSONDecoder().decode(RelatedIndex.self, from: data)
        }

        let meaningByAyah = Dictionary(uniqueKeysWithValues: meaning.ayat.map { ($0.ayah, $0.text) })
        var records: [Int: AyahRecord] = [:]
        for entry in translation.ayat {
            records[entry.ayah] = AyahRecord(
                ayah: entry.ayah,
                translation: Passage(source: .saheehTranslation, ayah: entry.ayah, text: entry.text),
                footnotes: footnotes[entry.ayah] ?? [],
                meaning: meaningByAyah[entry.ayah].map { Passage(source: .mukhtasar, ayah: entry.ayah, text: $0) }
            )
        }
        return Corpus(records: records, related: related, footnotesLoaded: footnotesLoaded)
    }

    public subscript(ayah: Int) -> AyahRecord? { records[ayah] }
    public var ayahCount: Int { records.count }
}

/// The refs-only file derived from Quranpedia's similar-ayat dump (committed; carries no text).
public struct RelatedIndex: Decodable, Sendable {
    public struct Entry: Decodable, Sendable {
        public let within55: [Int]
        public let outside55Count: Int
    }
    public let source: String
    public let dumpVersion: String?
    public let rawSHA256: String
    public let related: [String: Entry]

    public func related(to ayah: Int) -> [Int] { related[String(ayah)]?.within55 ?? [] }
}

/// Saheeh International footnotes for Surah 55, from the raw Quranpedia 1947 file, by the
/// deletion-only rules recorded in the extracted file. The ayah text re-extracted here must
/// equal the bundled text byte for byte, which ties the raw file to the bundled one.
enum SaheehFootnotes {
    private struct RawBook: Decodable {
        struct Entry: Decodable {
            let ayah_number: Int
            let surah_number: Int
            let translated_text: String
        }
        let ayahs: [Entry]
    }

    static func extract(rawData: Data, verifyingAgainst extracted: ExtractedTextFile) throws -> [Int: [Passage]] {
        let book = try JSONDecoder().decode(RawBook.self, from: rawData)
        let bundled = Dictionary(uniqueKeysWithValues: extracted.ayat.map { ($0.ayah, $0.text) })
        var result: [Int: [Passage]] = [:]
        for entry in book.ayahs where entry.surah_number == 55 {
            let field = entry.translated_text
            let parts = field.components(separatedBy: "<br />")
            var body = parts[0]
            let prefix = "(\(entry.ayah_number)) "
            guard body.hasPrefix(prefix) else { throw CorpusError.extractionDisagrees(ayah: entry.ayah_number) }
            body.removeFirst(prefix.count)
            body = body.replacingOccurrences(of: #"\[\d+\]"#, with: "", options: .regularExpression)
            guard let expected = bundled[entry.ayah_number], Array(body.utf8) == Array(expected.utf8) else {
                throw CorpusError.extractionDisagrees(ayah: entry.ayah_number)
            }
            // Footnote block: "\n____________________<br />\n[n]- text<br />\n[m]- text"
            guard parts.count > 1 else { continue }
            var block = parts.dropFirst().joined(separator: "<br />")
            if block.hasPrefix("\n____________________<br />\n") { block.removeFirst("\n____________________<br />\n".count) }
            var notes: [Passage] = []
            for (i, note) in block.components(separatedBy: "<br />\n").enumerated() {
                let trimmed = note.trimmingCharacters(in: .newlines)
                guard !trimmed.isEmpty else { continue }
                // "[1594]- Literally, ..." -> keep the text after "]- ", verbatim.
                let text: String
                if let range = trimmed.range(of: #"^\[\d+\]- "#, options: .regularExpression) {
                    text = String(trimmed[range.upperBound...])
                } else {
                    text = trimmed
                }
                notes.append(Passage(source: .saheehFootnote, ayah: entry.ayah_number, text: text, suffix: "#\(i + 1)"))
            }
            if !notes.isEmpty { result[entry.ayah_number] = notes }
        }
        return result
    }
}
