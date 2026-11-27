import Foundation

// Swift 5.7+，无 AppKit/SwiftUI、文件 I/O 或全局可变状态。
public enum NMRNucleus: String, Codable, Equatable, Sendable {
    case proton, carbon13, unknown

    public var title: String {
        switch self { case .proton: return "氢-1"; case .carbon13: return "碳-13"; case .unknown: return "未知核种" }
    }
    public var defaultLBHz: Double {
        switch self { case .proton, .unknown: return 0.3; case .carbon13: return 1.0 }
    }

    // nil 是未定义的字段；.unknown 也可表示一个有值但不支持的核种。
    private static func token(_ text: String?) -> NMRNucleus? {
        guard let text = text else { return nil }
        let s = text.uppercased().replacingOccurrences(of: "¹", with: "1").replacingOccurrences(of: "³", with: "3")
        let t = s.filter { !$0.isWhitespace && !"<>[](){}\"'^_-‐‑–".contains($0) }
        switch t {
        case "", "?", "OFF", "NONE", "UNKNOWN", "UNDEFINED": return nil
        case "1H", "H1", "PROTON", "PROTIUM", "HYDROGEN1", "1HYDROGEN": return .proton
        case "13C", "C13", "CARBON13", "13CARBON": return .carbon13
        default: return .unknown
        }
    }
    private static func resolve(_ fields: [String?]) -> NMRNucleus {
        var result: NMRNucleus?
        for field in fields {
            if let n = token(field) {
                if let old = result, old != n { return .unknown }
                result = n
            }
        }
        return result ?? .unknown
    }
    public static func identify(nuc1: String?, processedObserved: String? = nil) -> NMRNucleus {
        resolve([nuc1, processedObserved])
    }
    // 精确匹配 JCAMP 键；不搜索标题、脉冲程序、NUC2 或二维的另一条轴。
    private static func value(_ key: String, _ text: String?) -> String? {
        guard let text = text else { return nil }
        var continuation = false
        for sub in text.split(whereSeparator: { $0.isNewline }) {
            var line = String(sub)
            if let c = line.range(of: "$$") { line = String(line[..<c.lowerBound]) }
            line = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.isEmpty { continue }
            if line.hasPrefix("##") {
                continuation = false
                let body = line.dropFirst(2)
                guard let eq = body.firstIndex(of: "=") else { continue }
                var name = String(body[..<eq]).uppercased().filter { !$0.isWhitespace }
                if name.first == "$" { name.removeFirst() }
                guard name == key else { continue }
                let v = String(body[body.index(after: eq)...]).trimmingCharacters(in: .whitespacesAndNewlines)
                if !v.isEmpty { return v }
                continuation = true
            } else if continuation { return line }
        }
        return nil
    }
    public static func metadata(acqus: String?, procs: String?, processedObserved: String? = nil) -> NMRNucleus {
        resolve([value("NUC1", acqus), value("AXNUC", procs), value(".OBSERVENUCLEUS", procs), processedObserved])
    }
}

public enum NMRBaselinePolicy: String, Codable, Equatable, Sendable {
    case off, automatic, legacyEndpoints
    public var title: String {
        switch self { case .off: return "关闭基线"; case .automatic: return "保守自动基线"; case .legacyEndpoints: return "端点直线（旧版）" }
    }
}
public struct NMRProcessingOptions: Equatable, Codable, Sendable {
    public var lbOverride: Double?  // Hz；nil 不等于 0
    public var fill: Int           // 倍数，不是补入的点数
    public var baseline: NMRBaselinePolicy
    public init(lbOverride: Double? = nil, fill: Int = 2, baseline: NMRBaselinePolicy = .off) {
        self.lbOverride = lbOverride; self.fill = fill; self.baseline = baseline
    }
}
public struct NMRArrays: Equatable {
    public var ppm: [Double]
    public var real: [Double]
    public var imag: [Double]?
    public init(ppm: [Double], real: [Double], imag: [Double]? = nil) {
        self.ppm = ppm; self.real = real; self.imag = imag
    }
}
public enum NMRProcessingInput {
    // points 为截取有效 FID 后、补零前的复点数。transform 交付未相位、未扣基线、未平移的 FFT。
    case raw(nucleus: NMRNucleus, points: Int, transform: (Double, Int) throws -> NMRArrays)
    // 不可变的导入谱，不是上一次的显示缓存。
    case processed(nucleus: NMRNucleus, spectrum: NMRArrays)
}
public struct NMRPhaseFit: Equatable {
    public let p0: Double
    public let p1: Double
    public let regions: Int
    public let fittedFirstOrder: Bool
    public init(p0: Double, p1: Double, regions: Int, fittedFirstOrder: Bool) {
        self.p0 = p0; self.p1 = p1; self.regions = regions; self.fittedFirstOrder = fittedFirstOrder
    }
}
public typealias NMRPhaseEstimator = (NMRArrays, Double) throws -> NMRPhaseFit
// 输入已经相位，返回扣完旧基线的 real（不是基线曲线）。
public typealias NMREndpointFilter = (NMRArrays) throws -> [Double]

