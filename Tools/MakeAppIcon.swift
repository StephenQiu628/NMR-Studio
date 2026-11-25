// Tools/MakeAppIcon.swift
// /usr/bin/xcrun swift Tools/MakeAppIcon.swift OUTPUT.iconset

import Foundation
import CoreGraphics
import ImageIO
import Darwin

private struct IconError: Error, CustomStringConvertible {
    let description: String
    init(_ message: String) { description = message }
}

private func pt(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
    CGPoint(x: x, y: y)
}

// Continuous-shoulder square. Each corner enters and leaves its straight
// edge with zero curvature. Design coordinates are 128 x 128, y down.
private func platePath(_ b: CGRect) -> CGPath {
    let p = CGMutablePath()
    let r = min(b.width, b.height) * 0.325

    func turn(_ x: CGFloat, _ y: CGFloat, _ dx: CGFloat, _ dy: CGFloat) {
        func q(_ u: CGFloat, _ v: CGFloat) -> CGPoint {
            pt(x + r * (dx * u - dy * v), y + r * (dy * u + dx * v))
        }
        p.addLine(to: q(0, 0))
        p.addCurve(to: q(0.79, 0.21), control1: q(0.27, 0), control2: q(0.58, 0))
        p.addCurve(to: q(1, 1), control1: q(1, 0.42), control2: q(1, 0.73))
    }

    p.move(to: pt(b.midX, b.minY))
    turn(b.maxX - r, b.minY,      1,  0)
    turn(b.maxX,     b.maxY - r,  0,  1)
    turn(b.minX + r, b.maxY,     -1,  0)
    turn(b.minX,     b.minY + r,  0, -1)
    p.closeSubpath()
    return p
}

private struct Renderer {
    let space = CGColorSpace(name: CGColorSpace.sRGB)!

    func color(_ rgb: Int, _ alpha: CGFloat = 1) -> CGColor {
        CGColor(colorSpace: space, components: [
            CGFloat((rgb >> 16) & 255) / 255,
            CGFloat((rgb >> 8) & 255) / 255,
            CGFloat(rgb & 255) / 255,
            alpha
        ])!
    }

    func bitmap(_ side: Int) throws -> CGContext {
        let info = CGBitmapInfo.byteOrder32Big.rawValue |
                   CGImageAlphaInfo.premultipliedLast.rawValue
        guard let c = CGContext(data: nil, width: side, height: side,
                                bitsPerComponent: 8, bytesPerRow: 4 * side,
                                space: space, bitmapInfo: info) else {
            throw IconError("Cannot allocate \(side) × \(side) RGBA bitmap")
        }
        c.clear(CGRect(x: 0, y: 0, width: CGFloat(side), height: CGFloat(side)))
        c.setAllowsAntialiasing(true)
        c.setShouldAntialias(true)
        return c
    }

    func drawSpectrum(_ c: CGContext, pixels: Int) {
        let left: CGFloat = 24, right: CGFloat = 104
        let g: (base: CGFloat, pen: CGFloat, singlet: CGFloat, d1: CGFloat, d2: CGFloat)

        // Hint the resting line and peak centers in the smallest rasters.
        // At 16 px the doublet tips sit on columns 9 and 11, not between them.
        switch pixels {
        case 16: g = (76, 8.5, 44,   76, 92)
        case 32: g = (78, 5.2, 50,   74, 90)
        case 64: g = (80, 4.0, 49,   76, 88)
        default: g = (79, 3.4, 49.5, 76, 88)
        }

        let h1: CGFloat = pixels == 16 ? 44 : 47
        let h2: CGFloat = pixels == 16 ? 18 : 20
        let w1: CGFloat = pixels <= 32 ? 3.9 : 3.55
        let w2: CGFloat = pixels == 16 ? 2.2 : 2.45

        func lorentz(_ x: CGFloat, _ center: CGFloat,
                     _ height: CGFloat, _ halfWidth: CGFloat) -> CGFloat {
            let u = (x - center) / halfWidth
            return height / (1 + u * u)
        }

        func smoothStep(_ value: CGFloat) -> CGFloat {
            let t = min(1, max(0, value))
            return t * t * (3 - 2 * t)
        }

        let trace = CGMutablePath()
        trace.move(to: pt(left, g.base))
        let segments = 1280
        for i in 1...segments {
            let x = left + (right - left) * CGFloat(i) / CGFloat(segments)
            let absorption = lorentz(x, g.singlet, h1, w1)
                           + lorentz(x, g.d1, h2, w2)
                           + lorentz(x, g.d2, h2, w2)
            // Settle just the outer tails onto short, exactly level terminals.
            let window = smoothStep((x - left - 2) / 8)
                       * smoothStep((right - 2 - x) / 8)
            trace.addLine(to: pt(x, g.base - window * absorption))
        }

        // The inlay and the round-ended pen share one lower datum.
        let inlay = CGMutablePath()
        inlay.addPath(trace)
        inlay.addLine(to: pt(right, g.base + g.pen / 2))
        inlay.addLine(to: pt(left, g.base + g.pen / 2))
        inlay.closeSubpath()
        c.setFillColor(color(0x2BB3A3))
        c.addPath(inlay)
        c.fillPath()

        c.setLineCap(.round)
        c.setLineJoin(.round)
        c.setLineWidth(g.pen)
        c.setStrokeColor(color(0xDCFFF1))
        c.addPath(trace)
        c.strokePath()

        // Five quiet scale cuts, no frame or grid. Omit them at Dock sizes.
        if pixels >= 128 {
            c.setStrokeColor(color(0xDCFFF1, 0.30))
            c.setLineWidth(1.6)
            for i in 0...4 {
                let x = left + (right - left) * CGFloat(i) / 4
                let length: CGFloat = i.isMultiple(of: 2) ? 3.3 : 1.6
                c.move(to: pt(x, g.base + 7))
                c.addLine(to: pt(x, g.base + 7 + length))
            }
            c.strokePath()
        }
    }

