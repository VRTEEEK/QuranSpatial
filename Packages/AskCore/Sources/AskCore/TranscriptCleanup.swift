//
//  TranscriptCleanup.swift
//  AskCore
//
//  Directive 3, stage 3a. Called FIRST in AskEngine.ask, so the app and qs-ask share it. Two
//  things and nothing else:
//    clean(_:)        whole-word "gin" / "jin" -> "jinn" (the speech recogniser's spelling). This
//                     is the question the engine works on and the one the Answer carries.
//    forMatching(_:)  for KEYWORD MATCHING ONLY, never display: U+2019 folded to U+0027 so
//                     "qur'an" matches "Qur’an".
//

import Foundation

public enum TranscriptCleanup {
    public static func clean(_ transcript: String) -> String {
        transcript.replacingOccurrences(of: #"(?<![\p{L}\p{N}])(gin|jin)(?![\p{L}\p{N}])"#, with: "jinn",
                                        options: [.regularExpression, .caseInsensitive])
    }

    public static func forMatching(_ text: String) -> String {
        clean(text).replacingOccurrences(of: "\u{2019}", with: "'")
    }
}
