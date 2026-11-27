import Foundation

private enum SpectralPhase1D {
    static let rad = Double.pi / 180.0
    static let turn = 2.0 * Double.pi
    static let tiles = 64

    @inline(__always) static func wrap(_ x: Double) -> Double {
        return x - turn * (x / turn).rounded()
    }

    typealias Z = RegionalPhase.Z
    typealias Proposal = RegionalPhase.Proposal

    struct Anchor {
        let x: Double       // FFT index / (n - 1), NOT a ppm fraction
        let width: Double   // HWHM in the same coordinates
        let angle: Double   // desired additional rotation, in radians
        let quality: Double // 0...1, after hard evidence tests
        var weight: Double { return 0.5 + 0.5 * quality }
    }

    // Complex second difference: insensitive to a local affine baseline, and
    // its modulus does not require a provisional zero-order phase.
    @inline(__always) static func detail(_ z: [Z], _ j: Int) -> Z {
        return Z(r: z[j].r - 0.5 * (z[j-1].r + z[j+1].r),
                 i: z[j].i - 0.5 * (z[j-1].i + z[j+1].i))
    }

    static func pixelNoise(_ z: [Z]) -> Double {
        let m = z.count - 2
        let k = min(4096, m)
        var r = [Double](), i = [Double]()
        r.reserveCapacity(k)
        i.reserveCapacity(k)
        for s in 0..<k {
            let j = 1 + Int((Double(s) + 0.5) * Double(m) / Double(k))
            let d = detail(z, j)
            r.append(abs(d.r))
            i.append(abs(d.i))
        }
        r.sort()
        i.sort()
        // Lower absolute-normal quantile to reduce contamination by lines.
        // The detail filter's white-noise gain is sqrt(1.5).
        let q = 3 * k / 10
        let sd = max(r[q], i[q]) / (0.3853204664 * sqrt(1.5))
        return max(16.0 * Double.ulpOfOne, sd)
    }

    struct Sample {
        let t: Double
        let r: Double
        let i: Double
    }

    // Project the data off {1,t}. The templates below are projected off
    // exactly the same space, including when a bin is left out.
    struct Window {
        let lo: Int
        let hi: Int
        let origin: Double
        let invN: Double
        let invTT: Double
        let samples: [Sample]
        let power: Double

        init?(_ z: [Z], around c: Double, radius: Double, skip: Int = -1) {
            let l = max(0, Int(ceil(c - radius)))
            let h = min(z.count - 1, Int(floor(c + radius)))
            let omitted = skip >= l && skip <= h
            let m = h - l + 1 - (omitted ? 1 : 0)
            guard m >= 7 else { return nil }
            let inv = 1.0 / Double(m)
            let mid = 0.5 * (Double(l) + Double(h))
            let o = mid + (omitted ? (mid - Double(skip)) * inv : 0.0)
            var a = [Sample]()
            a.reserveCapacity(m)
            var sr = 0.0, si = 0.0, str = 0.0, sti = 0.0, tt = 0.0
            for j in l...h where j != skip {
                let t = Double(j) - o
                let v = z[j]
                sr += v.r
                si += v.i
                str += t * v.r
                sti += t * v.i
                tt += t * t
                a.append(Sample(t: t, r: v.r, i: v.i))
            }
            sr *= inv
            si *= inv
            str /= tt
            sti /= tt
            var energy = 0.0
            for j in a.indices {
                let s = a[j]
                let r = s.r - (sr + str * s.t)
                let i = s.i - (si + sti * s.t)
                a[j] = Sample(t: s.t, r: r, i: i)
                energy += r * r + i * i
            }
            lo = l
            hi = h
            origin = o
            invN = inv
            invTT = 1.0 / tt
            samples = a
            power = energy
        }
    }

    struct Shape {
        var c = 0.0, w = 1.0, score = -1.0
        var d = 0.0, s = 0.0, gap = 0.0, er = 0.0, ei = 0.0

        var orientation: (angle: Double, even: Double) {
            let a = 0.5 * atan2(s, d)
            let e = er * cos(a) + ei * sin(a)
            // Resolve the eigenvector's sign by positive absorption, not by
            // the sign of the dispersion (which depends on FFT convention).
            return (e < 0.0 ? a + Double.pi : a, abs(e))
        }
    }

