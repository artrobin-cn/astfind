// Flat / line-art icon candidates for Astfind, following the plate + mark convention of
// Feishu / ChatGPT / Qoder: white squircle, single flat mark, no gradients or gloss.
//
// Usage:
//   swift make-flat-icons.swift              writes <id>-1024.png and <id>.icns for every variant
//   swift make-flat-icons.swift sheet NAME   writes the contact sheet NAME.png

import AppKit
import SwiftUI

let canvas: CGFloat = 1024
let body = CGRect(x: 100, y: 100, width: 824, height: 824)
let plateRadius: CGFloat = 186
let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!

func c(_ hex: UInt32, _ a: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: a)
}

let ink = c(0x1B2432)
let accent = c(0x2F7CF6)
let white = c(0xFFFFFF)
let tints: [CGColor] = [c(0xBBD2FB), c(0x7FB0F8)]

// MARK: - Geometry helpers (design in top-left coordinates)

func P(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: x, y: canvas - y) }

/// Rect from a top-left origin, in canvas units.
func TR(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) -> CGRect {
    CGRect(x: x, y: canvas - y - h, width: w, height: h)
}

func roundPath(_ r: CGRect, _ radius: CGFloat) -> CGPath {
    RoundedRectangle(cornerRadius: radius, style: .continuous).path(in: r).cgPath
}

func fill(_ ctx: CGContext, _ path: CGPath, _ color: CGColor) {
    ctx.saveGState()
    ctx.setFillColor(color)
    ctx.addPath(path)
    ctx.fillPath()
    ctx.restoreGState()
}

func stroke(_ ctx: CGContext, _ path: CGPath, _ color: CGColor, _ width: CGFloat,
            cap: CGLineCap = .round, join: CGLineJoin = .round) {
    ctx.saveGState()
    ctx.setLineWidth(width)
    ctx.setStrokeColor(color)
    ctx.setLineCap(cap)
    ctx.setLineJoin(join)
    ctx.addPath(path)
    ctx.strokePath()
    ctx.restoreGState()
}

func circlePath(tl center: CGPoint, radius: CGFloat) -> CGPath {
    CGPath(ellipseIn: TR(center.x - radius, center.y - radius, radius * 2, radius * 2), transform: nil)
}

/// Point at 45° down-right of a top-left-space point.
func downRight(_ p: CGPoint, _ distance: CGFloat) -> CGPoint {
    CGPoint(x: p.x + distance * 0.70711, y: p.y + distance * 0.70711)
}

func linePath(from a: CGPoint, to b: CGPoint) -> CGPath {
    let path = CGMutablePath()
    path.move(to: P(a.x, a.y))
    path.addLine(to: P(b.x, b.y))
    return path
}

// MARK: - Plate

func plate(_ ctx: CGContext) {
    let sq = RoundedRectangle(cornerRadius: plateRadius, style: .continuous).path(in: body).cgPath
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -10), blur: 30, color: c(0x0B1220, 0.18))
    ctx.addPath(sq)
    ctx.setFillColor(white)
    ctx.fillPath()
    ctx.restoreGState()
    stroke(ctx, sq, c(0x0B1220, 0.07), 2, cap: .butt)
}

func clipPlate(_ ctx: CGContext) {
    let sq = RoundedRectangle(cornerRadius: plateRadius, style: .continuous).path(in: body).cgPath
    ctx.addPath(sq)
    ctx.clip()
}

// MARK: - Magnifier

/// Ring plus handle. The handle starts on the ring's centreline, so its round cap spans exactly
/// the ring band: no bulge inside the glass and no step on the outside silhouette.
func magnifier(_ ctx: CGContext, center: CGPoint, radius: CGFloat, weight: CGFloat,
               reach: CGFloat, color: CGColor) {
    let start = downRight(center, radius)
    let end = downRight(center, radius + reach)
    stroke(ctx, linePath(from: start, to: end), color, weight)
    stroke(ctx, circlePath(tl: center, radius: radius), color, weight)
}

/// Bounding box of ring + handle cap, in design (top-left) coordinates.
func lensBounds(_ center: CGPoint, _ radius: CGFloat, _ weight: CGFloat, _ reach: CGFloat) -> CGRect {
    let outer = radius + weight / 2
    var box = CGRect(x: center.x - outer, y: center.y - outer, width: outer * 2, height: outer * 2)
    let end = downRight(center, radius + reach)
    box = box.union(CGRect(x: end.x - weight / 2, y: end.y - weight / 2, width: weight, height: weight))
    return box
}

