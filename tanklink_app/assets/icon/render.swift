import AppKit
// usage: render out.png size layer.svg [layer.svg ...]
let a = CommandLine.arguments
let out = a[1]; let size = Int(a[2])!
let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
for p in a[3...] {
  guard let img = NSImage(contentsOfFile: p) else { fatalError("cannot load \(p)") }
  img.draw(in: NSRect(x: 0, y: 0, width: size, height: size))
}
NSGraphicsContext.restoreGraphicsState()
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
// Re-render (macOS, from assets/icon/):
//   swift render.swift icon_background.png 1024 background.svg
//   swift render.swift icon_foreground.png 1024 foreground.svg
//   swift render.swift icon.png 1024 background.svg foreground.svg
