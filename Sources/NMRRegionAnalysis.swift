import Foundation

// Same-target module, Swift 5. Height-normalized Gaussian/Lorentzian FWHM forms:
// https://github.com/jjhelmus/nmrglue/blob/master/nmrglue/analysis/lineshapes1d.py
// Here eta is explicitly the Lorentzian HEIGHT fraction, not an area fraction.
// The windowing, optimizer, diagnostics and line tests below are independent implementations.
enum NMRAnalysisError: LocalizedError {
    case message(String)
    var errorDescription: String? { switch self { case .message(let s): return s } }
}

struct NMRBand: Codable, Equatable {
    let lo: Double
    let hi: Double
    init(_ a: Double, _ b: Double) { if a <= b { lo = a; hi = b } else { lo = b; hi = a } }
    var width: Double { hi - lo }
    var mid: Double { lo + width / 2 }
    var valid: Bool { lo.isFinite && hi.isFinite && width.isFinite && width > 0 }
    func contains(_ x: Double) -> Bool { x >= lo && x <= hi }
    func mapped(_ f: (Double) -> Double) -> Self { Self(f(lo), f(hi)) }
}

struct NMRXY { let x: Double; let y: Double }

// key identifies the processed intensities AND calibrated axis; keep it stable across reopen.
// Copies share Array storage. The logical sample index is ascending; storage need not be.
struct NMRTrace {
    let key: String
    let ppm: [Double]
    let intensity: [Double]
    let observeMHz: Double?
    private let descending: Bool
    init(key: String, ppm: [Double], intensity: [Double], observeMHz: Double? = nil) throws {
        guard !key.isEmpty, ppm.count == intensity.count, ppm.count >= 2,
              ppm.allSatisfy({ $0.isFinite }), intensity.allSatisfy({ $0.isFinite }) else { throw NMRAnalysisError.message("谱轴或强度无效") }
        let desc = ppm[1] < ppm[0]
        for i in 1..<ppm.count where !(desc ? ppm[i] < ppm[i-1] : ppm[i] > ppm[i-1]) { throw NMRAnalysisError.message("谱轴须严格单调") }
        guard NMRBand(ppm[0], ppm[ppm.count-1]).valid else { throw NMRAnalysisError.message("谱宽无效") }
        if let f = observeMHz, !(f.isFinite && f > 0) { throw NMRAnalysisError.message("观测频率无效") }
        self.key = key; self.ppm = ppm; self.intensity = intensity; self.observeMHz = observeMHz; descending = desc
    }
    private func storage(_ i: Int) -> Int { descending ? ppm.count - 1 - i : i }
    func x(_ i: Int) -> Double { ppm[storage(i)] }
    func y(_ i: Int) -> Double { intensity[storage(i)] }
    var domain: NMRBand { NMRBand(x(0), x(ppm.count-1)) }
    private func bound(_ v: Double, upper: Bool) -> Int {
        var a = 0, b = ppm.count
        while a < b { let m = a + (b-a)/2; if x(m) < v || (upper && x(m) == v) { a = m+1 } else { b = m } }
        return a
    }
    func indices(in w: NMRBand) throws -> Range<Int> {
        guard w.valid, domain.contains(w.lo), domain.contains(w.hi) else { throw NMRAnalysisError.message("区域须在当前谱轴内") }
        return bound(w.lo, upper: false)..<bound(w.hi, upper: true)
    }
    // Drawing only. Each bin contributes actual extrema, in acquisition-coordinate order (ascending x).
    func preview(_ r: Range<Int>) -> [NMRXY] {
        guard !r.isEmpty else { return [] }
        var out = [NMRXY(x: x(r.lowerBound), y: y(r.lowerBound))], i = r.lowerBound
        let step = max(1, r.count / 768)
        while i < r.upperBound {
            let end = min(r.upperBound, i+step); var a = i, b = i
            for j in i..<end { if y(j) < y(a) { a = j }; if y(j) > y(b) { b = j } }
            out.append(NMRXY(x: x(min(a,b)), y: y(min(a,b))))
            if a != b { out.append(NMRXY(x: x(max(a,b)), y: y(max(a,b)))) }; i = end
        }
        out.append(NMRXY(x: x(r.upperBound-1), y: y(r.upperBound-1))); return out
    }
    func displayGain(in w: NMRBand, target: Double) throws -> Double {
        var m = 0.0; for i in try indices(in: w) { m = max(m, abs(y(i))) }
        guard target.isFinite, target > 0, m > 0, (target/m).isFinite, target/m > 0 else { throw NMRAnalysisError.message("目标须为正，区内须有非零信号") }; return target/m
    }
}

