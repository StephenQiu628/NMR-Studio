import Foundation

// Add these files to the same target. All ppm in the model are ORIGINAL ppm.
struct NMRProblem: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

private func requireNMR(_ ok: Bool, _ message: String) throws {
    if !ok { throw NMRProblem(message) }
}

private func median(_ values: [Double]) -> Double {
    if values.isEmpty { return 0 }
    let a = values.sorted(), k = a.count / 2
    return a.count % 2 == 1 ? a[k] : 0.5 * a[k-1] + 0.5 * a[k]
}

struct NMRSpan: Codable, Equatable {
    let low: Double
    let high: Double
    init(_ a: Double, _ b: Double) { low = min(a,b); high = max(a,b) }
    var width: Double { high - low }
    var valid: Bool { low.isFinite && high.isFinite && width.isFinite && low <= high }
    func contains(_ v: Double) -> Bool { v >= low && v <= high }
    func meets(_ other: Self) -> Bool { max(low,other.low) <= min(high,other.high) }
}

struct NMRRawBox: Codable, Equatable {
    let ppm: NMRSpan
    let intensity: NMRSpan
    var valid: Bool { ppm.valid && intensity.valid && ppm.width > 0 && intensity.width > 0 }
    func contains(_ x: Double, _ y: Double) -> Bool { ppm.contains(x) && intensity.contains(y) }
    func meets(_ b: Self) -> Bool { ppm.meets(b.ppm) && intensity.meets(b.intensity) }
}

enum NMRChemicalShift: Codable, Equatable {
    case point(Double)
    case range(NMRSpan)
    var valid: Bool {
        switch self { case .point(let x): return x.isFinite
        case .range(let r): return r.valid && r.width > 0 }
    }
    func shifted(by d: Double) -> Self {
        switch self { case .point(let x): return .point(x+d)
        case .range(let r): return .range(NMRSpan(r.low+d,r.high+d)) }
    }
}

enum NativeNMRPeakMultiplicity: String, Codable, CaseIterable {
    case s, d, t, q, m, dd
    // dd is manual only. An empty array always means no J reported.
    func permits(_ count: Int) -> Bool {
        switch self { case .s, .m: return count == 0
        case .dd: return (0...2).contains(count)
        default: return (0...1).contains(count) }
    }
}

struct NMREstimate: Codable, Equatable {
    let value: Double
    let uncertainty: Double // resolution/noise allowance; NOT a statistical confidence interval
    func scaled(_ factor: Double) -> Self { Self(value: value*factor, uncertainty: uncertainty*abs(factor)) }
}

struct NMRPickSettings: Codable, Equatable {
    var noiseFloor: Double = 0 // optional lower bound on sigma in phased-real units
    var minSNR: Double = 8
}

struct NMRAnalysisStamp: Codable, Equatable {
    let algorithm: Int
    let spectrumID: String
    let shapeRevision: String
    let gridAndRealCheck: String
    let nucleus: String
    let observedMHz: Double?
    let settings: NMRPickSettings
}

struct NMRSpectrum1D {
    let ppm: [Double]
    let real: [Double]
    let stamp: NMRAnalysisStamp
    fileprivate let sigmaFloor: Double
    var estimatedNoise: Double { sigmaFloor }

    init(spectrumID: String, shapeRevision: String, nucleus: String, observedMHz: Double?, originPPM: [Double], phasedReal: [Double], settings: NMRPickSettings = .init()) throws {
        try requireNMR(!spectrumID.isEmpty && !shapeRevision.isEmpty && !nucleus.isEmpty, "Missing acquisition identity, shape revision or nucleus")
        if let f = observedMHz { try requireNMR(f.isFinite && f > 0, "Use nil for unknown observed MHz") }
        try requireNMR(settings.minSNR.isFinite && settings.minSNR >= 6 && settings.noiseFloor.isFinite && settings.noiseFloor >= 0, "Invalid picker settings")
        let n = originPPM.count
        try requireNMR(n >= 7 && n == phasedReal.count, "Invalid 1D array lengths")
        var diffs = [Double](), scale = 0.0, check: UInt64 = 0xcbf29ce484222325
        diffs.reserveCapacity(n-1)
        for i in 0..<n {
            let x = originPPM[i], y = phasedReal[i]
            try requireNMR(x.isFinite && y.isFinite, "Nonfinite spectrum")
            check = (check ^ x.bitPattern) &* 1099511628211
            check = (check ^ y.bitPattern) &* 1099511628211
            scale = max(scale,abs(y))
            if i > 0 {
                try requireNMR(originPPM[i-1] > x && (y-phasedReal[i-1]).isFinite, "Expected strictly descending ppm and finite differences")
                diffs.append(y-phasedReal[i-1])
            }
        }
        try requireNMR((originPPM[0]-originPPM[n-1]).isFinite, "Invalid spectral span")
        let center = median(diffs)
        let noise = median(diffs.map { abs($0-center) }) / (0.67448975 * sqrt(2.0))
        sigmaFloor = max(settings.noiseFloor,noise,scale*1e-12,Double.leastNormalMagnitude)
        ppm = originPPM; real = phasedReal
        stamp = NMRAnalysisStamp(algorithm: 1, spectrumID: spectrumID, shapeRevision: shapeRevision, gridAndRealCheck: String(check,radix:16), nucleus: nucleus, observedMHz: observedMHz, settings: settings)
    }

