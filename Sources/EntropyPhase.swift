// SPDX-License-Identifier: MIT
// Copyright (c) 2026 The OpenReadout Authors
// Adapted from the OpenReadout contributors' nmr/phase.rs:
// https://github.com/openreadout/openreadout/blob/main/crates/openreadout-signal/src/nmr/phase.rs
// Source Git blob: aad71661b32aa9c734c5106f1bdb49fc6849e345
// ACME: Chen, Weng, Goh & Garland, J. Magn. Reson. 158, 164-168 (2002).
// Swift adaptation: host rotation convention, complex background removal,
// peak-preserving bounded supports, adjacent-bin derivatives, prior-relative
// ramp search, signed-core validation, and a separately fitted fixed-ramp model.

import Foundation

private enum EntropyPhaseError: LocalizedError {
    case invalidInput       // Length, non-finite value, or unusable numeric range
    case noSignal           // No sufficiently strong signal above background
    case maskTooComplex     // Cannot protect all detected peaks within the budget
    case inconclusive       // No defensible positive-absorption candidate

    var errorDescription: String? {
        switch self {
        case .invalidInput: return "复数谱数据或一阶相位超出可处理范围。"
        case .noSignal: return "没有检测到足够强的核磁信号，无法可靠估计相位。"
        case .maskTooComplex: return "谱图中候选峰过多，自动调相无法可靠区分峰和噪声。"
        case .inconclusive: return "未能确认可靠的吸收相位。可以在调相页手动预览。"
        }
    }
}

private enum EP {
    typealias Answer = (p0: Double, p1: Double, regions: Int, fittedFirstOrder: Bool)
    static let rad = Double.pi / 180.0
    static let maxDelta = 1440.0

    static func wrap(_ p: Double) -> Double {
        var a = p.truncatingRemainder(dividingBy: 360.0)
        if a >= 180 { a -= 360 }
        if a < -180 { a += 360 }
        return a
    }

    static func priorCost(_ d: Double) -> Double {
        let u = d / 360.0
        return 0.05 * u * u
    }

    // Called only on nonempty, bounded-size arrays.
    static func median(_ a: [Double]) -> Double {
        let s = a.sorted(), k = s.count / 2
        return s.count % 2 == 1 ? s[k] : 0.5 * (s[k - 1] + s[k])
    }

    // Robust straight line through slab medians, in the observed complex frame.
    static func line(_ x: [Double], _ y: [Double]) -> (Double, Double) {
        let groups = min(9, max(1, y.count / 32))
        var t = [Double](), v = [Double]()
        for g in 0..<groups {
            let l = g * y.count / groups, h = (g + 1) * y.count / groups
            t.append(0.5 * (x[l] + x[h - 1]))
            v.append(median(Array(y[l..<h])))
        }
        var slopes = [Double]()
        for j in 0..<groups {
            for i in 0..<j { slopes.append((v[j] - v[i]) / (t[j] - t[i])) }
        }
        let b = slopes.isEmpty ? 0.0 : median(slopes)
        return (median((0..<groups).map { v[$0] - b * t[$0] }), b)
    }

    // Scan at ORIGINAL resolution. Low runs must have a high seed. Within a
    // run, a drawdown followed by a rise can resolve additional magnitude peaks.
    static func mask(_ m: [Double], _ sigma: Double, _ mx: Double) throws
        -> ([ClosedRange<Int>], [Int]) {
        let low = max(5.0 * sigma, 1e-5 * mx)
        let high = max(8.0 * sigma, 1e-4 * mx)
        guard mx >= high else { throw EntropyPhaseError.noSignal }
        var blocks = [ClosedRange<Int>](), centers = [Int]()
        func record(_ k: Int) throws {
            guard centers.count < 96 else { throw EntropyPhaseError.maskTooComplex }
            centers.append(k)
        }
        var j = 0
        while j < m.count {
            if m[j] < low { j += 1; continue }
            let a = j
            var top = j
            while j < m.count && m[j] >= low {
                if m[j] > m[top] { top = j }
                j += 1
            }
            let b = j - 1
            guard m[top] >= high, a < b || m[top] >= 12.0 * sigma else { continue }
            let mark = centers.count
            var h = a, valley = a, seekingTop = true
            for k in a...b {
                if seekingTop {
                    if m[k] > m[h] { h = k }
                    if m[h] - m[k] >= max(3.5 * sigma, 0.25 * m[h]) {
                        if m[h] >= high { try record(h) }
                        seekingTop = false
                        valley = k
                    }
                } else {
                    if m[k] < m[valley] { valley = k }
                    if m[k] - m[valley] >= max(3.5 * sigma, 0.25 * m[k]) {
                        seekingTop = true
                        h = k
                    }
                }
            }
            if seekingTop && m[h] >= high { try record(h) }
            if !centers[mark..<centers.count].contains(top) { try record(top) }
            let l = max(0, a - 16), r = min(m.count - 1, b + 16)
            if let last = blocks.last, l <= last.upperBound + 1 {
                blocks[blocks.count - 1] = last.lowerBound...max(last.upperBound, r)
            } else {
                blocks.append(l...r)
            }
        }
        guard !centers.isEmpty else { throw EntropyPhaseError.noSignal }
        return (blocks, centers.sorted())
    }

