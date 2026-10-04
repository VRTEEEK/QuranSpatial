//
//  AyahTextureCache.swift
//  QuranSpatial
//
//  Rasterizes ayah text off the main actor and hands back ready textures.
//
//  Rasterizing on the advance is not an option: the existing test rasterizes a five-glyph
//  string in 43ms, a full ayah costs more, and the budget in CLAUDE.md is no single hitch
//  over 50ms. So the work happens ahead of time on a detached task and only the texture
//  hand-off touches the main actor.
//
//  Nor can all 78 be resident - roughly 200MB of texture. A window of three is kept:
//  previous, current, next. Previous is worth its place because a seek backwards or a
//  release-and-resume returns to it immediately.
//

import CoreGraphics
import CoreText
import Foundation
import Observation
import RealityKit
import os

/// CGImage is not Sendable under strict concurrency, but a rasterized image is immutable
/// once produced and is only ever read after hand-off.
private struct SendableRaster: @unchecked Sendable {
    let image: CGImage
    let pixelSize: CGSize
    let lineCount: Int
    let firstBaselineFromTopPixels: CGFloat
}

@MainActor
@Observable
final class AyahTextureCache {

    struct Entry {
        let texture: TextureResource
        /// Raster size in pixels. The plane is derived from this by a FIXED metres-per-pixel
        /// scale, so a glyph is the same physical size in every ayah.
        let pixelSize: CGSize
        /// How many lines the ayah wrapped to.
        let lineCount: Int
        /// Distance from the bitmap's top edge to the first line's baseline. The plane is
        /// anchored on this, so every segment's first line lands at the same world Y.
        let firstBaselineFromTopPixels: CGFloat
    }

    /// How a string becomes a raster. Injected so the English layer (Stage 2 B4) can run the
    /// same cache with a different direction and font; the Arabic instance is unchanged.
    typealias Rasterize = @Sendable (_ text: String, _ fontSizePixels: CGFloat,
                                     _ maxContentWidthPixels: Int, _ padding: CGFloat) -> ArabicTextRasterizer.WrappedText?

    /// The recitation's own path: right-to-left, ship-font cascade. The default.
    nonisolated static let arabic: Rasterize = { text, size, width, padding in
        ArabicTextRasterizer.rasterizeWrapped(text, fontSizePixels: size, maxContentWidthPixels: width, padding: padding)
    }

    /// The English layer: left-to-right, system font (decision F1), otherwise identical.
    nonisolated static let english: Rasterize = { text, size, width, padding in
        ArabicTextRasterizer.rasterizeWrapped(text, fontSizePixels: size, maxContentWidthPixels: width, padding: padding,
                                              writingDirection: .leftToRight,
                                              font: ArabicTextRasterizer.resolveSystemFont(for: text, size: size))
    }

    private let rasterize: Rasterize
    private var entries: [Int: Entry] = [:]
    private var inFlight: Set<Int> = []
    private let logger = Logger(subsystem: "com.vrteek.quranspatial", category: "AyahTexture")

    init(rasterize: @escaping Rasterize = AyahTextureCache.arabic) {
        self.rasterize = rasterize
    }

    func entry(for index: Int) -> Entry? { entries[index] }

    /// Starts rasterization if this index is neither cached nor already being produced.
    /// Font size is fixed and the width is bounded; length spends itself on line count.
    func prefetch(index: Int, text: String, fontSizePixels: CGFloat, maxContentWidthPixels: Int, padding: CGFloat) {
        guard entries[index] == nil, !inFlight.contains(index) else { return }
        inFlight.insert(index)
        let rasterize = self.rasterize
        Task.detached(priority: .userInitiated) { [weak self] in
            let raster = rasterize(text, fontSizePixels, maxContentWidthPixels, padding)
                .map { SendableRaster(image: $0.cgImage, pixelSize: $0.pixelSize, lineCount: $0.lineCount,
                                   firstBaselineFromTopPixels: $0.firstBaselineFromTopPixels) }
            await self?.finish(index: index, raster: raster)
        }
    }

    private func finish(index: Int, raster: SendableRaster?) {
        inFlight.remove(index)
        guard let raster else {
            logger.error("Rasterization failed for segment \(index)")
            return
        }
        guard let texture = try? TextureResource(
            image: raster.image, options: .init(semantic: .color, mipmapsMode: .none)
        ) else {
            logger.error("Texture creation failed for segment \(index)")
            return
        }
        entries[index] = Entry(texture: texture, pixelSize: raster.pixelSize, lineCount: raster.lineCount,
                               firstBaselineFromTopPixels: raster.firstBaselineFromTopPixels)
    }

    /// Drops everything outside the window, so memory stays bounded across 79 segments.
    func evict(keeping keep: Set<Int>) {
        for index in entries.keys where !keep.contains(index) {
            entries.removeValue(forKey: index)
        }
    }
}