public enum NMRBaselineReason: String, Codable, Equatable, Sendable {
    case short, grid, weak, noFloor, negative, range
    case floorBelowThreshold, noPositiveSignal
    public var title: String {
        switch self {
        case .short: return "点数太少"
        case .grid: return "谱轴不是近似等间隔的单调轴"
        case .weak: return "偏置、漂移或谱峰的证据不足"
        case .floorBelowThreshold: return "峰间背景接近零，偏置和漂移均低于扣除阈值"
        case .noPositiveSignal: return "未找到足以支持扣除基线的连续正信号"
        case .noFloor: return "背景支持不足，或无法可靠区分漂移与谱带"
        case .negative: return "候选基线下方有明显负信号"
        case .range: return "强度超出可安全拟合的范围"
        }
    }

    fileprivate var refinesWeak: Bool { self == .floorBelowThreshold || self == .noPositiveSignal }
}
public enum NMRAutoDecision: Codable, Equatable, Sendable {
    case skipped(NMRBaselineReason)
    // 两端强度（不是 ppm）；线性模型仅有两个自由度。
    case affine(first: Double, last: Double, anchors: Int, blocks: Int)
    case smoothV1(NMRSmoothCurveV1)
}
public struct NMRBaselineReceipt: Codable, Equatable, Sendable {
    public let count: Int
    public let decision: NMRAutoDecision

    public init(count: Int, decision: NMRAutoDecision) {
        self.count = count
        self.decision = decision
    }

    // One application kernel for import, new processing and recorded decisions.
    func applying(to real: [Double]) throws -> [Double] {
        guard count == real.count, count > 0, count <= NMRProcessingWorkflow.maxPoints else { throw NMRProcessingError.receipt }
        let result: [Double]
        switch decision {
        case .skipped: result = real
        case let .affine(l, r, k, m):
            guard count >= 2, l.isFinite, r.isFinite, k >= 2, k <= m, m <= 48 else { throw NMRProcessingError.receipt }
            result = NMRProcessingWorkflow.subtractLine(real, l, r)
        case let .smoothV1(curve):
            guard curve.matches(count: count) else { throw NMRProcessingError.receipt }
            let den = Double(count - 1)
            result = real.indices.map { real[$0] - NMRSmoothCurveV1.value(curve.knots, Double($0) / den) }
        }
        guard result.allSatisfy({ $0.isFinite }) else { throw NMRProcessingError.numbers }
        return result
    }

    // Keep the existing wire representation for affine and all skip reasons.
    private enum CodingKeys: String, CodingKey { case count, decision, weakDetail }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        count = try container.decode(Int.self, forKey: .count)
        let original = try container.decode(NMRAutoDecision.self, forKey: .decision)
        if case let .smoothV1(curve) = original, !curve.matches(count: count) {
            throw DecodingError.dataCorruptedError(forKey: .count, in: container, debugDescription: "平滑基线与谱点数不匹配")
        }
        if original == .skipped(.weak),
           let detail = try container.decodeIfPresent(String.self, forKey: .weakDetail),
           let reason = NMRBaselineReason(rawValue: detail), reason.refinesWeak {
            decision = .skipped(reason)
        } else {
            decision = original
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(count, forKey: .count)
        if case let .skipped(reason) = decision, reason.refinesWeak {
            try container.encode(NMRAutoDecision.skipped(.weak), forKey: .decision)
            try container.encode(reason.rawValue, forKey: .weakDetail)
        } else {
            try container.encode(decision, forKey: .decision)
        }
    }
}
public enum NMRBaselineStatus: Equatable {
    case off, legacyEndpoints, automatic(NMRAutoDecision)
    public var title: String {
        switch self {
        case .off: return "未启用基线"
        case .legacyEndpoints: return "已扣除端点直线基线"
        case let .automatic(.skipped(why)): return "未扣除自动基线：" + why.title
        case let .automatic(.affine(_, _, k, m)): return "已扣除自动直线基线（支持区块 \(k)/\(m)）"
        case let .automatic(.smoothV1(c)): return "已扣除 Whittaker 平滑基线（背景区块 \(c.anchors)/\(c.blocks)）"
        }
    }
}

