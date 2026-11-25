import Foundation

enum NMRReportNucleus: String, Codable, Hashable {
    case proton, carbon13
    var symbol: String { self == .proton ? "¹H" : "¹³C" }
}

enum NMRMultiplicity: String, Codable, CaseIterable, Hashable {
    case s, d, t, q, quint, sext, sept, dd, dt, td, dq, qd, tt, ddd, ddt, dtd, tdd, m
    case brS = "br s"

    var permitsResolvedJ: Bool { maxJ > 0 }

    fileprivate var maxJ: Int {
        switch self {
        case .s, .brS, .m: return 0
        case .dd, .dt, .td, .dq, .qd, .tt: return 2
        case .ddd, .ddt, .dtd, .tdd: return 3
        default: return 1
        }
    }
}

enum NMRJReview: String, Codable, CaseIterable, Hashable {
    case unreviewed, unresolved, approved
}

enum NMRShift: Codable, Equatable {
    case center(Double?)
    case bounds(Double?, Double?)

    var interval: ClosedRange<Double>? {
        switch self {
        case let .center(x?):
            guard x.isFinite else { return nil }
            return x...x
        case let .bounds(a?, b?):
            guard a.isFinite, b.isFinite, a != b else { return nil }
            return min(a, b)...max(a, b)
        default:
            return nil
        }
    }
}

enum NMRShiftSource {
    case asReported(NMRShift)
    case raw(NMRShift, additivePPM: Double)

    var forReport: NMRShift {
        let shift: NMRShift
        let delta: Double?
        switch self {
        case let .asReported(s): shift = s; delta = nil
        case let .raw(s, d): shift = s; delta = d
        }
        func coordinate(_ x: Double?) -> Double? {
            guard let x else { return nil }
            let result = delta.map { x + $0 } ?? x
            return result.isFinite ? result : nil
        }
        switch shift {
        case let .center(x): return .center(coordinate(x))
        case let .bounds(a, b): return .bounds(coordinate(a), coordinate(b))
        }
    }
}

struct NMRIntegral: Identifiable, Codable, Equatable {
    let id: UUID
    var label: String = ""
    var assignedH: Int? = nil
    var signedArea: Double? = nil

    // 显示坐标；相对值仍是测量上下文，不是 H 指派。
    var lowPPM: Double? = nil
    var highPPM: Double? = nil
    var relativeArea: Double? = nil
    var referenceTarget: Double? = nil
    var note: String? = nil
}

struct NMRRowOrigin: Codable, Equatable {
    let analysisID: UUID?
    let sourceApproval: Date?
    let reviewNotes: [String]
    let blocked: String?
    let suggestedLink: Bool

    // 只由当前实测来源设置。手工改链接不能建立定量依据。
    var quantitativeRegionID: UUID? = nil
    var shadowOf: UUID? = nil
}

struct NMRRow: Identifiable, Codable, Equatable {
    let id: UUID
    var include: Bool = false
    var approved: Bool = false
    var shift: NMRShift = .center(nil)
    var multiplicity: NMRMultiplicity? = nil
    var multiplicityApproved: Bool = false
    var jReview: NMRJReview = .unreviewed
    var jHz: [Double?] = []
    var integralID: UUID? = nil
    var omitUnassignedH: Bool? = nil
    var origin: NMRRowOrigin? = nil

    var explicitH: Int? = nil       // 无积分链接时，用户在草稿内直接指派
    var jBasisMHz: Double? = nil    // 仅计算所得的 Hz 依赖这个频率
}

struct NMRSpectrum: Identifiable, Codable, Equatable {
    let id: UUID
    let sampleID: UUID?
    let nucleus: NMRReportNucleus
    var selected: Bool = false
    var observedMHz: Double? = nil
    var solventDisplayName: String? = nil
    var integrals: [NMRIntegral] = []
    var rows: [NMRRow] = []
    var sourceRevision: String? = nil
    var sourceOffsetPPM: Double? = nil
}

struct NMRTextStyle: Codable, Equatable {
    var protonPlaces = 2
    var carbonPlaces = 1
    var jPlaces = 1
    var mhzPlaces = 0