    // First x <= value, or first x < value when strict. May return endIndex.
    fileprivate func bound(_ value: Double, strict: Bool) -> Int {
        var l = 0, r = ppm.count
        while l < r { let m = l + (r-l)/2
            if ppm[m] > value || (strict && ppm[m] == value) { l = m+1 } else { r = m }
        }
        return l
    }
}

enum NMRLineShape: String, Codable { case nearSymmetric, asymmetric, indeterminate }

struct NativeNMRPeakComponent: Codable, Equatable {
    let sample: Int // locator only within this shape/grid; not an integral ID
    let ppm: Double
    let positionErrorPPM: Double
    let intensity: Double // signed raw interpolated ordinate, NOT height above baseline
    let baseline: Double
    let stepPPM: Double
    let snr: Double
    let lowHalfPPM: Double?
    let highHalfPPM: Double?
    let apparentFWHM: NMREstimate? // ppm
    let halfWidthRatio: Double? // larger / smaller
    let shape: NMRLineShape
    var signedHeight: Double { intensity - baseline }
}

struct NMRPeakAnalysis: Codable, Equatable {
    let id: UUID
    let stamp: NMRAnalysisStamp
    let noiseScale: Double
    let components: [NativeNMRPeakComponent] // ascending original ppm
    let envelope: NMRSpan // outer measured half-height limits; apex on a side with no crossing
    let midExtremaPPM: NMREstimate
    let adjacentPPM: [NMREstimate]
    let gapOverMean: [Double]
    let reviewReasons: [String]
    let suggestedShift: NMRChemicalShift
    let suggestedMultiplicity: NativeNMRPeakMultiplicity
    let computedJsHz: [NMREstimate]
}

enum NMRBoxAnalyzer {
    private struct Side {
        var low: Double
        var half: Double? = nil
        var error = 0.0
    }

