import Foundation

// Processing-layer type. Keep exactly one definition in the application.
extension NMRNucleus {

    public var symbol: String {
        switch self {
        case .proton: return "¹H"
        case .carbon13: return "¹³C"
        case .unknown: return "未指定"
        }
    }
}

// A value snapshot, not just an index into the current version of a table.
public struct ReferenceLine: Identifiable, Codable, Equatable, Sendable {
    public let id: String
    public let solventID: String?       // nil for a manually specified standard
    public let material: String
    public let nucleus: NMRNucleus
    public let site: String
    public let ppm: Double
    public let note: String
    public let source: String
}

public struct ReferenceSolvent: Identifiable {
    public let id: String
    public let name: String
    public let aliases: [String]
    public let lines: [ReferenceLine]

    public func lines(for nucleus: NMRNucleus) -> [ReferenceLine] {
        lines.filter { $0.nucleus == nucleus }
    }

    fileprivate var names: [String] { [id, name] + aliases }
}

public enum SolventReferences {
    public static let supplement = "https://stoltz2.caltech.edu/publications/103-s-2010.pdf"
    public static let original = "原始工作：Gottlieb, Kotlyar & Nudelman, J. Org. Chem. (1997), DOI 10.1021/jo971176v。"

    private struct Site {
        let key: String
        let nucleus: NMRNucleus
        let name: String
        let ppm: Double
        let note: String
    }

    private static func h(_ key: String, _ name: String, _ ppm: Double, _ note: String = "使用此位点的残余质子信号；有裂分时取信号中心。") -> Site {
        Site(key: key, nucleus: .proton, name: name, ppm: ppm, note: note)
    }

    private static func c(_ key: String, _ name: String, _ ppm: Double, _ note: String = "若有可分辨的耦合裂分，表值指整个多重峰的中心，不是最高分量。") -> Site {
        Site(key: key, nucleus: .carbon13, name: name, ppm: ppm, note: note)
    }

    private static func solvent(_ id: String, _ name: String, _ aliases: [String], _ sites: [Site]) -> ReferenceSolvent {
        let lines = sites.map { s -> ReferenceLine in
            let table = s.nucleus == .proton ? "S1" : "S2"
            let citation = "Fulmer et al., Organometallics (2010), DOI 10.1021/om100106e, SI Table " + table + ", " + supplement
            return ReferenceLine(id: id + "." + s.nucleus.rawValue + "." + s.key, solventID: id, material: name, nucleus: s.nucleus, site: s.name, ppm: s.ppm, note: s.note, source: citation)
        }
        return ReferenceSolvent(id: id, name: name, aliases: aliases, lines: lines)
    }

    // The id, nucleus raw value and site key are persistent identifiers. Never recycle them.
    public static let all: [ReferenceSolvent] = [
        solvent("cdcl3", "氘代氯仿 · CDCl₃", ["CDCl3", "chloroform-d", "chloroform"], [
            h("ch", "CHCl₃", 7.26),
            c("c", "CDCl₃ · 碳", 77.16, "使用 C–D 三重峰的中心；不要按强度挑选一个分量。")
        ]),
        solvent("dmso-d6", "二甲基亚砜 · DMSO-d₆", ["DMSO", "DMSO-d6", "dimethyl sulfoxide-d6"], [
            h("methyl", "甲基 · 残余 H", 2.50), c("methyl", "甲基碳", 39.52)
        ]),
        solvent("cd3od", "氘代甲醇 · CD₃OD", ["CD3OD", "MeOD", "methanol-d4", "methanol"], [
            h("methyl", "甲基 · 残余 H", 3.31), c("methyl", "甲基碳", 49.00)
        ]),
        solvent("c6d6", "氘代苯 · C₆D₆", ["C6D6", "benzene-d6", "benzene"], [
            h("ring", "芳环 · 残余 H", 7.16), c("ring", "芳环碳", 128.06)
        ]),
        solvent("acetone-d6", "丙酮-d₆", ["acetone-d6", "acetone", "(CD3)2CO"], [
            h("methyl", "甲基 · 残余 H", 2.05), c("methyl", "甲基碳", 29.84), c("carbonyl", "羰基碳", 206.26)
        ]),
        solvent("cd3cn", "氘代乙腈 · CD₃CN", ["CD3CN", "MeCN-d3", "acetonitrile-d3", "acetonitrile"], [
            h("methyl", "甲基 · 残余 H", 1.94), c("methyl", "甲基碳", 1.32), c("nitrile", "腈基碳", 118.26)
        ]),
        solvent("d2o", "重水 · D₂O", ["D2O", "heavy water"], [
            h("hdo", "HDO · 交换信号", 4.79, "HDO 的位置随温度、pH 等变化。4.79 是表值，不是水相通用定标点；若使用独立标准，请手工指定。")
        ]),
        solvent("cd2cl2", "氘代二氯甲烷 · CD₂Cl₂", ["CD2Cl2", "dichloromethane-d2", "dichloromethane", "DCM-d2"], [
            h("ch", "亚甲基 · 残余 H", 5.32), c("c", "亚甲基碳", 53.84)
        ]),
        solvent("thf-d8", "四氢呋喃 · THF-d₈", ["THF", "THF-d8", "tetrahydrofuran-d8"], [
            h("beta", "β 位 · 残余 H", 1.72), h("alpha", "α 位（邻 O）· 残余 H", 3.58),
            c("beta", "β 位碳", 25.31), c("alpha", "α 位碳（邻 O）", 67.21)
        ]),
        solvent("toluene-d8", "甲苯-d₈", ["toluene-d8", "toluene"], [
            h("methyl", "甲基 · 残余 H", 2.08, "此条仅用于甲基信号，不适用于芳香区。"), c("methyl", "甲基碳", 20.43)
        ]),
        solvent("tfe-d3", "三氟乙醇 · TFE-d₃", ["TFE", "TFE-d3", "2,2,2-trifluoroethanol-d3", "trifluoroethanol"], [
            h("oh", "羟基 · 可交换 H", 5.02, "可交换质子对样品条件敏感；与亚甲基位点分开选择。"), h("ch2", "亚甲基 · 残余 H", 3.88),
            c("ch2", "亚甲基碳", 61.50), c("cf3", "CF₃ 碳", 126.28)
        ])
    ]

