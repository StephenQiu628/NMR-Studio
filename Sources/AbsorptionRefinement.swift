import Foundation

// Compare signed absorption areas in independently located regions. The
// area/magnitude and negative-wing criteria follow the approach studied for
// solution polymers by de Brouwer (JMR, doi:10.1016/j.jmr.2009.09.017).

enum AbsorptionRefinement {
    private static let rad = Double.pi / 180.0
    private static let maxSiteDelta = 105.0
    private typealias Line = (a: Double, b: Double) // increment at pivot, slope increment

    private struct Site {
        let p: Int, r8: Int, r12: Int
        let width: Double
    }

    private static func sites(_ m: [Double], top: Double, sigma: Double) -> [Site] {
        let n = m.count, spacing = max(2, m.count / 800)
        let cell = max(1, spacing / 2), drop = 0.025 * top + 5 * sigma
        let height = max(0.04 * top, 6 * sigma)
        var win = [Int](repeating: -1, count: 1 + (n - 1) / cell)
        func offer(_ p: Int) {
            let b = p / cell
            if m[p] >= height && (win[b] < 0 || m[p] > m[win[b]]) {
                win[b] = p
            }
        }

        // Full-resolution excursions: emit a crest only after both a rise and a fall.
        var low = m[0], crest = 0, endTop = 0, up = false
        for k in 1..<n {
            let h = m[k]
            if up {
                if h > m[crest] { crest = k; endTop = k }
                else if h == m[crest] && k == endTop + 1 { endTop = k }
                else if m[crest] - h >= drop {
                    offer(crest + (endTop - crest) / 2); up = false; low = h
                }
            } else {
                low = min(low, h)
                if h - low >= drop { up = true; crest = k; endTop = k }
            }
        }
        let order = win.indices.filter { win[$0] >= 0 }.sorted {
            let a = m[win[$0]], b = m[win[$1]]
            return a == b ? $0 < $1 : a > b
        }
        // Resolve nearby crests before setting flank distances. Otherwise a
        // shoulder inside a resonance can exclude its summit and cast a vote
        // of its own from a much narrower section of the same line.
        var distinct = [Int]()
        for p in order.map({ win[$0] }) where !distinct.contains(where: { abs($0 - p) < spacing }) {
            distinct.append(p)
        }
        distinct.sort()
        var g = [Site]()
        for (j, p) in distinct.enumerated() {
            let left = j == 0 ? n : p - distinct[j - 1]
            let right = j + 1 == distinct.count ? n : distinct[j + 1] - p
            let d = min(left, right), h = m[p]
            let cap = min(0.43 * Double(d), Double(min(p, n - 1 - p)))
            if cap < 1 { continue }

            // Bounded topographic prominence; sum of nearest-neighbor gaps is O(n).
            let lo = max(0, p - 4 * d), hi = min(n - 1, p + 4 * d)
            var l = p, r = p, ml = h, mr = h
            while l > lo && m[l-1] <= h { l -= 1; ml = min(ml, m[l]) }
            while r < hi && m[r+1] <= h { r += 1; mr = min(mr, m[r]) }
            let prom = h - max(ml, mr)
            if prom < drop { continue }
            let half = h - 0.5 * prom
            l = p; r = p
            while m[l] > half { l -= 1 }
            while m[r] > half { r += 1 }
            let dl = (half - m[l]) / (m[l+1] - m[l]), dr = (half - m[r]) / (m[r-1] - m[r])
            let w = 0.289 * (Double(r - l) - dl - dr)
            let small = Int(min(cap, 8 * w))
            if small > 0 && Double(small) >= 2 * w {
                g.append(Site(p: p, r8: small, r12: Int(min(cap, 12 * w)), width: w))
            }
        }
        if g.count > 32 {
            g.sort { m[$0.p] > m[$1.p] }
            return g.prefix(32).sorted { $0.p < $1.p }
        }
        return g
    }

    private struct Samples {
        var u = [Double](), v = [Double](), dx = [Double](), ends = [Int]()
    }
    private struct Moment {
        let net: Double, norm: Double
        var cost: Double { norm - 0.94 * abs(net) }
        var wing: Double { 0.5 * max(0, norm - abs(net)) } // minority-sign area
    }
    private struct Row {
        let s: Samples
        var re: [Double], im: [Double]
        init(_ s: Samples) { self.s = s; re = s.u; im = s.v }
        mutating func slope(_ b: Double) {
            if b == 0 { re = s.u; im = s.v; return }
            for k in s.dx.indices {
                let t = b * s.dx[k], c = cos(t), h = sin(t)
                re[k] = c * s.u[k] - h * s.v[k]; im[k] = h * s.u[k] + c * s.v[k]
            }
        }
        func loss(_ a: Double, _ omit: Int, _ save: Bool, _ out: inout [Moment]) -> Double {
            let t = a * AbsorptionRefinement.rad, c = cos(t), h = sin(t)
            var lo = 0, cost = 0.0
            for (j, hi) in s.ends.enumerated() {
                if j != omit {
                    var net = 0.0, norm = 0.0
                    for k in lo..<hi {
                        let r = c * re[k] - h * im[k]
                        net += r; norm += abs(r)
                    }
                    let m = Moment(net: net, norm: norm)
                    cost += m.cost
                    if save { out.append(m) }
                }
                lo = hi
            }
            return cost
        }
    }

