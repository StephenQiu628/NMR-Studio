import Foundation
import CoreGraphics

// All screen coordinates in this file are local layout POINTS, x right, y down.
// The index is in native (pre-additive-calibration) ppm, in ORIGINAL bin order.
func nrMidpoint(_ a: Double, _ b: Double) -> Double {
    let d = b - a
    return d.isFinite ? a + 0.5 * d : 0.5 * a + 0.5 * b
}

struct NRPlotMap {
    let rect: CGRect
    let offsetPPM: Double
    private let left: Double, right: Double, top: Double, bottom: Double

    // Use the renderer's inverse axes at the four plot boundaries. Do not pass
    // sorted min/max values: left can be higher ppm, and top can be lower y.
    init?(rect: CGRect, displayedLeft: Double, displayedRight: Double, offsetPPM: Double, intensityAtTop: Double, intensityAtBottom: Double) {
        let l = displayedLeft - offsetPPM, r = displayedRight - offsetPPM
        guard !rect.isNull, !rect.isInfinite, rect.size.width > 0, rect.size.height > 0,
              rect.minX.isFinite, rect.maxX.isFinite, rect.minY.isFinite, rect.maxY.isFinite,
              offsetPPM.isFinite, (r - l).isFinite, r != l,
              (intensityAtBottom - intensityAtTop).isFinite, intensityAtBottom != intensityAtTop else { return nil }
        self.rect = rect; self.offsetPPM = offsetPPM
        left = l; right = r; top = intensityAtTop; bottom = intensityAtBottom
    }

    func x(_ nativePPM: Double) -> CGFloat { rect.minX + CGFloat((nativePPM - left) / (right - left)) * rect.width }
    func y(_ ordinate: Double) -> CGFloat { rect.minY + CGFloat((ordinate - top) / (bottom - top)) * rect.height }
    func raw(atX x: CGFloat) -> Double { left + Double((x - rect.minX) / rect.width) * (right - left) }
    func ordinate(atY y: CGFloat) -> Double { top + Double((y - rect.minY) / rect.height) * (bottom - top) }
    func contains(_ p: CGPoint) -> Bool {
        p.x >= rect.minX && p.x <= rect.maxX && p.y >= rect.minY && p.y <= rect.maxY
    }
}

struct NRRadii {
    var xPoints: Double = 12
    var yPoints: Double = 18
}

enum NRRefinement: String, Codable { case bin, parabola, plateauMidpoint }
struct NRPeak: Codable {
    let first: Int, last: Int           // identity in the indexed data revision (inclusive)
    let maximum: Bool                   // local maximum vs local minimum, not sign of y
    let rawPPM: Double, ordinate: Double
    let refinement: NRRefinement
}

// A probe isn't a selection and isn't a peak annotation. In free space the
// ordinate is the ordinate UNDER THE POINTER, not a sampled spectral intensity.
struct NRProbe {
    let pointer: CGPoint, marker: CGPoint
    let cursorRawPPM: Double, cursorOrdinate: Double
    let peak: NRPeak?
}

enum NRIndexError: String, LocalizedError {
    case shape = "Mismatched ppm and intensity counts."
    case grid = "The ppm grid must be finite and strictly monotone."
    case relief = "Minimum adjacent relief must be finite and nonnegative."
    var errorDescription: String? { rawValue }
}

// Fit relative to the middle sample, scaling BOTH coordinates. l and r can
// have either orientation. Reject poor conditioning or an out-of-cell apex;
// don't clamp an extrapolation and call it a measured vertex.
private func nrVertex(_ xm: Double, _ x0: Double, _ xp: Double, _ ym: Double, _ y0: Double, _ yp: Double, maximum: Bool) -> (Double, Double)? {
    let dl = xm - x0, dr = xp - x0, scale = max(abs(dl), abs(dr))
    let dm = ym - y0, dp = yp - y0, sy = max(abs(dm), abs(dp))
    guard scale.isFinite, scale > 0, sy.isFinite,
          min(abs(dl), abs(dr)) > 8 * max(x0.ulp, max(xm.ulp, xp.ulp)),
          sy > 16 * max(y0.ulp, max(ym.ulp, yp.ulp)) else { return nil }
    let l = dl / scale, r = dr / scale
    guard l * r < 0, min(abs(l), abs(r)) >= 0.25 else { return nil }
    let sl = (dm / sy) / l, sr = (dp / sy) / r
    let a = (sr - sl) / (r - l), b = sl - a * l
    guard a.isFinite, abs(a) > 64 * Double.ulpOfOne, maximum ? a < 0 : a > 0 else { return nil }
    let t = -0.5 * (b / a)
    guard t.isFinite, t >= 0.5 * min(l, r), t <= 0.5 * max(l, r) else { return nil }
    let x = x0 + t * scale
    // Put the marker on the plotted polyline at the improved x. Do not invent
    // an intensity at the fitted apex or edit the trace.
    let y = t * l > 0 ? y0 + (t / l) * dm : y0 + (t / r) * dp
    return x.isFinite && y.isFinite ? (x, y) : nil
}

final class NRPeakIndex: Sendable {
    // Balanced ppm intervals, with 2D bounds for exact nearest-first pruning
    // even when many bins project into a few points. No spectrum array is
    // retained or scanned by probe(). Leaves contain at most 12 extrema.
    private struct Node {
        let lo: Int, end: Int, a: Int, b: Int
        let x0: Double, x1: Double, y0: Double, y1: Double
    }
    private let peaks: [NRPeak]
    private let nodes: [Node]
    var count: Int { peaks.count }

