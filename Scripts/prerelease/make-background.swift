// Copyright (c) 2026, OpenEmu Team
//
// Redistribution and use in source and binary forms, with or without
// modification, are permitted provided that the following conditions are met:
// ... (BSD 2-Clause, same as the rest of the app)
//
// make-background.swift: builds the pre-release DMG window background (600 x 500 points, drawn at 2x). It takes
// the OpenEmu logo and the dark colours from the RetroAchievements review background and draws the rest: a
// gradient, a red glow, the title, two numbered steps and an arrow. Finder puts the icons on top at the
// positions set in build-preview-dmg.sh. Run once; the result is committed as dmg-assets/background.png.
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

// Everything below is in points (600 x 500) and measured from the top left; S converts to pixels.
let S = 2
let w = 600 * S, h = 500 * S
let space = CGColorSpace(name: CGColorSpace.sRGB)!
let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
func y(_ top: CGFloat) -> CGFloat { CGFloat(h) - top * CGFloat(S) }  // top-left point -> context y
func px(_ v: CGFloat) -> CGFloat { v * CGFloat(S) }

// Colours sampled from the original's left edge: dark navy at the top, near-black lower down.
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
let low = average(10, 700, 180, 80)
for row in 0..<h {
    let t = CGFloat(row) / CGFloat(h)
    ctx.setFillColor(red: top.0 + (low.0 - top.0) * t, green: top.1 + (low.1 - top.1) * t,
                     blue: top.2 + (low.2 - top.2) * t, alpha: 1)
    ctx.fill(CGRect(x: 0, y: y(CGFloat(row) / CGFloat(S) ) - 1, width: CGFloat(w), height: 1))
}

// A soft red glow behind the title, as in the original.
ctx.saveGState()
ctx.translateBy(x: CGFloat(w) / 2, y: y(95))
ctx.scaleBy(x: 1, y: 0.33)
let glow = CGGradient(colorsSpace: space,
                      colors: [CGColor(red: 0.62, green: 0.1, blue: 0.13, alpha: 0.7), CGColor(red: 0.62, green: 0.1, blue: 0.13, alpha: 0)] as CFArray,
                      locations: [0, 1])!
ctx.drawRadialGradient(glow, startCenter: .zero, startRadius: 0, endCenter: .zero, endRadius: px(300), options: [])
ctx.restoreGState()

// The OpenEmu logo (with its "Native Apple Silicon" pill) from the original, centred at the top.
let logo = cg.cropping(to: CGRect(x: 268, y: 88, width: 284, height: 134))!
ctx.draw(logo, in: CGRect(x: CGFloat(w) / 2 - 142 * CGFloat(S) / 2 * 1.0, y: y(12 + 67), width: 142 * CGFloat(S), height: 67 * CGFloat(S)))

func text(_ string: String, size: CGFloat, bold: Bool, centreX: CGFloat, top t: CGFloat, glowRed: Bool = false) {
    let font = bold ? NSFont.boldSystemFont(ofSize: size * CGFloat(S)) : NSFont.systemFont(ofSize: size * CGFloat(S), weight: .medium)
    let shadow = NSShadow()
    shadow.shadowColor = glowRed ? NSColor(calibratedRed: 0.85, green: 0.1, blue: 0.1, alpha: 0.95) : NSColor(calibratedWhite: 0, alpha: 0.7)
    shadow.shadowBlurRadius = glowRed ? 8 : 4
    shadow.shadowOffset = NSSize(width: 0, height: -2)
    let para = NSMutableParagraphStyle(); para.alignment = .center
    let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.white, .shadow: shadow, .paragraphStyle: para]
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
    NSAttributedString(string: string, attributes: attrs).draw(in: NSRect(x: centreX - px(300), y: y(t) - px(size * 1.4), width: px(600), height: px(size * 1.5)))
    NSGraphicsContext.restoreGraphicsState()
}
text("Pre-Release Test Build", size: 22, bold: true, centreX: CGFloat(w) / 2, top: 88, glowRed: true)
text("1   Drag OpenEmu onto Applications", size: 15, bold: false, centreX: CGFloat(w) / 2, top: 130)
text("2   Then double-click each core, one at a time", size: 15, bold: false, centreX: CGFloat(w) / 2, top: 305)

// An arrow from the app to the Applications shortcut (icons sit at x = 170 and 430, centre y = 215).
ctx.setStrokeColor(red: 0.4, green: 0.9, blue: 0.4, alpha: 0.95)
ctx.setFillColor(red: 0.4, green: 0.9, blue: 0.4, alpha: 0.95)
ctx.setLineWidth(px(5)); ctx.setLineCap(.round)
ctx.move(to: CGPoint(x: px(240), y: y(215))); ctx.addLine(to: CGPoint(x: px(345), y: y(215))); ctx.strokePath()
ctx.move(to: CGPoint(x: px(362), y: y(215)))
ctx.addLine(to: CGPoint(x: px(338), y: y(201))); ctx.addLine(to: CGPoint(x: px(338), y: y(229))); ctx.closePath(); ctx.fillPath()

guard let out = ctx.makeImage() else { exit(1) }
let rep = NSBitmapImageRep(cgImage: out)
rep.size = NSSize(width: CGFloat(w) / 2, height: CGFloat(h) / 2)  // 144 dpi
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: args[2]))
print("wrote \(args[2]) \(w)x\(h)")