    private static func moments(_ s: Samples, _ f: Line) -> [Moment] {
        var row = Row(s), out = [Moment]()
        row.slope(f.b); _ = row.loss(f.a, -1, true, &out)
        return out
    }
    private static func fit(_ s: Samples, _ span: Double, skipping omit: Int = -1) -> Line {
        // No more than a half turn of additional slope, or 110 degrees between sites.
        let bound = min(180.0, 110.0 / span)
        var row = Row(s), scratch = [Moment](), da = 10.0, db = bound / 8
        var best: Line = (0, 0)
        var value = row.loss(0, omit, false, &scratch)
        func grid(_ origin: Line, _ na: Int, _ nb: Int) {
            for j in (-nb)...nb {
                let b = origin.b + Double(j) * db
                if abs(b) > bound { continue }
                row.slope(b)
                for i in (-na)...na {
                    let a = (origin.a + Double(i) * da).remainder(dividingBy: 180.0)
                    if abs(a) + 0.5 * span * abs(b) > maxSiteDelta { continue }
                    let v = row.loss(a, omit, false, &scratch)
                    if v < value { value = v; best = (a, b) }
                }
            }
        }
        grid(best, 9, 8)
        for _ in 0..<6 { da *= 0.5; db *= 0.5; grid(best, 2, 2) }
        return best
    }

    private static func improved(_ before: [Moment], _ after: [Moment], at x: [Double]) -> Bool {
        var norm = 0.0, wing = 0.0, gain = 0.0, decrease = 0.0, l = 1.0, r = 0.0
        for k in x.indices {
            let s = before[k], t = after[k]
            // Do not credit wing removal attributable merely to shrinking the projection.
            let keep = s.norm > 0 ? min(1.0, t.norm / s.norm) : 1.0
            let d = keep * s.wing - t.wing
            gain += d; norm += s.norm; wing += s.wing; decrease += s.cost - t.cost
            if d > 0.005 * s.norm { l = min(l, x[k]); r = max(r, x[k]) }
        }
        return decrease > 0 && gain > max(0.01 * norm, 0.12 * wing)
            && r - l >= 0.08 * (x[x.count-1] - x[0])
    }

    static func refine(real: [Double], imag: [Double], seedP0: Double, seedP1: Double) -> (p0: Double, p1: Double, regions: Int)? {
        let n = real.count
        guard n >= 3, imag.count == n, seedP0.isFinite, seedP1.isFinite,
              seedP0.ulp <= 0.125, seedP1.ulp <= 0.125 else { return nil }
        var scale = 0.0
        for k in 0..<n {
            let a = real[k], b = imag[k]
            guard a.isFinite && b.isFinite else { return nil }
            scale = max(scale, max(abs(a), abs(b)))
        }
        guard scale > 0 else { return nil }
        var mag = [Double](repeating: 0, count: n), top = 0.0
        for k in 0..<n {
            let a = real[k] / scale, b = imag[k] / scale
            mag[k] = (a*a + b*b).squareRoot(); top = max(top, mag[k])
        }
        // Median absolute short-lag differences, in normalized quadrature units.
        let lag = max(1, n / 512)
        var dr = [Double](), di = [Double]()
        for k in stride(from: lag, to: n, by: 1 + (n - 1 - lag) / 4096) {
            dr.append(abs(real[k] / scale - real[k-lag] / scale))
            di.append(abs(imag[k] / scale - imag[k-lag] / scale))
        }
        dr.sort(); di.sort()
        let mid = dr.count / 2, sigma = max(dr[mid], di[mid]) / 0.953872
        let g = sites(mag, top: top, sigma: sigma)
        guard g.count >= 3 else { return nil }
        let den = Double(n - 1), x = g.map { Double($0.p) / den }
        let span = x[x.count - 1] - x[0]
        guard span >= 0.10 else { return nil }
        let area = fitAreas(real: real, imag: imag, mag: mag, scale: scale, sigma: sigma,
                            sites: g, positions: x, seedP0: seedP0, seedP1: seedP1)
        if let fine = BackgroundPhase.polish(real: real, imag: imag, p0: area?.p0 ?? seedP0,
                                             p1: area?.p1 ?? seedP1, centers: g.map(\.p),
                                             halfWidths: g.map(\.width)) {
            return (fine.p0, fine.p1, g.count)
        }
        return area
    }