    fileprivate func valid(for nuclei: Set<NMRReportNucleus>) -> Bool {
        (0...6).contains(mhzPlaces) &&
        (!nuclei.contains(.proton) || ((0...6).contains(protonPlaces) && (1...6).contains(jPlaces))) &&
        (!nuclei.contains(.carbon13) || (0...6).contains(carbonPlaces))
    }
}

struct NMRReportDraft: Codable, Equatable {
    var spectra: [NMRSpectrum] = []
    var style = NMRTextStyle()
    var sourceSpectrum: NMRSpectrum? = nil
}

struct NMRLocation: Hashable {
    let spectrum: Int
    let row: Int?
}

struct NMRIssue {
    enum Kind: String { case conflict = "设置", incomplete = "待完成", warning = "提示" }
    let kind: Kind
    let location: NMRLocation?
    let message: String
}

struct NMRTextResult {
    let text: String?
    let issues: [NMRIssue]
}

struct NMRDraftText {
    let preview: String
    let issues: [NMRIssue]

    // 不做二次渲染、过滤、替换临时谱头或追加换行。
    var exportText: String? {
        !preview.isEmpty && issues.allSatisfy { $0.kind == .warning } ? preview : nil
    }
}

enum NMRTextReport {
    private static let locale = Locale(identifier: "en_US_POSIX")

    static func clean(_ s: String) -> String {
        s.trimmingCharacters(in: .whitespacesAndNewlines).precomposedStringWithCanonicalMapping
    }

    static func reportSolvent(_ raw: String?) -> String? {
        guard let raw,
              raw.rangeOfCharacter(from: CharacterSet.controlCharacters.union(.newlines)) == nil else {
            return nil
        }
        let s = clean(raw)
        let invalid = ["", "-", "—", "?", "unknown", "none", "off", "null", "n/a", "na",
                       "未知", "未指定", "tms", "dss", "tsp"]
        return invalid.contains(s.lowercased()) ? nil : s
    }

    private static func zeroText(_ s: String) -> Bool {
        s.allSatisfy { $0 == "-" || $0 == "." || $0 == "0" }
    }

    private static func fixed(_ x: Double, _ places: Int) -> String {
        let s = String(format: "%.\(places)f", locale: locale, x)
        return s.hasPrefix("-") && zeroText(s) ? String(s.dropFirst()) : s
    }

    private static func frequency(_ f: Double?, places: Int) -> String? {
        guard let f, f.isFinite, f > 0 else { return nil }
        let s = fixed(f, places)
        return zeroText(s) ? nil : s
    }

    private struct Position {
        let high: Double
        let low: Double
        let text: String
    }

    private static func position(_ shift: NMRShift, _ places: Int) -> Position? {
        guard let span = shift.interval else { return nil }
        let hi = span.upperBound, lo = span.lowerBound
        let h = fixed(hi, places)
        if case .center = shift { return Position(high: hi, low: lo, text: h) }
        let l = fixed(lo, places)
        return h == l ? nil : Position(high: hi, low: lo, text: h + "–" + l)
    }

    private struct Entry {
        let pos: Position
        let text: String
        let index: Int
    }

    private static func token(_ p: Position, _ attributes: [String], _ index: Int) -> Entry {
        let suffix = attributes.isEmpty ? "" : " (" + attributes.joined(separator: ", ") + ")"
        return Entry(pos: p, text: p.text + suffix, index: index)
    }

    private static func ordered(_ entries: [Entry]) -> [Entry] {
        entries.sorted {
            if $0.pos.high != $1.pos.high { return $0.pos.high > $1.pos.high }
            if $0.pos.low != $1.pos.low { return $0.pos.low > $1.pos.low }
            if $0.text != $1.text { return $0.text < $1.text }
            return $0.index < $1.index
        }
    }

    private static func jText(_ slots: [Double?], for m: NMRMultiplicity, places: Int) -> String? {
        guard !slots.isEmpty, slots.count <= m.maxJ else { return nil }
        var values: [String] = []
        for slot in slots {
            guard let j = slot, j.isFinite, j > 0 else { return nil }
            let s = fixed(j, places)
            guard !zeroText(s) else { return nil }
            values.append(s)
        }
        return "J = " + values.joined(separator: ", ") + " Hz"
    }

