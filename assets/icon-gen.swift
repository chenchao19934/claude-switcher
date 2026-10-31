import Cocoa

// Code-native icon source: all shapes are drawn directly at 2× into RGBA.
// Run from any working directory with: swift /path/to/assets/icon-gen.swift
let pixels = 2048
let canvas: CGFloat = 1024
guard let bitmap = NSBitmapImageRep(
    bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
    colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
), let context = NSGraphicsContext(bitmapImageRep: bitmap) else {
    fatalError("Cannot create RGBA drawing context")
}
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = context
context.cgContext.clear(CGRect(x: 0, y: 0, width: pixels, height: pixels))
context.cgContext.scaleBy(x: CGFloat(pixels) / canvas, y: CGFloat(pixels) / canvas)
context.cgContext.setAllowsAntialiasing(true)
context.cgContext.setShouldAntialias(true)

func color(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat) -> NSColor {
    NSColor(srgbRed: r, green: g, blue: b, alpha: 1)
}

// Tile: 82% of canvas, with no outside shadow or raster texture.
let tile = NSBezierPath(roundedRect: NSRect(x: 92, y: 92, width: 840, height: 840),
                        xRadius: 200, yRadius: 200)
NSGradient(starting: color(0.965, 0.977, 0.995), ending: .white)!.draw(in: tile, angle: 90)
color(0.91, 0.935, 0.965).setStroke()
tile.lineWidth = 1
tile.stroke()

// A broad directional ribbon; its half-turn counterpart completes the loop.
func ribbon() -> NSBezierPath {
    let path = NSBezierPath()
    path.move(to: NSPoint(x: 274, y: 557))
    path.line(to: NSPoint(x: 377, y: 660))
    path.curve(to: NSPoint(x: 458, y: 694),
               controlPoint1: NSPoint(x: 398, y: 681),
               controlPoint2: NSPoint(x: 427, y: 694))
    path.line(to: NSPoint(x: 588, y: 694))
    path.curve(to: NSPoint(x: 600, y: 706),
               controlPoint1: NSPoint(x: 595, y: 694),
               controlPoint2: NSPoint(x: 600, y: 699))
    path.line(to: NSPoint(x: 600, y: 731))
    path.curve(to: NSPoint(x: 630, y: 743),
               controlPoint1: NSPoint(x: 600, y: 747),
               controlPoint2: NSPoint(x: 619, y: 754))
    path.line(to: NSPoint(x: 781, y: 592))
    path.curve(to: NSPoint(x: 781, y: 536),
               controlPoint1: NSPoint(x: 797, y: 576),
               controlPoint2: NSPoint(x: 797, y: 552))
    path.line(to: NSPoint(x: 723, y: 478))
    path.line(to: NSPoint(x: 654, y: 547))
    path.line(to: NSPoint(x: 604, y: 597))
    path.line(to: NSPoint(x: 458, y: 597))
    path.curve(to: NSPoint(x: 434, y: 587),
               controlPoint1: NSPoint(x: 449, y: 597),
               controlPoint2: NSPoint(x: 440, y: 593))
    path.line(to: NSPoint(x: 343, y: 496))
    path.close()
    return path
}

let blue = ribbon()
let cyan = ribbon()
var rotation = AffineTransform(translationByX: 1024, byY: 1024)
rotation.scale(-1)
cyan.transform(using: rotation)
NSGradient(starting: color(0.00, 0.72, 0.85), ending: color(0.00, 0.82, 0.87))!
    .draw(in: cyan, angle: 20)
NSGradient(starting: color(0.025, 0.31, 0.94), ending: color(0.02, 0.47, 1.0))!
    .draw(in: blue, angle: 35)

// Geometric folds explain the overlap without shadows or noise.
func fold(_ points: [NSPoint], fill: NSColor) {
    let path = NSBezierPath()
    path.move(to: points[0])
    for point in points.dropFirst() { path.line(to: point) }
    path.close()
    fill.setFill()
    path.fill()
}
fold([NSPoint(x: 274, y: 557), NSPoint(x: 343, y: 496), NSPoint(x: 395, y: 548)],
     fill: color(0.015, 0.30, 0.73))
fold([NSPoint(x: 750, y: 467), NSPoint(x: 681, y: 528), NSPoint(x: 629, y: 476)],
     fill: color(0.005, 0.56, 0.71))

NSGraphicsContext.restoreGraphicsState()
guard let png = bitmap.representation(using: .png, properties: [:]) else {
    fatalError("Cannot encode PNG")
}
let output = URL(fileURLWithPath: #filePath).standardizedFileURL
    .deletingLastPathComponent().appendingPathComponent("icon-2048.png")
try png.write(to: output, options: .atomic)
print(output.path)