    func render(_ pixels: Int) throws -> CGImage {
        let samples = pixels <= 32 ? 8 : (pixels <= 128 ? 4 : (pixels == 256 ? 2 : 1))
        let n = pixels * samples
        let c = try bitmap(n)
        let s = CGFloat(n) / 128
        var designToBitmap = CGAffineTransform(a: s, b: 0, c: 0, d: -s,
                                               tx: 0, ty: CGFloat(n))

        let bounds = pixels == 16
            ? CGRect(x: 8, y: 8, width: 112, height: 112)
            : CGRect(x: 12, y: 11, width: 104, height: 104)

        // Cast the contact shadow in untransformed Quartz bitmap space;
        // its offset and blur are in raster pixels, independent of the flip.
        guard let body = platePath(bounds).copy(using: &designToBitmap) else {
            throw IconError("Cannot transform plate outline")
        }
        c.saveGState()
        if pixels > 16 {
            c.setShadow(offset: CGSize(width: 0, height: -1.6 * s),
                        blur: 2.25 * s, color: color(0x032428, 0.29))
        }
        c.setFillColor(color(0x0A3036))
        c.addPath(body)
        c.fillPath()
        c.restoreGState()

        c.concatenate(designToBitmap)

        // A shallow lower lip and one tonal change across the enamel face.
        // The spectral mark itself uses only solid inks.
        let faceBox = CGRect(x: bounds.minX + 0.45, y: bounds.minY + 0.45,
                             width: bounds.width - 0.9, height: bounds.height - 2.1)
        let face = platePath(faceBox)
        let stops = [color(0x195E5B), color(0x0B393F)] as CFArray
        guard let enamel = CGGradient(colorsSpace: space, colors: stops, locations: nil) else {
            throw IconError("Cannot create enamel shading")
        }

        c.saveGState()
        c.addPath(face)
        c.clip()
        c.drawLinearGradient(enamel,
                             start: pt(faceBox.midX, faceBox.minY),
                             end: pt(faceBox.midX, faceBox.maxY),
                             options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
        if pixels >= 64 {
            c.setLineWidth(1.15)
            c.setStrokeColor(color(0xDCFFF1, 0.12))
            c.addPath(face)
            c.strokePath()
        }
        c.restoreGState()

        drawSpectrum(c, pixels: pixels)
        return try resolve(c, pixels: pixels, samples: samples)
    }

    // Exact box resolve on premultiplied RGBA. No matte, resampling halo,
    // or interpolation-kernel choice at the transparent edge.
    func resolve(_ source: CGContext, pixels: Int, samples k: Int) throws -> CGImage {
        var result = source
        if k > 1 {
            result = try bitmap(pixels)
            source.flush()
            result.flush()
            guard let src = source.data?.assumingMemoryBound(to: UInt8.self),
                  let dst = result.data?.assumingMemoryBound(to: UInt8.self) else {
                throw IconError("Cannot access bitmap samples")
            }

            let sr = source.bytesPerRow, dr = result.bytesPerRow
            let count = k * k
            for y in 0..<pixels {
                for x in 0..<pixels {
                    let origin = (y * k) * sr + (x * k) * 4
                    let output = y * dr + x * 4
                    for channel in 0..<4 {
                        var sum = count / 2
                        for row in 0..<k {
                            var index = origin + row * sr + channel
                            for _ in 0..<k {
                                sum += Int(src[index])
                                index += 4
                            }
                        }
                        dst[output + channel] = UInt8(sum / count)
                    }
                }
            }
            withExtendedLifetime(source) {}
        }
        guard let image = result.makeImage() else {
            throw IconError("Cannot snapshot \(pixels) × \(pixels) image")
        }
        return image
    }
}

private func encodePNG(_ image: CGImage) throws -> Data {
    guard let bytes = CFDataCreateMutable(nil, 0),
          let dest = CGImageDestinationCreateWithData(bytes, "public.png" as CFString, 1, nil)
    else { throw IconError("Cannot create PNG destination") }

    CGImageDestinationAddImage(dest, image, nil)
    guard CGImageDestinationFinalize(dest) else { throw IconError("PNG encoding failed") }
    return bytes as Data
}

private func run() throws {
    guard CommandLine.arguments.count == 2 else {
        throw IconError("Usage: /usr/bin/xcrun swift Tools/MakeAppIcon.swift OUTPUT.iconset")
    }
    let folder = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
    guard folder.pathExtension == "iconset" else {
        throw IconError("Output directory must end in .iconset")
    }
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

    let renderer = Renderer()
    var byPixels = [Int: Data]()
    for points in [16, 32, 128, 256, 512] {
        for scale in [1, 2] {
            let pixels = points * scale
            let bytes: Data
            if let existing = byPixels[pixels] {
                bytes = existing
            } else {
                bytes = try autoreleasepool { try encodePNG(renderer.render(pixels)) }
                byPixels[pixels] = bytes
            }
            let suffix = scale == 2 ? "@2x" : ""
            let name = "icon_\(points)x\(points)\(suffix).png"
            try bytes.write(to: folder.appendingPathComponent(name), options: .atomic)
        }
    }
    print("Wrote 10 PNGs to \(folder.path)")
}

do {
    try run()
} catch {
    FileHandle.standardError.write(Data("MakeAppIcon: \(error)\n".utf8))
    exit(1)
}