struct NMRIntegralReference: Codable {
    let originalPPM: NMRBand
    let rawSignedArea: Double
    let target: Double
    var valid: Bool { originalPPM.valid && rawSignedArea.isFinite && rawSignedArea != 0 && target.isFinite && target > 0 }
}
struct NMRRelativeArea: Codable { let reference: NMRIntegralReference; let value: Double }
struct NMRAreaEvidence: Codable {
    let traceKey: String
    let calibratedPPM: NMRBand
    let originalPPM: NMRBand
    let rawSignedArea: Double
    let relative: NMRRelativeArea?
    let setsReference: Bool
}
// All five callbacks are synchronous on the host/UI thread. commitMark should commit atomically.
struct NMRAnalysisPorts {
    var toOriginalPPM: (Double) -> Double
    var fromOriginalPPM: (Double) -> Double
    var rawSignedArea: (NMRBand) throws -> Double
    var relativeToPriorReference: (Double) throws -> NMRRelativeArea?
    var commitMark: (NMRAreaEvidence) throws -> Void
    // Convenience adapter for calibrated = original + shift. integrate takes ascending BOUNDS,
    // not a reversed copy of the descending spectrum. The host owns its signed-area convention.
    static func translated(shift: Double, integrate: @escaping (Double, Double) throws -> Double, relative: @escaping (Double) throws -> NMRRelativeArea?, commit: @escaping (NMRAreaEvidence) throws -> Void) -> Self {
        Self(toOriginalPPM: { $0-shift }, fromOriginalPPM: { $0+shift }, rawSignedArea: { try integrate($0.lo, $0.hi) }, relativeToPriorReference: relative, commitMark: commit)
    }
}

enum NMRShape: String, Codable, CaseIterable { case lorentzian, gaussian, pseudoVoigt
    var label: String { switch self { case .lorentzian: return "洛伦兹"; case .gaussian: return "高斯"; case .pseudoVoigt: return "伪沃伊特" } }
    func fraction(_ mix: Double) -> Double { switch self { case .lorentzian: return 1; case .gaussian: return 0; case .pseudoVoigt: return mix } }
}
enum NMRFitStatus: String, Codable { case ok, caution, failed
    var label: String { switch self { case .ok: return "收敛"; case .caution: return "慎用"; case .failed: return "失败" } }
}
private let nmrLn2 = log(2.0)
private func nmrBasis(_ u: Double, _ eta: Double) -> (f: Double, du: Double) {
    let q = 4*u*u, l = 1/(1+q), g = exp(-nmrLn2*q)
    return (eta*l + (1-eta)*g, -8*u*(eta*l*l + (1-eta)*nmrLn2*g))
}
struct NMRComponent: Codable {
    let shape: NMRShape
    let centerPPM: Double
    let heightRaw: Double // above fitted background
    let fwhmPPM: Double // common FWHM of both terms in a pseudo-Voigt
    let lorentzHWHMPPM: Double?
    let gaussianSigmaPPM: Double?
    let lorentzFraction: Double
    let fullModelAreaRawPPM: Double // infinite-domain component only, NOT a measured integral
    func value(atPPM x: Double) -> Double { heightRaw * nmrBasis((x-centerPPM)/fwhmPPM, lorentzFraction).f }
}
struct NMRCurveSample: Codable { let ppm: Double; let observedRaw: Double; let backgroundRaw: Double; let fittedRaw: Double; let residualRaw: Double }
struct NMRFit: Codable {
    let traceKey: String; let windowPPM: NMRBand; let seedPPM: [Double]; let shape: NMRShape; let lorentzFraction: Double; let sampleCount: Int
    var status: NMRFitStatus = .failed
    var flags: [String] = []
    var iterations = 0, componentCount = 0
    var components: [NMRComponent] = []; var curve: [NMRCurveSample] = []
    var backgroundAtMidRaw: Double?; var slopeRawPerPPM: Double?
    var weightedRMSRaw: Double?; var rmsOverRange: Double?; var maxAbsResidualRaw: Double?
}

enum NMRPattern: String, Codable { case d, t, q }
struct NMRLineReadout: Codable {
    let traceKey: String; let windowPPM: NMRBand; let markedPPM: [Double]
    let apparentMidPPM: Double // midpoint of outer marks, not a chemical assignment
    let observeMHz: Double?; let frequencySource: String; let testFirstOrder: Bool
    var spacingTolerance = 0.05, heightTolerance = 0.22, widthRatioLimit = 1.35
    var twoMarkSpacingPPM: Double?; var twoMarkSpacingHz: Double?
    var meanStepPPM: Double?; var maxRelativeStepError: Double?; var maxRelativeHeightError: Double?
    var apparentFWHMPPM: [Double] = []; var noiseEstimateRaw: Double?
    var resolved = false; var compatiblePattern: NMRPattern?; var inferredJHz: Double?
    var flags: [String] = []
}

