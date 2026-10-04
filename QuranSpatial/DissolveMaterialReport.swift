//
//  DissolveMaterialReport.swift
//  QuranSpatial
//
//  Writes the dissolve material's load result to a file at launch, so a load failure can be
//  read verbatim by pulling the app container rather than by squinting at a HUD or running
//  the test target - which cannot run on device at all, because QuranSpatialTests has no
//  development team.
//
//  Same reasoning as FontIdentityReport: the thing that fails is the build actually running
//  on the headset, and the failure text is the whole diagnosis. The HUD line-limits it and
//  os_log needs a Mac with Console attached; this needs neither, and it does not need
//  anyone to be wearing the device, because loading a material is asset loading and does
//  not require an ImmersiveSpace.
//
//  It probes several (named:, from:) spellings rather than only the one the driver uses.
//  Each device round-trip costs a build and an install, so one pull should say which
//  spelling works, not merely that ours does not.
//

import CoreGraphics
import Foundation
import RealityKit
import RealityKitContent
import os

enum DissolveMaterialReport {

    static let filename = "dissolve-material.txt"

    private static let logger = Logger(subsystem: "com.vrteek.quranspatial", category: "DissolveMaterial")

    /// The spellings worth trying, most-expected first. `from:` is the scene name as the
    /// compiled manifest lists it, which is not obviously the same string as the source
    /// file's path, and that is exactly the sort of thing that is cheaper to test than to
    /// reason about.
    private static let candidates: [(named: String, from: String)] = [
        ("/Root/DissolveMaterial", "Materials/DissolveMaterial"),
        ("/Root/DissolveMaterial", "Materials/DissolveMaterial.usda"),
        // Immersive.usda references the material file, and a USD reference pulls in that
        // file's DEFAULT PRIM - which is the Xform "Root", not the Material. So inside the
        // Immersive scene the material should be one level deeper than it is in its own
        // scene. Both spellings are probed rather than reasoned about.
        ("/Root/DissolveMaterial", "Immersive"),
        ("/Root/DissolveMaterial/DissolveMaterial", "Immersive"),
        ("DissolveMaterial", "Materials/DissolveMaterial"),
        ("/Root/DissolveMaterial/DissolveMaterial", "Materials/DissolveMaterial"),
    ]

    @discardableResult
    @MainActor
    static func write() async -> URL? {
        var lines: [String] = []
        lines.append("written: \(ISO8601DateFormatter().string(from: Date()))")
        lines.append("bundle: \(realityKitContentBundle.bundleURL.lastPathComponent)")
        lines.append("bundlePath: \(realityKitContentBundle.bundlePath)")
        lines.append("")

        lines.append("--- ShaderGraphMaterial load probes ---")
        for candidate in candidates {
            let label = "named: \(candidate.named), from: \(candidate.from)"
            do {
                let material = try await ShaderGraphMaterial(
                    named: candidate.named, from: candidate.from, in: realityKitContentBundle
                )
                let names = material.parameterNames.sorted().joined(separator: ", ")
                lines.append("OK    \(label)")
                lines.append("      parameters: \(names)")
            } catch {
                lines.append("FAIL  \(label)")
                // Three renderings deliberately. `localizedDescription` on a RealityKit
                // error is routinely the useless one, `String(describing:)` gives the enum
                // case and its associated values, and the NSError bridge carries the domain,
                // code and userInfo that say which of them it actually is.
                lines.append("      describing:  \(String(describing: error))")
                lines.append("      reflecting:  \(String(reflecting: error))")
                lines.append("      localized:   \(error.localizedDescription)")
                let nsError = error as NSError
                lines.append("      domain: \(nsError.domain) code: \(nsError.code)")
                lines.append("      userInfo: \(nsError.userInfo)")
            }
        }

        lines.append("")
        lines.append("--- setParameter type probes ---")
        await probeParameterTypes(into: &lines)

        lines.append("")
        lines.append("--- Immersive scene ---")
        do {
            let entity = try await Entity(named: "Immersive", in: realityKitContentBundle)
            lines.append("OK    Entity(named: \"Immersive\")")
            describe(entity, depth: 0, into: &lines)
        } catch {
            lines.append("FAIL  Entity(named: \"Immersive\"): \(String(describing: error))")
        }

        let report = lines.joined(separator: "\n")
        // Also to stdout, so `devicectl device process launch --console` catches it without
        // pulling the container at all.
        print("=== DISSOLVE MATERIAL REPORT ===\n\(report)\n=== END ===")
        logger.notice("\(report, privacy: .public)")

        guard let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else {
            return nil
        }
        let url = documents.appendingPathComponent(filename)
        do {
            try report.write(to: url, atomically: true, encoding: .utf8)
            return url
        } catch {
            logger.error("Could not write dissolve material report: \(error.localizedDescription)")
            return nil
        }
    }

