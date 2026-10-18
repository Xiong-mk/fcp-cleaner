#!/usr/bin/env swift
// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Steve
// Render a deterministic Finder background using only macOS AppKit.
import AppKit

guard CommandLine.arguments.count == 2 else {
    fputs("Usage: swift render_dmg_background.swift OUTPUT.png\n", stderr)
    exit(2)
}

let width = 900
let height = 560
let bitmap = NSBitmapImageRep(
    bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
    isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
)!
let graphics = NSGraphicsContext(bitmapImageRep: bitmap)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = graphics
let cg = graphics.cgContext
cg.translateBy(x: 0, y: CGFloat(height))
cg.scaleBy(x: 1, y: -1)
let flipped = NSGraphicsContext(cgContext: cg, flipped: true)
NSGraphicsContext.current = flipped

func color(_ red: CGFloat, _ green: CGFloat, _ blue: CGFloat) -> NSColor {
    NSColor(srgbRed: red, green: green, blue: blue, alpha: 1)
}
func text(_ value: String, y: CGFloat, size: CGFloat,
          weight: NSFont.Weight = .regular, ink: NSColor) {
    let paragraph = NSMutableParagraphStyle()
    paragraph.alignment = .center
    (value as NSString).draw(in: NSRect(x: 40, y: y, width: 820, height: 48), withAttributes: [
        .font: NSFont.systemFont(ofSize: size, weight: weight),
        .foregroundColor: ink,
        .paragraphStyle: paragraph
    ])
}

let bounds = NSRect(x: 0, y: 0, width: width, height: height)
color(0.97, 0.98, 0.995).setFill()
bounds.fill()
let wash = NSGradient(starting: .white, ending: color(0.94, 0.96, 0.99))!
wash.draw(in: bounds, angle: 90)
let ink = color(0.16, 0.20, 0.28)
let muted = color(0.42, 0.47, 0.56)
let accent = color(0.31, 0.43, 0.88)

text("FCP Cleaner", y: 38, size: 30, weight: .semibold, ink: ink)
text("拖入应用程序，即可完成安装", y: 83, size: 16, ink: muted)

// Leave the real Finder icons at (200,245), (700,245), (450,415).
// The arrow rises above the two app/folder icons and ends toward Applications.
let arrow = NSBezierPath()
arrow.move(to: NSPoint(x: 320, y: 246))
arrow.curve(to: NSPoint(x: 580, y: 246),
            controlPoint1: NSPoint(x: 375, y: 133),
            controlPoint2: NSPoint(x: 525, y: 133))
arrow.lineWidth = 7
arrow.lineCapStyle = .round
accent.setStroke()
arrow.stroke()
let head = NSBezierPath()
head.move(to: NSPoint(x: 553, y: 233))
head.line(to: NSPoint(x: 580, y: 246))
head.line(to: NSPoint(x: 585, y: 216))
head.lineWidth = 7
head.lineCapStyle = .round
head.lineJoinStyle = .round
head.stroke()

let divider = NSBezierPath()
divider.move(to: NSPoint(x: 110, y: 345))
divider.line(to: NSPoint(x: 790, y: 345))
divider.lineWidth = 1
color(0.86, 0.89, 0.94).setStroke()
divider.stroke()

text("首次打开遇到提示？请双击下方安装说明", y: 500, size: 14, ink: muted)
NSGraphicsContext.restoreGraphicsState()

let output = URL(fileURLWithPath: CommandLine.arguments[1])
try FileManager.default.createDirectory(at: output.deletingLastPathComponent(),
                                     withIntermediateDirectories: true)
let data = bitmap.representation(using: .png, properties: [:])!
try data.write(to: output, options: .atomic)
print("Rendered \(width) × \(height): \(output.lastPathComponent)")