    struct Peak {
        let k, l, r: Int  // apex and approximate half-power shoulders
        let block: ClosedRange<Int>
        let weight: Double
    }

    static func peaks(_ blocks: [ClosedRange<Int>], _ centers: [Int],
                      _ m: [Double], _ mx: Double) -> [Peak] {
        var result = [Peak](), bi = 0
        for s in centers.indices {
            let k = centers[s]
            while blocks[bi].upperBound < k { bi += 1 }
            let block = blocks[bi]
            var a = block.lowerBound, b = block.upperBound
            if s > 0 { a = max(a, k - (k - centers[s - 1]) / 2) }
            if s + 1 < centers.count { b = min(b, k + (centers[s + 1] - k) / 2) }
            var l = k, r = k
            let cut = 0.7071067811865476 * m[k]
            while l > a && m[l] > cut { l -= 1 }
            while r < b && m[r] > cut { r += 1 }
            result.append(Peak(k: k, l: l, r: r, block: block, weight: sqrt(m[k] / mx)))
        }
        return result
    }

    static func indices(_ cap: Int, _ blocks: [ClosedRange<Int>], _ pk: [Peak],
                        _ m: [Double]) -> [Int] {
        let total = blocks.reduce(0) { $0 + $1.count }
        if total <= cap {
            var all = [Int]()
            all.reserveCapacity(total)
            for b in blocks { all.append(contentsOf: b) }
            return all
        }
        var keep = Set<Int>()
        keep.reserveCapacity(cap)
        func patch(_ k: Int, _ radius: Int, _ b: ClosedRange<Int>) {
            let l = max(b.lowerBound, k - radius), r = min(b.upperBound, k + radius)
            for j in l...r { keep.insert(j) }
        }
        // At most 11 mandatory bins per peak, including adjacent pairs. This
        // fits even on the coarse support. Never decimate these patches away.
        for p in pk {
            patch(p.k, 2, p.block); patch(p.l, 1, p.block); patch(p.r, 1, p.block)
        }
        let tiles = (cap - keep.count) / 6
        for b in blocks {
            let q = tiles * b.count / total
            for t in 0..<q {
                let l = b.lowerBound + t * b.count / q
                let end = b.lowerBound + (t + 1) * b.count / q
                var top = l
                for j in l..<end where m[j] > m[top] { top = j }
                patch(top, 1, b); patch(l + (end - l) / 2, 1, b)
            }
        }
        return keep.sorted()
    }

    struct Bin {
        let x, r, i: Double  // x = j/(n-1) minus pivot
        let link: Bool       // preceding retained bin is the true left neighbor
    }
    struct Rot {
        let r, i: Double
        let link: Bool
    }
    struct Fit {
        let a, d, loss, sign, profile: Double  // pivot angle and increment from prior
    }
    struct Row {
        let z: [Rot]
        let vr, vi, profile, d: Double

        func eval(_ angle: Double) -> Fit? {
            let a = EP.wrap(angle), t = a * EP.rad
            let c = cos(t), s = sin(t)
            let sign = vr * c - vi * s
            // Opposite absorption sign has score -sign; near-quadrature cores
            // are not a successful phase either. No per-region unanimity test.
            guard !z.isEmpty, sign >= 0.55, sign >= 0.85 * profile else { return nil }
            var last = 0.0, total = 0.0, hlogh = 0.0, neg = 0.0
            for e in z {
                let r = e.r * c - e.i * s
                if r < 0 { neg += r * r }
                if e.link {
                    let h = abs(r - last)
                    if h > 0 { total += h; hlogh += h * log(h) }
                }
                last = r
            }
            guard total > 0 else { return nil }
            let entropy = max(0.0, log(total) - hlogh / total)
            let loss = entropy + 1000.0 * neg + EP.priorCost(d)
            guard loss.isFinite else { return nil }
            return Fit(a: a, d: d, loss: loss, sign: sign, profile: profile)
        }
    }

