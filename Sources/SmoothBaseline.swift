import Foundation

// Ordinates in original intensity units, in SAMPLE order, including both ends.
// Knot i is at i/(knots.count-1), independent of the origin/direction of ppm.
public struct NMRSmoothCurveV1: Codable, Equatable, Sendable {
    static let knotLimit = 33
    static let blockLimit = 128
    public let knots: [Double]
    public let anchors: Int
    public let blocks: Int

    public init?(knots: [Double], anchors: Int, blocks: Int) {
        guard (12...Self.blockLimit).contains(blocks), (12...blocks).contains(anchors),
              (3...min(blocks, Self.knotLimit)).contains(knots.count), knots.allSatisfy({ $0.isFinite }) else { return nil }
        self.knots = knots; self.anchors = anchors; self.blocks = blocks
    }
    private enum CodingKeys: String, CodingKey { case knots, anchors, blocks }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let a = try c.decode(Int.self, forKey: .anchors), b = try c.decode(Int.self, forKey: .blocks)
        var list = try c.nestedUnkeyedContainer(forKey: .knots)
        var v = [Double]()
        while !list.isAtEnd && v.count < Self.knotLimit { v.append(try list.decode(Double.self)) }
        guard list.isAtEnd, let model = Self(knots: v, anchors: a, blocks: b) else {
            throw DecodingError.dataCorruptedError(forKey: .knots, in: c, debugDescription: "平滑基线的节点或区块记录无效")
        }
        self = model
    }
    func matches(count: Int) -> Bool {
        count >= 192 && count <= NMRProcessingWorkflow.maxPoints && blocks <= count / 6
    }
    // Callers supply 0 <= t <= 1. Convex combination, not a difference of large ordinates.
    @inline(__always) static func value(_ v: [Double], _ t: Double) -> Double {
        let x = t * Double(v.count - 1), i = min(Int(x), v.count - 2)
        let f = x - Double(i)
        return (1 - f) * v[i] + f * v[i + 1]
    }
}

// Multiscale signal exclusion and weighted Whittaker smoothing, adapted from
// Cobas et al., J. Magn. Reson. 183 (2006), doi:10.1016/j.jmr.2006.07.013.
// A failed affine consensus triggers the curve fit; signed-signal vetoes still apply.
enum SmoothBaseline {
    // Nonempty, bounded block statistics, always in normalized intensity units.
    private static func q(_ v: [Double], _ p: Double) -> Double {
        let s = v.sorted(), t = Double(v.count - 1) * p, i = Int(t)
        return s[i] + (t - Double(i)) * (s[min(i + 1, s.count - 1)] - s[i])
    }

    private static func support(_ w: [Double]) -> [Int]? {
        let m = w.count, ids = w.indices.filter { w[$0] >= 0.5 }
        guard ids.count >= 12, ids.count * 5 >= 2 * m, let l = ids.first, let r = ids.last,
              l <= m / 8, m - 1 - r <= m / 8 else { return nil }
        var quarters = [0, 0, 0, 0]
        for i in ids { quarters[4 * i / m] += 1 }
        guard quarters.allSatisfy({ $0 >= max(2, m / 40) }) else { return nil }
        for (i, j) in zip(ids, ids.dropFirst()) where (j - i - 1) * 10 > 3 * m { return nil }
        return ids
    }

    // Minimize sum w_i (y_i-u_i)^2 + lambda sum (u_i-2u_{i+1}+u_{i+2})^2.
    // Lower two bands and diagonal only. With two distinct supported sites
    // neither a constant nor a ramp is a null vector of the normal matrix.
    private static func whittaker(_ y: [Double], _ w: [Double], _ lambda: Double) -> [Double]? {
        let m = y.count
        var d = w, b = [Double](repeating: 0, count: m), c = [Double](repeating: 0, count: m)
        var u = y.indices.map { w[$0] * y[$0] }
        for i in 0..<(m - 2) {
            d[i] += lambda; d[i + 1] += 4 * lambda; d[i + 2] += lambda
            b[i + 1] -= 2 * lambda; b[i + 2] -= 2 * lambda; c[i + 2] = lambda
        }
        for i in 0..<m {
            if i >= 2 { c[i] /= d[i - 2]; b[i] -= c[i] * b[i - 1] }
            if i >= 1 { b[i] /= d[i - 1] }
            let pivot = d[i] - b[i] * b[i] - c[i] * c[i]
            guard pivot.isFinite, pivot > 0 else { return nil }
            d[i] = sqrt(pivot)
            if i >= 1 { u[i] -= b[i] * u[i - 1] }
            if i >= 2 { u[i] -= c[i] * u[i - 2] }
            u[i] /= d[i]
        }
        for i in y.indices.reversed() {
            if i + 1 < m { u[i] -= b[i + 1] * u[i + 1] }
            if i + 2 < m { u[i] -= c[i + 2] * u[i + 2] }
            u[i] /= d[i]
        }
        return u.allSatisfy({ $0.isFinite }) ? u : nil
    }

