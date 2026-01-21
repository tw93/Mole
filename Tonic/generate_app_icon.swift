#!/usr/bin/env swift
//
//  generate_app_icon.swift
//  Tonic
//
//  Run this script to generate app icon assets with gradient drop design
//  Usage: swift generate_app_icon.swift
//

import Foundation
import AppKit

// Icon sizes to generate
let iconSizes = [
    (size: 16, scale: 1, filename: "icon_16x16.png"),
    (size: 16, scale: 2, filename: "icon_16x16@2x.png"),
    (size: 32, scale: 1, filename: "icon_32x32.png"),
    (size: 32, scale: 2, filename: "icon_32x32@2x.png"),
    (size: 128, scale: 1, filename: "icon_128x128.png"),
    (size: 128, scale: 2, filename: "icon_128x128@2x.png"),
    (size: 256, scale: 1, filename: "icon_256x256.png"),
    (size: 256, scale: 2, filename: "icon_256x256@2x.png"),
    (size: 512, scale: 1, filename: "icon_512x512.png"),
    (size: 512, scale: 2, filename: "icon_512x512@2x.png"),
]

// Colors
let accentColor = NSColor(red: 0.3, green: 0.5, blue: 1.0, alpha: 1.0) // TonicColors.accent
let proColor = NSColor(red: 1.0, green: 0.75, blue: 0.0, alpha: 1.0)    // TonicColors.pro

func generateIcon(size: Int, scale: Int, filename: String) {
    let actualSize = CGFloat(size * scale)
    let image = NSImage(size: NSSize(width: actualSize, height: actualSize))
    image.lockFocus()

    let rect = NSRect(x: 0, y: 0, width: actualSize, height: actualSize)

    // Create gradient
    let gradient = NSGradient(colors: [accentColor, proColor])
    gradient?.draw(in: rect, angle: 45)

    // Draw drop shape (circle)
    let dropRect = NSRect(
        x: actualSize * 0.15,
        y: actualSize * 0.15,
        width: actualSize * 0.7,
        height: actualSize * 0.7
    )

    let dropPath = NSBezierPath(ovalIn: dropRect)
    NSColor.white.setFill()
    dropPath.fill()

    // Add highlight
    let highlightRect = NSRect(
        x: actualSize * 0.28,
        y: actualSize * 0.5,
        width: actualSize * 0.15,
        height: actualSize * 0.12
    )
    let highlightPath = NSBezierPath(ovalIn: highlightRect)
    NSColor.white.withAlphaComponent(0.3).setFill()
    highlightPath.fill()

    image.unlockFocus()

    // Save to file
    let outputPath = "Tonic/Assets.xcassets/AppIcon.appiconset/\(filename)"
    if let tiffData = image.tiffRepresentation,
       let bitmap = NSBitmapImageRep(data: tiffData),
       let pngData = bitmap.representation(using: .png, properties: [:]) {
        do {
            try pngData.write(to: URL(fileURLWithPath: outputPath))
            print("Generated: \(filename)")
        } catch {
            print("Error saving \(filename): \(error)")
        }
    }
}

func main() {
    print("Generating Tonic app icons...")
    print("Accent color: \(accentColor)")
    print("Pro color: \(proColor)")
    print()

    for iconInfo in iconSizes {
        generateIcon(size: iconInfo.size, scale: iconInfo.scale, filename: iconInfo.filename)
    }

    print("\nDone! Icons generated to Tonic/Assets.xcassets/AppIcon.appiconset/")
}

main()