struct NMRAnalysisRecord: Codable {
    var version = 1
    var cropOriginalPPM: NMRBand?; var displayGain: Double?; var manualMHz: Double?
    var seedsOriginalPPM: [Double] = []; var marksOriginalPPM: [Double] = []
    var shape: NMRShape = .lorentzian; var mix = 0.5
    var integrals: [NMRAreaEvidence] = []; var fit: NMRFit?; var lines: NMRLineReadout?
    init() {}
    enum CodingKeys: String, CodingKey { case version, cropOriginalPPM, displayGain, manualMHz, seedsOriginalPPM, marksOriginalPPM, shape, mix, integrals, fit, lines }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decodeIfPresent(Int.self, forKey: .version) ?? 1
        guard version == 1 else { throw NMRAnalysisError.message("不支持的区域记录版本") }
        cropOriginalPPM = try c.decodeIfPresent(NMRBand.self, forKey: .cropOriginalPPM); displayGain = try c.decodeIfPresent(Double.self, forKey: .displayGain); manualMHz = try c.decodeIfPresent(Double.self, forKey: .manualMHz)
        seedsOriginalPPM = try c.decodeIfPresent([Double].self, forKey: .seedsOriginalPPM) ?? []; marksOriginalPPM = try c.decodeIfPresent([Double].self, forKey: .marksOriginalPPM) ?? []
        shape = try c.decodeIfPresent(NMRShape.self, forKey: .shape) ?? .lorentzian; mix = try c.decodeIfPresent(Double.self, forKey: .mix) ?? 0.5
        integrals = try c.decodeIfPresent([NMRAreaEvidence].self, forKey: .integrals) ?? []; fit = try c.decodeIfPresent(NMRFit.self, forKey: .fit); lines = try c.decodeIfPresent(NMRLineReadout.self, forKey: .lines)
    }
}

enum NMRAnalysis {
    static func band(_ t: NMRTrace, _ r: NMRAnalysisRecord, _ p: NMRAnalysisPorts) throws -> NMRBand {
        let w = r.cropOriginalPPM?.mapped(p.fromOriginalPPM) ?? t.domain
        _ = try t.indices(in: w); return w
    }
    static func integrate(_ t: NMRTrace, in w: NMRBand, referenceTarget: Double?, ports p: NMRAnalysisPorts) throws -> NMRAreaEvidence {
        _ = try t.indices(in: w); let original = w.mapped(p.toOriginalPPM)
        guard original.valid else { throw NMRAnalysisError.message("原轴边界无效") }
        let raw = try p.rawSignedArea(w); guard raw.isFinite else { throw NMRAnalysisError.message("积分无效") }
        let relative: NMRRelativeArea?
        if let target = referenceTarget {
            let ref = NMRIntegralReference(originalPPM: original, rawSignedArea: raw, target: target)
            guard ref.valid else { throw NMRAnalysisError.message("参考面积不能为零，参考值须为正") }; relative = NMRRelativeArea(reference: ref, value: target)
        } else { relative = try p.relativeToPriorReference(raw) }
        if let v = relative, !(v.reference.valid && v.value.isFinite) { throw NMRAnalysisError.message("参考记录无效") }
        let e = NMRAreaEvidence(traceKey: t.key, calibratedPPM: w, originalPPM: original, rawSignedArea: raw, relative: relative, setsReference: referenceTarget != nil)
        try p.commitMark(e); return e
    }
    private static func nearest(_ xs: [Double], _ v: Double) -> Int {
        var a = 0, b = xs.count-1
        while a < b { let m = a+(b-a)/2; if xs[m] < v { a = m+1 } else { b = m } }
        return a > 0 && abs(xs[a-1]-v) <= abs(xs[a]-v) ? a-1 : a
    }
    private static func clip(_ x: Double, _ lo: Double, _ hi: Double) -> Double { min(hi, max(lo, x)) }
    // Solve a column-scaled damped normal system on free variables by Cholesky.
    // h stores the lower triangle; a small undamped pivot also serves as a conditioning warning.
    private static func step(_ h: [Double], _ g: [Double], _ d: [Double], _ free: [Int], _ lambda: Double) -> [Double]? {
        let m = g.count, n = free.count; var l = [Double](repeating: 0, count: n*n), z = [Double](repeating: 0, count: n)
        for i in 0..<n {
            let a = free[i]; z[i] = g[a]/d[a]
            for j in 0...i {
                let b = free[j]; var v = h[a*m+b]/(d[a]*d[b]) + (i == j ? lambda : 0)
                for k in 0..<j { v -= l[i*n+k]*l[j*n+k] }
                if i == j { guard v.isFinite, v > 1e-9 else { return nil }; l[i*n+j] = sqrt(v) }
                else { l[i*n+j] = v/l[j*n+j] }
            }
            for k in 0..<i { z[i] -= l[i*n+k]*z[k] }; z[i] /= l[i*n+i]
        }
        var delta = [Double](repeating: 0, count: m)
        for i in (0..<n).reversed() {
            for k in (i+1)..<n { z[i] -= l[k*n+i]*z[k] }; z[i] /= l[i*n+i]; delta[free[i]] = z[i]/d[free[i]]
        }; return delta.allSatisfy({ $0.isFinite }) ? delta : nil
    }