// MARK: - A · lens + document

let lensCenter = CGPoint(x: 489.5, y: 489.5)
let lensRadius: CGFloat = 200
let lensWeight: CGFloat = 58
let handleReach: CGFloat = 150
let pageSize = CGSize(width: 150, height: 184)
let pageRadius: CGFloat = 27

let aBounds = lensBounds(lensCenter, lensRadius, lensWeight, handleReach)

func pageRect() -> CGRect {
    TR(lensCenter.x - pageSize.width / 2, lensCenter.y - pageSize.height / 2,
       pageSize.width, pageSize.height)
}

/// Three text lines inside the page, top-aligned with even margins.
func textLines(_ ctx: CGContext, _ color: CGColor, barHeight: CGFloat, widths: [CGFloat], gap: CGFloat) {
    let inset: CGFloat = 40
    let top = lensCenter.y - pageSize.height / 2 + inset
    for (i, w) in widths.enumerated() {
        let y = top + CGFloat(i) * (barHeight + gap)
        fill(ctx, roundPath(TR(lensCenter.x - w / 2, y, w, barHeight), barHeight / 2), color)
    }
}

func aFlat(_ ctx: CGContext) {
    fill(ctx, roundPath(pageRect(), pageRadius), accent)
    textLines(ctx, white, barHeight: 17, widths: [84, 84, 56], gap: 25)
    magnifier(ctx, center: lensCenter, radius: lensRadius, weight: lensWeight, reach: handleReach, color: ink)
}

func aLine(_ ctx: CGContext) {
    let page = pageRect()
    fill(ctx, roundPath(page, pageRadius), white)
    textLines(ctx, ink, barHeight: 18, widths: [82, 82, 54], gap: 24)
    stroke(ctx, roundPath(page, pageRadius), ink, 28)
    magnifier(ctx, center: lensCenter, radius: lensRadius, weight: lensWeight, reach: handleReach, color: ink)
}

// MARK: - C · sources behind the lens

/// The cards are larger than the lens and fan up-left, so the stack keeps a readable body
/// at the lower-left while the glass rests on the front card's upper-right corner.
/// Everything lives in one style struct so the composition can be re-proportioned without
/// touching the drawing code.
struct CLayers {
    var cardSize: CGFloat = 296
    var cardStep: CGFloat = 56
    var origin = CGPoint(x: 336, y: 404)          // front card, top-left
    var lensCenter = CGPoint(x: 566, y: 476)
    var lensRadius: CGFloat = 116
    var lensWeight: CGFloat = 44
    var reach: CGFloat = 92
    var dotRadius: CGFloat = 26

    static let cardRadius: CGFloat = 62

    func cardRect(_ index: Int) -> CGRect {
        TR(origin.x - CGFloat(index) * cardStep,
           origin.y - CGFloat(index) * cardStep,
           cardSize, cardSize)
    }

    var bounds: CGRect {
        cardRect(2).union(cardRect(1)).union(cardRect(0))
            .union(lensBounds(lensCenter, lensRadius, lensWeight, reach))
    }

    func draw(_ ctx: CGContext) {
        fill(ctx, roundPath(cardRect(2), Self.cardRadius), tints[0])
        fill(ctx, roundPath(cardRect(1), Self.cardRadius), tints[1])
        fill(ctx, roundPath(cardRect(0), Self.cardRadius), accent)
        magnifier(ctx, center: lensCenter, radius: lensRadius, weight: lensWeight, reach: reach, color: ink)
        fill(ctx, circlePath(tl: lensCenter, radius: dotRadius), white)
    }
}

let cStyle = CLayers()

/// Bigger glass, same cards: the lens gains weight relative to the stack.
let cStyleLoud = CLayers(cardSize: 296, cardStep: 56,
                         origin: CGPoint(x: 336, y: 404),
                         lensCenter: CGPoint(x: 566, y: 512),
                         lensRadius: 132, lensWeight: 48, reach: 100, dotRadius: 30)

/// Line art keeps the cards inside the glass: overlapping outlined cards behind a ring can only
/// be separated with a keyline, and the keyline always leaves a clipped stub on the card's corner.
func cLine(_ ctx: CGContext) {
    for i in (0...2).reversed() {
        let r = stackRect(i)
        fill(ctx, roundPath(r, sCardRadius), white)
        stroke(ctx, roundPath(r, sCardRadius), ink, 28)
    }
    magnifier(ctx, center: lensCenter, radius: lensRadius, weight: lensWeight, reach: handleReach, color: ink)
}