    // Share ramp rotations across all intercepts at this slope. Validation
    // uses symmetric magnitude-core samples, not the ACME derivative or penalty.
    static func row(_ bins: [Bin], _ votes: [Bin], _ prior: Double, _ d: Double) -> Row {
        let b = (prior + d) * rad
        var vr = 0.0, vi = 0.0
        for v in votes {
            let t = b * v.x, c = cos(t), s = sin(t)
            vr += v.r * c - v.i * s
            vi += v.r * s + v.i * c
        }
        let profile = hypot(vr, vi)  // best possible signed-core score over P0
        var z = [Rot]()
        if profile >= 0.55 {
            z.reserveCapacity(bins.count)
            for v in bins {
                let t = b * v.x, c = cos(t), s = sin(t)
                z.append(Rot(r: v.r * c - v.i * s, i: v.r * s + v.i * c, link: v.link))
            }
        }
        return Row(z: z, vr: vr, vi: vi, profile: profile, d: d)
    }

    static func prefer(_ f: Fit, _ g: Fit) -> Bool {
        // Strict ordering, with sub-nanonat ties resolved by absorption score
        // (important for a one-bin peak with angle-independent entropy).
        let x = (f.loss * 1e9).rounded(), y = (g.loss * 1e9).rounded()
        if x != y { return x < y }
        if f.sign != g.sign { return f.sign > g.sign }
        if abs(f.d) != abs(g.d) { return abs(f.d) < abs(g.d) }
        if f.d != g.d { return f.d < g.d }
        return f.a < g.a
    }

    static func take(_ f: Fit?, _ best: inout Fit?) {
        guard let p = f else { return }
        if let g = best, !prefer(p, g) { return }
        best = p
    }

    static func circle(_ r: Row) -> Fit? {
        guard !r.z.isEmpty else { return nil }
        var best: Fit? = nil
        for k in 0..<24 { take(r.eval(15.0 * Double(k)), &best) }
        take(r.eval(atan2(-r.vi, r.vr) / rad), &best)
        return best
    }

    static func fixedFit(_ r: Row) -> Fit? {
        guard var f = circle(r) else { return nil }
        var h = 7.5
        for _ in 0..<9 {
            for _ in 0..<2 {
                var next: Fit? = f
                take(r.eval(f.a - h), &next); take(r.eval(f.a + h), &next)
                guard let g = next, prefer(g, f) else { break }
                f = g
            }
            h *= 0.5
        }
        return f
    }

    static func jointFit(_ seed: Fit, _ bins: [Bin], _ votes: [Bin], _ prior: Double) -> Fit? {
        let start = row(bins, votes, prior, seed.d)
        var first = circle(start)
        take(start.eval(seed.a), &first)
        guard var f = first else { return nil }
        var ha = 7.5, hd = 22.5
        for _ in 0..<9 {
            for _ in 0..<2 {
                var next: Fit? = f
                for k in (-1)...1 {
                    let d = f.d + Double(k) * hd
                    if abs(d) > maxDelta { continue }
                    let r = row(bins, votes, prior, d)
                    for j in (-1)...1 { take(r.eval(f.a + Double(j) * ha), &next) }
                }
                guard let g = next, prefer(g, f) else { break }
                f = g
            }
            ha *= 0.5; hd *= 0.5
        }
        return f
    }