// 应用的 Settings 可直接指向此类型。项目仍是原来的扁平 Settings 容器。
public struct NMRProcessingSettings: Codable, Equatable, Sendable {
    public var options: NMRProcessingOptions {
        didSet {
            if options != oldValue { automaticBaselineV1 = nil }
            if options.lbOverride != oldValue.lbOverride { savedAutomaticLB = nil }
        }
    }
    public var p0: Double { didSet { if p0 != oldValue { automaticBaselineV1 = nil } } }
    public var p1: Double { didSet { if p1 != oldValue { automaticBaselineV1 = nil } } }
    public var offset: Double  // 最后平移，不使强度拟合失效
    public fileprivate(set) var savedAutomaticLB: Double? = nil
    public fileprivate(set) var automaticBaselineV1: NMRBaselineReceipt? = nil
    public init(options: NMRProcessingOptions = NMRProcessingOptions(), p0: Double = 0, p1: Double = 0, offset: Double = 0) {
        self.options = options; self.p0 = p0; self.p1 = p1; self.offset = offset
    }
    mutating func installImportedBaseline(_ receipt: NMRBaselineReceipt?) {
        options.baseline = receipt == nil ? .off : .automatic
        automaticBaselineV1 = receipt
    }
    // 深度处理中显式选择一个值，或重新选择“按核种”。
    public mutating func chooseLB(_ hz: Double?) {
        options.lbOverride = hz; savedAutomaticLB = nil; automaticBaselineV1 = nil
    }
    private enum CodingKeys: String, CodingKey {
        case lb, fill, p0, p1, offset, baseline, baselinePolicy, lbAutomatic, automaticBaselineV1
    }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let hz = try c.decodeIfPresent(Double.self, forKey: .lb)
        let auto = try c.decodeIfPresent(Bool.self, forKey: .lbAutomatic) ?? false
        let policy: NMRBaselinePolicy
        if let p = try c.decodeIfPresent(NMRBaselinePolicy.self, forKey: .baselinePolicy) { policy = p }
        else { policy = (try c.decodeIfPresent(Bool.self, forKey: .baseline) ?? false) ? .legacyEndpoints : .off }
        self.init(options: NMRProcessingOptions(lbOverride: auto ? nil : hz, fill: try c.decodeIfPresent(Int.self, forKey: .fill) ?? 2, baseline: policy), p0: try c.decodeIfPresent(Double.self, forKey: .p0) ?? 0, p1: try c.decodeIfPresent(Double.self, forKey: .p1) ?? 0, offset: try c.decodeIfPresent(Double.self, forKey: .offset) ?? 0)
        savedAutomaticLB = auto ? hz : nil
        automaticBaselineV1 = try c.decodeIfPresent(NMRBaselineReceipt.self, forKey: .automaticBaselineV1)
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encodeIfPresent(options.lbOverride ?? savedAutomaticLB, forKey: .lb)
        try c.encode(options.lbOverride == nil, forKey: .lbAutomatic)
        try c.encode(options.fill, forKey: .fill)
        try c.encode(p0, forKey: .p0); try c.encode(p1, forKey: .p1); try c.encode(offset, forKey: .offset)
        try c.encode(options.baseline, forKey: .baselinePolicy)
        try c.encode(options.baseline == .legacyEndpoints, forKey: .baseline)
        try c.encodeIfPresent(automaticBaselineV1, forKey: .automaticBaselineV1)
    }
}