    // Local model: complex affine background + exp(i*phi) * (A*E + i*B*O).
    // E = 1/(1+u^2), O = u*E. A and B are independent real coefficients;
    // dispersion may have either handedness or even be absent. For a unit
    // vector v at angle phi the explained energy after fitting A,B is
    // (v.e)^2 + (v.q)^2, with e,q the normalized correlations below. Thus
    // only center and width need searching; phi is a 2x2 principal axis.
    static func match(_ a: Window, center: Double, width: Double) -> Shape {
        let c = center - a.origin, iw = 1.0 / width
        var se = 0.0, so = 0.0, te = 0.0, to = 0.0, ee = 0.0, oo = 0.0
        var er = 0.0, ei = 0.0, orr = 0.0, oi = 0.0
        for p in a.samples {
            let u = (p.t - c) * iw
            let e = 1.0 / (1.0 + u * u), o = u * e
            se += e
            so += o
            te += p.t * e
            to += p.t * o
            ee += e * e
            oo += o * o
            er += p.r * e
            ei += p.i * e
            orr += p.r * o
            oi += p.i * o
        }
        let ge = ee - se * se * a.invN - te * te * a.invTT
        let go = oo - so * so * a.invN - to * to * a.invTT
        guard ge > 1e-10 * ee, go > 1e-10 * oo else { return Shape() }
        let ne = 1.0 / sqrt(ge), no = 1.0 / sqrt(go)
        er *= ne
        ei *= ne
        let qr = oi * no, qi = -orr * no // multiply odd correlation by -i
        let xx = er * er + qr * qr, yy = ei * ei + qi * qi
        let d = xx - yy, s = 2.0 * (er * ei + qr * qi)
        let gap = sqrt(d * d + s * s)
        return Shape(c: center, w: width, score: 0.5 * (xx + yy + gap),
                     d: d, s: s, gap: gap, er: er, ei: ei)
    }

    static func measure(_ p: Proposal, bands: [[Z]], noise: [Double], n: Int) -> Anchor? {
        // Fit at substantially finer resolution than the detection scale.
        // Dyadic bin centers, including the half-bin offsets, map back to the
        // original sampled FFT grid. No integer-center restriction in the fit.
        let level = max(0, p.level - 4)
        let ratio = Double(1 << (p.level - level))
        let cell = Double(1 << level)
        let nominal = (Double(p.bin) + 0.5) * ratio - 0.5
        let radius = max(6.0, 2.5 * ratio)
        let z = bands[level]
        guard let a = Window(z, around: nominal, radius: radius),
              a.samples.count >= 9, a.power > 0.0 else { return nil }
        let low = level == 0 ? max(0.08, ratio / 40.0) : 1.1
        let high = 0.68 * radius
        var best = Shape()
        func examine(_ c: Double, _ w: Double) {
            guard abs(c - nominal) <= ratio, c >= Double(a.lo + 1),
                  c <= Double(a.hi - 1), w >= low, w <= high else { return }
            let f = match(a, center: c, width: w)
            if f.score > best.score { best = f }
        }
        var w = low
        while true {
            for j in -4...4 { examine(nominal + Double(j) * ratio * 0.25, w) }
            if w == high { break }
            w = min(high, 1.8 * w)
        }
        guard best.score > 0.0 else { return nil }
        var dc = ratio * 0.125, factor = sqrt(1.8)
        for _ in 0..<11 {
            for _ in 0..<2 {
                let c0 = best.c, w0 = best.w
                for j in -1...1 {
                    let c = c0 + Double(j) * dc
                    examine(c, w0 / factor)
                    if j != 0 { examine(c, w0) }
                    examine(c, w0 * factor)
                }
                if best.c == c0 && best.w == w0 { break }
            }
            dc *= 0.5
            factor = sqrt(factor)
        }
        let margin = min(best.c - Double(a.lo), Double(a.hi) - best.c)
        guard margin >= 2.0 * best.w, best.w > 1.01 * low,
              abs(best.c - nominal) < 0.999 * ratio,
              best.gap > 0.35 * best.score else { return nil }

        let sd = noise[level]
        let rss = max(0.0, a.power - best.score)
        let df = Double(2 * a.samples.count - 9)
        let err = max(sd, sqrt(rss / df))
        let obs = best.orientation
        let snr = sqrt(best.score) / err, evenSNR = obs.even / err
        let mismatch = max(0.0, rss - df * sd * sd) / best.score
        guard snr >= 7.5, evenSNR >= 4.5, mismatch < 0.32 else { return nil }

        // Check a different span, WITHOUT the nearest bin. An isolated noise
        // spike has no corroborating wings. Blends often give inconsistent
        // axes or a large unexplained residual even with a free center.
        guard let wing = Window(z, around: best.c, radius: max(5.25, 3.6 * best.w),
                                skip: Int(best.c.rounded())) else { return nil }
        let f = match(wing, center: best.c, width: best.w)
        guard f.score > 0.0, f.gap > 0.22 * f.score else { return nil }
        let wingRSS = max(0.0, wing.power - f.score)
        let wingErr = max(sd, sqrt(wingRSS / Double(2 * wing.samples.count - 7)))
        guard sqrt(f.score) > 3.8 * wingErr else { return nil }
        let alt = f.orientation
        var delta = abs(wrap(alt.angle - obs.angle))
        if alt.even < 3.0 * wingErr { delta = min(delta, Double.pi - delta) }
        guard delta < 22.0 * rad else { return nil }
        let u = delta / (14.0 * rad)
        let quality = min(1.0, snr / 16.0) * min(1.0, evenSNR / 9.0)
                      / (1.0 + 5.0 * mismatch + u * u)
        let last = Double(n - 1)
        return Anchor(x: ((best.c + 0.5) * cell - 0.5) / last,
                      width: best.w * cell / last, angle: wrap(-obs.angle), quality: quality)
    }

