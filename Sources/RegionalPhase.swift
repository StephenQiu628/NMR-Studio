import Foundation

// Regional absorption/dispersion separation, inspired by Bao et al.
// (10.1016/j.jmr.2013.06.012) and PAMPAS (10.1006/jmre.2000.2123).
// All angles here are additional rotations of the prior-rotated FFT, in radians.
enum RegionalPhase {
    struct Z {
        var r: Double
        var i: Double
        var power: Double { return r * r + i * i }
        static func + (a: Z, b: Z) -> Z { return Z(r: a.r + b.r, i: a.i + b.i) }
        static func - (a: Z, b: Z) -> Z { return Z(r: a.r - b.r, i: a.i - b.i) }
        static func * (a: Z, b: Double) -> Z { return Z(r: a.r * b, i: a.i * b) }
        func dot(_ b: Z) -> Double { return r * b.r + i * b.i }
    }

    struct Proposal {
        let level: Int
        let bin: Int
        let strength: Double
    }

    struct Solution {
        let edge: Double
        let delta: Double
        let regions: Int
        let fitted: Bool
    }

    struct Check {
        let solution: Solution?
        let allowRamp: Bool
    }

    private static let rad = Double.pi / 180.0
    private static let period = Double.pi // an absorption AXIS, not a directed vector
    private static let zero = Z(r: 0.0, i: 0.0)

    @inline(__always) private static func axis(_ t: Double) -> Double {
        return t - period * (t / period).rounded()
    }

    private static func circle(_ t: Double) -> Double {
        let turn = 2.0 * period
        return t - turn * (t / turn).rounded()
    }

    private struct Bank {
        let z: [[Z]]
        let noise: [Double]

        // Exact range sums from the contiguous dyadic means. No subsampling
        // of a wing or a narrow component, and no full-size prefix buffers.
        func mean(_ lo: Int, _ hi: Int) -> Z {
            var a = lo, b = hi + 1, k = 0
            var v = RegionalPhase.zero, size = 1.0
            while a < b {
                if k + 1 == z.count {
                    for j in a..<b { v = v + z[k][j] * size }
                    break
                }
                if (a & 1) != 0 { v = v + z[k][a] * size; a += 1 }
                if a < b && (b & 1) != 0 { b -= 1; v = v + z[k][b] * size }
                a /= 2; b /= 2; size *= 2.0; k += 1
            }
            return v * (1.0 / Double(hi - lo + 1))
        }

        func sd(_ count: Int) -> Double {
            let k = min(noise.count - 1, Int.bitWidth - 1 - count.leadingZeroBitCount)
            return max(noise[k], 0.8 * noise[min(k + 1, noise.count - 1)])
        }
    }

    private struct Core {
        let lo, hi, strength: Double
        var mid: Double { return 0.5 * (lo + hi) }
        var width: Double { return max(0.8, 0.5 * (hi - lo)) }
    }

