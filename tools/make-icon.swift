// Renders the app icon (Resources/icon.svg, from tools/make-logo.py) to a 1024px PNG.
// Usage: swift tools/make-icon.swift <out.png>
import AppKit

let out = CommandLine.arguments[1]
let svg = URL(filePath: #filePath).deletingLastPathComponent().appending(path: "../Resources/icon.svg")
guard let logo = NSImage(contentsOf: svg) else { fatalError("cannot read \(svg.path)") }
let px = 1024
let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8,
                           samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                           colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
// macOS icon grid: an 824px tile centred on the 1024 canvas.
logo.draw(in: NSRect(x: 100, y: 100, width: 824, height: 824))
NSGraphicsContext.current = nil
try! rep.representation(using: .png, properties: [:])!.write(to: URL(filePath: out))
