import AppKit
import Foundation
import ImageIO

let root = URL(fileURLWithPath: "/Users/atr/code/Compositor/work/geometry-validation/input", isDirectory: true)
try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

struct Item {
    var file: String
    var kind: String
    var scene: String
    var expect: String
    var note: String
}

var items: [Item] = []

func save(_ image: CGImage, _ name: String) {
    let url = root.appendingPathComponent(name)
    guard let dest = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil) else {
        fputs("could not create \(name)\n", stderr)
        exit(1)
    }
    CGImageDestinationAddImage(dest, image, nil)
    guard CGImageDestinationFinalize(dest) else {
        fputs("could not write \(name)\n", stderr)
        exit(1)
    }
}

func canvas(_ width: Int, _ height: Int, _ draw: (CGContext) -> Void) -> CGImage {
    let space = CGColorSpace(name: CGColorSpace.sRGB)!
    let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                            space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    context.setFillColor(CGColor(srgbRed: 0.94, green: 0.94, blue: 0.93, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    context.translateBy(x: 0, y: CGFloat(height))
    context.scaleBy(x: 1, y: -1)
    draw(context)
    return context.makeImage()!
}

func stroke(_ context: CGContext, _ a: CGPoint, _ b: CGPoint, width: CGFloat = 10) {
    context.setStrokeColor(CGColor(srgbRed: 0.06, green: 0.06, blue: 0.07, alpha: 1))
    context.setLineWidth(width)
    context.setLineCap(.square)
    context.move(to: a)
    context.addLine(to: b)
    context.strokePath()
}

func throughY(vp: CGPoint, anchor: CGPoint, y0: CGFloat, y1: CGFloat) -> (CGPoint, CGPoint) {
    let slope = (anchor.x - vp.x) / (anchor.y - vp.y)
    func at(_ y: CGFloat) -> CGPoint { CGPoint(x: vp.x + (y - vp.y) * slope, y: y) }
    return (at(y0), at(y1))
}

func throughX(vp: CGPoint, anchor: CGPoint, x0: CGFloat, x1: CGFloat) -> (CGPoint, CGPoint) {
    let slope = (anchor.y - vp.y) / (anchor.x - vp.x)
    func at(_ x: CGFloat) -> CGPoint { CGPoint(x: x, y: vp.y + (x - vp.x) * slope) }
    return (at(x0), at(x1))
}

let width = 1200
let height = 800

let strongVP = CGPoint(x: 600, y: -900)
let strong = canvas(width, height) { context in
    for anchor in [CGFloat(260), 480, 760, 980] {
        let line = throughY(vp: strongVP, anchor: CGPoint(x: anchor, y: 640), y0: 30, y1: 770)
        stroke(context, line.0, line.1)
    }
}
save(strong, "synthetic-strong-vertical.png")
items.append(Item(file: "synthetic-strong-vertical.png", kind: "synthetic", scene: "strong architectural perspective",
                  expect: "vertical", note: "Four walls meet at (600, -900) in y-down pixels. No horizon."))

let mildVP = CGPoint(x: 600, y: -4200)
let mild = canvas(width, height) { context in
    for anchor in [CGFloat(220), 520, 820, 1040] {
        let line = throughY(vp: mildVP, anchor: CGPoint(x: anchor, y: 500), y0: 40, y1: 760)
        stroke(context, line.0, line.1)
    }
}
save(mild, "synthetic-mild-vertical.png")
items.append(Item(file: "synthetic-mild-vertical.png", kind: "synthetic", scene: "mild perspective",
                  expect: "vertical", note: "Vanishing point (600, -4200). Convergence is only a few degrees."))

let interiorV = CGPoint(x: 600, y: -700)
let interiorH = CGPoint(x: 3200, y: 420)
let interior = canvas(width, height) { context in
    for anchor in [CGFloat(180), 420, 780, 1020] {
        let line = throughY(vp: interiorV, anchor: CGPoint(x: anchor, y: 620), y0: 36, y1: 760)
        stroke(context, line.0, line.1, width: 8)
    }
    for anchor in [CGFloat(140), 320, 520, 700] {
        let line = throughX(vp: interiorH, anchor: CGPoint(x: 600, y: anchor), x0: 40, x1: 1160)
        stroke(context, line.0, line.1, width: 8)
    }
}
save(interior, "synthetic-interior.png")
items.append(Item(file: "synthetic-interior.png", kind: "synthetic", scene: "interior architecture",
                  expect: "full", note: "Vertical vanishing point (600, -700) and horizontal vanishing point (3200, 420)."))

let wideV = CGPoint(x: 600, y: -260)
let wideH = CGPoint(x: 2600, y: 400)
let wide = canvas(width, height) { context in
    for anchor in [CGFloat(160), 400, 800, 1080] {
        let line = throughY(vp: wideV, anchor: CGPoint(x: anchor, y: 700), y0: 50, y1: 760)
        stroke(context, line.0, line.1)
    }
    for anchor in [CGFloat(180), 400, 620] {
        let line = throughX(vp: wideH, anchor: CGPoint(x: 500, y: anchor), x0: 30, x1: 1100)
        stroke(context, line.0, line.1, width: 8)
    }
}
save(wide, "synthetic-wide.png")
items.append(Item(file: "synthetic-wide.png", kind: "synthetic", scene: "wide-angle architecture",
                  expect: "full", note: "Close vertical vanishing point (600, -260), so the walls converge hard."))

let horizon = canvas(width, height) { context in
    stroke(context, CGPoint(x: 40, y: 470), CGPoint(x: 1160, y: 350), width: 12)
    stroke(context, CGPoint(x: 40, y: 620), CGPoint(x: 1160, y: 500), width: 12)
}
save(horizon, "synthetic-tilted-horizon.png")
items.append(Item(file: "synthetic-tilted-horizon.png", kind: "synthetic", scene: "tilted horizon",
                  expect: "level", note: "Two parallel lines, slope -120/1120. No vertical structure."))

let misleading = canvas(width, height) { context in
    stroke(context, CGPoint(x: 40, y: 80), CGPoint(x: 700, y: 720), width: 14)
    stroke(context, CGPoint(x: 200, y: 40), CGPoint(x: 1100, y: 640), width: 14)
    stroke(context, CGPoint(x: 80, y: 700), CGPoint(x: 900, y: 80), width: 12)
    stroke(context, CGPoint(x: 980, y: 60), CGPoint(x: 1080, y: 740), width: 6)
    stroke(context, CGPoint(x: 140, y: 80), CGPoint(x: 200, y: 740), width: 6)
}
save(misleading, "synthetic-misleading-lines.png")
items.append(Item(file: "synthetic-misleading-lines.png", kind: "synthetic", scene: "misleading structural lines",
                  expect: "identity or a very small correction",
                  note: "Long diagonals dominate. Two short near-verticals are weaker and slightly off plumb."))

let blank = canvas(width, height) { context in
    for y in 0..<height {
        let t = CGFloat(y) / CGFloat(height)
        context.setFillColor(CGColor(srgbRed: 0.55 + 0.3 * t, green: 0.62 + 0.2 * t, blue: 0.7, alpha: 1))
        context.fill(CGRect(x: 0, y: y, width: width, height: 1))
    }
}
save(blank, "synthetic-no-lines.png")
items.append(Item(file: "synthetic-no-lines.png", kind: "synthetic", scene: "no useful straight lines",
                  expect: "identity", note: "Smooth gradient. Auto should leave it alone."))

let portraitVP = CGPoint(x: 400, y: -640)
let portrait = canvas(800, 1200) { context in
    for anchor in [CGFloat(140), 300, 520, 680] {
        let line = throughY(vp: portraitVP, anchor: CGPoint(x: anchor, y: 900), y0: 40, y1: 1160)
        stroke(context, line.0, line.1)
    }
}
save(portrait, "synthetic-portrait-vertical.png")
items.append(Item(file: "synthetic-portrait-vertical.png", kind: "synthetic", scene: "portrait orientation",
                  expect: "vertical", note: "800×1200. Vanishing point (400, -640)."))

let offCenterVP = CGPoint(x: 40, y: -800)
let offCenter = canvas(width, height) { context in
    for anchor in [CGFloat(360), 620, 860, 1100] {
        let line = throughY(vp: offCenterVP, anchor: CGPoint(x: anchor, y: 500), y0: 40, y1: 760)
        stroke(context, line.0, line.1)
    }
}
save(offCenter, "synthetic-off-center.png")
items.append(Item(file: "synthetic-off-center.png", kind: "synthetic", scene: "off-center subject",
                  expect: "vertical", note: "Vanishing point (40, -800), left of the frame. Walls sit on the right."))

let samples = [
    ("05-Perspective-Vertical-Tutorial-Kevin_Barre.jpg", "photo-vertical-landscape.png", "strong architectural perspective"),
    ("06-Perspective-Vertical-Tutorial-Kevin_Barre.jpg", "photo-vertical-portrait.png", "portrait architectural perspective"),
    ("12-Perspective-8Points-Tutorial-Martijn_Kort.jpg", "photo-eight-point.png", "two-direction architectural perspective"),
]
let sampleRoot = URL(fileURLWithPath: "/Users/atr/Pictures/DxO ViewPoint 5 Samples", isDirectory: true)
for sample in samples {
    let source = sampleRoot.appendingPathComponent(sample.0)
    guard let src = CGImageSourceCreateWithURL(source as CFURL, nil) else { continue }
    let options: [CFString: Any] = [
        kCGImageSourceCreateThumbnailFromImageAlways: true,
        kCGImageSourceThumbnailMaxPixelSize: 1600,
        kCGImageSourceCreateThumbnailWithTransform: true,
    ]
    guard let image = CGImageSourceCreateThumbnailAtIndex(src, 0, options as CFDictionary) else { continue }
    save(image, sample.1)
    items.append(Item(file: sample.1, kind: "photograph", scene: sample.2, expect: "vertical or full",
                      note: "DxO ViewPoint 5 sample \(sample.0), longest side 1600, re-encoded as PNG with no camera metadata."))
}

let manifest: [String: Any] = [
    "coordinateSystem": "y grows downward, matching the PNG rows",
    "images": items.map { item in
        ["file": item.file, "kind": item.kind, "scene": item.scene, "expect": item.expect, "note": item.note]
    }
]
let data = try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys])
try data.write(to: root.appendingPathComponent("manifest.json"))
print("wrote \(items.count) images")
