import Foundation

// For a small remaining phase error, the real signal between peaks contains
// a fraction of the imaginary (dispersive) component. Fit its phase ramp
// jointly with a smooth nuisance background; only the angles are applied.

enum BackgroundPhase {
    private typealias Row = (x: [Double], y: Double, hold: Bool)

    private static func median(_ a: [Double]) -> Double {
        let s = a.sorted()
        return 0.5 * (s[(s.count - 1)/2] + s[s.count/2])
    }
    private static func residual(_ r: Row, _ b: [Double]) -> Double {
        var e = r.y
        for i in b.indices { e -= r.x[i] * b[i] }
        return e
    }

    // Equilibrate the weighted Gram matrix, then pivot both axes together.
    private static func solve(_ gram: [Double], _ rhs: [Double]) -> [Double]? {
        let d = rhs.count
        var g = gram, h = rhs, order = Array(0..<d)
        let norm = order.map { sqrt(g[$0 * (d + 1)]) }
        guard norm.allSatisfy({ $0 > 0 }) else { return nil }
        for i in 0..<d {
            h[i] /= norm[i]
            for j in 0...i {
                let v = g[i*d+j] / norm[i] / norm[j]
                g[i*d+j] = v; g[j*d+i] = v
            }
        }
        for k in 0..<d {
            let p = (k..<d).max(by: { g[order[$0]*(d+1)] < g[order[$1]*(d+1)] })!
            order.swapAt(k, p)
            let i = order[k], pivot = g[i*d+i], tail = order[(k+1)..<d]
            guard pivot > 1e-7 else { return nil } // remaining relative column energy
            for j in tail {
                let f = g[j*d+i] / pivot
                h[j] -= f * h[i]
                for l in tail { g[j*d+l] -= f * g[i*d+l] }
            }
        }
        for k in (0..<d).reversed() {
            let i = order[k]
            for j in order[(k+1)..<d] { h[i] -= g[i*d+j] * h[j] }
            h[i] /= g[i*d+i]
        }
        return h.indices.map { h[$0] / norm[$0] }
    }

    private static func fit(_ rows: [Row], _ d: Int) -> [Double]? {
        let left = rows.lazy.filter { $0.x[1] < 0 }.count
        guard rows.count >= 4*d, min(left, rows.count - left) >= 8 else { return nil }
        var e = rows.map { $0.y }, b = [Double]()
        for _ in 0..<11 {
            let m = median(e), s = max(0.00008, 1.4826 * median(e.map { abs($0 - m) }))
            var g = [Double](repeating: 0, count: d*d), h = [Double](repeating: 0, count: d)
            for k in rows.indices {
                let r = rows[k], q = min(1, 1.5*s / (abs(e[k]) + 1e-15)), w = q*q
                for i in 0..<d {
                    let wx = w * r.x[i]
                    h[i] += wx * r.y
                    for j in 0...i { g[i*d+j] += wx * r.x[j] }
                }
            }
            guard let z = solve(g, h), z.allSatisfy({ $0.isFinite }) else { return nil }
            b = z; e = rows.map { residual($0, z) }
        }
        return b
    }

    static func polish(real: [Double], imag: [Double], p0: Double, p1: Double,
                       centers: [Int], halfWidths: [Double]) -> (p0: Double, p1: Double)? {
        let n = real.count, span = Double(n - 1), rad = Double.pi / 180
        guard n >= 2, imag.count == n, p0.isFinite, p1.isFinite,
              centers.count >= 3, centers.count == halfWidths.count else { return nil }
        for k in centers.indices {
            guard (0..<n).contains(centers[k]), k == 0 || centers[k-1] < centers[k],
                  halfWidths[k].isFinite, halfWidths[k] > 0 else { return nil }
        }
        let ends = [centers[0], centers[centers.count - 1]]
        guard Double(ends[1] - ends[0]) >= 0.10*span else { return nil }
        // Represent maximum magnitude in two factors to avoid overflow.
        var unit = 0.0, peak2 = 0.0
        for j in real.indices {
            guard real[j].isFinite, imag[j].isFinite else { return nil }
            unit = max(unit, max(abs(real[j]), abs(imag[j])))
        }
        guard unit > 0 else { return nil }
        for j in real.indices {
            let r = real[j]/unit, i = imag[j]/unit
            peak2 = max(peak2, r*r + i*i)
        }
        let peak = sqrt(peak2), m = min(n, 3840), seed = p0.truncatingRemainder(dividingBy: 360)
        func rows(_ degree: Int, _ widths: Double) -> [Row] {
            var bands: [(lo: Double, hi: Double)] = []
            for (c, w) in zip(centers, halfWidths) { // interval union in center order
                var lo = Double(c) - widths*w, hi = Double(c) + widths*w
                while let t = bands.last, t.hi >= lo {
                    lo = min(lo, t.lo); hi = max(hi, t.hi); bands.removeLast()
                }
                bands.append((lo, hi))
            }
            var out: [Row] = [], band = 0
            for k in 0..<m {
                let j = Int((Double(k)*span / Double(m-1)).rounded()), pos = Double(j)
                while band < bands.count && bands[band].hi < pos { band += 1 }
                if band < bands.count && pos >= bands[band].lo { continue }
                let t = pos/span, u = 2*t - 1
                let phi = rad * (seed + (p1*t).truncatingRemainder(dividingBy: 360))
                let c = cos(phi), s = sin(phi), r = real[j]/unit/peak, i = imag[j]/unit/peak
                let im = r*s + i*c
                var x = [1.0, u]
                for l in 2...degree {
                    x.append((Double(2*l-1)*u*x[l-1] - Double(l-1)*x[l-2]) / Double(l))
                }
                x += [im, im*u] // final two coefficients are additive corrective radians
                // Hold out contiguous frequency intervals so that adjacent
                // zero-filled samples do not straddle every validation boundary.
                let block = min(79, Int(80 * t))
                out.append((x, r*c - i*s, block % 5 == 0))
            }
            return out
        }

        let data = rows(5, 8), train = data.filter { !$0.hold }, test = data.filter { $0.hold }
        guard test.count >= 12, let base = fit(train, 6), let joint = fit(train, 8) else { return nil }
        let e0 = median(test.map { abs(residual($0, base)) })
        let e1 = median(test.map { abs(residual($0, joint)) })
        guard e0 - e1 > max(0.02*e0, 32*Double.ulpOfOne),
              let main = fit(data, 8), let alt = fit(rows(3, 12), 6) else { return nil }
        func angle(_ b: [Double], _ u: Double) -> Double { return (b[b.count-2] + u*b[b.count-1])/rad }
        var size = 0.0
        for j in ends { // affine predictions and their difference are bounded by the endpoints
            let u = 2*Double(j)/span - 1, x = angle(main, u), y = angle(alt, u)
            guard max(abs(x), abs(y)) <= 12, abs(x-y) <= 3.5 else { return nil }
            size = max(size, abs(x))
        }
        guard size > 0.35 else { return nil }
        for u in [-1.0, 1.0] {
            guard max(abs(angle(main, u)), abs(angle(alt, u))) <= 25 else { return nil }
        }
        return (p0 + angle(main, -1), p1 + 2*main[7]/rad)
    }
}