    struct Measurements {
        let wing: RegionalPhase.Check
        let local: [Anchor]
    }

    static func measurements(_ root: [Z]) -> Measurements {
        // Fewer than 2*n complex samples over the entire averaging pyramid.
        // Scan all scales in O(n); neither fit windows nor the number of
        // nonlinear searches grows with the FFT length.
        var bands = [root], noise = [Double]()
        var lists = [[Proposal]](repeating: [], count: tiles)
        while true {
            let k = bands.count - 1, z = bands[k], m = z.count
            let block = Double(1 << k)
            let whiteFloor = (noise.first ?? 0.0) / sqrt(block)
            let sd = max(whiteFloor, pixelNoise(z))
            noise.append(sd)
            let threshold = 4.8 * sqrt(1.5) * sd
            let t2 = threshold * threshold
            var top = [[Proposal]](repeating: [], count: tiles)
            var prev = detail(z, 1).power, value = detail(z, 2).power
            for j in 2..<(m - 2) {
                let next = detail(z, j + 1).power
                if value > t2 && value > prev && value >= next {
                    let x = (Double(j) + 0.5) * block / Double(root.count)
                    let bin = min(tiles - 1, Int(x * Double(tiles)))
                    let strength = value * block // contrast energy at this scale
                    if top[bin].count < 4 || strength > top[bin][3].strength {
                        top[bin].append(Proposal(level: k, bin: j, strength: strength))
                        top[bin].sort { $0.strength > $1.strength }
                        if top[bin].count > 4 { top[bin].removeLast() }
                    }
                }
                prev = value
                value = next
            }
            for b in 0..<tiles { lists[b].append(contentsOf: top[b]) }
            let count = m / 2
            if count < 9 { break }
            var next = [Z]()
            next.reserveCapacity(count)
            for j in 0..<count {
                let l = z[2*j], r = z[2*j + 1]
                next.append(Z(r: 0.5 * (l.r + r.r), i: 0.5 * (l.i + r.i)))
            }
            bands.append(next)
        }
        let wing = RegionalPhase.assess(bands: bands, noise: noise, lists: lists)
        if wing.solution != nil { return Measurements(wing: wing, local: []) }
        var fits = [Anchor]()
        for b in 0..<tiles {
            lists[b].sort { $0.strength > $1.strength }
            for p in lists[b].prefix(16) {
                if let a = measure(p, bands: bands, noise: noise, n: root.count) {
                    fits.append(a)
                }
            }
        }
        // Keep the best line-shape evidence, not the largest amplitude. Merge
        // overlapping supports and thin spatially: re-detections of one line
        // and dozens of components in one small multiplet are not votes.
        fits.sort { $0.quality != $1.quality ? $0.quality > $1.quality : $0.x < $1.x }
        var independent = [Anchor]()
        for a in fits {
            let overlaps = independent.contains {
                abs($0.x - a.x) < max(1.0 / 96.0, 2.5 * ($0.width + a.width))
            }
            if !overlaps { independent.append(a) }
        }
        return Measurements(wing: wing, local: independent.sorted { $0.x < $1.x })
    }