    private static func selection(_ d: NMRReportDraft, issues: inout [NMRIssue]) -> [Int] {
        let selected = d.spectra.indices.filter { d.spectra[$0].selected }
        func conflict(_ text: String, _ loc: NMRLocation? = nil) {
            issues.append(NMRIssue(kind: .conflict, location: loc, message: text))
        }
        if selected.isEmpty { conflict("请选一份实际采集的谱。¹H 或 ¹³C 任一份就够。") }
        if selected.count > 1 {
            let samples = selected.map { d.spectra[$0].sampleID }
            if samples.contains(nil) || Set(samples).count != 1 {
                conflict("合并要求已确认的同一样品。请取消附谱或换用正确的工程。")
            }
        }
        var sources = Set<UUID>(), nuclei = Set<NMRReportNucleus>()
        for i in selected {
            let s = d.spectra[i], loc = NMRLocation(spectrum: i, row: nil)
            if !sources.insert(s.id).inserted { conflict("采集 ID 重复；请取消重复谱。", loc) }
            if !nuclei.insert(s.nucleus).inserted { conflict("同一核种最多选一份谱。", loc) }
        }
        return selected.sorted {
            if d.spectra[$0].nucleus == d.spectra[$1].nucleus { return $0 < $1 }
            return d.spectra[$0].nucleus == .proton
        }
    }

    // MARK: - 已有的严格行级 API

    private static func entry(_ r: NMRRow, index: Int, nucleus: NMRReportNucleus, style: NMRTextStyle,
                              regions: [UUID: [NMRIntegral]], owners: [UUID: Set<UUID>],
                              issue: (NMRIssue.Kind, String) -> Void) -> Entry? {
        var valid = true
        func missing(_ reason: String) { valid = false; issue(.incomplete, reason) }

        if let reason = r.origin?.blocked {
            missing(reason + "。请在源工程修复，或取消纳入本行。")
            return nil
        }
        if !r.approved { missing("核对本行所列值后确认本行，或取消纳入。") }
        let pos = position(r.shift, nucleus == .proton ? style.protonPlaces : style.carbonPlaces)
        if pos == nil { missing("填写有限峰位，或填写两个显示时仍可区分的端点。") }

        var attributes: [String] = []
        if nucleus == .proton {
            if let m = r.multiplicity {
                if r.multiplicityApproved { attributes.append(m.rawValue) }
                else if r.approved { missing("核对裂分类型后重新确认本行。") }
            } else {
                missing("选择实际观察到的裂分；标一点不等于单峰。")
            }
            switch r.jReview {
            case .unreviewed:
                if !r.jHz.isEmpty || r.multiplicity?.permitsResolvedJ == true {
                    missing("请核对所列 J 或明确确认不列。")
                }
            case .unresolved:
                if !r.jHz.isEmpty || r.multiplicity?.permitsResolvedJ == true {
                    issue(.warning, "本行按已核对的不列 J 约定输出。")
                }
            case .approved:
                if let m = r.multiplicity, let j = jText(r.jHz, for: m, places: style.jPlaces) {
                    attributes.append(j)
                } else {
                    missing("J 的数量或数值不适用于当前裂分；须为显示时非零的正 Hz。")
                }
            }
            func unassigned() {
                if r.omitUnassignedH == true { issue(.warning, "本行未指派，正文不列 H。") }
                else { missing("关联积分并指派正整数 H，或明确选择不列氢数。") }
            }
            if let id = r.integralID {
                if let matches = regions[id], matches.count == 1 {
                    if (owners[id]?.count ?? 0) > 1 {
                        missing("不能将一整段积分分给多个纳入行。")
                    } else if let h = matches[0].assignedH {
                        if h <= 0 { missing("积分指派须为正整数 H。") }
                        else if r.omitUnassignedH == true { missing("已有 H 指派，请取消“不列氢数”并核对。") }
                        else { attributes.append("\(h)H") }
                    } else { unassigned() }
                } else { missing("关联积分不存在或 ID 不唯一。") }
            } else { unassigned() }
        } else if r.multiplicity != nil || r.jReview != .unreviewed || !r.jHz.isEmpty {
            issue(.warning, "¹³C 正文只列位移。")
        }
        guard valid, let p = pos else { return nil }
        return token(p, attributes, index)
    }

