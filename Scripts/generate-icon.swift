// generate-icon.swift — deterministic CoreGraphics renderer for the
// "墨海拾贝" (Ink-Sea Pearl) macOS app icon.
//
// Usage:  swift Scripts/generate-icon.swift
//
// Draws the icon purely from geometry (no external images, no randomness,
// no timestamps, no font rasterization) and emits the 10 PNGs required by a
// macOS AppIcon.appiconset into
// app/Support/Resources/Assets.xcassets/AppIcon.appiconset/.
// Repeated runs on the same machine with the same toolchain produce
// byte-identical files (同机同工具链确定性).
//
// Design (开卷星芒, "open book and star"): a deep ink-blue diagonal
// gradient ground; an open book in warm paper white as the sole large shape
// (a general research library, not a single-discipline monogram); a four-point
// candlelight-gold star rising from the gutter between the pages — the
// "检索发现知识" metaphor; a thin gold ring (#C9A45C) as the single refined
// outline. The canvas is a fully opaque square; the macOS rounded-corner
// mask is applied by the system, not here.
//
// Detail tiers: 16/32px merge the two pages into one silhouette; 64px adds
// the page gutter; 128px and up adds a one-pixel dark offset pass under the
// book for a subtle top-lit relief.

import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

let fm = FileManager.default

let scriptPath = CommandLine.arguments[0]
let repoRoot = URL(fileURLWithPath: scriptPath).deletingLastPathComponent().deletingLastPathComponent()
let iconsetDir = repoRoot.appendingPathComponent("app/Support/Resources/Assets.xcassets/AppIcon.appiconset")

// MARK: - Palette (design system), fixed sRGB color space

let srgb = CGColorSpace(name: CGColorSpace.sRGB)!

func rgb(_ hex: UInt32, alpha: CGFloat = 1.0) -> CGColor {
    CGColor(colorSpace: srgb,
            components: [CGFloat((hex >> 16) & 0xFF) / 255.0,
                         CGFloat((hex >> 8) & 0xFF) / 255.0,
                         CGFloat(hex & 0xFF) / 255.0,
                         alpha])!
}

let bgTop = rgb(0x1B2A3E)      // deep ink blue (upper left)
let bgBottom = rgb(0x0F1622)    // near-black graphite (lower right)
let paperWhite = rgb(0xF5F0E6)  // warm paper white (open book)
let ringGold = rgb(0xC9A45C, alpha: 0.60) // candlelight gold hairline ring
let starGold = rgb(0xC9A45C)    // candlelight gold, full strength (star)
let gutterShadow = rgb(0x0F1622, alpha: 0.40) // page gutter line
let reliefShadow = rgb(0x000000, alpha: 0.35) // book emboss offset (full detail)

// MARK: - Icon drawing (all geometry normalized to canvas size)