public enum NMRProcessingAction: Equatable {
    case replay           // 只读已提交的参数和基线决定
    case applySettings    // 包括深度处理的试算；不使用旧的自动基线决定
    case phaseOnly
    case phaseAndBaseline // 新估计的是绝对相位，不是对显示谱的增量
    case baselineOnly     // 保留已有相位，仅估计基线
}
public enum NMRLBSource: Equatable {
    case notUsed, explicit, nucleusDefault, recordedAutomatic
    public var title: String {
        switch self { case .notUsed: return "导入谱，不加窗"; case .explicit: return "显式线宽"; case .nucleusDefault: return "按核种（未知时用兼容值）"; case .recordedAutomatic: return "已记录的自动线宽" }
    }
}
public struct NMRProcessingOutput {
    public let spectrum: NMRArrays
    public let originalPPM: [Double]
    public let settings: NMRProcessingSettings
    public let nucleus: NMRNucleus
    public let lbHz: Double?
    public let fillUsed: Int?
    public let lbSource: NMRLBSource
    public let phaseApplicable: Bool
    public let fit: NMRPhaseFit?
    public let baseline: NMRBaselineStatus
    public let action: NMRProcessingAction
    public var shouldJournal: Bool {
        if action == .replay { return false }
        if action == .baselineOnly, case .automatic(.skipped(_)) = baseline { return false }
        return true
    }
    public var message: String {
        if fit != nil { return "已估计相位；" + baseline.title }
        if action == .baselineOnly && !shouldJournal { return baseline.title + "；保留原显示与记录" }
        return baseline.title
    }
}
public enum NMRProcessingError: LocalizedError {
    case arrays, tooLarge, fill, numbers, phaseAxis, quadrature, onlyReal, estimatorMissing, negativeFit, receipt, history, stale
    case transformFailed(Error), estimateFailed(Error), endpointsFailed(Error)
    public var errorDescription: String? {
        switch self {
        case .arrays: return "谱数组为空、长度不一致或含非有限数值。"
        case .tooLarge: return "谱点数或补零长度超出处理上限。"
        case .fill: return "补零倍数必须为正整数。"
        case .numbers: return "处理参数或运算结果不是有限数值。"
        case .phaseAxis: return "估计相位需要至少两个按 ppm 递减的点。"
        case .quadrature: return "没有虚通道，不能估计相位；可使用“仅自动基线”。"
        case .onlyReal: return "“仅自动基线”用于已处理的单实通道谱。"
        case .estimatorMissing: return "没有连接相位估计器。"
        case .negativeFit: return "自动相位产生明显占优的倒峰，未提交；请在深度处理中检查相位。"
        case .receipt: return "已记录的基线与当前谱不匹配，未套用。"
        case .history: return "项目历史位置无效。"
        case .stale: return "数据或记录已改变，请重新试算。"
        case .transformFailed: return "FID 加窗、补零或傅里叶变换失败，未提交。"
        case .estimateFailed(let error): return "相位估计失败。 " + error.localizedDescription
        case .endpointsFailed: return "旧版端点基线处理失败，未提交。"
        }
    }
}