    // A localized return to the same underlying trend with quiet flanks is
    // ambiguous even if it is very smooth. Inspect the proposed EDIT, not
    // the largest peak in the data (which might be orders of magnitude taller).
    private static func bandLike(_ p: [Double], _ ids: [Int], _ error: Double) -> Bool {
        let m = p.count
        let bend = p.indices.map { i -> Double in
            let t = Double(i) / Double(m - 1)
            return abs(p[i] - ((1 - t) * p[0] + t * p[m - 1]))
        }
        guard let h = bend.max(), h > max(0.00025, 4 * error) else { return false }
        let ends = Array(bend.prefix(m / 8)) + Array(bend.suffix(m / 8))
        guard q(ends, 0.85) < 0.14 * h else { return false }
        let core = bend.indices.filter { bend[$0] >= 0.35 * h }
        guard let l = core.first, let r = core.last else { return false }
        let width = Double(r - l + 1) / Double(m)
        let crown = bend.filter { $0 >= 0.7 * h }.count
        let witnesses = ids.filter { bend[$0] >= 0.7 * h }.count
        return width < 0.47 || (width < 0.58 && 3 * witnesses < crown)
    }

    // Preconditions supplied by NMRFloor: finite real, valid uniform grid,
    // 192...maxPoints samples, z = max(abs(real)) > 0, sigma relative to z.
    static func decide(_ real: [Double], scale z: Double, noise sigma: Double) -> NMRAutoDecision {
        let n = real.count, m = min(NMRSmoothCurveV1.blockLimit, n / 6), samples = min(33, n / m)
        let den = Double(n - 1)
        var x = [Double](), y = [Double](), spread = [Double]()
        for i in 0..<m {
            let l = i * n / m, r = (i + 1) * n / m - 1
            let s = (0..<samples).map { real[l + $0 * (r - l) / (samples - 1)] / z }.sorted()
            x.append(0.5 * Double(l + r) / den)
            y.append(0.5 * (s[(samples - 1) / 2] + s[samples / 2]))
            spread.append(s[3 * (samples - 1) / 4] - s[(samples - 1) / 4])
        }
        // Allow for correlated noise after windowing/zero fill. A third
        // difference rejects local quadratic drift; 1.425 is the lower-quartile
        // |N(0,20)| scale for independent noisy block centers.
        let d3 = (3..<m).map { i -> Double in
            let a = y[i] - y[i - 1], b = y[i - 1] - y[i - 2], c = y[i - 2] - y[i - 3]
            return abs(a - 2 * b + c)
        }
        let e = max(0.00002, max(1.25 * sigma / sqrt(Double(samples)), q(d3, 0.25) / 1.425))
        let backgroundSpread = q(spread, 0.40)
        let spreadLimit = max(3.8 * sigma, 4.5 * backgroundSpread + 4 * e)
        var w = spread.map { $0 <= spreadLimit ? 1.0 : 0.0 }
        let pilot = y.indices.map { i -> Double in
            guard i > 0, i + 1 < m else { return y[i] }
            return min(max(y[i], min(y[i - 1], y[i + 1])), max(y[i - 1], y[i + 1]))
        }
        // One clean half-stencil suffices: a tall narrow line should not punch
        // satellite holes at every filter radius. Slopes AND bends, both signs.
        for h in [1, max(2, m / 48), max(3, m / 24)] {
            let f = h == 1 ? y : pilot
            let slopes = (h..<m).map { abs(f[$0] - f[$0 - h]) }
            let bends = ((2 * h)..<m).map { i -> Double in
                let right = f[i] - f[i - h]
                let left = f[i - h] - f[i - 2 * h]
                return abs(right - left)
            }
            let slopeLimit = 4 * q(slopes, 0.40) + 4 * e, bendLimit = 4.5 * q(bends, 0.40) + 6 * e
            for i in w.indices where w[i] > 0 {
                func calm(_ step: Int) -> Bool {
                    let j = i + step, k = j + step
                    guard f.indices.contains(k) else { return false }
                    let d = f[j] - f[i]
                    return abs(d) <= slopeLimit && abs(f[k] - f[j] - d) <= bendLimit
                }
                if !calm(h) && !calm(-h) { w[i] = 0 }
            }
        }
        let mask = w
        // Extend exclusions into a neighboring block only if its samples still
        // vary. Two adjoining quiet blocks can constrain drift between broad peaks.
        let shoulderSpread = max(2 * e, 2 * backgroundSpread)
        for i in w.indices where mask[i] > 0 {
            let island = i > 0 && i + 1 < m && mask[i - 1] == 0 && mask[i + 1] == 0
            let left = i >= 2 && mask[i - 1] == 0 && mask[i - 2] == 0
            let right = i + 2 < m && mask[i + 1] == 0 && mask[i + 2] == 0
            if island || (m >= 64 && (left || right) && spread[i] > shoulderSpread) { w[i] = 0 }
        }

        var fit = y, ids = [Int]()
        let length = Double(m) / 32, lambda = length * length * length * length
        // A fixed smoothing length in spectrum fractions, not in FFT points.
        // Symmetric redescending weights; never promote a masked wing to anchor.
        for pass in 0..<3 {
            guard let sites = support(w) else { return .skipped(.noFloor) }
            guard let u = whittaker(y, w, lambda) else { return .skipped(.range) }
            ids = sites; fit = u
            if pass == 2 { break }
            let delta = ids.map { y[$0] - u[$0] }, center = q(delta, 0.5), levels = ids.map { u[$0] }
            let cut = max(4 * e, 5 * q(delta.map { abs($0 - center) }, 0.5)) + 0.02 * (q(levels, 0.90) - q(levels, 0.10))
            let old = w
            for i in w.indices where w[i] > 0 {
                let t = abs(y[i] - u[i] - center) / cut
                if t > 1 { w[i] = min(w[i], t >= 2 ? 0 : 1 / (t * t)) }
            }
            if w == old { break }
        }
        // Do not invent an extremum inside a signal gap. Continue an end
        // tangent by at most ONE block; hold beyond it rather than extrapolate.
        for (l, r) in zip(ids, ids.dropFirst()) where r > l + 1 {
            let low = min(fit[l], fit[r]), high = max(fit[l], fit[r])
            for i in (l + 1)..<r { fit[i] = max(low, min(high, fit[i])) }
        }
        let k = min(NMRSmoothCurveV1.knotLimit, m), last = ids[ids.count - 1]
        var j = ids[0], knots = [Double]()
        for a in 0..<k {
            let t = Double(a) / Double(k - 1)
            while j + 1 < last && x[j + 1] < t { j += 1 }
            let f = max(-1, min(2, (t - x[j]) / (x[j + 1] - x[j])))
            knots.append(fit[j] + f * (fit[j + 1] - fit[j]))
        }
        // Test the compact interpolant that would actually be saved.
        let p = x.map { NMRSmoothCurveV1.value(knots, $0) }, values = ids.map { p[$0] }
        let amp = q(values.map { abs($0) }, 0.90), gate = max(0.0012, 4 * e)
        let before = ids.map { abs(y[$0]) }, err = q(ids.map { abs(y[$0] - p[$0]) }, 0.80)
        if amp <= gate {
            let flat = q(before, 0.85) <= gate + e && err <= max(3 * e, 0.0004)
            return .skipped(flat ? .floorBelowThreshold : .noFloor)
        }
        let span = q(values, 0.90) - q(values, 0.10)
        guard err <= max(3 * e, max(0.0002, 0.18 * span)), err < 0.5 * q(before, 0.80) + e,
              !bandLike(p, ids, e) else { return .skipped(.noFloor) }
        let margin = min(0.15 * amp, max(0.00004, max(e, q(ids.map { p[$0] - y[$0] }, 0.90))))
        knots = knots.map { $0 >= 0 ? max(0, $0 - margin) : min(0, $0 + margin) }
        var gains = [Int]()
        for sector in 0..<4 {
            let sites = ids.filter { 4 * $0 / m == sector }
            let old = q(sites.map { abs(y[$0]) }, 0.65)
            let new = q(sites.map { abs(y[$0] - NMRSmoothCurveV1.value(knots, x[$0])) }, 0.65)
            guard new <= old + max(3 * e, 0.0002) else { return .skipped(.noFloor) }
            if old - new > max(2 * e, 0.0002) && new < 0.67 * old { gains.append(sector) }
        }
        guard let l = gains.first, let r = gains.last, r - l >= 2 else { return .skipped(.noFloor) }

        // Full-resolution signed check, NOT on decimated centers. Small noise
        // and measured interpolation error are not evidence for a negative line.
        let slack = min(0.08 * span, 2 * err), noise = 6 * max(e, sigma)
        let low = max(0.0016, noise) + slack, high = max(0.0032, noise) + slack + margin + err
        var up = 0, down = 0, positive = false
        for i in real.indices {
            let v = real[i] / z, level = NMRSmoothCurveV1.value(knots, Double(i) / den), d = v - level
            down = d < -(low + (level < 0 ? margin : 0)) ? down + 1 : 0
            if down >= 2 { return .skipped(.negative) }
            up = d > high ? up + 1 : 0
            if !positive && up >= 2 {
                let cell = ((i + 1) * m - 1) / n
                positive = w[cell] < 0.5 || v - y[cell] > max(4 * sigma, 0.0004)
            }
        }
        guard positive else { return .skipped(.noPositiveSignal) }
        guard let model = NMRSmoothCurveV1(knots: knots.map { $0 * z }, anchors: ids.count, blocks: m) else { return .skipped(.range) }
        return .smoothV1(model)
    }
}