    @discardableResult
    static func confirmRow(_ k: Int, in spectrum: inout NMRSpectrum, style: NMRTextStyle) -> String? {
        guard spectrum.rows.indices.contains(k), spectrum.rows[k].include else { return "请先纳入本行。" }
        var row = spectrum.rows[k]
        guard spectrum.rows.filter({ $0.id == row.id }).count == 1 else { return "行 ID 重复。" }
        row.approved = true
        if spectrum.nucleus == .proton {
            row.multiplicityApproved = row.multiplicity != nil
            if row.jReview != .unresolved { row.jReview = row.jHz.isEmpty ? .unresolved : .approved }
        }
        var probe = spectrum
        probe.selected = true
        probe.rows[k] = row
        let loc = NMRLocation(spectrum: 0, row: k)
        let issues = render(NMRReportDraft(spectra: [probe], style: style)).issues
        if let blocker = issues.first(where: {
            $0.kind == .conflict || ($0.kind == .incomplete && $0.location == loc)
        }) { return blocker.message }
        spectrum.rows[k] = row
        return nil
    }

    static func render(_ draft: NMRReportDraft, completeOnly: Bool = false) -> NMRTextResult {
        var issues: [NMRIssue] = []
        let selected = selection(draft, issues: &issues)
        func note(_ kind: NMRIssue.Kind, _ text: String, _ at: NMRLocation? = nil) {
            issues.append(NMRIssue(kind: kind, location: at, message: text))
        }
        if !draft.style.valid(for: Set(selected.map { draft.spectra[$0].nucleus })) {
            note(.conflict, "请修正显示精度。")
        }
        guard issues.isEmpty else { return NMRTextResult(text: nil, issues: issues) }
        var lines: [String] = []
        for i in selected {
            let s = draft.spectra[i], at = NMRLocation(spectrum: i, row: nil)
            let f = frequency(s.observedMHz, places: draft.style.mhzPlaces)
            if f == nil { note(.incomplete, "填写本核种实际观测 MHz。", at) }
            let solvent = reportSolvent(s.solventDisplayName)
            if solvent == nil { note(.incomplete, "填写一行实际样品溶剂。", at) }
            if !s.rows.contains(where: { $0.include }) { note(.incomplete, "没有纳入行。", at) }
            let copies = Dictionary(grouping: s.rows.indices, by: { s.rows[$0].id })
            let regions = Dictionary(grouping: s.integrals, by: \.id)
            var owners: [UUID: Set<UUID>] = [:]
            for r in s.rows where r.include {
                if let id = r.integralID { owners[id, default: []].insert(r.id) }
            }
            var visited = Set<UUID>(), entries: [Entry] = []
            for k in s.rows.indices {
                let r = s.rows[k], loc = NMRLocation(spectrum: i, row: k)
                guard r.include, visited.insert(r.id).inserted else { continue }
                if let group = copies[r.id], group.count > 1 {
                    if group.contains(where: { $0 != k && s.rows[$0] != r }) {
                        note(.incomplete, "相同源行 ID 的副本有冲突。", loc)
                        continue
                    }
                    note(.warning, "相同副本只采用一次。", loc)
                }
                if let e = entry(r, index: k, nucleus: s.nucleus, style: draft.style,
                                 regions: regions, owners: owners, issue: { note($0, $1, loc) }) {
                    entries.append(e)
                }
            }
            var seen = Set<String>(), tokens: [String] = []
            for e in ordered(entries) {
                if seen.insert(e.text).inserted { tokens.append(e.text) }
                else { note(.warning, "相同显示项只列一次，未相加氢数。", NMRLocation(spectrum: i, row: e.index)) }
            }
            if let f, let solvent, !tokens.isEmpty {
                lines.append("\(s.nucleus.symbol) NMR (\(f) MHz, \(solvent)) δ " + tokens.joined(separator: ", ") + ".")
            }
        }
        let allowed = !lines.isEmpty && (completeOnly || !issues.contains(where: { $0.kind == .incomplete }))
        return NMRTextResult(text: allowed ? lines.joined(separator: "\n").precomposedStringWithCanonicalMapping : nil,
                             issues: issues)
    }

    // MARK: - 整稿事务