    private static func key(_ s: String) -> String {
        // NFKC also makes subscript digits searchable with an ASCII keyboard.
        s.precomposedStringWithCompatibilityMapping.lowercased().components(separatedBy: CharacterSet.alphanumerics.inverted).joined()
    }

    public static func search(_ query: String, nucleus: NMRNucleus) -> [ReferenceSolvent] {
        let q = key(query)
        return all.filter { s in
            !s.lines(for: nucleus).isEmpty && (q.isEmpty || s.names.contains { key($0).contains(q) })
        }
    }

    // Pass ONLY the parsed Bruker SOLVENT field here. An exact, unambiguous name
    // match is a suggestion, not a selection. No ppm data is used in this API.
    public static func suggestion(brukerSOLVENT: String?, nucleus: NMRNucleus) -> ReferenceSolvent? {
        guard let text = brukerSOLVENT else { return nil }
        let q = key(text)
        guard !q.isEmpty else { return nil }
        let matches = all.filter { s in !s.lines(for: nucleus).isEmpty && s.names.contains { key($0) == q } }
        return matches.count == 1 ? matches.first : nil
    }

    public static func line(id: String) -> ReferenceLine? {
        for s in all {
            if let line = s.lines.first(where: { $0.id == id }) { return line }
        }
        return nil
    }
}

public enum ManualStandard: String, CaseIterable, Hashable {
    case custom, tms, dss, tsp

    public var title: String {
        switch self {
        case .custom: return "自定义参考"
        case .tms: return "TMS（四甲基硅烷）"
        case .dss: return "DSS（水相标准）"
        case .tsp: return "TSP（水相标准）"
        }
    }

    public var note: String {
        switch self {
        case .custom: return "请记录标准名称、位点或参考依据。"
        case .tms: return "若实际使用 TMS 作零点，可输入 0.00 ppm。"
        case .dss, .tsp: return "这是独立的水相标准，不是 HDO。按实际使用的标准、核种和方法输入目标值。"
        }
    }
}

public struct CalibrationIssue: LocalizedError {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}

// Construct once per processed axis, not per keystroke. Array storage is copy-on-write.
// An invalid axis remains representable so the sheet can explain why Apply is disabled.
public struct CalibrationAxis {
    private let raw: [Double]
    private let minGap: Double

    public init(rawDescendingPPM raw: [Double]) {
        self.raw = raw
        var gap = Double.infinity
        if raw.count >= 2, let first = raw.first, first.isFinite {
            var previous = first
            for x in raw.dropFirst() {
                guard x.isFinite, previous > x else { gap = 0; break }
                gap = min(gap, previous - x)
                previous = x
            }
        } else { gap = 0 }
        minGap = gap
    }

    public func displayedRange(offset: Double) throws -> ClosedRange<Double> {
        guard minGap > 0, let high = raw.first, let low = raw.last else {
            throw CalibrationIssue("需要至少两个有限、严格降序的原始 ppm 坐标。请检查轴单位和数据顺序。")
        }
        guard offset.isFinite else { throw CalibrationIssue("当前 offset 不是有限 ppm 值；请先复位或修复设置。") }
        let lo = low + offset, hi = high + offset
        guard lo.isFinite, hi.isFinite, hi > lo else { throw CalibrationIssue("平移后轴溢出或重合；请检查 ppm 单位和 offset。") }
        // Addition is monotone, but an enormous offset could round adjacent points
        // to the same Double. Scan for actual ties only when spacing is at risk.
        if offset != 0 && minGap <= 2 * max(abs(lo), abs(hi)).ulp {
            var previous = hi
            for x in raw.dropFirst() {
                let displayed = x + offset
                guard previous > displayed else { throw CalibrationIssue("此 offset 使相邻采样坐标重合；请检查输入。") }
                previous = displayed
            }
        }
        return lo...hi
    }
}

