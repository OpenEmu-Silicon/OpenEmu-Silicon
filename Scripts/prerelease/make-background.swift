// Copyright (c) 2026, OpenEmu Team
//
// Redistribution and use in source and binary forms, with or without
// modification, are permitted provided that the following conditions are met:
// ... (BSD 2-Clause, same as the rest of the app)
//
// make-background.swift: builds the pre-release DMG window background (600 x 500 points, drawn at 2x).
// It is deliberately plain: a light background with dark text, because Finder always draws the names
// under the icons in dark text when a window has a background picture, so a dark background makes them
// unreadable. Finder puts the icons on top at the positions set in build-preview-dmg.sh.
// Run once; the result is committed as dmg-assets/background.png.
//
//   swiftc -O Scripts/prerelease/make-background.swift -o /tmp/make-background
//   /tmp/make-background Scripts/prerelease/dmg-assets/background.png

import AppKit
import CoreGraphics

let args = CommandLine.arguments
guard args.count == 2 else {
    FileHandle.standardError.write(Data("usage: make-background <output.png>\n".utf8))
    exit(1)
}

let S = 2
let w = 600 * S, h = 500 * S
let space = CGColorSpace(name: CGColorSpace.sRGB)!
let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
func y(_ top: CGFloat) -> CGFloat { CGFloat(h) - top * CGFloat(S) }  // top-left point -> context y
func px(_ v: CGFloat) -> CGFloat { v * CGFloat(S) }

// Light grey-blue gradient, top to bottom.
for row in 0..<h {
    let t = CGFloat(row) / CGFloat(h)
    ctx.setFillColor(red: (246 - 22 * t) / 255, green: (247 - 20 * t) / 255, blue: (251 - 15 * t) / 255, alpha: 1)
    ctx.fill(CGRect(x: 0, y: CGFloat(h - row - 1), width: CGFloat(w), height: 1))
}

func text(_ string: String, size: CGFloat, weight: NSFont.Weight, top t: CGFloat, color: NSColor) {
    let font = NSFont.systemFont(ofSize: size * CGFloat(S), weight: weight)
    let para = NSMutableParagraphStyle(); para.alignment = .center
    let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color, .paragraphStyle: para]
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
    NSAttributedString(string: string, attributes: attrs)
        .draw(in: NSRect(x: 0, y: y(t) - px(size * 1.4), width: CGFloat(w), height: px(size * 1.5)))
    NSGraphicsContext.restoreGraphicsState()
}
let ink = NSColor(calibratedRed: 0.11, green: 0.11, blue: 0.13, alpha: 1)
text("OpenEmu Pre-Release Test Build", size: 24, weight: .bold, top: 40, color: ink)
text("1   Drag OpenEmu onto Applications", size: 17, weight: .semibold, top: 125, color: ink)
text("2   Then double-click each core, one at a time", size: 17, weight: .semibold, top: 305, color: ink)

// An arrow from the app to the Applications shortcut (icons sit at x = 170 and 430, centre y = 215).
ctx.setStrokeColor(red: 0.04, green: 0.38, blue: 0.82, alpha: 1)
ctx.setFillColor(red: 0.04, green: 0.38, blue: 0.82, alpha: 1)
ctx.setLineWidth(px(5)); ctx.setLineCap(.round)
ctx.move(to: CGPoint(x: px(240), y: y(215))); ctx.addLine(to: CGPoint(x: px(345), y: y(215))); ctx.strokePath()
ctx.move(to: CGPoint(x: px(362), y: y(215)))
ctx.addLine(to: CGPoint(x: px(338), y: y(201))); ctx.addLine(to: CGPoint(x: px(338), y: y(229))); ctx.closePath(); ctx.fillPath()

guard let out = ctx.makeImage() else { exit(1) }
let rep = NSBitmapImageRep(cgImage: out)
rep.size = NSSize(width: CGFloat(w) / 2, height: CGFloat(h) / 2)  // 144 dpi
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: args[1]))
print("wrote \(args[1]) \(w)x\(h)")