enum NMRFloor {
    private struct Bin { let x: Double; let m: Double; let iqr: Double }
    private static func median(_ v: [Double]) -> Double {
        let s = v.sorted(), k = s.count / 2
        return s.count % 2 == 1 ? s[k] : (s[k - 1] + s[k]) * 0.5
    }
    private static func scale(_ v: [Double]) -> Double { v.reduce(0.0) { max($0, abs($1)) } }
    // 相邻差的 MAD；先除以尺度，再求差，避免对极大强度直接做减法。
    private static func noise(_ v: [Double], _ z: Double) -> Double {
        let m = min(1025, v.count - 1)
        guard m > 0 else { return 0 }
        var d = [Double](); d.reserveCapacity(m)
        for k in 0..<m {
            let i = k * (v.count - 1) / m
            d.append(v[i + 1] / z - v[i] / z)
        }
        let center = median(d)
        return median(d.map { abs($0 - center) }) / 0.953873
    }
    // 只作自动估相的粗大极性错误否决，不用于改相位或翻转单个峰。
    static func inverted(_ v: [Double]) -> Bool {
        let z = scale(v), m = min(513, v.count)
        guard z > 0, m >= 3 else { return false }
        let center = median((0..<m).map { v[$0 * (v.count - 1) / (m - 1)] / z })
        var up = 0.0, down = 0.0
        for a in v { let d = a / z - center; up = max(up, d); down = max(down, -d) }
        return down > max(7 * noise(v, z), 2.8 * max(1e-10, up))
    }
    static func decide(_ a: NMRArrays) -> NMRAutoDecision {
        let v = a.real, n = v.count
        guard n >= 192 else { return .skipped(.short) }
        guard n <= NMRProcessingWorkflow.maxPoints, v.allSatisfy({ $0.isFinite }) else { return .skipped(.range) }
        guard a.ppm.count == n else { return .skipped(.grid) }
        let h = (a.ppm[n - 1] - a.ppm[0]) / Double(n - 1)
        guard h.isFinite, h != 0 else { return .skipped(.grid) }
        for j in 1..<n {
            let d = a.ppm[j] - a.ppm[j - 1]
            if !d.isFinite || d == 0 || abs(d - h) > 0.03 * abs(h) { return .skipped(.grid) }
        }
        let z = scale(v)
        guard z > 0 else { return .skipped(.noPositiveSignal) }
        let sigma = noise(v, z)
        let bCount = min(48, n / 16), q = min(33, n / bCount)
        let tol = max(0.0004, 4 * sigma / sqrt(Double(q)))
        var bins = [Bin](); bins.reserveCapacity(bCount)
        for b in 0..<bCount {
            let lo = b * n / bCount, hi = (b + 1) * n / bCount - 1
            var sample = [Double](); sample.reserveCapacity(q)
            for k in 0..<q { sample.append(v[lo + k * (hi - lo) / (q - 1)] / z) }
            sample.sort()
            let m = (sample[(q - 1) / 2] + sample[q / 2]) * 0.5
            bins.append(Bin(x: Double(lo + hi) / (2 * Double(n - 1)), m: m, iqr: sample[3 * (q - 1) / 4] - sample[(q - 1) / 4]))
        }
        // 首尾不作锚。候选直线必须在两侧都有支持；允许成片的正峰高出它，
        // 却不允许用一条穿过峰肩的高线把其它整个区块压成负峰。
        let trim = max(1, bCount / 16), interior = trim..<(bCount - trim)
        func support(_ a0: Double, _ slope: Double) -> (ids: [Int], loss: Double)? {
            var ids = [Int](), loss = 0.0
            var left = false, right = false
            let spread = 3.5 * sigma + abs(slope) / Double(bCount) + 4 * tol
            for i in bins.indices {
                let b = bins[i], r = b.m - (a0 + slope * b.x)
                if r < -3 * tol { return nil }
                if interior.contains(i), abs(r) <= tol, b.iqr <= spread {
                    ids.append(i); loss += r * r
                    left = left || b.x < 0.28; right = right || b.x > 0.72
                }
            }
            guard left, right, ids.count * 5 >= interior.count * 3 else { return nil }
            return (ids, loss)
        }
        var best = [Int](), bestLoss = Double.infinity, intercept = 0.0, slope = 0.0
        for i in interior {
            for j in (i + 1)..<interior.upperBound {
                let dx = bins[j].x - bins[i].x
                if dx < 0.40 { continue }
                let b = (bins[j].m - bins[i].m) / dx, c = bins[i].m - b * bins[i].x
                if let s = support(c, b), s.ids.count > best.count || (s.ids.count == best.count && s.loss < bestLoss) {
                    best = s.ids; bestLoss = s.loss; intercept = c; slope = b
                }
            }
        }
        guard !best.isEmpty else { return SmoothBaseline.decide(v, scale: z, noise: sigma) }
        // 仅在共识锚上细化一次，不迭代扩大锚区。
        let mx = best.reduce(0.0) { $0 + bins[$1].x } / Double(best.count)
        let my = best.reduce(0.0) { $0 + bins[$1].m } / Double(best.count)
        var xx = 0.0, xy = 0.0
        for k in best { let dx = bins[k].x - mx; xx += dx * dx; xy += dx * (bins[k].m - my) }
        if xx > 0 {
            let b = xy / xx, c = my - b * mx
            if let s = support(c, b), s.ids.count >= best.count {
                intercept = c; slope = b; best = s.ids
            }
        }
        guard max(abs(intercept), abs(intercept + slope)) > max(3 * tol, 1.5 * sigma) else {
            return .skipped(.floorBelowThreshold)
        }
        let high = max(6 * sigma, 8 * tol), low = max(6 * sigma, 4 * tol)
        var positive = false, upRun = 0, downRun = 0
        for i in 0..<n {
            let r = v[i] / z - (intercept + slope * (Double(i) / Double(n - 1)))
            upRun = r > high ? upRun + 1 : 0
            downRun = r < -low ? downRun + 1 : 0
            if upRun >= 2 { positive = true }
            if downRun >= 2 { return .skipped(.negative) }
        }
        guard positive else { return .skipped(.noPositiveSignal) }
        func shrink(_ x: Double) -> Double { x >= 0 ? max(0, x - tol) : min(0, x + tol) }
        let first = shrink(intercept) * z, last = shrink(intercept + slope) * z
        guard first.isFinite, last.isFinite else { return .skipped(.range) }
        return .affine(first: first, last: last, anchors: best.count, blocks: bCount)
    }
}