    // Call once per data/peak-policy revision, not in a mouse handler or body.
    // NaN/Inf intensities break the trace. minimumAdjacentRelief is a local
    // two-sided step floor in ordinate units, NOT an absolute intensity cutoff.
    init(ppm: [Double], intensity y: [Double], minimumAdjacentRelief: Double = 0, includeMaxima: Bool = true, includeMinima: Bool = true) throws {
        guard ppm.count == y.count else { throw NRIndexError.shape }
        guard minimumAdjacentRelief.isFinite, minimumAdjacentRelief >= 0 else { throw NRIndexError.relief }
        let n = ppm.count
        let ascending = n < 2 || ppm[1] > ppm[0]
        for i in ppm.indices {
            guard ppm[i].isFinite, i == 0 || (ascending ? ppm[i] > ppm[i-1] : ppm[i] < ppm[i-1]) else { throw NRIndexError.grid }
        }
        var found: [NRPeak] = [], i = 0
        while i < n {
            let v = y[i]
            guard v.isFinite else { i += 1; continue }
            var j = i
            while j + 1 < n && y[j+1] == v { j += 1 }
            defer { i = j + 1 }
            guard i > 0, j + 1 < n else { continue }
            let m = y[i-1], p = y[j+1]
            guard m.isFinite, p.isFinite else { continue }
            let high = v > m && v > p, low = v < m && v < p
            guard (high && includeMaxima) || (low && includeMinima), min(abs(v - m), abs(v - p)) >= minimumAdjacentRelief else { continue }
            var x = ppm[i], h = v, kind = NRRefinement.bin
            if j != i {
                x = nrMidpoint(ppm[i], ppm[j]); kind = .plateauMidpoint
            } else if let vertex = nrVertex(ppm[i-1], x, ppm[i+1], m, v, p, maximum: high) {
                x = vertex.0; h = vertex.1; kind = .parabola
            }
            found.append(NRPeak(first: i, last: j, maximum: high, rawPPM: x, ordinate: h, refinement: kind))
        }
        var tree: [Node] = []
        func build(_ lo: Int, _ end: Int) -> Int {
            if end - lo <= 12 {
                var x0 = found[lo].rawPPM, x1 = x0, y0 = found[lo].ordinate, y1 = y0
                for k in lo..<end {
                    let p = found[k]
                    x0 = min(x0, p.rawPPM); x1 = max(x1, p.rawPPM)
                    y0 = min(y0, p.ordinate); y1 = max(y1, p.ordinate)
                }
                tree.append(Node(lo: lo, end: end, a: -1, b: -1, x0: x0, x1: x1, y0: y0, y1: y1))
            } else {
                let mid = lo + (end - lo) / 2
                let a = build(lo, mid), b = build(mid, end)
                let u = tree[a], v = tree[b]
                tree.append(Node(lo: lo, end: end, a: a, b: b, x0: min(u.x0, v.x0), x1: max(u.x1, v.x1), y0: min(u.y0, v.y0), y1: max(u.y1, v.y1)))
            }
            return tree.count - 1
        }
        if !found.isEmpty { _ = build(0, found.count) }
        peaks = found; nodes = tree
    }

    private func nearest(_ p: CGPoint, _ m: NRPlotMap, _ radii: NRRadii) -> NRPeak? {
        let rx = radii.xPoints, ry = radii.yPoints
        guard !nodes.isEmpty, rx > 0, ry > 0, rx.isFinite, ry.isFinite else { return nil }
        // Eligibility and ranking use the SAME screen ellipse, including its
        // boundary. Equal distances break by original bin identity, not height.
        var best = 1.0, winner: NRPeak?
        func gap(_ q: CGFloat, _ a: CGFloat, _ b: CGFloat, _ lower: CGFloat, _ upper: CGFloat) -> Double {
            let l = max(lower, min(a, b)), h = min(upper, max(a, b))
            return l <= h ? Double(max(0, max(l - q, q - h))) : .infinity
        }
        func bound(_ i: Int) -> Double {
            let u = nodes[i]
            let dx = gap(p.x, m.x(u.x0), m.x(u.x1), m.rect.minX, m.rect.maxX) / rx
            let dy = gap(p.y, m.y(u.y0), m.y(u.y1), m.rect.minY, m.rect.maxY) / ry
            return dx * dx + dy * dy
        }
        func visit(_ i: Int, _ lowerBound: Double) {
            guard lowerBound <= best else { return }
            let u = nodes[i]
            if u.a < 0 {
                for k in u.lo..<u.end {
                    let e = peaks[k], q = CGPoint(x: m.x(e.rawPPM), y: m.y(e.ordinate))
                    guard m.contains(q) else { continue }
                    let dx = Double(q.x - p.x) / rx, dy = Double(q.y - p.y) / ry
                    let d = dx * dx + dy * dy
                    if d < best || (d == best && e.first < (winner?.first ?? Int.max)) { best = d; winner = e }
                }
            } else {
                let a = bound(u.a), b = bound(u.b)
                if a <= b { visit(u.a, a); visit(u.b, b) } else { visit(u.b, b); visit(u.a, a) }
            }
        }
        let root = nodes.count - 1
        visit(root, bound(root)); return winner
    }

    func probe(_ point: CGPoint, in map: NRPlotMap, radii: NRRadii = NRRadii(), snapping: Bool = true) -> NRProbe? {
        guard map.contains(point) else { return nil }
        let x = map.raw(atX: point.x), y = map.ordinate(atY: point.y)
        guard x.isFinite, y.isFinite else { return nil }
        let e = snapping ? nearest(point, map, radii) : nil
        let q = e.map { CGPoint(x: map.x($0.rawPPM), y: map.y($0.ordinate)) } ?? point
        return NRProbe(pointer: point, marker: q, cursorRawPPM: x, cursorOrdinate: y, peak: e)
    }
}