    // Bounded projected Levenberg-Marquardt, analytical Jacobian, local affine background.
    // No interpolation, zero filling, FFT assumption or changes to trace. WLS weights are
    // abscissa-cell lengths (a spatial L2 objective, not inverse-variance weights).
    static func fit(_ trace: NMRTrace, in w: NMRBand, seeds: [Double], shape: NMRShape, mix: Double = 0.5) throws -> NMRFit {
        let r = try trace.indices(in: w), n = r.count
        guard (1...6).contains(seeds.count), seeds.allSatisfy({ $0.isFinite && w.contains($0) }), mix.isFinite, (0...1).contains(mix) else { throw NMRAnalysisError.message("区内需 1–6 个有限初值，混合比例须为 0–1") }
        let ss = seeds.sorted(), eta = shape.fraction(mix), k = ss.count, m = 2+3*k
        let empty = NMRFit(traceKey: trace.key, windowPPM: w, seedPPM: ss, shape: shape, lorentzFraction: eta, sampleCount: n)
        var out = empty
        func fail(_ text: String) -> NMRFit { var f = empty; f.iterations = out.iterations; f.flags = [text]; return f }
        guard n <= 2048 else { return fail("超过 2048 点，请缩小拟合窗") }; guard n >= 2*m+3 else { return fail("独立采样点不足") }
        let xs = r.map { trace.x($0) }, raw = r.map { trace.y($0) }, t = xs.map { ($0-w.mid)/w.width }
        guard let low = raw.min(), let high = raw.max() else { return fail("无数据") }
        let scale = high-low, anchor = low+scale/2
        guard scale.isFinite, scale > 0, anchor.isFinite else { return fail("强度无变化或超范围") }
        let y = raw.map { ($0-anchor)/scale }, tw = t[n-1]-t[0]; guard tw > 0 else { return fail("窗内谱宽不足") }
        var wt = [Double](repeating: 0, count: n)
        for i in 0..<n {
            if i > 0 && t[i] <= t[i-1] { return fail("谱轴数值分辨率不足") }
            wt[i] = (t[min(i+1,n-1)]-t[max(i-1,0)])/(2*tw)
        }
        let slope = (y[n-1]-y[0])/tw, intercept = y[0]-slope*t[0]
        let net = t.indices.map { y[$0]-intercept-slope*t[$0] }
        guard net.max() ?? 0 > 1e-7 else { return fail("未见正向吸收线") }
        var p = [intercept, slope], lb = [-Double.infinity, -Double.infinity], ub = [Double.infinity, Double.infinity]
        let centers = ss.map { ($0-w.mid)/w.width }
        for i in 0..<k {
            let c = centers[i], j = nearest(t,c); guard j > 0, j < n-1 else { return fail("初值过近窗边") }
            let mesh = max(t[j]-t[j-1], t[j+1]-t[j]), minW = max(2*mesh, 1e-7)
            if i > 0 && c-centers[i-1] <= mesh { return fail("初值重合或过近") }
            let a = max(max(t[0], c-0.15), i > 0 ? (centers[i-1]+c)/2 : t[0])
            let b = min(min(t[n-1], c+0.15), i+1 < k ? (centers[i+1]+c)/2 : t[n-1])
            guard a < c, c < b, minW < 0.8 else { return fail("初值附近采样不足") }
            let h = clip(net[j], 0.025, 2); var left = j, right = j
            while left > 0 && net[left] > h/2 { left -= 1 }; while right < n-1 && net[right] > h/2 { right += 1 }
            var width = t[right]-t[left]; if i > 0 { width = min(width, 1.2*(c-centers[i-1])) }; if i+1 < k { width = min(width, 1.2*(centers[i+1]-c)) }
            p += [h, c, log(clip(width, minW, 0.8))]; lb += [1e-8, a, log(minW)]; ub += [4, b, 0] // max width = window width
        }
        func evaluate(_ v: [Double], derivatives: Bool) -> (cost: Double, h: [Double], g: [Double]) {
            var h = [Double](repeating: 0, count: derivatives ? m*m : 0), g = [Double](repeating: 0, count: derivatives ? m : 0), jac = [Double](repeating: 0, count: m)
            let widths = (0..<k).map { exp(v[4+3*$0]) }; var cost = 0.0; jac[0] = 1
            for i in 0..<n {
                var pred = v[0]+v[1]*t[i]; jac[1] = t[i]
                for s in 0..<k {
                    let j = 2+3*s, u = (t[i]-v[j+1])/widths[s], b = nmrBasis(u,eta); pred += v[j]*b.f
                    if derivatives { jac[j] = b.f; jac[j+1] = -v[j]*b.du/widths[s]; jac[j+2] = -v[j]*b.du*u }
                }
                let e = y[i]-pred; cost += wt[i]*e*e
                if derivatives { for a in 0..<m { let d = jac[a]*wt[i]; g[a] += d*e; for b in 0...a { h[a*m+b] += d*jac[b] } } }
            }; return (cost,h,g)
        }
        var lambda = 0.001, converged = false
        for iter in 1...80 {
            out.iterations = iter
            let e = evaluate(p, derivatives: true), d = (0..<m).map { sqrt(max(e.h[$0*m+$0], 1e-18)) }
            guard e.cost.isFinite, e.g.allSatisfy({ $0.isFinite }) else { return fail("数值超范围") }
            let free = (0..<m).filter { !((p[$0] <= lb[$0] && e.g[$0] < 0) || (p[$0] >= ub[$0] && e.g[$0] > 0)) }
            let grad = free.reduce(0.0) { max($0, abs(e.g[$1]/d[$1])) }
            if grad < 1e-9 || e.cost < 1e-20 { converged = true; break }
            if let dv = step(e.h,e.g,d,free,lambda) {
                let v = (0..<m).map { clip(p[$0]+dv[$0],lb[$0],ub[$0]) }; let trial = evaluate(v, derivatives: false).cost
                if trial.isFinite && trial < e.cost {
                    let change = (0..<m).reduce(0.0) { max($0, abs(v[$1]-p[$1])) }; p = v
                    if lambda <= 1 && change < 1e-6 && e.cost-trial < 1e-10*max(e.cost,1e-12) { converged = true; break }
                    lambda = max(1e-10, lambda*0.3); continue
                }
            }
            lambda *= 8; if lambda > 1e12 { break }
        }
        guard converged else { return fail("未收敛；调整初值或拟合窗") }
        let e = evaluate(p, derivatives: true), rel = sqrt(e.cost), rms = scale*rel, base = anchor+scale*p[0], tilt = scale*p[1]/w.width
        guard rms.isFinite, base.isFinite, tilt.isFinite else { return fail("拟合参数超范围") }
        out.backgroundAtMidRaw = base; out.slopeRawPerPPM = tilt; out.rmsOverRange = rel; out.weightedRMSRaw = rms
        func warn(_ s: String) { if !out.flags.contains(s) { out.flags.append(s) } }
        if rel > 0.06 { warn("残差偏大") }
        let diag = (0..<m).map { sqrt(max(e.h[$0*m+$0],1e-18)) }; if step(e.h,e.g,diag,Array(0..<m),0) == nil { warn("参数近共线") }
        for s in 0..<k {
            let j = 2+3*s, height = scale*p[j], c = w.mid+w.width*p[j+1], width = w.width*exp(p[j+2])
            let area = height*width*(eta*Double.pi/2 + (1-eta)*sqrt(Double.pi)/(2*sqrt(nmrLn2)))
            guard height.isFinite, height > 0, width.isFinite, width > 0, c.isFinite, area.isFinite else { return fail("组分参数超范围") }
            for a in j..<(j+3) where min(p[a]-lb[a],ub[a]-p[a]) < 1e-5 { warn("参数触界") }
            if height < 4*rms || p[j] < 1e-5 { warn("弱组分") }; if min(c-xs[0],xs[n-1]-c) < width { warn("窗边截线") }
            if xs.filter({ abs($0-c) <= width/2 }).count < 4 { warn("半高宽内采样少") }
            if let prev = out.components.last, c-prev.centerPPM < 0.9*(width+prev.fwhmPPM)/2 { warn("组分重叠，分解可能不唯一") }
            out.components.append(NMRComponent(shape: shape, centerPPM: c, heightRaw: height, fwhmPPM: width, lorentzHWHMPPM: eta > 0 ? width/2 : nil, gaussianSigmaPPM: eta < 1 ? width/sqrt(8*nmrLn2) : nil, lorentzFraction: eta, fullModelAreaRawPPM: area))
        }
        var worst = 0.0
        for i in 0..<n {
            let bg = base+tilt*(xs[i]-w.mid), fitted = out.components.reduce(bg) { $0+$1.value(atPPM: xs[i]) }, residual = raw[i]-fitted
            guard bg.isFinite, fitted.isFinite, residual.isFinite else { return fail("曲线超范围") }
            worst = max(worst, abs(residual)); out.curve.append(NMRCurveSample(ppm: xs[i], observedRaw: raw[i], backgroundRaw: bg, fittedRaw: fitted, residualRaw: residual))
        }
        out.maxAbsResidualRaw = worst; out.componentCount = out.components.count; out.status = out.flags.isEmpty ? .ok : .caution; return out
    }