public struct ReferencePick: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Hashable, Sendable { case peak, center }
    public let rawPPM: Double         // original ppm coordinate, NEVER display ppm
    public let kind: Kind
    public let label: String
    public init(rawPPM: Double, kind: Kind, label: String) {
        self.rawPPM = rawPPM; self.kind = kind; self.label = label
    }
}

public enum CalibrationObservation {
    case typedDisplay(Double)         // on the CURRENT display axis
    case selected(ReferencePick)      // explicit user selection on the same spectrum
}

public enum CalibrationTarget {
    case tabulated(String)            // stable line ID
    case manual(ManualStandard, ppm: Double, detail: String)
}

public struct ShiftCalibrationRecord: Codable, Equatable, Sendable {
    public let version: Int
    public let nucleus: NMRNucleus
    public let pick: ReferencePick?   // nil means exact typed display ppm
    public let measuredDisplayPPM: Double
    public let targetPPM: Double
    public let deltaPPM: Double       // incremental, NOT the new Settings.offset
    public let previousOffsetPPM: Double
    public let offsetPPM: Double      // absolute cumulative offset after this edit
    public let reference: ReferenceLine
}

public enum ShiftCalibration {
    public static func parsePPM(_ text: String, field: String) throws -> Double {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { throw CalibrationIssue("请输入" + field + "（ppm）。") }
        let allowed = CharacterSet(charactersIn: "0123456789eE+-.")
        guard t.rangeOfCharacter(from: allowed.inverted) == nil, let x = Double(t), x.isFinite else {
            throw CalibrationIssue(field + "必须是有限数值。请用小数点，不加单位或千位分隔符。")
        }
        return x
    }

    public static func propose(axis: CalibrationAxis, nucleus: NMRNucleus, currentOffset: Double, observation: CalibrationObservation, target: CalibrationTarget) throws -> ShiftCalibrationRecord {
        let bounds = try axis.displayedRange(offset: currentOffset)
        guard nucleus != .unknown else { throw CalibrationIssue("请先选择本谱的核种：¹H 或 ¹³C。") }
        let measured: Double, rawMeasured: Double, pick: ReferencePick?
        switch observation {
        case .typedDisplay(let x):
            measured = x; rawMeasured = x - currentOffset; pick = nil
        case .selected(let p):
            let rawBounds = try axis.displayedRange(offset: 0)
            guard p.rawPPM.isFinite, rawBounds.contains(p.rawPPM) else {
                throw CalibrationIssue("所选点不在本谱原始轴内。请在当前谱图重新选峰或中心。")
            }
            rawMeasured = p.rawPPM; measured = p.rawPPM + currentOffset; pick = p
        }
        guard measured.isFinite, bounds.contains(measured) else {
            throw CalibrationIssue("实测位置超出当前显示全谱 [\(bounds.lowerBound), \(bounds.upperBound)] ppm。请从当前轴读数，不要输入平移前的值或 Hz。")
        }

        let ref: ReferenceLine
        switch target {
        case .tabulated(let id):
            guard let line = SolventReferences.line(id: id), line.nucleus == nucleus else {
                throw CalibrationIssue("请选择与当前核种一致的溶剂和具体参考线。")
            }
            ref = line
        case .manual(let standard, let ppm, let detail):
            let text = detail.trimmingCharacters(in: .whitespacesAndNewlines)
            guard ppm.isFinite else { throw CalibrationIssue("请输入有限的自定义目标 ppm。") }
            guard standard != .custom || !text.isEmpty else { throw CalibrationIssue("请填写自定义标准的名称、位点或依据，供项目和导出记录使用。") }
            ref = ReferenceLine(id: "manual.\(standard.rawValue).\(nucleus.rawValue)", solventID: nil, material: standard.title, nucleus: nucleus, site: text.isEmpty ? "使用者指定的标准信号" : text, ppm: ppm, note: standard.note, source: "用户手工指定，非溶剂表值")
        }

        let delta = ref.ppm - measured
        let next = currentOffset + delta
        guard delta.isFinite, next.isFinite else { throw CalibrationIssue("定标量溢出；请核对实测值和目标值的单位。") }
        _ = try axis.displayedRange(offset: next)
        let aligned = rawMeasured + next
        guard aligned.isFinite, abs(aligned - ref.ppm) <= max(1e-10, 8 * abs(ref.ppm).ulp) else {
            throw CalibrationIssue("此组数值在 Double 精度下不能可靠对齐；请检查单位或复位异常 offset。")
        }
        return ShiftCalibrationRecord(version: 1, nucleus: nucleus, pick: pick, measuredDisplayPPM: measured, targetPPM: ref.ppm, deltaPPM: delta, previousOffsetPPM: currentOffset, offsetPPM: next, reference: ref)
    }
}