// detail tiers: 0 = 16px, 1 = 32px, 2 = 64px, 3 = full detail (>= 128px,
// + book relief). Tiers 0/1 merge the pages into one silhouette; the mark
// must read whole at 16px, so nothing else is dropped.
func drawIcon(pixels: Int, detail: Int) -> CGImage {
    let s = CGFloat(pixels)
    let ctx = CGContext(data: nil, width: pixels, height: pixels,
                        bitsPerComponent: 8, bytesPerRow: 0, space: srgb,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!

    // Bitmap contexts are y-up; all layout below is authored y-down.
    ctx.translateBy(x: 0, y: s)
    ctx.scaleBy(x: 1, y: -1)

    // Background diagonal gradient, upper-left → lower-right (opaque; the
    // rounded-corner silhouette is the system's job).
    let colors = [bgTop, bgBottom] as CFArray
    if let gradient = CGGradient(colorsSpace: srgb, colors: colors, locations: [0.0, 1.0]) {
        ctx.drawLinearGradient(gradient,
                               start: CGPoint(x: 0, y: 0),
                               end: CGPoint(x: s, y: s),
                               options: [])
    }

    // ---- Gold hairline ring (thin outline, the refined accent) ----
    let ringCx = s * 0.5, ringCy = s * 0.5
    let ringR = s * 0.40
    let ringW = max(1.0, s * 0.014)  // ≈1.5pt at 1024px
    ctx.setStrokeColor(ringGold)
    ctx.setLineWidth(ringW)
    ctx.addEllipse(in: CGRect(x: ringCx - ringR, y: ringCy - ringR,
                              width: ringR * 2, height: ringR * 2))
    ctx.strokePath()

    // ---- Open book (warm paper white, centered in the ring, lower half) ----
    let cx = s * 0.5
    let bookHalf = s * 0.25           // half width of the open spread
    let spineY = s * 0.74             // book bottom at the gutter
    let gutterTopY = s * 0.565        // page top at the gutter
    let outerTopY = s * 0.53          // page top at the outer edge

    /// One page of the open spread. `left` mirrors the geometry.
    func pagePath(left: Bool) -> CGPath {
        let sign: CGFloat = left ? -1 : 1
        let outerX = cx + sign * bookHalf
        let p = CGMutablePath()
        p.move(to: CGPoint(x: cx, y: spineY))
        // Bottom edge: a gentle sag toward the outer corner.
        p.addQuadCurve(to: CGPoint(x: outerX, y: spineY - s * 0.012),
                       control: CGPoint(x: cx + sign * bookHalf * 0.55,
                                        y: spineY + s * 0.018))
        // Outer edge with a small page curl.
        p.addQuadCurve(to: CGPoint(x: outerX, y: outerTopY),
                       control: CGPoint(x: outerX + sign * s * 0.012,
                                        y: outerTopY + s * 0.035))
        // Top edge: a soft arc rising from the gutter to the outer edge.
        p.addQuadCurve(to: CGPoint(x: cx, y: gutterTopY),
                       control: CGPoint(x: cx + sign * bookHalf * 0.5,
                                        y: outerTopY - s * 0.006))
        p.closeSubpath()
        return p
    }

    /// Whole-spread silhouette for the small tiers (no gutter, no curl).
    func bookSilhouettePath() -> CGPath {
        let p = CGMutablePath()
        let leftX = cx - bookHalf, rightX = cx + bookHalf
        p.move(to: CGPoint(x: leftX, y: outerTopY + s * 0.015))
        p.addQuadCurve(to: CGPoint(x: cx, y: gutterTopY),
                       control: CGPoint(x: cx - bookHalf * 0.5,
                                        y: outerTopY - s * 0.004))
        p.addQuadCurve(to: CGPoint(x: rightX, y: outerTopY + s * 0.015),
                       control: CGPoint(x: cx + bookHalf * 0.5,
                                        y: outerTopY - s * 0.004))
        p.addQuadCurve(to: CGPoint(x: rightX, y: spineY - s * 0.012),
                       control: CGPoint(x: rightX + s * 0.008,
                                        y: outerTopY + s * 0.05))
        p.addQuadCurve(to: CGPoint(x: cx, y: spineY),
                       control: CGPoint(x: cx + bookHalf * 0.55,
                                        y: spineY + s * 0.016))
        p.addQuadCurve(to: CGPoint(x: leftX, y: spineY - s * 0.012),
                       control: CGPoint(x: cx - bookHalf * 0.55,
                                        y: spineY + s * 0.016))
        p.closeSubpath()
        return p
    }

    let leftPage = pagePath(left: true)
    let rightPage = pagePath(left: false)
    if detail >= 3 {
        // Top-lit relief: a 1px dark offset pass beneath the paper face.
        ctx.saveGState()
        ctx.translateBy(x: 1.0, y: -1.0)
        ctx.setFillColor(reliefShadow)
        ctx.addPath(leftPage)
        ctx.addPath(rightPage)
        ctx.fillPath()
        ctx.restoreGState()
    }
    ctx.setFillColor(paperWhite)
    if detail >= 2 {
        ctx.addPath(leftPage)
        ctx.addPath(rightPage)
        ctx.fillPath()
        // Gutter line where the pages meet.
        ctx.setStrokeColor(gutterShadow)
        ctx.setLineWidth(max(1.0, s * 0.006))
        ctx.move(to: CGPoint(x: cx, y: gutterTopY))
        ctx.addLine(to: CGPoint(x: cx, y: spineY))
        ctx.strokePath()
    } else {
        ctx.addPath(bookSilhouettePath())
        ctx.fillPath()
    }

    // ---- Rising star (four-point sparkle, candlelight gold) ----
    let starCy = s * 0.36
    let starR = s * 0.08
    let star = CGMutablePath()
    let cardinals = [CGPoint(x: cx, y: starCy - starR),   // top
                     CGPoint(x: cx + starR, y: starCy),  // right
                     CGPoint(x: cx, y: starCy + starR),  // bottom
                     CGPoint(x: cx - starR, y: starCy)]  // left
    star.move(to: cardinals[0])
    for i in 1...4 {
        // Control at the center: edges bow inward into a sparkle.
        star.addQuadCurve(to: cardinals[i % 4], control: CGPoint(x: cx, y: starCy))
    }
    star.closeSubpath()

    ctx.setFillColor(starGold)
    ctx.addPath(star)
    ctx.fillPath()

    return ctx.makeImage()!
}

// MARK: - PNG output (ImageIO, deterministic)

func writePNG(_ image: CGImage, to url: URL) throws {
    let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(dest, image, nil)
    guard CGImageDestinationFinalize(dest) else {
        throw NSError(domain: "generate-icon", code: 1,
                      userInfo: [NSLocalizedDescriptionKey: "failed to finalize PNG at \(url.path)"])
    }
}

let sizes: [(name: String, pixels: Int, detail: Int)] = [
    ("icon_16x16.png",       16,   0),
    ("icon_16x16@2x.png",    32,   1),  // 16pt @2x
    ("icon_32x32.png",       32,   1),
    ("icon_32x32@2x.png",    64,   2),  // 32pt @2x
    ("icon_128x128.png",     128,  3),
    ("icon_128x128@2x.png",  256,  3),
    ("icon_256x256.png",     256,  3),
    ("icon_256x256@2x.png",  512,  3),
    ("icon_512x512.png",     512,  3),
    ("icon_512x512@2x.png",  1024, 3),
]

try fm.createDirectory(at: iconsetDir, withIntermediateDirectories: true)
for spec in sizes {
    let image = drawIcon(pixels: spec.pixels, detail: spec.detail)
    try writePNG(image, to: iconsetDir.appendingPathComponent(spec.name))
    print("wrote \(spec.name) (\(spec.pixels)x\(spec.pixels), detail \(spec.detail))")
}
print("done: \(iconsetDir.path)")