    // A complex-detail maximum is just a seed. Locate a connected magnitude
    // core on a finer grid. The magnitude is relative to two exterior slabs;
    // neither the split into real/imaginary nor a symmetric line fit is used.
    private static func core(_ p: Proposal, _ bank: Bank) -> Core? {
        let cell = 1 << p.level, n = bank.z[0].count
        let sd = bank.noise[p.level]
        guard cell <= max(4, n / 12),
              p.strength >= (6.35 * 6.35 * 1.5) * sd * sd * Double(cell) else { return nil }
        let k = max(0, p.level - 5), fine = 1 << k, s = cell / fine
        let z = bank.z[k], mid = (Double(p.bin) + 0.5) * Double(s) - 0.5
        let radius = max(6, 3 * s), bar = max(1, s / 2)
        let l = max(0, Int(floor(mid)) - radius), h = min(z.count - 1, Int(ceil(mid)) + radius)
        guard h - l > 2 * bar + 2 else { return nil }
        var left = zero, right = zero
        for j in 0..<bar { left = left + z[l + j]; right = right + z[h - j] }
        left = left * (1.0 / Double(bar)); right = right * (1.0 / Double(bar))
        let x0 = Double(l) + 0.5 * Double(bar - 1)
        let drift = (right - left) * (1.0 / Double(h - l - bar + 1))
        func power(_ j: Int) -> Double { return (z[j] - left - drift * (Double(j) - x0)).power }
        let low = max(l + bar, Int(ceil(mid - Double(s))))
        let high = min(h - bar, Int(floor(mid + Double(s))))
        guard low <= high else { return nil }
        var top = low, peak = power(low)
        for j in low...high {
            let v = power(j)
            if v > peak { peak = v; top = j }
        }
        guard peak >= power(top - 1), peak >= power(top + 1),
              peak > 16.0 * bank.noise[k] * bank.noise[k] else { return nil }
        let cut = 0.38 * peak
        var a = top, b = top
        while a > l && power(a) > cut { a -= 1 }
        while b < h && power(b) > cut { b += 1 }
        let va = power(a), vb = power(b)
        guard a < top, b > top, va <= cut, vb <= cut else { return nil }
        let xl = Double(a) + (cut - va) / (power(a + 1) - va)
        let xr = Double(b) - (cut - vb) / (power(b - 1) - vb)
        guard k == 0 || xr - xl >= 2.5 else { return nil }
        return Core(lo: (xl + 0.5) * Double(fine) - 0.5,
                    hi: (xr + 0.5) * Double(fine) - 0.5, strength: p.strength)
    }

    private struct Group {
        var lo, hi, rightWidth, strength: Double
        var mid: Double { return 0.5 * (lo + hi) }
    }

    private static func groups(_ bank: Bank, _ lists: [[Proposal]]) -> ([Group], Bool) {
        var hits = [Core]()
        for tile in lists {
            for seed in tile { if let h = core(seed, bank) { hits.append(h) } }
        }
        hits.sort { $0.strength != $1.strength ? $0.strength > $1.strength : $0.mid < $1.mid }
        let floorEnergy = (hits.first?.strength ?? 0.0) * 1e-7
        var kept = [Core](), crowded = false
        for h in hits {
            if h.strength < floorEnergy { break }
            if kept.contains(where: { abs($0.mid - h.mid) <= max(1.5, $0.width + h.width) }) { continue }
            if kept.count == 384 { crowded = true; break }
            kept.append(h)
        }
        kept.sort { $0.mid < $1.mid }
        var result = [Group]()
        for h in kept {
            // With no room for two sets of wings, measure the envelope of
            // the multiplet. Use the adjoining component widths for the gap.
            if let g = result.last, h.lo - g.hi <= 2.8 * (g.rightWidth + h.width) {
                let j = result.count - 1
                result[j].lo = min(g.lo, h.lo)
                result[j].hi = max(g.hi, h.hi)
                result[j].rightWidth = h.width
                result[j].strength = max(g.strength, h.strength)
            } else {
                result.append(Group(lo: h.lo, hi: h.hi, rightWidth: h.width, strength: h.strength))
            }
        }
        return (result, crowded)
    }

    private struct Patch {
        let bank: Bank
        let c, reach: Int
        let frac, half, x, strength: Double

        // Mean of translated bins using linear interpolation at a common
        // fractional center. The two endpoint terms telescope exactly.
        func avg(_ l: Int, _ h: Int) -> Z {
            let a = c + l, b = c + h
            let v = bank.mean(a, b)
            return v + (bank.z[0][b + 1] - bank.z[0][a]) * (frac / Double(h - l + 1))
        }
    }

    private struct Point {
        let x, angle, positive, error, weight, strength: Double
        init(_ p: Patch, _ angle: Double, _ positive: Double, _ error: Double) {
            self.x = p.x; self.angle = RegionalPhase.axis(angle); self.positive = positive
            self.error = max(RegionalPhase.rad, error)
            self.weight = 0.65 + 0.35 * min(1.0, (3.0 * RegionalPhase.rad) / self.error)
            self.strength = p.strength
        }
    }

    private struct Shell {
        let index: Int
        let d, angle, mass, snr, positive: Double
    }