    // Positions are marks on the calibrated spectrum, NOT fitted components. Do not move them
    // to make their spacings agree. Examine neighboring samples only to check the evidence.
    static func readLines(_ trace: NMRTrace, in w: NMRBand, marks: [Double], manualMHz: Double? = nil, testFirstOrder: Bool = false) throws -> NMRLineReadout {
        let r = try trace.indices(in: w)
        guard (1...64).contains(marks.count), marks.allSatisfy({ $0.isFinite && w.contains($0) }), Set(marks).count == marks.count else { throw NMRAnalysisError.message("区内需 1–64 个不同标记") }
        let f = manualMHz ?? trace.observeMHz; if let mhz = f, !(mhz.isFinite && mhz > 0) { throw NMRAnalysisError.message("请核对本核观测频率") }
        let s = marks.sorted(), k = s.count, span = s[k-1]-s[0]
        var o = NMRLineReadout(traceKey: trace.key, windowPPM: w, markedPPM: s, apparentMidPPM: s[0]+span/2, observeMHz: f, frequencySource: manualMHz != nil ? "manual" : (f == nil ? "missing" : "metadata"), testFirstOrder: testFirstOrder)
        func hz(_ ppm: Double) throws -> Double? { guard let mhz = f else { return nil }; let v = ppm*mhz; guard v.isFinite else { throw NMRAnalysisError.message("频差超范围") }; return v }
        if f == nil { o.flags.append("缺本核频率，仅报 ppm") }
        if k == 2 { o.twoMarkSpacingPPM = span; o.twoMarkSpacingHz = try hz(span) }
        func stop(_ flag: String) -> NMRLineReadout { var copy = o; copy.flags.append(flag); return copy }
        guard k <= 4 else { return stop("复杂线组，仅报表观中心") }; guard r.count >= 9, r.count <= 8192 else { return stop("请选含 9–8192 点的局部窗") }
        let x = r.map { trace.x($0) }, y = r.map { trace.y($0) }, n = r.count, range = y.max()! - y.min()!
        guard range.isFinite, range > 0 else { return stop("未见线形") }
        // Endpoint chord removed for diagnostics only. Normalize for dimensionless thresholds.
        let edge = (y[n-1]-y[0])/range
        let z: [Double] = x.indices.map { (y[$0]-y[0])/range - edge*((x[$0]-x[0])/(x[n-1]-x[0])) }
        let dif = (1..<n).map { abs(z[$0]-z[$0-1]) }.sorted(), noise = max(1e-12,dif[dif.count/2]/0.953872)
        if (noise*range).isFinite { o.noiseEstimateRaw = noise*range }
        func isTop(_ j: Int) -> Bool { j > 0 && j < n-1 && z[j] > z[j-1] && z[j] >= z[j+1] }
        var tops: [Int] = []
        for mark in s {
            let j = nearest(x,mark), a = max(1,j-1), b = min(n-2,j+1)
            guard a <= b, let q = (a...b).filter({ isTop($0) }).max(by: { z[$0] < z[$1] }), z[q] > 6*noise,
                  abs(x[q]-mark) <= 1.5*max(x[q]-x[q-1],x[q+1]-x[q]), q > (tops.last ?? -1) else { return stop("标记未对应独立、足够强的极大值") }; tops.append(q)
        }
        for j in 1..<k {
            let a = tops[j-1], b = tops[j], h = min(z[a],z[b]), valley = z[a...b].min()!
            guard b-a >= 4, h-valley > 3*noise, valley <= 0.6*h else { return stop("线谷不足以证实分辨") }
            for i in (a+1)...b where x[i]-x[i-1] > (x[b]-x[a])/4 { return stop("线间采样过疏") }
        }
        o.resolved = k > 1
        var symmetric = true
        for q in tops {
            let h = z[q]/2; var a = q, b = q
            while a > 0 && z[a] > h { a -= 1 }; while b < n-1 && z[b] > h { b += 1 }
            guard a < q, b > q, z[a] <= h, z[b] <= h, b-a >= 4 else { return stop("半高宽证据不足") }
            let left = x[a]+(x[a+1]-x[a])*((h-z[a])/(z[a+1]-z[a])), right = x[b-1]+(x[b]-x[b-1])*((z[b-1]-h)/(z[b-1]-z[b]))
            let l = x[q]-left, u = right-x[q]; guard l > 0, u > 0 else { return stop("半高宽无效") }
            o.apparentFWHMPPM.append(right-left); if max(l,u)/min(l,u) > 1.5 { symmetric = false }
        }
        guard k >= 2 else { return stop("单标记，仅报表观峰形") }
        let mean = span/Double(k-1); guard mean > 0 else { return stop("间距无效") }; o.meanStepPPM = mean
        let err = (1..<k).map { abs((s[$0]-s[$0-1])/mean-1) }.max()!; o.maxRelativeStepError = err
        guard testFirstOrder else { return stop("未作一阶检验；间距不等于归属") }
        guard err <= o.spacingTolerance else { return stop("相邻间距不等") }
        let widths = o.apparentFWHMPPM; guard symmetric, widths.max()!/widths.min()! <= o.widthRatioLimit, widths.max()! <= 0.75*mean else { return stop("峰形不对称、展宽或重叠") }
        let heights = tops.map { z[$0] }, expected: [Double] = k == 2 ? [1,1] : (k == 3 ? [1,2,1] : [1,3,3,1])
        let es = expected.reduce(0,+), hs = heights.reduce(0,+); let herr = (0..<k).map { abs((heights[$0]/hs)/(expected[$0]/es)-1) }.max()!; o.maxRelativeHeightError = herr
        guard herr <= o.heightTolerance else { return stop("线强不符二项比例") }
        let threshold = max(6*noise,0.15*heights.min()!)
        for i in 1..<(n-1) where isTop(i) && z[i] > threshold && !tops.contains(where: { abs($0-i) <= 1 }) { return stop("窗内有额外极大值") }
        o.compatiblePattern = k == 2 ? .d : (k == 3 ? .t : .q); o.inferredJHz = try hz(mean); o.flags.append("仅与孤立一阶线组相容，非归属"); return o
    }
}