    /// Which `MaterialParameters.Value` case each parameter actually accepts.
    ///
    /// `incorrectTypeForParameterName` names the failure but not the parameter, and the
    /// driver sets seven of them - so without this the only way to find the offender is one
    /// build-install-launch cycle per guess. USD's declared type is not a reliable guide:
    /// an `asset` input might want `.textureResource` or the `.texture` wrapper, and there
    /// is no documentation that settles it.
    @MainActor
    private static func probeParameterTypes(into lines: inout [String]) async {
        guard var material = try? await ShaderGraphMaterial(
            named: DissolveDriver.materialPath, from: DissolveDriver.materialResource,
            in: realityKitContentBundle
        ) else {
            lines.append("  (skipped - material did not load)")
            return
        }
        guard let texture = probeTexture() else {
            lines.append("  (skipped - could not build a probe texture)")
            return
        }

        let white = CGColor(red: 1, green: 1, blue: 1, alpha: 1)
        let candidates: [(String, [(String, MaterialParameters.Value)])] = [
            ("progress", [("float", .float(0.5))]),
            ("edgeWidth", [("float", .float(0.12))]),
            ("noiseOffset", [("simd2Float", .simd2Float(SIMD2<Float>(12, 34)))]),
            ("noiseScale", [("simd2Float", .simd2Float(SIMD2<Float>(1.75, 0.54)))]),
            ("textColor", [("color", .color(white)), ("simd3Float", .simd3Float(SIMD3<Float>(1, 1, 1)))]),
            ("textTexture", [("textureResource", .textureResource(texture)),
                             ("texture", .texture(.init(texture)))]),
        ]

        // What the material says each parameter ALREADY holds. `setParameter` reports only
        // that a type was wrong, never which type it wanted; `getParameter` names it.
        lines.append("  -- current values --")
        for name in material.parameterNames.sorted() {
            let current = material.getParameter(name: name)
            lines.append("  get \(name) -> \(current.map { String(describing: $0) } ?? "nil")")
        }
        lines.append("  -- set attempts --")

        for (name, options) in candidates {
            for (typeLabel, value) in options {
                do {
                    try material.setParameter(name: name, value: value)
                    lines.append("OK    \(name) <- .\(typeLabel)")
                } catch {
                    lines.append("FAIL  \(name) <- .\(typeLabel): \(String(describing: error))")
                }
            }
        }

    }

    /// A 2x2 opaque white texture, built here rather than borrowed from the dissolve, so
    /// this probe stays valid whatever the dissolve's own noise source becomes.
    private static func probeTexture() -> TextureResource? {
        var pixels = [UInt8](repeating: 255, count: 2 * 2 * 4)
        guard let provider = CGDataProvider(data: Data(pixels) as CFData),
              let image = CGImage(
                width: 2, height: 2, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: 8,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent
              )
        else { return nil }
        pixels.removeAll()
        return try? TextureResource(image: image, options: .init(semantic: .color, mipmapsMode: .none))
    }

    /// Names and material types down the loaded scene, so a material that arrived under a
    /// different path than expected is visible rather than merely absent.
    private static func describe(_ entity: Entity, depth: Int, into lines: inout [String]) {
        let indent = String(repeating: "  ", count: depth + 3)
        var line = "\(indent)\(entity.name.isEmpty ? "<unnamed>" : entity.name) [\(type(of: entity))]"
        if let model = entity.components[ModelComponent.self] {
            let materials = model.materials.map { "\(type(of: $0))" }.joined(separator: ", ")
            line += " materials: [\(materials)]"
        }
        lines.append(line)
        for child in entity.children { describe(child, depth: depth + 1, into: &lines) }
    }
}