    private static func wings(_ p: Patch) -> Point? {
        let limit = min(Double(p.reach), max(38.0, 36.0 * p.half))
        var d = max(2.0, 1.06 * p.half), s = [Shell]()
        for k in 0..<14 {
            let a = Int(ceil(d)), b = max(a + 1, Int((1.45 * d).rounded()))
            let e = max(b + 1, Int((1.85 * d).rounded())), f = max(e + 1, Int((2.55 * d).rounded()))
            if Double(f) > limit { break }
            d *= 1.43
            let di = 0.5 * Double(a + b), t = Double(a + b) / Double(e + f)
            let r = p.avg(a, b), l = p.avg(-b, -a)
            let ro = p.avg(e, f), lo = p.avg(-f, -e)
            let back = (ro + lo) * 0.5
            // Odd parity: constant cancels within each pair, affine drift
            // cancels BETWEEN pairs. For a 1/u tail the gain is proportional
            // to (1-t*t)/di. Even absorption (~1/u^2) largely cancels.
            let q = ((r - l) - (ro - lo) * t) * 0.5
            let even = (r + l) * 0.5 - back
            let area = p.avg(-b, b) - back
            let m = sqrt(q.power), h = sqrt(area.power)
            let si = p.bank.sd(b - a + 1), so = p.bank.sd(f - e + 1), sc = p.bank.sd(2 * b + 1)
            let sq = sqrt(0.5 * (si * si + t * t * so * so)), sa = sqrt(sc * sc + 0.5 * so * so)
            // Opposing wings after subtracting the exterior secant, plus a
            // measurable integrated core approximately transverse to them.
            guard m > 4.8 * sq, h > 4.5 * sa, even.power < 0.74 * q.power,
                  abs(q.dot(area)) < 0.57 * m * h else { continue }
            // Rotate q to IMAGINARY, not real. Reversing dispersion changes
            // this angle by pi, not the inferred absorption axis.
            s.append(Shell(index: k, d: di, angle: atan2(q.r, q.i), mass: m * di / (1.0 - t * t),
                           snr: min(m / sq, 1.8 * h / sa), positive: -atan2(area.i, area.r)))
        }
        var best: Point? = nil, merit = -1.0
        for j in s.indices where j > 0 {
            let end = s[j]
            var sw = 0.0, st = 0.0, ss = 0.0, vv = 0.0
            for i in stride(from: j, through: 0, by: -1) {
                let v = s[i], ratio = end.d / v.d
                if end.index - v.index != j - i { break }
                let dt = circle(v.angle - end.angle), span = log(ratio)
                // A plateau must have the SAME directed odd contrast across
                // scales, and roughly constant inferred tail coefficient.
                if abs(dt) > 13.0 * rad || abs(log(v.mass / end.mass)) > min(0.77, 0.21 + 0.56 * span) { break }
                let u = min(1.0, v.snr / 14.0) / ratio, w = u * u
                sw += w; st += w * dt; ss += w * dt * dt; vv += w / (v.snr * v.snr)
                if ratio < 1.34 { continue }
                let mu = st / sw
                let err = sqrt(max(0.0, ss / sw - mu * mu) + vv / sw)
                let clear = min(1.0, end.d / (3.5 * p.half))
                let scaled = err / (6.0 * rad)
                let score = (1.0 + min(1.65, span)) * (0.6 + 0.4 * clear) / (1.0 + scaled * scaled)
                if score > merit {
                    merit = score
                    best = Point(p, end.angle + mu, end.positive, err)
                }
            }
        }
        return best
    }