// MARK: - C · sources inside the lens

let sCardSize: CGFloat = 146
let sCardRadius: CGFloat = 32
let sCardStep: CGFloat = 34
/// Offset by one step so the fan's bounding box — not the front card — sits on the lens centre.
let sFrontCenter = CGPoint(x: lensCenter.x + sCardStep, y: lensCenter.y + sCardStep)

func stackRect(_ index: Int) -> CGRect {
    let center = CGPoint(x: sFrontCenter.x - CGFloat(index) * sCardStep,
                         y: sFrontCenter.y - CGFloat(index) * sCardStep)
    return TR(center.x - sCardSize / 2, center.y - sCardSize / 2, sCardSize, sCardSize)
}

func cInside(_ ctx: CGContext) {
    fill(ctx, roundPath(stackRect(2), sCardRadius), tints[0])
    fill(ctx, roundPath(stackRect(1), sCardRadius), tints[1])
    fill(ctx, roundPath(stackRect(0), sCardRadius), accent)
    magnifier(ctx, center: lensCenter, radius: lensRadius, weight: lensWeight, reach: handleReach, color: ink)
}

// MARK: - Variants & rendering

struct Variant {
    let id: String
    let title: String
    let note: String
    let bounds: CGRect      // design-space bbox of the mark, used for optical centering
    var scale: CGFloat = 1  // extra enlargement of the finished mark, around its own centre
    let draw: (CGContext) -> Void
}

let variants: [Variant] = [
    Variant(id: "a-flat-lens-doc", title: "A1 · 平涂透镜", note: "墨圈 + 蓝色页面，两色平涂",
            bounds: aBounds, draw: aFlat),
    Variant(id: "a-line-lens-doc", title: "A2 · 墨线透镜", note: "通体墨线，页面轮廓与三行字",
            bounds: aBounds, draw: aLine),
    Variant(id: "c-flat-layers", title: "C1 · 层叠镜外", note: "当前装机版：整图约占底板 62%",
            bounds: cStyle.bounds, draw: cStyle.draw),
    Variant(id: "c-flat-layers-big", title: "C1+ · 整图 +10%", note: "只放大整图，镜圈与卡片比例不变",
            bounds: cStyle.bounds, scale: 1.10, draw: cStyle.draw),
    Variant(id: "c-flat-layers-bigger", title: "C1++ · +16% 且镜圈加大", note: "整图再大，镜圈额外 +14%，镜心下移压进底卡",
            bounds: cStyleLoud.bounds, scale: 1.16, draw: cStyleLoud.draw),
    Variant(id: "c-line-layers", title: "C2 · 层叠镜内·线", note: "三张卡收进镜内，纯线无填充",
            bounds: aBounds, draw: cLine),
    Variant(id: "c-inside-stack", title: "C3 · 层叠镜内·涂", note: "同 C2 构图，蓝色平涂",
            bounds: aBounds, draw: cInside),
]

func render(_ variant: Variant, size: Int) -> CGImage {
    let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                        space: sRGB, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.interpolationQuality = .high
    ctx.scaleBy(x: CGFloat(size) / canvas, y: CGFloat(size) / canvas)
    plate(ctx)
    ctx.saveGState()
    clipPlate(ctx)
    ctx.translateBy(x: 512 - variant.bounds.midX, y: -(512 - variant.bounds.midY))
    if variant.scale != 1 {
        ctx.translateBy(x: 512, y: 512)
        ctx.scaleBy(x: variant.scale, y: variant.scale)
        ctx.translateBy(x: -512, y: -512)
    }
    variant.draw(ctx)
    ctx.restoreGState()
    return ctx.makeImage()!
}

func pngData(_ image: CGImage) -> Data {
    NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])!
}

let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()

func writeICNS(_ variant: Variant, to url: URL) throws {
    let fm = FileManager.default
    let iconset = fm.temporaryDirectory.appendingPathComponent("Astfind-\(UUID().uuidString).iconset")
    try fm.createDirectory(at: iconset, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: iconset) }
    for base in [16, 32, 128, 256, 512] {
        try pngData(render(variant, size: base)).write(to: iconset.appendingPathComponent("icon_\(base)x\(base).png"))
        try pngData(render(variant, size: base * 2)).write(to: iconset.appendingPathComponent("icon_\(base)x\(base)@2x.png"))
    }
    let task = Process()
    task.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
    task.arguments = ["-c", "icns", iconset.path, "-o", url.path]
    try task.run()
    task.waitUntilExit()
    guard task.terminationStatus == 0 else { throw NSError(domain: "iconutil", code: Int(task.terminationStatus)) }
}