    struct Line {
        var mid: Double   // residual correction at x=1/2
        var slope: Double // residual correction across the entire array
    }

    static func consensus(_ a: [Anchor], linear: Bool) -> (Line, Int)? {
        guard let first = a.first, let last = a.last else { return nil }
        let span = last.x - first.x
        // Two wrapped phases alone cannot check a slope or its winding.
        if linear && (a.count < 3 || span < 0.08) { return nil }
        let total = a.reduce(0.0) { $0 + $1.weight }
        let outer = (linear ? 28.0 : 40.0) * rad
        // Search windings RELATIVE to the supplied first order. Sparse phase
        // observations do not identify arbitrary turns between them. Limit
        // the bank by mean anchor spacing and a six-turn computation budget.
        let turns = min(6.0, 0.5 * Double(a.count - 1))
        let limit = linear ? turn * turns / span : 0.0
        var bestScore = -Double.infinity, line = Line(mid: first.angle, slope: 0.0)
        func seed(_ mid: Double, _ b: Double) {
            let m = wrap(mid)
            var score = 0.0
            for h in a {
                let r = wrap(h.angle - (m + b * (h.x - 0.5))) / outer
                if abs(r) < 1.0 {
                    let t = 1.0 - r * r
                    score += h.weight * t * t * t
                }
            }
            // Prefer windings near the prior for nearly equivalent consensus.
            // This is only branch selection, not shrinkage in the final fit.
            score -= 0.008 * total * abs(b) * span / turn
            if score > bestScore {
                bestScore = score
                line = Line(mid: m, slope: b)
            }
        }
        var cs = 0.0, sn = 0.0
        for h in a {
            seed(h.angle, 0.0)
            cs += h.weight * cos(h.angle)
            sn += h.weight * sin(h.angle)
        }
        seed(atan2(sn, cs), 0.0)
        if linear {
            for i in 0..<(a.count - 1) {
                for j in (i + 1)..<a.count {
                    let dx = a[j].x - a[i].x
                    let dy = wrap(a[j].angle - a[i].angle)
                    let kmax = Int(floor((limit * dx + Double.pi) / turn))
                    for k in (-kmax)...kmax {
                        let b = (dy + Double(k) * turn) / dx
                        if abs(b) <= limit {
                            seed(a[i].angle - b * (a[i].x - 0.5), b)
                        }
                    }
                }
            }
        }

        // Circular Tukey IRLS. Unwrap each residual about the current line,
        // never about the preceding peak. Center the weighted normal equations.
        for pass in 0...12 {
            let residual = a.map { wrap($0.angle - (line.mid + line.slope * ($0.x - 0.5))) }
            var cut = outer
            if pass >= 4 {
                let ar = residual.map { abs($0) }.sorted()
                let med = 0.5 * (ar[(ar.count - 1) / 2] + ar[ar.count / 2])
                cut = min(outer, max(8.0 * rad, 4.685 * 1.4826 * med))
            }
            var sw = 0.0, sx = 0.0, sr = 0.0, xx = 0.0, xr = 0.0, rr = 0.0
            var used = 0, mass = 0.0
            for j in a.indices {
                let r = residual[j], u = r / cut
                if abs(u) >= 1.0 { continue }
                let h = a[j], x = h.x - 0.5, t = 1.0 - u * u
                let w = h.weight * t * t
                sw += w
                sx += w * x
                sr += w * r
                xx += w * x * x
                xr += w * x * r
                rr += w * r * r
                if abs(u) <= 0.8 { used += 1; mass += h.weight }
            }
            guard sw > 0.0 else { return nil }
            let mx = sx / sw, mr = sr / sw
            let v = max(0.0, xx - mx * sx)
            if linear && v <= 1e-6 * sw { return nil }
            if pass == 12 {
                guard 2 * used > a.count, mass > 0.5 * total else { return nil }
                if linear {
                    let scatter = max(2.0 * rad, sqrt(rr / sw))
                    guard used >= 3, v > 0.035 * 0.035 * sw,
                          scatter / sqrt(v) < 25.0 * rad else { return nil }
                }
                return (line, used)
            }
            let db = linear ? (xr - mx * sr) / v : 0.0
            line.mid = wrap(line.mid + mr - db * mx)
            line.slope += db
            if linear && abs(line.slope) > limit + outer / span { return nil }
        }
        return nil
    }