    // Absorption-only special case: if there is no trustworthy quadrature
    // tail, an integrated area can still identify an axis in a demonstrably
    // rank-one complex group. Check multiple slabs, not the apex phase.
    private static func collinearArea(_ p: Patch) -> Point? {
        let b = max(2, Int(ceil(1.8 * p.half))), e = max(b + 1, Int(ceil(2.6 * p.half)))
        let f = max(e + 1, Int(ceil(3.6 * p.half)))
        guard f <= p.reach else { return nil }
        let l = p.avg(-f, -e), r = p.avg(e, f), base = (r + l) * 0.5
        let m = 2 * b + 1, area = p.avg(-b, b) - base, h = sqrt(area.power)
        let so = p.bank.sd(f - e + 1), si = p.bank.sd(m), sd = sqrt(si * si + 0.5 * so * so)
        guard h > 11.0 * sd else { return nil }
        let dir = area * (1.0 / h), bars = min(15, m)
        var energy = 0.0, minor = 0.0, resolved = 0
        for k in 0..<bars {
            let a = -b + k * m / bars, z = -b + (k + 1) * m / bars - 1
            let t = 0.5 * Double(a + z) / Double(e + f)
            let v = p.avg(a, z) - base - (r - l) * t
            let w = Double(z - a + 1) / Double(m), perp = dir.r * v.i - dir.i * v.r
            energy += w * v.power; minor += w * perp * perp
            if v.dot(dir) > max(0.1 * h, 3.5 * p.bank.sd(z - a + 1)) { resolved += 1 }
        }
        guard resolved >= 3, energy > 0.0, area.power >= 0.18 * energy,
              minor < 0.003 * energy else { return nil }
        let angle = -atan2(area.i, area.r)
        return Point(p, angle, angle, max(sd / h, sqrt(minor / energy)))
    }

    private struct Line { var a, b: Double } // intercept at data pivot, full-band slope
    private struct Trial { let line: Line; let score: Double }
    private struct Accepted { let trial: Trial; let ids: [Int] }

    @inline(__always) private static func residual(_ p: Point, _ line: Line, _ pivot: Double) -> Double {
        return axis(p.angle - line.a - line.b * (p.x - pivot))
    }

    @inline(__always) private static func support(_ r: Double) -> Double {
        let u = r / (18.0 * rad)
        if abs(u) >= 1.0 { return 0.0 }
        let t = 1.0 - u * u
        return t * t
    }

    private static func tally(_ p: [Point], _ line: Line, _ pivot: Double) -> Double {
        return p.reduce(0.0) { $0 + $1.weight * support(residual($1, line, pivot)) }
    }

    private static func profile(_ p: [Point], _ b: Double, _ pivot: Double) -> Trial {
        let t = p.map { axis($0.angle - b * ($0.x - pivot)) }
        var best = Trial(line: Line(a: 0.0, b: b), score: -1.0)
        for a in t {
            var s = 0.0
            for j in t.indices { s += p[j].weight * support(axis(t[j] - a)) }
            if s > best.score { best = Trial(line: Line(a: a, b: b), score: s) }
        }
        return best
    }

    private struct Step { let line: Line; let sw, mx, v: Double }

    private static func step(_ p: [Point], _ ids: [Int], _ g: Line, _ pivot: Double,
                             _ linear: Bool, _ cut: Double) -> Step? {
        var sw = 0.0, sx = 0.0, sr = 0.0, xx = 0.0, xr = 0.0
        for i in ids {
            let z = p[i], r = residual(z, g, pivot), x = z.x - pivot
            var w = z.weight
            if cut > 0.0 {
                let u = r / cut
                if abs(u) >= 1.0 { continue }
                let t = 1.0 - u * u; w *= t * t
            }
            sw += w; sx += w * x; sr += w * r; xx += w * x * x; xr += w * x * r
        }
        guard sw > 0.0 else { return nil }
        let mx = sx / sw, v = max(0.0, xx - mx * sx)
        if linear && v <= 1e-8 * sw { return nil }
        let db = linear ? (xr - mx * sr) / v : 0.0
        return Step(line: Line(a: axis(g.a + sr / sw - db * mx), b: g.b + db), sw: sw, mx: mx, v: v)
    }

    private static func polish(_ p: [Point], _ seed: Line, _ pivot: Double, _ linear: Bool) -> Line? {
        var line = seed
        let ids = Array(p.indices)
        for k in 0..<10 {
            guard let s = step(p, ids, line, pivot, linear, (k < 4 ? 18.0 : 11.0) * rad) else { return nil }
            line = s.line
        }
        return line
    }

    private static func constant(_ p: [Point], _ pivot: Double) -> Line {
        let seed = profile(p, 0.0, pivot).line
        return polish(p, seed, pivot, false) ?? seed
    }

