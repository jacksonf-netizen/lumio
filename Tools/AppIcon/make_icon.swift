// Builds the app icon from Tools/AppIcon/source.jpg.
//
//   swift Tools/AppIcon/make_icon.swift
//
// Crops the artwork around the TV, fits it into the standard macOS icon shape (an 824 pt rounded
// square with a soft shadow on a 1024 pt canvas) and writes every size into
// App/IPTVMac/Assets.xcassets/AppIcon.appiconset.
import AppKit

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let source = root.appendingPathComponent("Tools/AppIcon/source.jpg")
let output = root.appendingPathComponent("App/IPTVMac/Assets.xcassets/AppIcon.appiconset")

guard let image = NSImage(contentsOf: source),
      let art = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
    fatalError("Can't read \(source.path)")
}

// The TV sits in the middle of the artwork; keep the central 70% so it fills the icon.
let side = CGFloat(min(art.width, art.height)) * 0.70
let crop = CGRect(x: (CGFloat(art.width) - side) / 2, y: (CGFloat(art.height) - side) / 2, width: side, height: side)
guard let cropped = art.cropping(to: crop) else { fatalError("Crop failed") }

func render(size: Int) -> Data {
    let canvas = CGFloat(size)
    let scale = canvas / 1024
    let shape = CGRect(x: 100 * scale, y: 100 * scale, width: 824 * scale, height: 824 * scale)
    let radius = 185 * scale
    let space = CGColorSpace(name: CGColorSpace.sRGB)!
    let context = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                            space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    context.interpolationQuality = .high
    let path = CGPath(roundedRect: shape, cornerWidth: radius, cornerHeight: radius, transform: nil)

    // Shadow under the shape, as in Apple's icon template.
    context.saveGState()
    context.setShadow(offset: CGSize(width: 0, height: -10 * scale), blur: 20 * scale,
                      color: CGColor(gray: 0, alpha: 0.35))
    context.addPath(path)
    context.setFillColor(CGColor(srgbRed: 0.03, green: 0.07, blue: 0.17, alpha: 1))
    context.fillPath()
    context.restoreGState()

    context.saveGState()
    context.addPath(path)
    context.clip()
    context.draw(cropped, in: shape)
    context.restoreGState()

    let bitmap = NSBitmapImageRep(cgImage: context.makeImage()!)
    return bitmap.representation(using: .png, properties: [:])!
}

try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
var entries: [String] = []
for points in [16, 32, 128, 256, 512] {
    for factor in [1, 2] {
        let name = "icon_\(points)x\(points)\(factor == 2 ? "@2x" : "").png"
        try render(size: points * factor).write(to: output.appendingPathComponent(name))
        entries.append("""
            { "idiom" : "mac", "size" : "\(points)x\(points)", "scale" : "\(factor)x", "filename" : "\(name)" }
        """)
    }
}
let contents = "{\n  \"images\" : [\n\(entries.joined(separator: ",\n"))\n  ],\n  \"info\" : { \"author\" : \"xcode\", \"version\" : 1 }\n}\n"
try contents.write(to: output.appendingPathComponent("Contents.json"), atomically: true, encoding: .utf8)
let catalog = output.deletingLastPathComponent().appendingPathComponent("Contents.json")
try "{\n  \"info\" : { \"author\" : \"xcode\", \"version\" : 1 }\n}\n".write(to: catalog, atomically: true, encoding: .utf8)
print("Wrote \(entries.count) icon sizes to \(output.path)")