    // 上限是自动建议的保守范围，不是限制用户显式指派的 H 数。
    static func wholeTarget(_ x: Double?) -> Int? {
        guard let x, x.isFinite, (1...99).contains(x), x.rounded() == x else { return nil }
        return Int(x)
    }

    private struct Integrations {
        let spectrum: NMRSpectrum
        let regions: [UUID: [NMRIntegral]]
        let owners: [UUID: [Int]]
        let anchor: NMRIntegral?

        init(_ s: NMRSpectrum) {
            spectrum = s
            regions = Dictionary(grouping: s.integrals, by: \.id)
            var links: [UUID: [Int]] = [:]
            for k in s.rows.indices {
                if let id = s.rows[k].integralID { links[id, default: []].append(k) }
            }
            owners = links
            let anchors = s.integrals.filter { $0.referenceTarget != nil }
            anchor = anchors.count == 1 ? anchors[0] : nil
        }

        // 源是唯一、完整、可定量的实测区间；草稿编辑后仍须是同一归属。
        func matched(_ b: NMRIntegral) -> Bool {
            guard regions[b.id]?.count == 1, let indices = owners[b.id], indices.count == 1,
                  let k = indices.first, let lo = b.lowPPM, let hi = b.highPPM, lo < hi,
                  let area = b.signedArea, area.isFinite, area > 0 else { return false }
            let row = spectrum.rows[k]
            guard row.origin?.quantitativeRegionID == b.id, row.origin?.blocked == nil,
                  let p = row.shift.interval, lo <= p.lowerBound, p.upperBound <= hi else { return false }
            return !spectrum.rows.indices.contains { j in
                let other = spectrum.rows[j]
                guard j != k, other.include || other.origin?.shadowOf == nil,
                      let p = other.shift.interval else { return false }
                return (lo...hi).overlaps(p)
            }
        }

        func hydrogen(_ r: NMRRow, notes: inout [String]) -> String? {
            if r.omitUnassignedH == true {
                notes.append("按草稿选择不列 H")
                return nil
            }
            func explicit(_ h: Int?) -> String? {
                guard let h, h > 0 else { return nil }
                return "\(h)H"
            }
            guard let id = r.integralID else {
                if let h = explicit(r.explicitH) { return h }
                notes.append(r.explicitH == nil ? "无 H 指派" : "H 非正，未列")
                return nil
            }
            guard let group = regions[id], group.count == 1, owners[id]?.count == 1 else {
                notes.append("积分缺失、重复或被多行关联，未列 H")
                return nil
            }
            let b = group[0]
            if let h = b.assignedH {
                if let value = explicit(h) { return value }
                notes.append("积分指派不是正整数，未列 H")
                return nil
            }

            guard let a = anchor, let n = NMRTextReport.wholeTarget(a.referenceTarget),
                  a.assignedH == nil || a.assignedH == n,
                  matched(b), matched(a), let ratio = b.relativeArea, ratio.isFinite,
                  let h = NMRTextReport.wholeTarget(ratio.rounded()),
                  abs(ratio - Double(h)) <= min(0.10, 0.04 * Double(h)) else {
                notes.append("无明确 H 指派；未按面积推定")
                return nil
            }
            guard a.assignedH == n else {
                notes.append("若参考归一值确为已知 \(n)H，建议 \(h)H；尚未指明单位，正文不列")
                return nil
            }
            notes.append("正文的 \(h)H 为归一建议（参考 \(n)H）；可修改或不列")
            return "\(h)H"
        }
    }