    private static func certify(_ p: [Point], _ g: Line, _ pivot: Double, _ linear: Bool,
                                _ limit: Double) -> Accepted? {
        let ids = p.indices.filter { i in
            abs(residual(p[i], g, pivot)) <= min(12.0 * rad, max(7.0 * rad, 2.5 * p[i].error))
        }
        guard let i = ids.first, let j = ids.last, 3 * ids.count >= 2 * p.count,
              let s = step(p, ids, g, pivot, linear, 0.0) else { return nil }
        let lo = p[i].x, hi = p[j].x, span = hi - lo, line = s.line
        let full = p[p.count - 1].x - p[0].x
        if full >= 0.06 && span < 0.68 * full { return nil }
        if ids.count == 1 && p[i].error > 7.0 * rad { return nil }
        if linear {
            guard ids.count >= 3, span >= 0.06, s.v > (0.017 * 0.017) * s.sw,
                  abs(line.b) <= limit + 1e-8, abs(line.b) * span < 0.95 * period || ids.count >= 4,
                  ids.contains(where: { p[$0].x > lo + 0.1 * span && p[$0].x < hi - 0.1 * span }) else { return nil }
        }
        // Give the supplied P1 its own best intercept on the SAME regions.
        let base = linear ? constant(ids.map { p[$0] }, pivot) : line
        var ss = 0.0, press = 0.0, gains = 0, firstGain = hi, lastGain = lo
        for k in ids {
            let z = p[k], r = residual(z, line, pivot)
            ss += z.weight * r * r
            if linear {
                let x = z.x - pivot - s.mx
                let leverage = z.weight * (1.0 / s.sw + x * x / s.v)
                guard leverage < 0.975 else { return nil }
                // Deleted-region prediction error on this winding. Prevent a
                // distant single vote from validating its own fitted slope.
                let test = abs(r) / (1.0 - leverage)
                press += z.weight * test * test
                if abs(residual(z, base, pivot)) > test + max(1.15 * rad, 0.45 * z.error) {
                    gains += 1; firstGain = min(firstGain, z.x); lastGain = max(lastGain, z.x)
                }
            }
        }
        guard sqrt(ss / s.sw) < 6.0 * rad else { return nil }
        if linear {
            let errors = ids.map { p[$0].error }.sorted()
            let rms = sqrt((ss / s.sw) * Double(ids.count) / Double(ids.count - 2))
            let sigma = max(1.35 * rad, max(0.8 * errors[errors.count / 2], rms))
            guard abs(line.b) * span > 4.5 * rad, abs(line.b) * sqrt(s.v) > 2.6 * sigma,
                  sqrt(press / s.sw) < 8.0 * rad, gains >= max(2, (ids.count + 3) / 4),
                  lastGain - firstGain >= 0.18 * span else { return nil }
        }
        return Accepted(trial: Trial(line: line, score: tally(p, line, pivot)), ids: ids)
    }

    private static func answer(_ f: Accepted, _ p: [Point], _ pivot: Double, _ linear: Bool) -> Solution {
        let line = f.trial.line
        var edge = line.a - line.b * pivot, vote = 0, sx = 0.0
        for i in f.ids {
            let z = p[i], c = cos(edge + line.b * z.x - z.positive)
            if c > 0.4 { vote += 1 } else if c < -0.4 { vote -= 1 }
            sx += z.x
        }
        // One global sign, by majority of integrated absorptions. On a tie
        // prefer the smaller rotation at the supported data, not at a band edge.
        if vote < 0 || (vote == 0 && cos(edge + line.b * sx / Double(f.ids.count)) < 0.0) { edge += period }
        edge = circle(edge)
        if !linear {
            let e = f.ids.map { p[$0].error }.sorted()
            let deadband = min(1.6 * rad, e[e.count / 2] / sqrt(Double(e.count)))
            if abs(edge) <= deadband { edge = 0.0 }
        }
        return Solution(edge: edge, delta: line.b, regions: f.ids.count, fitted: linear)
    }

