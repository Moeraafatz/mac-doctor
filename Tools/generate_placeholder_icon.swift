#!/usr/bin/env swift
//
//  generate_placeholder_icon.swift
//  Mac Doctor
//
//  Generates the placeholder 1024 pt master icon. The checked-in PNG sizes
//  in Assets.xcassets/AppIcon.appiconset are derived from this file with
//  /usr/bin/sips. Replace this artwork with an original production icon
//  before public distribution.
//
//  Run from the repository root:
//      /usr/bin/swift Tools/generate_placeholder_icon.swift
//

import AppKit
import Foundation

let canvas = 1024
let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let outputDirectory = root
    .appendingPathComponent("MacDoctor")
    .appendingPathComponent("Resources")
    .appendingPathComponent("Assets.xcassets")
    .appendingPathComponent("AppIcon.appiconset")

try FileManager.default.createDirectory(
    at: outputDirectory,
    withIntermediateDirectories: true
)

guard let bitmap = NSBitmapImageRep(
    bitmapDataPlanes: nil,
    pixelsWide: canvas,
    pixelsHigh: canvas,
    bitsPerSample: 8,
    samplesPerPixel: 4,
    hasAlpha: true,
    isPlanar: false,
    colorSpaceName: .deviceRGB,
    bytesPerRow: 0,
    bitsPerPixel: 0
) else {
    fatalError("Could not allocate the icon bitmap")
}

bitmap.size = NSSize(width: canvas, height: canvas)

NSGraphicsContext.saveGraphicsState()
guard let context = NSGraphicsContext(bitmapImageRep: bitmap) else {
    fatalError("Could not create the icon drawing context")
}
NSGraphicsContext.current = context
context.imageInterpolation = .high
context.shouldAntialias = true

NSColor.clear.setFill()
NSRect(x: 0, y: 0, width: canvas, height: canvas).fill()

let iconRect = NSRect(x: 82, y: 82, width: 860, height: 860)
let iconPath = NSBezierPath(roundedRect: iconRect, xRadius: 196, yRadius: 196)

let dropShadow = NSShadow()
dropShadow.shadowColor = NSColor.black.withAlphaComponent(0.30)
dropShadow.shadowBlurRadius = 38
dropShadow.shadowOffset = NSSize(width: 0, height: -16)
dropShadow.set()

guard let background = NSGradient(colors: [
    NSColor(srgbRed: 0.13, green: 0.12, blue: 0.13, alpha: 1),
    NSColor(srgbRed: 0.04, green: 0.04, blue: 0.05, alpha: 1)
]) else {
    fatalError("Could not create the icon gradient")
}
background.draw(in: iconPath, angle: -55)

NSShadow().set()

NSColor.white.withAlphaComponent(0.18).setStroke()
iconPath.lineWidth = 3
iconPath.stroke()

let glowRect = NSRect(x: 116, y: 470, width: 700, height: 430)
let glowPath = NSBezierPath(ovalIn: glowRect)
guard let glow = NSGradient(colors: [
    NSColor.white.withAlphaComponent(0.14),
    NSColor.white.withAlphaComponent(0.0)
]) else {
    fatalError("Could not create the highlight gradient")
}
glow.draw(in: glowPath, relativeCenterPosition: NSPoint(x: -0.2, y: 0.2))

guard let symbol = NSImage(
    systemSymbolName: "stethoscope",
    accessibilityDescription: nil
) else {
    fatalError("SF Symbol stethoscope is unavailable")
}

let configuration = NSImage.SymbolConfiguration(pointSize: 480, weight: .semibold)
guard let configuredSymbol = symbol.withSymbolConfiguration(configuration) else {
    fatalError("Could not configure the stethoscope symbol")
}

let symbolSize = configuredSymbol.size
let tintedSymbol = NSImage(size: symbolSize, flipped: false) { rect in
    configuredSymbol.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1)
    NSColor.white.setFill()
    rect.fill(using: .sourceAtop)
    return true
}

let maximumSymbolDimension: CGFloat = 520
let scale = min(
    maximumSymbolDimension / symbolSize.width,
    maximumSymbolDimension / symbolSize.height
)
let drawSize = NSSize(
    width: symbolSize.width * scale,
    height: symbolSize.height * scale
)
let drawRect = NSRect(
    x: (CGFloat(canvas) - drawSize.width) / 2,
    y: (CGFloat(canvas) - drawSize.height) / 2,
    width: drawSize.width,
    height: drawSize.height
)

let symbolShadow = NSShadow()
symbolShadow.shadowColor = NSColor.black.withAlphaComponent(0.22)
symbolShadow.shadowBlurRadius = 26
symbolShadow.shadowOffset = NSSize(width: 0, height: -8)
symbolShadow.set()

tintedSymbol.draw(in: drawRect, from: .zero, operation: .sourceOver, fraction: 1)
NSShadow().set()

NSGraphicsContext.restoreGraphicsState()

guard let png = bitmap.representation(using: .png, properties: [:]) else {
    fatalError("Could not encode the icon PNG")
}

let masterURL = outputDirectory.appendingPathComponent("icon_512x512@2x.png")
try png.write(to: masterURL)
print("Wrote \(masterURL.path)")