// MARK: - Contact sheet

func sheet(_ list: [Variant], to url: URL, heading: String, subheading: String) throws {
    let W: CGFloat = 2048, H: CGFloat = 1340
    let ctx = CGContext(data: nil, width: Int(W), height: Int(H), bitsPerComponent: 8, bytesPerRow: 0,
                        space: sRGB, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.interpolationQuality = .high
    ctx.setFillColor(c(0xF6F7F9))
    ctx.fill(CGRect(x: 0, y: 0, width: W, height: H))
    ctx.setFillColor(c(0x0E1116))
    ctx.fill(CGRect(x: 0, y: 0, width: W, height: 340))

    let previous = NSGraphicsContext.current
    NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)

    func text(_ s: String, centeredAt x: CGFloat, bottom y: CGFloat, size: CGFloat,
              weight: NSFont.Weight, color: NSColor) {
        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: size, weight: weight),
                                                   .foregroundColor: color]
        let w = (s as NSString).size(withAttributes: attrs).width
        (s as NSString).draw(at: CGPoint(x: x - w / 2, y: y), withAttributes: attrs)
    }

    let inkColor = NSColor(srgbRed: 0.09, green: 0.11, blue: 0.15, alpha: 1)
    let sub = NSColor(srgbRed: 0.42, green: 0.45, blue: 0.5, alpha: 1)

    text(heading, centeredAt: W / 2, bottom: 1210, size: 46, weight: .bold, color: inkColor)
    text(subheading, centeredAt: W / 2, bottom: 1164, size: 24, weight: .regular, color: sub)

    let iconSize: CGFloat = list.count > 5 ? 260 : (list.count > 4 ? 300 : 360)
    let spacing: CGFloat = min(480, (W - 160) / CGFloat(max(list.count - 1, 1)))
    let firstX = (W - spacing * CGFloat(list.count - 1)) / 2
    for (i, v) in list.enumerated() {
        let x = firstX + spacing * CGFloat(i)
        ctx.draw(render(v, size: Int(iconSize * 2)), in: CGRect(x: x - iconSize / 2, y: 810, width: iconSize, height: iconSize))
        text(v.title, centeredAt: x, bottom: 762, size: 28, weight: .semibold, color: inkColor)
        text(v.note, centeredAt: x, bottom: 728, size: 19, weight: .regular, color: sub)
    }

    // Small sizes, actual pixels, on the dark strip.
    let smalls: [CGFloat] = [128, 64, 32, 16]
    let offsets: [CGFloat] = [0, 150, 234, 288]
    for (i, v) in list.enumerated() {
        let baseX = firstX + spacing * CGFloat(i) - 160
        for (j, s) in smalls.enumerated() {
            ctx.draw(render(v, size: Int(s)), in: CGRect(x: baseX + offsets[j], y: 180, width: s, height: s))
            text(String(Int(s)), centeredAt: baseX + offsets[j] + s / 2, bottom: 138, size: 19,
                 weight: .regular, color: NSColor(srgbRed: 0.58, green: 0.62, blue: 0.68, alpha: 1))
        }
    }

    NSGraphicsContext.current = previous
    try pngData(ctx.makeImage()!).write(to: url)
}

// MARK: - Main

if CommandLine.arguments.count > 2, CommandLine.arguments[1] == "sheet" {
    let ids = Array(CommandLine.arguments.dropFirst(3))
    let list = ids.isEmpty ? variants : variants.filter { ids.contains($0.id) }
    guard !list.isEmpty else {
        print("no variant matched \(ids)")
        exit(1)
    }
    let heading = ids.isEmpty ? "Astfind · 扁平 / 线条图标候选" : "Astfind · C1 放大对比"
    let subheading = ids.isEmpty
        ? "同一套白色圆角底板；去掉渐变与高光，只有平涂与墨线两种笔法"
        : "同一构图三种尺寸：现版 / 整图 +10% / 整图 +16% 且镜圈加大"
    try sheet(list, to: root.appendingPathComponent(CommandLine.arguments[2]),
              heading: heading, subheading: subheading)
    print("sheet: \(CommandLine.arguments[2])")
    exit(0)
}

for v in variants {
    try pngData(render(v, size: 1024)).write(to: root.appendingPathComponent("\(v.id)-1024.png"))
    try writeICNS(v, to: root.appendingPathComponent("\(v.id).icns"))
    print("wrote \(v.id)")
}