    private static func decide(_ p: [Point], _ extent: Double, _ separated: Bool) -> Check {
        let weak = Check(solution: nil, allowRamp: separated)
        guard let first = p.first, let last = p.last else { return weak }
        let span = last.x - first.x, pivot = 0.5 * (first.x + last.x)
        // With only one or two independent wings a small satellite can bias
        // even the constant phase. Use the established line/entropy fallback.
        if p.count < 3 || (separated && span < min(0.065, 0.5 * extent)) { return weak }
        let base = constant(p, pivot)
        let fixed = certify(p, base, pivot, false, 0.0).map { answer($0, p, pivot, false) }
        let safe = Check(solution: fixed, allowRamp: separated)
        guard span >= 0.06, p.count >= 3 else { return safe }

        // Profile all intercept branches as the slope varies. Spacing bounds
        // the angular grid error on the DATA span. Budget both windings and
        // absolute change from the technical prior; refine off grid below.
        let turns = min(6.0, 0.68 * Double(p.count - 1))
        let limit = min(8.0 * period, turns * period / span)
        let steps = max(1, Int(ceil(limit * span / (4.0 * rad))))
        let total = p.reduce(0.0) { $0 + $1.weight }, baseScore = tally(p, base, pivot)
        var grid = [Trial]()
        for k in (-steps)...steps {
            let t = profile(p, limit * Double(k) / Double(steps), pivot)
            if t.score >= 0.42 * total { grid.append(t) }
        }
        grid.sort { $0.score != $1.score ? $0.score > $1.score : abs($0.line.b) < abs($1.line.b) }
        var explored = [Double](), valid = [Accepted]()
        for t in grid {
            if explored.contains(where: { abs($0 - t.line.b) * span < 0.32 * period }) { continue }
            explored.append(t.line.b)
            if let g = polish(p, t.line, pivot, true), let f = certify(p, g, pivot, true, limit),
               f.trial.score > baseScore + 0.008 * total { valid.append(f) }
        }
        guard let best = valid.map({ $0.trial.score }).max() else { return safe }
        let near = valid.filter { $0.trial.score >= best - 0.035 * total }
        guard let chosen = near.min(by: { abs($0.trial.line.b) < abs($1.trial.line.b) }) else { return safe }
        let b = chosen.trial.line.b
        let ambiguous = near.contains { f in
            let d = f.trial.line.b
            return abs(d - b) * span > 0.55 * period && (abs(d) - abs(b)) * span < 0.4 * period
        }
        if ambiguous { return Check(solution: fixed, allowRamp: false) }
        return Check(solution: answer(chosen, p, pivot, true), allowRamp: true)
    }

    static func assess(bands: [[Z]], noise: [Double], lists: [[Proposal]]) -> Check {
        let bank = Bank(z: bands, noise: noise), n = bands[0].count, den = Double(n - 1)
        let (g, crowded) = groups(bank, lists)
        let extent = ((g.last?.mid ?? 0.0) - (g.first?.mid ?? 0.0)) / den
        let separated = g.count >= 2 && extent >= 0.06
        if crowded { return Check(solution: nil, allowRamp: separated) }
        var points = [Point]()
        for k in g.indices {
            let v = g[k], c = Int(floor(v.mid))
            let left = k == 0 ? 0.0 : 0.5 * (g[k - 1].hi + v.lo)
            let right = k + 1 == g.count ? den : 0.5 * (v.hi + g[k + 1].lo)
            let space = Int(floor(min(v.mid - left, right - v.mid)))
            let reach = min(space, min(c, n - 2 - c))
            guard reach >= 4 else { continue }
            let p = Patch(bank: bank, c: c, reach: reach, frac: v.mid - Double(c),
                          half: max(0.8, 0.5 * (v.hi - v.lo)), x: v.mid / den, strength: v.strength)
            if let h = wings(p) ?? collinearArea(p) { points.append(h) }
        }
        // Disjoint measured supports, then a spatial vote cap. Signal energy
        // sets priority within a neighborhood, not weight in the phase fit.
        points.sort { $0.strength != $1.strength ? $0.strength > $1.strength : $0.x < $1.x }
        var independent = [Point]()
        for h in points {
            if !independent.contains(where: { abs($0.x - h.x) < 1.0 / 160.0 }) { independent.append(h) }
            if independent.count == 96 { break }
        }
        return decide(independent.sorted { $0.x < $1.x }, extent, separated)
    }
}