public enum NMRProcessingWorkflow {
    public static let maxPoints = 1 << 22
    private static func validate(_ s: NMRArrays) throws {
        let n = s.real.count
        guard n <= maxPoints else { throw NMRProcessingError.tooLarge }
        guard n > 0, s.ppm.count == n, s.imag.map({ $0.count == n }) ?? true,
              s.real.allSatisfy({ $0.isFinite }), s.ppm.allSatisfy({ $0.isFinite }),
              s.imag?.allSatisfy({ $0.isFinite }) ?? true else { throw NMRProcessingError.arrays }
    }
    private static func phased(_ s: NMRArrays, _ p0: Double, _ p1: Double) throws -> NMRArrays {
        guard let im = s.imag, p0 != 0 || p1 != 0 else { return s }
        let den = Double(max(1, s.real.count - 1))
        var re = s.real, ii = im
        for j in s.real.indices {
            let angle = (p0 + p1 * Double(j) / den) * (Double.pi / 180)
            let c = cos(angle), t = sin(angle)
            let r = s.real[j] * c - im[j] * t, i = s.real[j] * t + im[j] * c
            guard r.isFinite, i.isFinite else { throw NMRProcessingError.numbers }
            re[j] = r; ii[j] = i
        }
        return NMRArrays(ppm: s.ppm, real: re, imag: ii)
    }
    static func subtractLine(_ v: [Double], _ first: Double, _ last: Double) -> [Double] {
        let den = Double(max(1, v.count - 1))
        return v.indices.map { j in
            let t = Double(j) / den
            return v[j] - ((1 - t) * first + t * last)
        }
    }
    // 独立使用时的字面首点/末点连线。宿主旧实现若用端区均值等，注入原函数。
    public static func linearEndpoints(_ s: NMRArrays) throws -> [Double] {
        guard s.real.count > 1, let l = s.real.first, let r = s.real.last else { return s.real }
        return subtractLine(s.real, l, r)
    }
    public static func run(_ input: NMRProcessingInput, settings original: NMRProcessingSettings, action: NMRProcessingAction, estimate: NMRPhaseEstimator? = nil, legacy: NMREndpointFilter = NMRProcessingWorkflow.linearEndpoints) throws -> NMRProcessingOutput {
        var s = original
        guard s.p0.isFinite, s.p1.isFinite, s.offset.isFinite else { throw NMRProcessingError.numbers }
        let nucleus: NMRNucleus, fft: NMRArrays, source: NMRLBSource
        var hz: Double?, factor: Int?
        switch input {
        case let .raw(n, count, transform):
            let f = s.options.fill
            guard f >= 1 else { throw NMRProcessingError.fill }
            guard count > 0, count <= maxPoints / f else { throw NMRProcessingError.tooLarge }
            let value: Double
            if let v = s.options.lbOverride { value = v; source = .explicit; s.savedAutomaticLB = nil }
            else if let v = s.savedAutomaticLB { value = v; source = .recordedAutomatic }
            else { value = n.defaultLBHz; source = .nucleusDefault; s.savedAutomaticLB = value }
            guard value.isFinite else { throw NMRProcessingError.numbers }
            nucleus = n; hz = value; factor = f
            do { fft = try transform(value, f) } catch { throw NMRProcessingError.transformFailed(error) }
        case let .processed(n, a):
            nucleus = n; fft = a; source = .notUsed
        }
        try validate(fft)
        var fit: NMRPhaseFit?
        if action == .phaseAndBaseline || action == .phaseOnly {
            guard fft.imag != nil else { throw NMRProcessingError.quadrature }
            guard fft.ppm.count >= 2, zip(fft.ppm, fft.ppm.dropFirst()).allSatisfy({ $0.0 > $0.1 }) else { throw NMRProcessingError.phaseAxis }
            guard let estimate = estimate else { throw NMRProcessingError.estimatorMissing }
            let f: NMRPhaseFit
            do { f = try estimate(fft, s.p1) } catch { throw NMRProcessingError.estimateFailed(error) }
            guard f.p0.isFinite, f.p1.isFinite else { throw NMRProcessingError.numbers }
            s.p0 = f.p0; s.p1 = f.p1; fit = f
        }
        if action == .phaseAndBaseline || action == .baselineOnly { s.options.baseline = .automatic }
        var out = try phased(fft, s.p0, s.p1)
        if fit != nil && NMRFloor.inverted(out.real) { throw NMRProcessingError.negativeFit }
        let status: NMRBaselineStatus
        switch s.options.baseline {
        case .off: s.automaticBaselineV1 = nil; status = .off
        case .legacyEndpoints:
            do { out.real = try legacy(out) } catch { throw NMRProcessingError.endpointsFailed(error) }
            s.automaticBaselineV1 = nil; status = .legacyEndpoints
        case .automatic:
            let receipt: NMRBaselineReceipt
            if action == .replay, let saved = s.automaticBaselineV1 { receipt = saved }
            else { receipt = NMRBaselineReceipt(count: out.real.count, decision: NMRFloor.decide(out)) }
            out.real = try receipt.applying(to: out.real)
            s.automaticBaselineV1 = receipt
            status = .automatic(receipt.decision)
        }
        guard out.real.count == fft.real.count, out.real.allSatisfy({ $0.isFinite }) else { throw NMRProcessingError.arrays }
        if s.offset != 0 {
            out.ppm = fft.ppm.map { $0 + s.offset }
            guard out.ppm.allSatisfy({ $0.isFinite }) else { throw NMRProcessingError.numbers }
        }
        return NMRProcessingOutput(spectrum: out, originalPPM: fft.ppm, settings: s, nucleus: nucleus, lbHz: hz, fillUsed: factor, lbSource: source, phaseApplicable: fft.imag != nil, fit: fit, baseline: status, action: action)
    }
}