    static func preview(_ draft: NMRReportDraft) -> NMRDraftText {
        var issues: [NMRIssue] = []
        let selected = selection(draft, issues: &issues)
        func note(_ kind: NMRIssue.Kind, _ text: String, _ at: NMRLocation?) {
            issues.append(NMRIssue(kind: kind, location: at, message: text))
        }

        var style = draft.style
        if !style.valid(for: Set(selected.map { draft.spectra[$0].nucleus })) {
            style = NMRTextStyle()
            note(.warning, "工程精度无效，本次预览与 TXT 均使用默认精度。", nil)
        }

        var lines: [String] = []
        for i in selected {
            let s = draft.spectra[i], at = NMRLocation(spectrum: i, row: nil)
            let f = frequency(s.observedMHz, places: style.mhzPlaces)
            let solvent = reportSolvent(s.solventDisplayName)
            if f == nil { note(.incomplete, "请填本核实际观测 MHz（正有限值，显示时不为零）。", at) }
            if solvent == nil { note(.incomplete, "请选择或输入实际样品溶剂，不是参考标准。", at) }
            let temporary = f == nil || solvent == nil
            let header = (temporary ? "〔临时谱头，不导出〕 " : "") +
                "\(s.nucleus.symbol) NMR (\(f ?? "待填") MHz, \(solvent ?? "待选溶剂")) δ "

            let measurements = Integrations(s)
            let copies = Dictionary(grouping: s.rows, by: \.id)
            let places = s.nucleus == .proton ? style.protonPlaces : style.carbonPlaces
            var entries: [Entry] = []
            for k in s.rows.indices {
                let r = s.rows[k], loc = NMRLocation(spectrum: i, row: k)
                if let blocked = r.origin?.blocked {
                    note(.warning, "本行未列：" + blocked, loc)
                    continue
                }
                guard r.include else { continue }
                guard copies[r.id]?.count == 1 else {
                    note(.warning, "本行 ID 不唯一，未列；请在源工程检查重复记录。", loc)
                    continue
                }
                var notes = r.origin?.reviewNotes ?? []
                let p: Position
                if let formatted = position(r.shift, places) {
                    p = formatted
                } else if let span = r.shift.interval, span.lowerBound < span.upperBound {
                    // 保留实测区间，不虚构中心，也不输出两个一样的端点。
                    let hi = span.upperBound, lo = span.lowerBound
                    let more = (places...6).compactMap { position(r.shift, $0) }.first
                    p = more ?? Position(high: hi, low: lo, text: "\(hi)–\(lo)")
                    notes.append("窄区间多保留了端点位数")
                } else {
                    note(.warning, "本行没有有限峰位或完整区间，未列；可在草稿编辑中修正。", loc)
                    continue
                }
                var attributes: [String] = []
                if s.nucleus == .proton {
                    if let m = r.multiplicity { attributes.append(m.rawValue) }
                    else { notes.append("裂分未定，不列类型") }

                    if r.jReview == .unresolved {
                        if !r.jHz.isEmpty { notes.append("按草稿选择不列 J") }
                    } else if !r.jHz.isEmpty {
                        if let basis = r.jBasisMHz, s.observedMHz != basis {
                            notes.append("观测频率与计算依据 \(basis) MHz 不符，不列旧 J")
                        } else if let m = r.multiplicity, let j = jText(r.jHz, for: m, places: style.jPlaces) {
                            attributes.append(j)
                        } else {
                            notes.append("J 的类型、数量、正号或精度不符，整组 J 未列")
                        }
                    } else if r.multiplicity?.permitsResolvedJ == true {
                        notes.append("无确定的 Hz，不列 J")
                    }
                    if let h = measurements.hydrogen(r, notes: &notes) { attributes.append(h) }
                }
                if !notes.isEmpty { note(.warning, notes.joined(separator: "；"), loc) }
                entries.append(token(p, attributes, k))
            }
            let excluded = s.rows.filter { !$0.include }.count
            if excluded > 0 { note(.warning, "\(excluded) 行未纳入，仍可在草稿编辑中查看。", at) }
            if entries.isEmpty {
                note(.incomplete, "本谱无纳入且可用的标记峰位。积分本身不是峰位；可修正选择或取消附谱。", at)
                lines.append(header + "〔无可列峰位〕")
            } else {
                // 不因小数位相同就吞掉不同 ID 的实测组，更不相加氢数。
                var seen = Set<String>()
                let tokens = ordered(entries).map { e -> String in
                    if !seen.insert(e.text).inserted {
                        note(.warning, "不同标记的显示项相同；请检查重合信号或提高精度。",
                             NMRLocation(spectrum: i, row: e.index))
                    }
                    return e.text
                }
                lines.append(header + tokens.joined(separator: ", ") + ".")
            }
        }
        let text = lines.isEmpty ? "〔未选择谱〕" : lines.joined(separator: "\n")
        return NMRDraftText(preview: text.precomposedStringWithCanonicalMapping, issues: issues)
    }
}
