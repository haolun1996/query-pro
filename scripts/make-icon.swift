// Builds Resources/AppIcon.icns from Resources/AppIcon-source.png.
//
//   swift scripts/make-icon.swift
//
// The source is a generated 1024² image with the icon tile drawn on a flat background. We crop inside the tile's own
// rim and re-mask it onto Apple's macOS grid (824² rounded square centered on a 1024² transparent canvas), so the
// generator's background never shows and the icon lines up with system icons in the Dock.
import AppKit
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
let source = root.appending(path: "Resources/AppIcon-source.png")
let output = root.appending(path: "Resources/AppIcon.icns")

// Tile bounds in the source, measured by brightness (166…858), inset past the glass rim.
let crop = CGRect(x: 176, y: 176, width: 672, height: 672)
let canvas: CGFloat = 1024
let tile: CGFloat = 824
let radius: CGFloat = tile * 0.225

guard let imageSource = CGImageSourceCreateWithURL(source as CFURL, nil),
    let full = CGImageSourceCreateImageAtIndex(imageSource, 0, nil),
    let art = full.cropping(to: crop)
else { fatalError("can't read \(source.path)") }

func render(size: Int) -> CGImage {
    let ctx = CGContext(
        data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.interpolationQuality = .high
    let scale = CGFloat(size) / canvas
    ctx.scaleBy(x: scale, y: scale)
    let rect = CGRect(x: (canvas - tile) / 2, y: (canvas - tile) / 2, width: tile, height: tile)
    ctx.addPath(CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil))
    ctx.clip()
    ctx.draw(art, in: rect)
    return ctx.makeImage()!
}

let iconset = FileManager.default.temporaryDirectory.appending(path: "AppIcon-\(UUID().uuidString).iconset")
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: iconset) }

for points in [16, 32, 128, 256, 512] {
    for factor in [1, 2] {
        let name = factor == 1 ? "icon_\(points)x\(points).png" : "icon_\(points)x\(points)@2x.png"
        let dest = CGImageDestinationCreateWithURL(
            iconset.appending(path: name) as CFURL, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, render(size: points * factor), nil)
        guard CGImageDestinationFinalize(dest) else { fatalError("can't write \(name)") }
    }
}

let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", iconset.path, "-o", output.path]
try iconutil.run()
iconutil.waitUntilExit()
guard iconutil.terminationStatus == 0 else { fatalError("iconutil failed") }
print("Wrote \(output.path)")