    static func analyze(_ box: NMRRawBox, clipped: Bool, trace t: NMRSpectrum1D) throws -> NMRPeakAnalysis {
        try requireNMR(box.valid, "Empty or nonfinite raw box")
        let x = t.ppm, y = t.real, n = x.count
        let start = t.bound(box.ppm.high,strict:false), end = t.bound(box.ppm.low,strict:true)
        try requireNMR(start < end, "No spectral samples in box")
        var reasons = Set<String>()
        if clipped { reasons.insert("Drag truncated at plot boundary") }
        // Independent flanks, NOT samples selected by the ordinate gate. A missing
        // anchor permits inspection but never a first-order claim.
        let lEnd = max(0,start-8), rStart = min(n,end+8)
        let lb = max(0,lEnd-32)..<lEnd, rb = rStart..<min(n,rStart+32)
        func anchor(_ band: Range<Int>) -> (x: Double, y: Double)? {
            guard band.count >= 8 else { return nil }
            return (0.5*x[band.lowerBound]+0.5*x[band.upperBound-1],median(Array(y[band])))
        }
        let la = anchor(lb), ra = anchor(rb)
        if la == nil || ra == nil { reasons.insert("Incomplete baseline flanks / data edge") }
        let fallback = la?.y ?? ra?.y ?? median(y)
        func base(_ u: Double) -> Double {
            guard let a = la, let b = ra else { return fallback }
            let f = max(0,min(1,(u-a.x)/(b.x-a.x)))
            return (1-f)*a.y + f*b.y
        }
        let deviations = (Array(lb)+Array(rb)).map { abs(y[$0]-base(x[$0])) }
        let sigma = max(t.sigmaFloor,1.4826*median(deviations))
        let extra = max(48,end-start), lo = max(0,start-extra), hi = min(n-1,end-1+extra)
        // Walk the original trace, not a y-masked trace. Stop at a material
        // turnaround so a half-height crossing cannot jump across another line.
        func side(_ dir: Int, _ i: Int, _ px: Double, _ h: Double, _ sign: Double) -> Side {
            var out = Side(low:h), prevX = px, prevH = h, j = i
            if (dir < 0 && x[j] <= px) || (dir > 0 && x[j] >= px) { j += dir }
            while j >= lo && j <= hi {
                let v = sign*(y[j]-base(x[j]))
                if v-out.low > max(4*sigma,0.05*h) { break }
                if out.half == nil && v <= 0.5*h && prevH > 0.5*h {
                    let dx = x[j]-prevX, drop = prevH-v
                    out.half = prevX + dx*((prevH-0.5*h)/drop)
                    out.error = max(0.5*abs(dx),abs(dx)*(2*sigma/drop))
                }
                out.low = min(out.low,v)
                if v <= 0.22*h { break }
                prevX = x[j]; prevH = v; j += dir
            }
            return out
        }
        var picked = [NativeNMRPeakComponent](), context = [NativeNMRPeakComponent]()
        var index = max(1,lo)
        while index <= min(n-2,hi) {
            let i = index
            var j = i
            while j+1 < n && y[j+1] == y[i] { j += 1 }
            index = j+1
            guard j+1 < n else { break }
            let sign: Double
            if y[i] > y[i-1] && y[j] > y[j+1] { sign = 1 }
            else if y[i] < y[i-1] && y[j] < y[j+1] { sign = -1 }
            else { continue }
            if j-i >= 2 {
                if NMRSpan(x[j],x[i]).meets(box.ppm) && box.intensity.contains(y[i]) && sign*(y[i]-base(x[i])) >= t.stamp.settings.minSNR*sigma { reasons.insert("Flat/clipped extremum (not picked)") }
                continue
            }
            // Quadratic vertex on the actual, possibly nonuniform, grid. Two
            // equal top samples are supported; longer flat tops aren't localized.
            let xl = x[i-1]-x[i], xr = x[i+1]-x[i]
            let sl = (y[i-1]-y[i])/xl, sr = (y[i+1]-y[i])/xr
            let a = (sl-sr)/(xl-xr), b = sl-a*xl
            guard a.isFinite && b.isFinite && a*sign < 0 else { continue }
            let dx = -0.5*b/a
            guard dx >= xr && dx <= xl else { continue }
            let px = x[i]+dx, top = y[i]+dx*(b+a*dx), baseline = base(px)
            let h = sign*(top-baseline), step = max(xl,-xr)
            guard top.isFinite && h.isFinite && h >= t.stamp.settings.minSNR*sigma else { continue }
            let inside = box.contains(px,top)
            let left = side(-1,i,px,h,sign), right = side(1,i,px,h,sign)
            let prominence = min(h-left.low,h-right.low)
            guard prominence >= max(4.5*sigma,0.18*h) else {
                if inside && prominence >= max(3*sigma,0.08*h) { reasons.insert("Possible unresolved shoulder") }
                continue
            }
            let wing = min(sign*(y[i-1]-base(x[i-1])),sign*(y[j+1]-base(x[j+1])))
            guard wing >= 0.35*h else {
                if inside { reasons.insert("Impulse / undersampled wing (not picked)") }; continue
            }
            var width: NMREstimate?, ratio: Double?, shape = NMRLineShape.indeterminate
            let isolated = max(left.low,right.low) <= 0.28*h
            if let u = left.half, let v = right.half {
                let w = u-v, small = min(u-px,px-v)
                guard small > 0 && w >= 3.5*step else {
                    if inside { reasons.insert("Line narrower than sampling limit (not picked)") }; continue
                }
                let e = left.error + right.error, r = max(u-px,px-v)/small
                width = NMREstimate(value:w,uncertainty:e); ratio = r
                if isolated && e <= 0.35*w { shape = r <= 1.45 ? .nearSymmetric : .asymmetric }
            }
            let c = NativeNMRPeakComponent(sample:i, ppm:px, positionErrorPPM:max(0.5*step,(width?.value ?? (2*step))*(sigma/h)), intensity:top, baseline:baseline, stepPPM:step, snr:h/sigma, lowHalfPPM:right.half, highHalfPPM:left.half, apparentFWHM:width, halfWidthRatio:ratio, shape:shape)
            if inside {
                picked.append(c)
                if !isolated { reasons.insert("Shallow saddle or truncated wing") }
                if shape != .nearSymmetric { reasons.insert("Asymmetric or uncertain half-height profile") }
                if c.snr < 12 { reasons.insert("Low interpretation SNR") }
                if let u = left.half, !box.ppm.contains(u) { reasons.insert("Half-height interval crosses x edge") }
                if let v = right.half, !box.ppm.contains(v) { reasons.insert("Half-height interval crosses x edge") }
            } else { context.append(c) }
        }
        let p = picked.sorted { $0.ppm < $1.ppm }
        guard let first = p.first, let last = p.last else { throw NMRProblem("No supported signed extremum inside this 2D box; no group created") }
        let center = NMREstimate(value:0.5*first.ppm+0.5*last.ppm,uncertainty:0.5*(first.positionErrorPPM+last.positionErrorPPM))
        let env = NMRSpan(p.map { $0.lowHalfPPM ?? $0.ppm }.min()!,p.map { $0.highHalfPPM ?? $0.ppm }.max()!)
        let gaps = zip(p,p.dropFirst()).map { pair in NMREstimate(value:pair.1.ppm-pair.0.ppm,uncertainty:pair.1.positionErrorPPM+pair.0.positionErrorPPM) }
        let mean = gaps.isEmpty ? 0 : (last.ppm-first.ppm)/Double(gaps.count)
        if p.contains(where: { ($0.signedHeight > 0) != (first.signedHeight > 0) }) { reasons.insert("Mixed polarity") }
        let widths = p.compactMap { $0.apparentFWHM?.value }
        if let small = widths.min(), let large = widths.max(), large > 1.5*small { reasons.insert("Inconsistent component widths") }
        for (a,b) in zip(p,p.dropFirst()) {
            let w = max(a.apparentFWHM?.value ?? 0,b.apparentFWHM?.value ?? 0)
            if b.ppm-a.ppm < max(2*w,6*max(a.stepPPM,b.stepPPM)) { reasons.insert("Neighbors too close relative to FWHM or grid") }
            let sign = a.signedHeight > 0 ? 1.0 : -1.0
            var valley = Double.infinity
            for i in min(a.sample,b.sample)...max(a.sample,b.sample) { valley = min(valley,sign*(y[i]-base(x[i]))) }
            if valley > 0.28*min(abs(a.signedHeight),abs(b.signedHeight)) { reasons.insert("Interline valley not deep enough") }
        }
        if gaps.contains(where: { $0.uncertainty > 0.15*mean || abs($0.value-mean) > min(0.08*mean,max(0.035*mean,$0.uncertainty)) }) { reasons.insert("Uncertain or nonuniform adjacent spacings") }
        // Excluded extrema are context ONLY. In particular a distant opposite-
        // sign line at the same x zoom does not enter the component list.
        for z in context {
            let between = z.ppm >= first.ppm && z.ppm <= last.ppm
            let edge = z.ppm < first.ppm ? first : last
            let reach = max(2.5*max(edge.apparentFWHM?.value ?? 0,z.apparentFWHM?.value ?? 0),6*edge.stepPPM)
            let likeSign = (edge.signedHeight > 0) == (z.signedHeight > 0)
            if between || abs(z.ppm-edge.ppm) <= max(reach,likeSign ? 1.3*mean : 0) { reasons.insert("Nearby excluded line / possibly partial pattern"); break }
        }
        let ratios: [Double]
        let candidate: NativeNMRPeakMultiplicity
        switch p.count {
        case 1: candidate = .s; ratios = [1]
        case 2: candidate = .d; ratios = [1,1]
        case 3: candidate = .t; ratios = [1,2,1]
        case 4: candidate = .q; ratios = [1,3,3,1]
        default: candidate = .m; ratios = []; reasons.insert("Unsupported component pattern")
        }
        if !ratios.isEmpty {
            let unit = median(zip(p,ratios).map { abs($0.0.signedHeight)/$0.1 })
            for (c,r) in zip(p,ratios) {
                let expect = r*unit
                if abs(abs(c.signedHeight)-expect) > min(0.23*expect,0.16*expect+2*sigma) { reasons.insert("Height ratios not first order") }
            }
        }
        let mult: NativeNMRPeakMultiplicity = reasons.isEmpty ? candidate : .m
        var js = [NMREstimate]()
        if [.d,.t,.q].contains(mult), let f = t.stamp.observedMHz {
            let err = gaps.map { abs($0.value-mean)+$0.uncertainty }.max() ?? 0
            let j = NMREstimate(value:mean,uncertainty:err).scaled(f)
            try requireNMR(j.value.isFinite && j.uncertainty.isFinite, "Invalid frequency scale")
            js = [j]
        }
        return NMRPeakAnalysis(id:UUID(),stamp:t.stamp,noiseScale:sigma,components:p,envelope:env,midExtremaPPM:center,adjacentPPM:gaps,gapOverMean:gaps.map { $0.value/mean },reviewReasons:reasons.sorted(),suggestedShift:mult == .m ? .range(box.ppm) : .point(center.value),suggestedMultiplicity:mult,computedJsHz:js)
    }
}

