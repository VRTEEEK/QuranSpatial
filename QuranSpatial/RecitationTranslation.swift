//
//  RecitationTranslation.swift
//  QuranSpatial
//
//  Decoded shape of Resources/en-rahman-saheeh-1947.json - the English translation layer's
//  text. Saheeh International, Quranpedia book 1947 (Decisions (human), 2026-09-29).
//
//  THE FILE IS NOT IN THE REPO and never will be until a licence or permission is documented.
//  It is gitignored (`QuranSpatial/Resources/en-*.json`) and placed by hand for local builds;
//  its ABSENCE is a supported state exactly like the ship font's: no file, no English layer,
//  one log line, and the Arabic is untouched. A build for anyone else is made by not having
//  the file.
//
//  Verbatim means byte-identical to the extraction script's output: no normalisation, no
//  punctuation or whitespace repair, compared with `isByteIdentical`, never `==` (the text
//  carries U+0101, U+012B and U+2019). The file carries `textSHA256` over its own ayat so a
//  corrupted copy refuses to load; the tests pin that hash as a constant so a substituted
//  edition fails too - without a word of the translation appearing in the repo.
//

import CryptoKit
import Foundation
import os

struct RecitationTranslationFile: Decodable {
    let edition: String
    let sourceBook: Int
    let sourceURL: String
    /// SHA-256 of the raw Quranpedia file the text was extracted from. Pinned in the tests.
    let rawSHA256: String
    /// The extraction script's own rule strings. Metadata; nothing compares them.
    let extractionRules: [String]
    /// SHA-256 over the 78 ayah texts, in order, joined by "\n", UTF-8.
    let textSHA256: String
    let ayat: [TranslatedAyah]

    static let resourceName = "en-rahman-saheeh-1947"

    /// Index 0 is the intro and has no English (decided 2026-09-30); index N is ayah N.
    func text(forSegmentIndex index: Int) -> String? {
        index == 0 ? nil : ayat.first { $0.ayah == index }?.text
    }

    /// The hash the file claims, recomputed from what was decoded.
    var computedTextSHA256: String {
        Self.sha256Hex(ayat.map(\.text).joined(separator: "\n"))
    }

    var textIsIntact: Bool { computedTextSHA256 == textSHA256 }

    static func sha256Hex(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    enum LoadError: Error, Equatable {
        case absent
        case corrupted(expected: String, actual: String)
    }

    /// Throws `.absent` when the file is not bundled and `.corrupted` when its text does not
    /// hash to its own `textSHA256`. A corrupted translation is never displayed.
    static func loadFromBundle(resourceName: String = resourceName) throws -> RecitationTranslationFile {
        guard let url = Bundle.main.url(forResource: resourceName, withExtension: "json") else {
            throw LoadError.absent
        }
        let file = try JSONDecoder().decode(RecitationTranslationFile.self, from: Data(contentsOf: url))
        guard file.textIsIntact else {
            throw LoadError.corrupted(expected: file.textSHA256, actual: file.computedTextSHA256)
        }
        return file
    }

    /// The app's entry point: nil for absent or corrupted, with the reason logged once.
    static func loadIfPresent(resourceName: String = resourceName) -> RecitationTranslationFile? {
        let logger = Logger(subsystem: "com.vrteek.quranspatial", category: "Translation")
        do {
            let file = try loadFromBundle(resourceName: resourceName)
            logger.notice("english: loaded \(file.ayat.count) ayat from \(resourceName, privacy: .public) (\(file.edition, privacy: .public), book \(file.sourceBook)), textSHA256 ok")
            return file
        } catch LoadError.absent {
            logger.notice("english: absent - no \(resourceName, privacy: .public).json in the bundle; Arabic only")
            return nil
        } catch let LoadError.corrupted(expected, actual) {
            logger.fault("english: REFUSED - text hashes to \(actual, privacy: .public), file claims \(expected, privacy: .public). Not displayed.")
            return nil
        } catch {
            logger.fault("english: REFUSED - \(resourceName, privacy: .public).json did not decode: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }
}

struct TranslatedAyah: Decodable, Equatable {
    let ayah: Int
    let text: String
}