    private static func fitAreas(real: [Double], imag: [Double], mag: [Double], scale: Double,
                                 sigma: Double, sites g: [Site], positions x: [Double],
                                 seedP0: Double, seedP1: Double) -> (p0: Double, p1: Double, regions: Int)? {
        let n = real.count, den = Double(n - 1)
        let span = x[x.count - 1] - x[0], pivot = x[0] + 0.5 * span
        let p0 = seedP0.truncatingRemainder(dividingBy: 360.0)

        func samples(_ wide: Bool) -> Samples {
            var s = Samples()
            for site in g {
                let p = site.p, r = wide ? site.r12 : site.r8, flank = max(1, (2 * r + 1) / 16)
                var br = 0.0, bi = 0.0
                for k in 0..<flank {
                    let l = p - r + k, h = p + r - k
                    br += real[l] / scale + real[h] / scale; bi += imag[l] / scale + imag[h] / scale
                }
                br /= Double(2 * flank); bi /= Double(2 * flank)
                let side = min(150, r), step = Double(r) / Double(side)
                let weight = step / (mag[p] * site.width)
                for k in (-side)...side {
                    let j = p + Int((Double(k) * step).rounded()), pos = Double(j) / den
                    let t = (p0 + (seedP1 * pos).truncatingRemainder(dividingBy: 360.0)) * rad
                    let c = cos(t), h = sin(t), a = real[j] / scale - br, b = imag[j] / scale - bi
                    s.u.append(weight * (c*a - h*b)); s.v.append(weight * (h*a + c*b))
                    s.dx.append((pos - pivot) * rad)
                }
                s.ends.append(s.u.count)
            }
            return s
        }

        let primary = samples(false), start = moments(primary, (0, 0))
        guard start.reduce(0.0, { $0 + $1.wing }) > 0.01 * start.reduce(0.0, { $0 + $1.norm }) else { return nil }
        let f = fit(primary, span), finish = moments(primary, f)
        guard improved(start, finish, at: x) else { return nil }
        var votes = 0, a = f.a
        for k in g.indices {
            let product = start[k].net * finish[k].net
            votes += product > 0 ? 1 : (product < 0 ? -1 : 0)
        }
        guard votes != 0 else { return nil }
        if votes < 0 { a += a < 0 ? 180 : -180 } // one global branch only
        guard abs(a) + 0.5 * span * abs(f.b) <= maxSiteDelta else { return nil }

        let check = samples(true), base = moments(check, (0, 0))
        guard improved(base, moments(check, f), at: x) else { return nil }
        // A near-uniform rotation can also reduce the flank-subtracted cost
        // on an already absorptive asymmetric multiplet. In that case require
        // opposite-sign lobes in two of the original, unflattened regions.
        if abs(f.b) * span < 8 {
            func projected(_ j: Int) -> Double {
                let phase = (p0 + seedP1 * (Double(j) / den)) * rad
                return (real[j] / scale) * cos(phase) - (imag[j] / scale) * sin(phase)
            }
            let background = stride(from: 0, to: n, by: max(1, n / 1024)).map(projected).sorted()
            let zero = background[background.count / 2]
            var bipolar = 0
            for site in g {
                var lo = 0.0, hi = 0.0
                for j in stride(from: site.p - site.r12, through: site.p + site.r12, by: max(1, site.r12 / 150)) {
                    let y = projected(j) - zero
                    lo = min(lo, y); hi = max(hi, y)
                }
                if min(-lo, hi) > max(6 * sigma, 0.02 * max(-lo, hi)) { bipolar += 1 }
            }
            guard bipolar >= 2 else { return nil }
        }
        // If geometry clipped both expansions identically, hold out an interior site.
        let omit = g.allSatisfy({ $0.r8 == $0.r12 }) ? g.count / 2 : -1
        let alt = fit(check, span, skipping: omit)
        let da = (alt.a - f.a).remainder(dividingBy: 180.0)
        guard abs(da) + 0.5 * span * abs(alt.b - f.b) <= 8.0 else { return nil }
        if omit >= 0 && moments(check, alt)[omit].cost > base[omit].cost + 0.005 * base[omit].norm { return nil }
        return (seedP0 + (a - f.b * pivot), seedP1 + f.b, g.count)
    }
}