enum NMRValueSource: String, Codable { case computed, userEntered }

struct NMRApproval: Codable, Equatable {
    let analysisID: UUID
    let approvedAt: Date
    let rawShift: NMRChemicalShift
    let multiplicity: NativeNMRPeakMultiplicity
    let jsHz: [Double]
    let shiftSource: NMRValueSource
    let multiplicitySource: NMRValueSource
    let jsSource: NMRValueSource
}

struct NMRPeakGroup: Identifiable, Codable, Equatable {
    let id: UUID
    let createdAt: Date
    let rawBox: NMRRawBox
    let dragClipped: Bool
    var analysis: NMRPeakAnalysis
    var linkedMarkID: String?
    var assignedH: Int?
    var approval: NMRApproval?
    var included: Bool = false
    fileprivate mutating func unapprove() { approval = nil; included = false }
}

// Opaque, lossless host ID token; signedArea comes FROM the existing integrator.
struct NMRMarkSnapshot {
    let id: String
    let spectrumID: String
    let signedArea: Double
}

struct NMRExportGroup {
    let groupID: UUID
    let spectrumID: String
    let analysisID: UUID
    let linkedMarkID: String?
    let approvedShift: NMRChemicalShift? // display/reference frame of this export call
    let approvedMultiplicity: NativeNMRPeakMultiplicity?
    let approvedJsHz: [Double]?
    let assignedH: Int?
    let included: Bool
    let approvedAt: Date?
    let shiftSource: NMRValueSource?
    let multiplicitySource: NMRValueSource?
    let jsSource: NMRValueSource?
}