    static func run(_ real: [Double], _ imag: [Double], _ prior: Double) throws -> Answer {
        let n = real.count
        guard n == imag.count, n >= 32, prior.isFinite, abs(prior) <= 1e7 else {
            throw EntropyPhaseError.invalidInput
        }
        let den = Double(n - 1)
        var scale = 0.0
        for j in 0..<n {
            guard real[j].isFinite, imag[j].isFinite else { throw EntropyPhaseError.invalidInput }
            scale = max(scale, max(abs(real[j]), abs(imag[j])))
        }
        guard scale > 0 else { throw EntropyPhaseError.noSignal }
        // Stratification is for background/noise ONLY, not for locating signal.
        let q = min(n, 8192)
        var x = [Double](), re = [Double](), im = [Double]()
        var state: UInt64 = 0x39ba741d
        for k in 0..<q {
            let l = k * n / q, h = (k + 1) * n / q
            state = (state &* 6364136223846793005) &+ 1442695040888963407
            let j = l + Int((state >> 16) % UInt64(h - l))
            x.append(Double(j) / den); re.append(real[j] / scale); im.append(imag[j] / scale)
        }
        let (ar, br) = line(x, re), (ai, bi) = line(x, im)
        let sr = median(x.indices.map { abs(re[$0] - (ar + br * x[$0])) })
        let si = median(x.indices.map { abs(im[$0] - (ai + bi * x[$0])) })
        let sigma = max(64.0 * Double.ulpOfOne, max(sr, si) / 0.6744897501960817)
        func signal(_ j: Int) -> (Double, Double) {
            let t = Double(j) / den
            return (real[j] / scale - (ar + br * t), imag[j] / scale - (ai + bi * t))
        }
        var m = [Double](repeating: 0, count: n), mx = 0.0
        for j in 0..<n {
            let (r, i) = signal(j)
            m[j] = sqrt(r * r + i * i); mx = max(mx, m[j])
        }
        let (blocks, centers) = try mask(m, sigma, mx)
        let pk = peaks(blocks, centers, m, mx)
        let weight = pk.reduce(0.0) { $0 + $1.weight }
        let pivot = pk.reduce(0.0) { $0 + $1.weight * (Double($1.k) / den) } / weight
        func bin(_ j: Int, _ link: Bool) -> Bin {
            let (r, i) = signal(j)
            return Bin(x: Double(j) / den - pivot, r: r / mx, i: i / mx, link: link)
        }
        func sites(_ cap: Int) -> [Bin] {
            let ids = indices(cap, blocks, pk, m)
            var result = [Bin](), prev = -2
            result.reserveCapacity(ids.count)
            for j in ids { result.append(bin(j, j == prev + 1)); prev = j }
            return result
        }
        var votes = [Bin]()
        for p in pk {
            let r = min(max(1, n / 100), min(p.k - p.l, p.r - p.k))
            let ks = Set([p.k, p.k - r, p.k + r, p.k - r / 2, p.k + r / 2]).sorted()
            let mass = ks.reduce(0.0) { $0 + m[$1] / mx }
            let w = p.weight / (weight * mass)
            for k in ks {
                let v = bin(k, false)
                votes.append(Bin(x: v.x, r: w * v.r, i: w * v.i, link: false))
            }
        }
        func answer(_ f: Fit, _ fitted: Bool) -> Answer {
            let slope = fitted ? prior + f.d : prior
            return (wrap(f.a - slope * pivot), slope, blocks.count, fitted)
        }

        let fine = sites(8192), fixedRow = row(fine, votes, prior, 0)
        let fixed = fixedFit(fixedRow)
        // Padding, tails and the endpoints of a broad line are NOT independent
        // evidence for P1. Test leverage of credible localized apices instead.
        let strong = pk.filter {
            m[$0.k] >= max(10.0 * sigma, 0.02 * mx) && Double($0.r - $0.l) <= 0.08 * den
        }
        var span = 0.0, spread = 0.0
        if strong.count >= 2, let a = strong.first, let b = strong.last {
            span = Double(b.k - a.k) / den
            let w = strong.reduce(0.0) { $0 + $1.weight }
            let center = strong.reduce(0.0) { $0 + $1.weight * (Double($1.k) / den) } / w
            var ss = 0.0
            for p in strong {
                let u = Double(p.k) / den - center
                ss += p.weight * u * u
            }
            spread = sqrt(ss / w)
        }
        if span >= 0.18 && spread >= 0.075 {
            let coarse = sites(1536)
            var grid = [Fit]()
            for k in (-32)...32 {
                if let f = circle(row(coarse, votes, prior, 45.0 * Double(k))) { grid.append(f) }
            }
            let order = grid.sorted(by: prefer)
            var seeds = [Fit]()
            func propose(_ f: Fit) {
                if seeds.count < 4 && !seeds.contains(where: { abs($0.d - f.d) < 90 }) {
                    seeds.append(f)
                }
            }
            if let f = order.first { propose(f) }
            if let f = order.max(by: { $0.profile < $1.profile }) { propose(f) }
            if let f = fixed { propose(f) }
            for f in order { propose(f) }
            let polished = seeds.compactMap { jointFit($0, fine, votes, prior) }
            // Compare ONLY fine-support objectives. Profile gain asks whether
            // changing P1 helps even after giving fixed P1 its best sign angle.
            let eligible = polished.filter { f in
                guard f.d != 0, f.profile >= fixedRow.profile + 0.003 else { return false }
                if let g = fixed { return f.loss + 0.01 < g.loss && f.sign >= g.sign + 0.001 }
                return true
            }
            if let best = eligible.sorted(by: prefer).first {
                var alternatives = polished
                if let g = fixed { alternatives.append(g) }
                let dataLoss = best.loss - priorCost(best.d)
                let windingAmbiguity = alternatives.contains { g in
                    abs(g.d - best.d) * span > 180 && g.profile >= best.profile - 0.01 &&
                    g.sign >= best.sign - 0.015 && g.loss - priorCost(g.d) <= dataLoss + 0.03
                }
                if !windingAmbiguity { return answer(best, true) }
            }
        }
        if let f = fixed { return answer(f, false) }
        throw EntropyPhaseError.inconclusive
    }
}

/// Absolute application phases in degrees, for the supplied, unmodified FFT.
func estimateByEntropy(real: [Double], imag: [Double], initialFirstOrder: Double) throws
    -> (p0: Double, p1: Double, regions: Int, fittedFirstOrder: Bool) {
    return try EP.run(real, imag, initialFirstOrder)
}