// Separate, long-form evidence CSV. Numeric strings use Swift's locale-independent representation.
extension NMRAnalysisRecord {
    func analysisCSV(currentKey: String) -> String {
        var rows = ["section,item,quantity,unit,value,flags,trace_key"]
        func quote(_ s: String) -> String { "\"" + s.replacingOccurrences(of: "\"", with: "\"\"") + "\"" }
        func row(_ section: String, _ i: Int, _ name: String, _ unit: String, _ value: String, _ flags: String, _ key: String) { rows.append([section,String(i),name,unit,value,flags,key].map(quote).joined(separator: ",")) }
        func bounds(_ b: NMRBand, _ section: String, _ i: Int, _ axis: String, _ flag: String, _ key: String) { row(section,i,axis+"_lo","ppm",String(b.lo),flag,key); row(section,i,axis+"_hi","ppm",String(b.hi),flag,key) }
        row("settings",0,"display_gain","1",String(displayGain ?? 1),"display_only",currentKey)
        row("settings",0,"crop","1",cropOriginalPPM == nil ? "full" : "window","original_axis",currentKey)
        if let b = cropOriginalPPM { bounds(b,"settings",0,"original","crop",currentKey) }; if let f = manualMHz { row("settings",0,"manual_frequency","MHz",String(f),"override",currentKey) }
        for (i,v) in seedsOriginalPPM.enumerated() { row("seed",i,"original_position","ppm",String(v),"user",currentKey) }; for (i,v) in marksOriginalPPM.enumerated() { row("mark",i,"original_position","ppm",String(v),"user",currentKey) }
        for (i,a) in integrals.enumerated() {
            let flag = a.setsReference ? "sets_reference" : (a.relative == nil ? "no_reference" : "prior_reference"), key = a.traceKey
            bounds(a.originalPPM,"integral",i,"original",flag,key); bounds(a.calibratedPPM,"integral",i,"calibrated",flag,key)
            row("integral",i,"signed_area","raw*ppm",String(a.rawSignedArea),flag,key)
            if let v = a.relative { let r = v.reference; bounds(r.originalPPM,"integral",i,"ref_original",flag,key); row("integral",i,"ref_area","raw*ppm",String(r.rawSignedArea),flag,key); row("integral",i,"ref_target","relative",String(r.target),flag,key); row("integral",i,"relative_area","relative",String(v.value),flag,key) }
        }
        if let f = fit {
            let fl = ([f.status.rawValue] + f.flags).joined(separator: ";"), key = f.traceKey
            func num(_ name: String, _ unit: String, _ v: Double?) { if let a = v { row("fit",0,name,unit,String(a),fl,key) } }
            bounds(f.windowPPM,"fit",0,"calibrated",fl,key); row("fit",0,"shape","1",f.shape.rawValue,fl,key); num("eta_L","1",f.lorentzFraction)
            row("fit",0,"component_count","count",String(f.componentCount),fl,key); row("fit",0,"iterations","count",String(f.iterations),fl,key); row("fit",0,"samples","count",String(f.sampleCount),fl,key)
            for (i,v) in f.seedPPM.enumerated() { row("fit_seed",i,"center","ppm",String(v),fl,key) }
            num("background_at_window_mid","raw",f.backgroundAtMidRaw); num("slope","raw/ppm",f.slopeRawPerPPM); num("weighted_rms","raw",f.weightedRMSRaw); num("rms_over_range","1",f.rmsOverRange); num("max_abs_residual","raw",f.maxAbsResidualRaw)
            for (i,c) in f.components.enumerated() {
                func cv(_ name: String, _ unit: String, _ v: Double?) { if let a = v { row("component",i,name,unit,String(a),fl,key) } }
                cv("center","ppm",c.centerPPM); cv("height","raw",c.heightRaw); cv("fwhm","ppm",c.fwhmPPM); cv("lorentz_hwhm","ppm",c.lorentzHWHMPPM); cv("gauss_sigma","ppm",c.gaussianSigmaPPM); cv("eta_L","1",c.lorentzFraction); cv("full_model_area","raw*ppm",c.fullModelAreaRawPPM)
            }
            for (i,p) in f.curve.enumerated() { row("curve",i,"x","ppm",String(p.ppm),fl,key); row("curve",i,"observed","raw",String(p.observedRaw),fl,key); row("curve",i,"background","raw",String(p.backgroundRaw),fl,key); row("curve",i,"fitted","raw",String(p.fittedRaw),fl,key); row("curve",i,"observed_minus_fitted","raw",String(p.residualRaw),fl,key) }
        }
        if let l = lines {
            let fl = ([l.frequencySource,l.resolved ? "resolved" : "not_verified",l.testFirstOrder ? "first_order_test" : "marks_only"]+l.flags).joined(separator: ";"), key = l.traceKey
            func ln(_ name: String, _ unit: String, _ v: Double?) { if let a = v { row("lines",0,name,unit,String(a),fl,key) } }
            bounds(l.windowPPM,"lines",0,"calibrated",fl,key); ln("apparent_mid","ppm",l.apparentMidPPM); ln("frequency","MHz",l.observeMHz); ln("two_mark_spacing","ppm",l.twoMarkSpacingPPM); ln("two_mark_spacing","Hz",l.twoMarkSpacingHz); ln("mean_step","ppm",l.meanStepPPM); ln("inferred_J","Hz",l.inferredJHz)
            ln("step_tolerance","1",l.spacingTolerance); ln("height_tolerance","1",l.heightTolerance); ln("width_ratio_limit","1",l.widthRatioLimit); ln("step_error","1",l.maxRelativeStepError); ln("height_error","1",l.maxRelativeHeightError); ln("noise_estimate","raw",l.noiseEstimateRaw)
            if let p = l.compatiblePattern { row("lines",0,"compatible_pattern","1",p.rawValue,fl,key) }; for (i,v) in l.markedPPM.enumerated() { row("line_mark",i,"calibrated_position","ppm",String(v),fl,key) }; for (i,v) in l.apparentFWHMPPM.enumerated() { row("line_mark",i,"apparent_fwhm","ppm",String(v),fl,key) }
        }
        return rows.joined(separator: "\r\n") + "\r\n"
    }
}