    static func run(_ spectrum: Spectrum, initial: Double) throws -> (p0: Double, p1: Double, regions: Int, fittedFirstOrder: Bool) {
        guard initial.isFinite else { throw NMRError("请输入有效的一阶相位。") }
        guard let im = spectrum.imag else { throw NMRError("自动调相需要包含实部和虚部的复数谱。") }
        let re = spectrum.real, ppm = spectrum.ppm, n = re.count
        guard n >= 9, im.count == n, ppm.count == n else {
            throw NMRError("自动调相至少需要九个实部、虚部与 ppm 一一对应的采样点。")
        }
        var scale = 0.0, varies = false
        for j in 0..<n {
            if re[j] != re[0] || im[j] != im[0] { varies = true }
            guard re[j].isFinite, im[j].isFinite, ppm[j].isFinite else {
                throw NMRError("谱图含无效采样值，无法自动调相。")
            }
            if j > 0 && ppm[j] >= ppm[j-1] { throw NMRError("自动调相需要递减的 ppm 轴。") }
            scale = max(scale, max(abs(re[j]), abs(im[j])))
        }
        guard scale > 0.0 else { throw NMRError("谱图信号全为零，无法估计相位。") }

        guard varies else { throw NMRError("谱图为常量，无法可靠估计相位。") }

        // Normalize before forming powers. Apply the known ramp first, with
        // periodic oscillator resets to bound drift on long transforms.
        let step = (initial / Double(n - 1)).truncatingRemainder(dividingBy: 360.0) * rad
        let cr = cos(step), si = sin(step)
        var c = 1.0, s = 0.0
        var z = [Z]()
        z.reserveCapacity(n)
        for j in 0..<n {
            if (j & 1023) == 0 {
                let t = step * Double(j)
                c = cos(t)
                s = sin(t)
            }
            let r = re[j] / scale, i = im[j] / scale
            z.append(Z(r: r * c - i * s, i: r * s + i * c))
            let nc = c * cr - s * si
            s = s * cr + c * si
            c = nc
        }
        let measured = measurements(z)
        if let f = measured.wing.solution {
            let p1 = initial + f.delta / rad
            guard p1.isFinite else { throw NMRError("一阶相位超出数值范围。") }
            return (wrap(f.edge) / rad, p1, f.regions, f.fitted)
        }
        let a = measured.local
        if measured.wing.allowRamp, let (line, used) = consensus(a, linear: true) {
            let p1 = initial + line.slope / rad
            guard p1.isFinite else { throw NMRError("一阶相位超出数值范围。") }
            return (wrap(line.mid - 0.5 * line.slope) / rad, p1, used, true)
        }
        if let (line, used) = consensus(a, linear: false) {
            return (wrap(line.mid) / rad, initial, used, false)
        }
        // A cluster can identify the absorption phase even if individual
        // line fits disagree or the data cannot constrain a full-band ramp.
        let fallback = try estimateByEntropy(real: re, imag: im, initialFirstOrder: initial)
        guard !fallback.fittedFirstOrder || measured.wing.allowRamp else {
            throw NMRError("独立峰区不足或相位绕转不明确，无法确认一阶相位。")
        }
        return fallback
    }
}

/// Degrees, left-edge anchored, for multiplication by exp(+i*theta).
/// regions counts independent inlier regions, not bins or scale detections.
func estimateSpectralPhase(_ spectrum: Spectrum, initialFirstOrder: Double) throws -> (p0: Double, p1: Double, regions: Int, fittedFirstOrder: Bool) {
    let estimate = try SpectralPhase1D.run(spectrum, initial: initialFirstOrder)
    if let imaginary = spectrum.imag,
       let refined = AbsorptionRefinement.refine(real: spectrum.real, imag: imaginary,
                                                seedP0: estimate.p0, seedP1: estimate.p1) {
        let edge = refined.p0.remainder(dividingBy: 360)
        return (edge, refined.p1, refined.regions, true)
    }
    return estimate
}
