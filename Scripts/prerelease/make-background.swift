// Copyright (c) 2026, OpenEmu Team
//
// Redistribution and use in source and binary forms, with or without
// modification, are permitted provided that the following conditions are met:
// ... (BSD 2-Clause, same as the rest of the app)
//
// make-background.swift: builds the pre-release DMG window background from the RetroAchievements review
// background by covering its RetroAchievements logo and title with matching background and drawing the
// pre-release title instead. Run once; the result is committed as dmg-assets/background.png.
//
//   swiftc -O Scripts/prerelease/make-background.swift -o /tmp/make-background
//   /tmp/make-background Scripts/retro-achievements/dmg-assets/background.png Scripts/prerelease/dmg-assets/background.png

import AppKit
import CoreGraphics

let args = CommandLine.arguments
guard args.count == 3, let source = NSImage(contentsOfFile: args[1]),
      let cg = source.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
    FileHandle.standardError.write(Data("usage: make-background <original.png> <output.png>\n".utf8))
    exit(1)
}

let w = cg.width, h = cg.height
let space = CGColorSpace(name: CGColorSpace.sRGB)!
let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!

// CoreGraphics has its origin at the bottom left; the layout below is measured from the top, as in an image editor.
func rect(_ x: Int, _ top: Int, _ width: Int, _ height: Int) -> CGRect {
    CGRect(x: x, y: h - top - height, width: width, height: height)
}
// CGImage.cropping measures from the top left, unlike the drawing context.
func crop(_ x: Int, _ top: Int, _ width: Int, _ height: Int) -> CGImage {
    cg.cropping(to: CGRect(x: x, y: top, width: width, height: height))!
}

ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))

// 1. Replace everything above the grid (the RetroAchievements logo, divider and title included) with a smooth
//    dark gradient sampled from the original's left edge, fading into the original where the grid begins.
let sourceRep = NSBitmapImageRep(cgImage: cg)
func average(_ x0: Int, _ y0: Int, _ width: Int, _ height: Int) -> (CGFloat, CGFloat, CGFloat) {
    var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, n: CGFloat = 0
    for yy in y0..<(y0 + height) { for xx in x0..<(x0 + width) {
        if let c = sourceRep.colorAt(x: xx, y: yy)?.usingColorSpace(.sRGB) {
            r += c.redComponent; g += c.greenComponent; b += c.blueComponent; n += 1
        }
    } }
    return (r / n, g / n, b / n)
}
let top = average(10, 10, 180, 30)
let low = average(10, 330, 180, 40)
let gradientEnd = 380
let fadeFrom = 330
for row in 0..<gradientEnd {
    let t = CGFloat(row) / CGFloat(gradientEnd)
    let alpha: CGFloat = row < fadeFrom ? 1 : CGFloat(gradientEnd - row) / CGFloat(gradientEnd - fadeFrom)
    ctx.setFillColor(red: top.0 + (low.0 - top.0) * t, green: top.1 + (low.1 - top.1) * t,
                     blue: top.2 + (low.2 - top.2) * t, alpha: alpha)
    ctx.fill(rect(0, row, w, 1))
}

// 2. A soft red glow behind the title, like the original's.
ctx.saveGState()
ctx.clip(to: rect(0, 0, w, 400))
ctx.translateBy(x: 600, y: CGFloat(h) - 305)
ctx.scaleBy(x: 1, y: 0.33)
let glow = CGGradient(colorsSpace: space,
                      colors: [CGColor(red: 0.62, green: 0.1, blue: 0.13, alpha: 0.75), CGColor(red: 0.62, green: 0.1, blue: 0.13, alpha: 0)] as CFArray,
                      locations: [0, 1])!
ctx.drawRadialGradient(glow, startCenter: .zero, startRadius: 0, endCenter: .zero, endRadius: 520, options: [])
ctx.restoreGState()

// 3. Redraw the OpenEmu logo (with its "Native Apple Silicon" pill) in the centre.
let logo = crop(268, 88, 284, 134)
ctx.draw(logo, in: rect(600 - 142, 88, 284, 134))

// 4. The new title, in the same style as the old one: white bold text with a red glow.
let font = NSFont.boldSystemFont(ofSize: 36)
let shadow = NSShadow()
shadow.shadowColor = NSColor(calibratedRed: 0.85, green: 0.1, blue: 0.1, alpha: 0.95)
shadow.shadowBlurRadius = 8
shadow.shadowOffset = NSSize(width: 0, height: -2)
let para = NSMutableParagraphStyle(); para.alignment = .center
let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.white, .shadow: shadow, .paragraphStyle: para]
let title = NSAttributedString(string: "Pre-Release Test Build", attributes: attrs)
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
title.draw(in: NSRect(x: 200, y: CGFloat(h) - 345, width: 800, height: 60))
NSGraphicsContext.restoreGraphicsState()

guard let out = ctx.makeImage() else { exit(1) }
let rep = NSBitmapImageRep(cgImage: out)
rep.size = NSSize(width: CGFloat(w) / 2, height: CGFloat(h) / 2)  // 144 dpi, like the original
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: args[2]))
print("wrote \(args[2]) \(w)x\(h)")
