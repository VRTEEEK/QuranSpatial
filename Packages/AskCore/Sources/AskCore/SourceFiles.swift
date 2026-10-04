//
//  SourceFiles.swift
//  AskCore
//
//  Where the local source files are. The texts are gitignored and placed by
//  tools/fetch-sources.py; the refs-only related index is committed.
//

import Foundation

public struct SourceFiles: Sendable {
    public var translation: URL      // QuranSpatial/Resources/en-rahman-saheeh-1947.json
    public var meaning: URL          // QuranSpatial/Resources/en-rahman-mukhtasar-27824.json
    public var related: URL?         // QuranSpatial/Resources/related-55-quranpedia-similar.json
    public var rawTranslation: URL?  // scratch/1947.json (footnotes)

    public init(translation: URL, meaning: URL, related: URL? = nil, rawTranslation: URL? = nil) {
        self.translation = translation; self.meaning = meaning; self.related = related; self.rawTranslation = rawTranslation
    }

    /// The repository layout: walks up from `start` to the directory that contains
    /// `QuranSpatial/Resources`, or returns nil.
    public static func locateRepository(startingAt start: URL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)) -> SourceFiles? {
        var dir = start.standardizedFileURL
        for _ in 0..<8 {
            let res = dir.appendingPathComponent("QuranSpatial/Resources")
            if FileManager.default.fileExists(atPath: res.appendingPathComponent("ar-rahman-text.json").path) {
                return inRepository(root: dir)
            }
            let parent = dir.deletingLastPathComponent()
            if parent.path == dir.path { break }
            dir = parent
        }
        return nil
    }

    public static func inRepository(root: URL) -> SourceFiles {
        let res = root.appendingPathComponent("QuranSpatial/Resources")
        let raw = root.appendingPathComponent("scratch/1947.json")
        return SourceFiles(
            translation: res.appendingPathComponent("en-rahman-saheeh-1947.json"),
            meaning: res.appendingPathComponent("en-rahman-mukhtasar-27824.json"),
            related: res.appendingPathComponent("related-55-quranpedia-similar.json"),
            rawTranslation: FileManager.default.fileExists(atPath: raw.path) ? raw : nil
        )
    }

    /// The app bundle layout (resources flattened to the bundle root). Footnotes are not
    /// bundled, so the raw file is nil.
    public static func inBundle(_ bundle: Bundle) -> SourceFiles? {
        guard let t = bundle.url(forResource: "en-rahman-saheeh-1947", withExtension: "json"),
              let m = bundle.url(forResource: "en-rahman-mukhtasar-27824", withExtension: "json") else { return nil }
        return SourceFiles(translation: t, meaning: m,
                           related: bundle.url(forResource: "related-55-quranpedia-similar", withExtension: "json"),
                           rawTranslation: nil)
    }
}