// 可选的纯值事务适配器。Entry 必须是值快照；不创建另一套持久化历史。
public struct NMRJournalStep<Entry> {
    public let entries: [Entry]
    public let cursor: Int
    public let output: NMRProcessingOutput
    public let install: Bool
}
public enum NMRJournal {
    // prepared 来自同一数据、同一代已提交记录。接受试算时不再执行任何处理。
    public static func committing<Entry>(_ prepared: NMRProcessingOutput, entries: [Entry], cursor: Int, settings: WritableKeyPath<Entry, NMRProcessingSettings>) throws -> NMRJournalStep<Entry> {
        guard entries.indices.contains(cursor), prepared.action != .replay else { throw NMRProcessingError.history }
        guard prepared.shouldJournal else { return NMRJournalStep(entries: entries, cursor: cursor, output: prepared, install: false) }
        var next = entries[cursor]
        next[keyPath: settings] = prepared.settings
        var journal = Array(entries.prefix(cursor + 1))
        journal.append(next)
        return NMRJournalStep(entries: journal, cursor: journal.count - 1, output: prepared, install: true)
    }
    // 打开、撤销、重做都是选取完整记录，不从显示谱反算，也不写入新条目。
    public static func selecting<Entry>(_ index: Int, entries: [Entry], settings: KeyPath<Entry, NMRProcessingSettings>, input: NMRProcessingInput, legacy: NMREndpointFilter = NMRProcessingWorkflow.linearEndpoints) throws -> NMRJournalStep<Entry> {
        guard entries.indices.contains(index) else { throw NMRProcessingError.history }
        let o = try NMRProcessingWorkflow.run(input, settings: entries[index][keyPath: settings], action: .replay, legacy: legacy)
        return NMRJournalStep(entries: entries, cursor: index, output: o, install: true)
    }
}