struct NMRPeakFile: Codable {
    let schemaVersion: Int
    let spectrumID: String
    private(set) var groups: [NMRPeakGroup]
    init(spectrumID: String) { schemaVersion = 1; self.spectrumID = spectrumID; groups = [] }
    private struct Header: Decodable { let schemaVersion: Int }

    static func read(_ url: URL, spectrumID: String) throws -> Self {
        let data: Data
        do { data = try Data(contentsOf:url) } catch {
            let e = error as NSError
            if e.domain == NSCocoaErrorDomain && e.code == NSFileReadNoSuchFileError { return Self(spectrumID:spectrumID) }
            throw error
        }
        let d = JSONDecoder(); d.dateDecodingStrategy = .millisecondsSince1970
        let header = try d.decode(Header.self,from:data)
        try requireNMR(header.schemaVersion == 1, "Unsupported annotation schema; original file left untouched")
        let f = try d.decode(Self.self,from:data)
        try f.validate(spectrumID: spectrumID)
        return f
    }

    func validate(spectrumID: String) throws {
        try requireNMR(schemaVersion == 1 && self.spectrumID == spectrumID &&
                       Set(groups.map(\.id)).count == groups.count, "峰组版本、谱图编号或峰组编号无效。")
        for g in groups {
            let a = g.analysis
            try requireNMR(g.rawBox.valid && a.stamp.spectrumID == spectrumID && !a.components.isEmpty && a.envelope.valid && a.suggestedShift.valid && a.noiseScale > 0, "Invalid saved group")
            try requireNMR(a.components.allSatisfy { $0.sample >= 0 && $0.stepPPM > 0 && g.rawBox.contains($0.ppm,$0.intensity) }, "Invalid saved peak locator")
            if let id = g.linkedMarkID { try requireNMR(!id.isEmpty, "Empty Mark ID") }
            if let h = g.assignedH { try requireNMR(h > 0 && g.linkedMarkID != nil, "Invalid saved H assignment") }
            if let v = g.approval {
                try requireNMR(v.analysisID == a.id && v.rawShift.valid && v.multiplicity.permits(v.jsHz.count) && v.jsHz.allSatisfy { $0 > 0 }, "Invalid saved approval")
            } else { try requireNMR(!g.included, "Inclusion without approval") }
        }
    }

    func write(_ url: URL) throws {
        let e = JSONEncoder(); e.dateEncodingStrategy = .millisecondsSince1970; e.outputFormatting = [.sortedKeys]
        let data = try e.encode(self)
        try FileManager.default.createDirectory(at:url.deletingLastPathComponent(),withIntermediateDirectories:true,attributes:nil)
        try data.write(to:url,options:.atomic)
    }
    private func index(_ id: UUID) throws -> Int {
        guard let i = groups.firstIndex(where: { $0.id == id }) else { throw NMRProblem("Unknown group") }; return i
    }
    private func conflicts(_ g: NMRPeakGroup) -> Bool {
        let indices = Set(g.analysis.components.map { $0.sample })
        return groups.contains { b in
            b.id != g.id && (b.rawBox.meets(g.rawBox) || (g.analysis.stamp.gridAndRealCheck == b.analysis.stamp.gridAndRealCheck && b.analysis.components.contains { indices.contains($0.sample) }))
        }
    }
    private func mark(_ id: String, _ lookup: (String) -> NMRMarkSnapshot?) -> NMRMarkSnapshot? {
        guard let m = lookup(id), m.id == id, m.spectrumID == spectrumID, m.signedArea.isFinite else { return nil }; return m
    }
    func blockingReason(_ g: NMRPeakGroup, trace: NMRSpectrum1D, lookup: (String) -> NMRMarkSnapshot?) -> String? {
        if g.analysis.stamp != trace.stamp || trace.stamp.spectrumID != spectrumID { return "Stale analysis: review the raw box on the current trace and remeasure" }
        if conflicts(g) { return "Boxes or components in conflict: resolve before use" }
        if let id = g.linkedMarkID {
            if mark(id,lookup) == nil { return "Linked host integral is missing or invalid" }
            if groups.contains(where: { $0.id != g.id && $0.linkedMarkID == id }) { return "Integral linked more than once" }
        }
        if g.assignedH != nil && trace.stamp.nucleus != "1H" { return "H count requires a proton integral" }
        return nil
    }
    @discardableResult mutating func add(_ box: NMRRawBox, clipped: Bool, trace: NMRSpectrum1D) throws -> UUID {
        try requireNMR(trace.stamp.spectrumID == spectrumID, "Wrong spectrum")
        let a = try NMRBoxAnalyzer.analyze(box,clipped:clipped,trace:trace)
        let g = NMRPeakGroup(id:UUID(),createdAt:Date(),rawBox:box,dragClipped:clipped,analysis:a)
        try requireNMR(!conflicts(g), "Box overlaps an existing group or repeats a component; edit/remove that group first")
        groups.append(g); return g.id
    }
    mutating func remeasure(_ id: UUID, trace: NMRSpectrum1D) throws {
        try requireNMR(spectrumID == trace.stamp.spectrumID, "Wrong spectrum")
        let i = try index(id); var g = groups[i]
        g.analysis = try NMRBoxAnalyzer.analyze(g.rawBox,clipped:g.dragClipped,trace:trace)
        try requireNMR(!conflicts(g), "Conflicting groups")
        g.unapprove(); groups[i] = g
    }
    mutating func remove(_ id: UUID) throws { let i = try index(id); groups.remove(at:i) }
    mutating func link(_ id: UUID, to selected: NMRMarkSnapshot?, lookup: (String) -> NMRMarkSnapshot?) throws {
        let i = try index(id)
        if let m = selected {
            try requireNMR(!m.id.isEmpty && m.spectrumID == spectrumID && mark(m.id,lookup) != nil, "Selected integral is unavailable on this spectrum")
            try requireNMR(!groups.contains { $0.id != id && $0.linkedMarkID == m.id }, "This integral already has a group")
        }
        if groups[i].linkedMarkID != selected?.id { groups[i].linkedMarkID = selected?.id; groups[i].assignedH = nil; groups[i].unapprove() }
    }
    mutating func setH(_ h: Int?, for id: UUID, trace: NMRSpectrum1D, lookup: (String) -> NMRMarkSnapshot?) throws {
        let i = try index(id), g = groups[i]
        if let v = h {
            try requireNMR(v > 0 && trace.stamp.nucleus == "1H" && g.linkedMarkID != nil, "Link a proton integral and enter a positive integer")
            if let why = blockingReason(g,trace:trace,lookup:lookup) { throw NMRProblem(why) }
        }
        if g.assignedH != h { groups[i].assignedH = h; groups[i].unapprove() }
    }
    func suggestedH(for target: UUID, relativeTo reference: UUID, trace: NMRSpectrum1D, lookup: (String) -> NMRMarkSnapshot?) -> Double? {
        guard reference != target, trace.stamp.nucleus == "1H", let a = groups.first(where: { $0.id == target }), let b = groups.first(where: { $0.id == reference }), blockingReason(a,trace:trace,lookup:lookup) == nil, blockingReason(b,trace:trace,lookup:lookup) == nil, let h = b.assignedH, let ia = a.linkedMarkID, let ib = b.linkedMarkID, ia != ib, let ma = mark(ia,lookup), let mb = mark(ib,lookup), mb.signedArea != 0 else { return nil }
        let result = Double(h)*(ma.signedArea/mb.signedArea)
        return result.isFinite && result > 0 ? result : nil
    }
    // nil override = explicitly approve the computed field. [] override = user chose no J.
    mutating func approve(_ id: UUID, trace: NMRSpectrum1D, lookup: (String) -> NMRMarkSnapshot?, rawShiftOverride: NMRChemicalShift?, multOverride: NativeNMRPeakMultiplicity?, jsOverrideHz: [Double]?) throws {
        let i = try index(id), g = groups[i], a = g.analysis
        if let why = blockingReason(g,trace:trace,lookup:lookup) { throw NMRProblem(why) }
        let s = rawShiftOverride ?? a.suggestedShift, m = multOverride ?? a.suggestedMultiplicity
        try requireNMR(s.valid, "Invalid reviewed shift/range")
        try requireNMR(m == a.suggestedMultiplicity || jsOverrideHz != nil, "Changed multiplicity: explicitly review the J field (it may be empty)")
        let js = jsOverrideHz ?? a.computedJsHz.map { $0.value }
        try requireNMR(m.permits(js.count) && js.allSatisfy { $0.isFinite && $0 > 0 }, "Invalid number or value of Js for this multiplicity")
        groups[i].approval = NMRApproval(analysisID:a.id,approvedAt:Date(),rawShift:s,multiplicity:m,jsHz:js,shiftSource:rawShiftOverride == nil ? .computed : .userEntered,multiplicitySource:multOverride == nil ? .computed : .userEntered,jsSource:jsOverrideHz == nil ? .computed : .userEntered)
        groups[i].included = false
    }
    mutating func setIncluded(_ value: Bool, id: UUID, trace: NMRSpectrum1D, lookup: (String) -> NMRMarkSnapshot?) throws {
        let i = try index(id), g = groups[i]
        if value {
            if let why = blockingReason(g,trace:trace,lookup:lookup) { throw NMRProblem(why) }
            try requireNMR(g.approval?.analysisID == g.analysis.id, "Approve interpretation first")
        }
        groups[i].included = value
    }
    func exportGroups(trace: NMRSpectrum1D, referenceDelta: Double, lookup: (String) -> NMRMarkSnapshot?) throws -> [NMRExportGroup] {
        try requireNMR(referenceDelta.isFinite && trace.stamp.spectrumID == spectrumID, "Wrong export frame")
        return try groups.map { g in
            let ok = blockingReason(g,trace:trace,lookup:lookup) == nil
            let v = ok && g.approval?.analysisID == g.analysis.id ? g.approval : nil
            let display = v?.rawShift.shifted(by:referenceDelta)
            try requireNMR(display?.valid != false, "Invalid referenced shift")
            return NMRExportGroup(groupID:g.id,spectrumID:spectrumID,analysisID:g.analysis.id,linkedMarkID:g.linkedMarkID,approvedShift:display,approvedMultiplicity:v?.multiplicity,approvedJsHz:v?.jsHz,assignedH:ok ? g.assignedH : nil,included:g.included && v != nil,approvedAt:v?.approvedAt,shiftSource:v?.shiftSource,multiplicitySource:v?.multiplicitySource,jsSource:v?.jsSource)
        }
    }
}
