import Foundation

enum StudioReferences {
    private static let catalog = {
        var names = [String: String]()
        var aliases = [String: String]()
        var lines = [ReferenceLine]()
        let formatted = ["cdcl3":"CDCl₃", "dmso-d6":"DMSO-d₆", "cd3od":"CD₃OD",
                         "c6d6":"C₆D₆", "acetone-d6":"丙酮-d₆", "cd3cn":"CD₃CN", "d2o":"D₂O",
                         "cd2cl2":"CD₂Cl₂", "thf-d8":"THF-d₈", "toluene-d8":"甲苯-d₈", "tfe-d3":"TFE-d₃"]
        for solvent in SolventReferences.all {
            names[solvent.id] = formatted[solvent.id] ?? solvent.name
            for name in solvent.aliases + [solvent.id, solvent.name] { aliases[NRTFA.key(name)] = solvent.id }
            lines.append(contentsOf: solvent.lines)
        }
        try? NRTFA.install(displayByID: &names, aliasToID: &aliases, lines: &lines)
        let centers = Set(lines.filter { $0.nucleus == .carbon13 }.map(\.id))
        let targets = lines.map { NRTarget.catalog($0, displayByID: names, centerIDs: centers,
            conditionSensitiveIDs: ["d2o.proton.hdo", "tfe-d3.proton.oh"]) }
        return (names: names, aliases: aliases, targets: targets)
    }()

    static var targets: [NRTarget] { catalog.targets }

    // 溶剂目录，不是 targets（后者按参考线/核种/位点划分）。
    static let reportSolvents: [String] = catalog.names.keys.sorted().compactMap { catalog.names[$0] }

    static func solventID(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let name = raw.trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "<>")))
        return catalog.aliases[NRTFA.key(name)]
    }

    static func solventName(_ raw: String?) -> String? {
        if let id = solventID(raw) { return catalog.names[id] }
        guard let raw else { return nil }
        let name = raw.trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "<>")))
        return ["", "none", "off", "unknown"].contains(name.lowercased()) ? nil : name
    }
}

enum StudioReport {
    private static func shift(_ s: NMRChemicalShift?) -> NMRShift {
        switch s {
        case .point(let x): return .center(x)
        case .range(let r): return .bounds(r.low, r.high)
        case nil: return .center(nil)
        }
    }

    // 保留原生已审阅导出值的投影接口。这里传入的 approvedShift 已在显示坐标。
    static func spectrum(dataset: Dataset, id: UUID, sampleID: UUID, nucleus: NMRReportNucleus,
                         rows: [NMRExportGroup]) -> NMRSpectrum {
        var s = NMRSpectrum(id: id, sampleID: sampleID, nucleus: nucleus, selected: true,
                            observedMHz: dataset.observeMHz,
                            solventDisplayName: StudioReferences.solventName(dataset.solvent))
        var linked = Set<UUID>()
        for g in rows {
            let link = g.linkedMarkID.flatMap(UUID.init(uuidString:))
            if let link, linked.insert(link).inserted {
                s.integrals.append(NMRIntegral(id: link, label: "积分", assignedH: g.assignedH))
            }
            let m = g.approvedMultiplicity.flatMap { NMRMultiplicity(rawValue: $0.rawValue) }
            s.rows.append(NMRRow(id: g.groupID, include: g.included, approved: g.approvedShift != nil,
                                 shift: shift(g.approvedShift), multiplicity: m, multiplicityApproved: m != nil,
                                 jReview: g.approvedJsHz.map { $0.isEmpty ? .unresolved : .approved } ?? .unreviewed,
                                 jHz: (g.approvedJsHz ?? []).map(Optional.some), integralID: link))
        }
        return s
    }

    private static let explanations: [String: String] = [
        "Stale analysis: review the raw box on the current trace and remeasure": "峰组已过期，请在当前谱上重测原框",
        "Boxes or components in conflict: resolve before use": "框或分峰冲突，请在峰组编辑器消解",
        "Linked host integral is missing or invalid": "源积分缺失或无效",
        "Integral linked more than once": "源积分被重复关联",
        "H count requires a proton integral": "源 H 指派不是氢谱积分",
        "Drag truncated at plot boundary": "框选在图边界被截断",
        "Incomplete baseline flanks / data edge": "基线两翼不完整或靠近数据边缘",
        "Flat/clipped extremum (not picked)": "有平顶或截断的极值未拾取",
        "Possible unresolved shoulder": "可能有未分辨的肩峰",
        "Impulse / undersampled wing (not picked)": "有脉冲或采样不足的峰翼未拾取",
        "Line narrower than sampling limit (not picked)": "有低于采样宽度限制的线未拾取",
        "Shallow saddle or truncated wing": "峰间谷浅或峰翼被截断",
        "Asymmetric or uncertain half-height profile": "半高峰形不对称或不确定",
        "Low interpretation SNR": "用于判读裂分的信噪比偏低",
        "Half-height interval crosses x edge": "半高区间超出框选横向边界",
        "Mixed polarity": "分峰极性混杂",
        "Inconsistent component widths": "分峰宽度不一致",
        "Neighbors too close relative to FWHM or grid": "相邻线相对线宽或采样间距过近",
        "Interline valley not deep enough": "峰间谷不够深",
        "Uncertain or nonuniform adjacent spacings": "相邻线间距不确定或不均匀",
        "Nearby excluded line / possibly partial pattern": "附近有框外谱线，可能是部分裂分",
        "Unsupported component pattern": "分峰模式不在自动判读范围内",
        "Height ratios not first order": "强度比不符合一阶裂分"
    ]

    private static func explanation(_ raw: String) -> String { explanations[raw] ?? raw }

    // reviewReasons 是必要而非唯一条件。不根据组框宽度、积分或线数单独猜类型。
    private static func firstOrder(_ a: NMRPeakAnalysis) -> (m: NMRMultiplicity, gap: Double?)? {
        let p = a.components
        guard a.reviewReasons.isEmpty, let first = p.first, let last = p.last,
              p.allSatisfy({ $0.ppm.isFinite && $0.stepPPM.isFinite && $0.stepPPM > 0 &&
                  $0.signedHeight.isFinite && $0.signedHeight != 0 &&
                  ($0.signedHeight > 0) == (first.signedHeight > 0) }),
              a.adjacentPPM.count == p.count - 1 else { return nil }

        let m: NMRMultiplicity
        switch (a.suggestedMultiplicity, p.count) {
        case (.s, 1): return (.s, nil)
        case (.d, 2): m = .d
        case (.t, 3): m = .t
        case (.q, 4): m = .q
        default: return nil
        }
        let mean = (last.ppm - first.ppm) / Double(p.count - 1)
        guard mean.isFinite, mean > 0 else { return nil }
        for j in a.adjacentPPM.indices {
            let measured = p[j + 1].ppm - p[j].ppm
            let g = a.adjacentPPM[j]
            guard measured >= 6 * max(p[j].stepPPM, p[j + 1].stepPPM),
                  g.value.isFinite, abs(g.value - measured) <= max(16 * mean.ulp, mean * 1e-9),
                  g.uncertainty.isFinite, (0...(0.15 * mean)).contains(g.uncertainty),
                  abs(measured - mean) <= min(0.08 * mean, max(0.035 * mean, g.uncertainty)) else { return nil }
        }
        return (m, mean)
    }

    private static func measuredJ(_ a: NMRPeakAnalysis, gap: Double?) -> Double? {
        guard let gap, let f = a.stamp.observedMHz, f.isFinite, f > 0,
              a.computedJsHz.count == 1, let j = a.computedJsHz.first else { return nil }
        let expected = gap * f
        guard expected.isFinite, expected > 0, j.value.isFinite, j.value > 0,
              j.uncertainty.isFinite, j.uncertainty >= 0, j.uncertainty <= 0.25 * expected,
              abs(expected - j.value) <= max(16 * expected.ulp, expected * 1e-9) else { return nil }
        return j.value
    }

    private static func unique<T>(_ values: [T]?) -> T? {
        guard let values, values.count == 1 else { return nil }
        return values[0]
    }

    private static func readBand(_ m: Mark, display: Spectrum, delta: Double,
                                 reference: IntegrationReference?) -> NMRIntegral {
        var b = NMRIntegral(id: m.id, label: "无效区间")
        if let ref = reference, ref.markID == m.id, ref.target.isFinite {
            b.referenceTarget = ref.target
        }
        let lo = m.lo + delta, hi = m.hi + delta
        guard lo.isFinite, hi.isFinite, lo < hi else {
            b.note = "端点无效，未计算面积"
            return b
        }
        b.lowPPM = lo; b.highPPM = hi; b.label = "\(hi)–\(lo) ppm"
        guard display.range.contains(lo), display.range.contains(hi) else {
            b.note = "区间不完整地落在当前谱内，不使用截断面积"
            return b
        }
        let area = display.area(lo...hi)
        guard area.isFinite else { b.note = "当前有符号面积非有限值"; return b }
        b.signedArea = area
        if area <= 0 { b.note = "面积非正；保留符号，不取绝对值推 H，请检查相位与基线" }
        return b
    }

    static func makeDraft(dataset: Dataset, id: UUID, sampleID: UUID, nucleus: NMRReportNucleus,
                          marks: [Mark], displayed: Spectrum, referenceDelta: Double,
                          file: NMRPeakFile?, trace: NMRSpectrum1D?, traceKey: String?,
                          reference: IntegrationReference? = nil,
                          from saved: NMRReportDraft?) throws -> NMRReportDraft {
        guard referenceDelta.isFinite else { throw NMRError("参考坐标无效，不能投影到当前 ppm 轴。") }
        var source = spectrum(dataset: dataset, id: id, sampleID: sampleID, nucleus: nucleus, rows: [])
        source.sourceRevision = trace?.stamp.gridAndRealCheck ?? traceKey
        source.sourceOffsetPPM = referenceDelta
        source.solventDisplayName = NMRTextReport.reportSolvent(source.solventDisplayName)
        if source.observedMHz?.isFinite == false { source.observedMHz = nil }

        let groups = file?.groups ?? []
        let bands = marks.filter { !$0.isPeak }, points = marks.filter(\.isPeak)
        let markIDs = Dictionary(grouping: marks, by: \.id)
        let groupIDs = Dictionary(grouping: groups, by: \.id)
        source.integrals = bands.map { readBand($0, display: displayed, delta: referenceDelta, reference: reference) }
        let bandIndices = Dictionary(grouping: bands.indices, by: { bands[$0].id })
        func bandIndex(_ key: UUID) -> Int? {
            markIDs[key]?.count == 1 ? unique(bandIndices[key]) : nil
        }
        // 不从读数构造“峰”；不从悬空链接构造“积分”。
        let measured = source.integrals
        func lookup(_ token: String) -> NMRMarkSnapshot? {
            guard let key = UUID(uuidString: token), let j = bandIndex(key),
                  let area = measured[j].signedArea else { return nil }
            return NMRMarkSnapshot(id: token, spectrumID: id.uuidString, signedArea: area)
        }
        if let ref = reference, let j = bandIndex(ref.markID), let anchor = measured[j].signedArea,
           anchor != 0, ref.target.isFinite, ref.target > 0 {
            for i in measured.indices {
                if let area = measured[i].signedArea {
                    let v = (area / anchor) * ref.target
                    if v.isFinite { source.integrals[i].relativeArea = v }
                }
            }
        }

        let reservations = Dictionary(grouping: groups.indices, by: {
            groups[$0].linkedMarkID.flatMap(UUID.init(uuidString:))
        })
        // 这些诊断只否决积分依据，不会把当前谱上的可靠 ppm 一并丢弃。
        let integralProblems: Set<String> = ["Linked host integral is missing or invalid",
                                             "Integral linked more than once", "H count requires a proton integral"]
        var cleanPattern = Set<UUID>()
        for g in groups {
            let a = g.analysis
            var notes = a.reviewReasons.map(explanation)
            var blocked: String?
            var usableLink = true
            if file?.schemaVersion != 1 || file?.spectrumID != id.uuidString || groupIDs[g.id]?.count != 1 {
                blocked = "峰组版本、采集或标识不匹配"
            } else if let trace, let file {
                if let why = file.blockingReason(g, trace: trace, lookup: lookup) {
                    if integralProblems.contains(why) { notes.append(explanation(why)); usableLink = false }
                    else { blocked = explanation(why) }
                }
                if blocked == nil && (!g.rawBox.valid || !a.envelope.valid || a.components.isEmpty ||
                    !a.components.allSatisfy({ trace.ppm.indices.contains($0.sample) &&
                        g.rawBox.contains($0.ppm, $0.intensity) })) {
                    blocked = "当前分峰定位记录无效，请重测"
                }
            } else { blocked = "当前数据不能验证原分析，请在源工程重测" }

            let link = g.linkedMarkID.flatMap(UUID.init(uuidString:))
            if let link, reservations[Optional(link)]?.count != 1 {
                usableLink = false
                notes.append("同一积分有多个源链接")
            }
            var r = NMRRow(id: g.id, include: true, integralID: nucleus == .proton ? link : nil)
            if blocked == nil {
                let pattern = firstOrder(a)
                if pattern != nil { cleanPattern.insert(g.id) }
                let approval = g.approval.flatMap { $0.analysisID == a.id && $0.rawShift.valid ? $0 : nil }
                if g.approval != nil && approval == nil { notes.append("审批不对应当前分析，仅使用当前测量") }
                let raw = approval?.rawShift ?? a.suggestedShift
                let projected = raw.shifted(by: referenceDelta)
                if raw.valid && projected.valid { r.shift = shift(projected) }
                else { notes.append("未取得有效的参考后位移") }

                r.approved = approval != nil && r.shift.interval != nil
                if nucleus == .proton {
                    if let v = approval {
                        r.multiplicity = NMRMultiplicity(rawValue: v.multiplicity.rawValue)
                        r.multiplicityApproved = r.multiplicity != nil
                        r.jHz = v.jsHz.map { $0.isFinite ? $0 : nil }
                        r.jReview = v.jsHz.isEmpty ? .unresolved : .approved
                        if !v.jsHz.isEmpty && v.jsSource == .computed { r.jBasisMHz = a.stamp.observedMHz }
                    } else if let pattern {
                        r.multiplicity = pattern.m
                        if let j = measuredJ(a, gap: pattern.gap) {
                            r.jHz = [j]; r.jBasisMHz = a.stamp.observedMHz
                        } else if !a.computedJsHz.isEmpty {
                            notes.append("计算 J 与当前线数、间距或频率不符")
                        }
                    } else if notes.isEmpty {
                        notes.append("分量数或实测间距不足以支持一阶裂分")
                    }
                    if let h = g.assignedH {
                        if usableLink, h > 0, let link, let j = bandIndex(link), measured[j].signedArea != nil {
                            source.integrals[j].assignedH = h
                        } else { notes.append("源 H 指派没有可用的独立积分，未采用") }
                    }
                }
                if a.components.contains(where: { $0.signedHeight < 0 }) {
                    notes.append("含负向分峰，请检查相位；不据此推 H")
                }
            }
            r.origin = NMRRowOrigin(analysisID: a.id, sourceApproval: g.approval?.approvedAt,
                                    reviewNotes: notes, blocked: blocked, suggestedLink: false)
            source.rows.append(r)
        }

        // 仅去掉同一采样位置/分峰/组中心的旧点的默认勾选，不吞掉大框内的其他峰。
        let shadows: [UUID?] = points.map { m in
            guard m.lo.isFinite else { return nil }
            for k in groups.indices where source.rows[k].origin?.blocked == nil && source.rows[k].shift.interval != nil {
                let a = groups[k].analysis
                if a.components.contains(where: { abs(m.lo - $0.ppm) <= $0.stepPPM }) { return groups[k].id }
                if let step = a.components.map(\.stepPPM).min(),
                   groups[k].rawBox.ppm.contains(m.lo), abs(m.lo - a.midExtremaPPM.value) <= step {
                    return groups[k].id
                }
            }
            return nil
        }

        let spans = groups.map(\.rawBox.ppm).filter(\.valid) + points.indices.compactMap { k -> NMRSpan? in
            guard shadows[k] == nil, points[k].lo.isFinite else { return nil }
            return NMRSpan(points[k].lo, points[k].hi)
        }
        // 任一其他标记碰到区间、或任一其他积分碰到标记，都不自动归属。
        func geometric(_ span: NMRSpan, group: Int?) -> Int? {
            guard nucleus == .proton, span.valid else { return nil }
            let hits = bands.indices.filter {
                let b = bands[$0]
                return b.lo.isFinite && b.hi.isFinite && b.lo < b.hi && NMRSpan(b.lo, b.hi).meets(span)
            }
            guard let j = unique(hits), bandIndex(bands[j].id) == j, measured[j].signedArea != nil,
                  bands[j].lo <= span.low, bands[j].hi >= span.high else { return nil }
            if let used = reservations[Optional(bands[j].id)], unique(used) != group || group == nil { return nil }
            let region = NMRSpan(bands[j].lo, bands[j].hi)
            return spans.lazy.filter { region.meets($0) }.prefix(2).count == 1 ? j : nil
        }

        for k in groups.indices {
            let g = groups[k]
            guard var o = source.rows[k].origin, o.blocked == nil,
                  let j = geometric(g.rawBox.ppm, group: k) else { continue }
            let b = bands[j]
            if g.linkedMarkID == nil {
                source.rows[k].integralID = b.id
                source.rows[k].approved = false
                o = NMRRowOrigin(analysisID: o.analysisID, sourceApproval: o.sourceApproval,
                                 reviewNotes: o.reviewNotes, blocked: nil, suggestedLink: true)
            }
            let a = g.analysis
            if source.rows[k].integralID == b.id, cleanPattern.contains(g.id),
               a.components.allSatisfy({ $0.signedHeight > 0 }),
               let area = measured[j].signedArea, a.noiseScale.isFinite, a.noiseScale > 0,
               area > 5 * a.noiseScale * (b.hi - b.lo),
               let hi = measured[j].highPPM, let lo = measured[j].lowPPM {
                let p = displayed.nearest(hi), q = displayed.nearest(lo)
                if !displayed.real[min(p, q)...max(p, q)].contains(where: { $0 < -3 * a.noiseScale }) {
                    o.quantitativeRegionID = b.id
                }
            }
            source.rows[k].origin = o
        }

        for k in points.indices {
            let m = points[k], x = m.lo + referenceDelta
            let valid = x.isFinite && displayed.range.contains(x) && markIDs[m.id]?.count == 1
            let link = valid && shadows[k] == nil ? geometric(NMRSpan(m.lo, m.hi), group: nil).map { bands[$0].id } : nil
            var origin = NMRRowOrigin(analysisID: nil, sourceApproval: nil,
                                      reviewNotes: shadows[k] == nil ? [] : ["旧点与当前峰组同位，默认只列峰组"],
                                      blocked: valid ? nil : "点不在当前轴内或标记 ID 重复",
                                      suggestedLink: link != nil)
            origin.shadowOf = shadows[k]
            source.rows.append(NMRRow(id: m.id, include: shadows[k] == nil,
                                      shift: .center(valid ? x : nil), integralID: link, origin: origin))
        }

        // 更老的工程只存过原生 approved 字段，没有分析身份。仅用于识别基线。
        var oldProjection: NMRSpectrum?
        if let base = saved?.sourceSpectrum, base.sourceRevision == nil, base.sourceOffsetPPM == nil,
           let file, let trace, file.schemaVersion == 1, file.spectrumID == id.uuidString,
           let exports = try? file.exportGroups(trace: trace, referenceDelta: referenceDelta, lookup: lookup) {
            var p = spectrum(dataset: dataset, id: id, sampleID: sampleID, nucleus: nucleus, rows: exports)
            for k in exports.indices where exports[k].approvedJsHz == nil { p.rows[k].jReview = .unresolved }
            oldProjection = p
        }
        let live = restore(source, from: saved, oldProjection: oldProjection)
        let others = (saved?.spectra ?? []).filter { $0.id != id && $0.nucleus != nucleus }.map {
            var s = $0; s.selected = false; return s
        }
        return NMRReportDraft(spectra: [live] + others, style: saved?.style ?? NMRTextStyle(),
                              sourceSpectrum: source)
    }

    // 三方合并：source 始终是未编辑的当前事实，绝不拿保存的报告充当下一次的源。
    static func restore(_ source: NMRSpectrum, from draft: NMRReportDraft?,
                        oldProjection: NMRSpectrum? = nil) -> NMRSpectrum {
        guard let saved = unique(draft?.spectra.filter { $0.id == source.id && $0.nucleus == source.nucleus }) else {
            return source
        }
        var report = source
        guard let base = draft?.sourceSpectrum, base.id == source.id, base.nucleus == source.nucleus else {
            // 无基线不复活峰位/审批。保留已有的报表谱头；没有旧值时使用实际元数据。
            report.observedMHz = saved.observedMHz ?? source.observedMHz
            report.solventDisplayName = NMRTextReport.reportSolvent(saved.solventDisplayName) ?? source.solventDisplayName
            return report
        }
        if base.observedMHz == source.observedMHz { report.observedMHz = saved.observedMHz }
        if base.solventDisplayName == source.solventDisplayName { report.solventDisplayName = saved.solventDisplayName }
        let old = oldProjection.map { base.rows == $0.rows && base.integrals == $0.integrals } ?? false
        let sameFrame = base.sourceRevision == source.sourceRevision &&
            (base.sourceOffsetPPM == nil || base.sourceOffsetPPM == source.sourceOffsetPPM) &&
            base.observedMHz == source.observedMHz
        guard sameFrame || old else { return report }

        let before = Dictionary(grouping: base.integrals, by: \.id)
        let current = Dictionary(grouping: source.integrals, by: \.id)
        let edits = Dictionary(grouping: saved.integrals, by: \.id)
        func sameRegion(_ id: UUID?) -> Bool {
            guard let id else { return true }
            guard let a = unique(before[id]), let b = unique(current[id]) else { return false }
            // 上一代目录也保存了区间 label 和实际有符号面积。
            return a == b || (sameFrame && a.label == b.label && a.signedArea != nil &&
                a.signedArea == b.signedArea && a.assignedH == b.assignedH)
        }
        for i in report.integrals.indices {
            let id = report.integrals[i].id
            if sameRegion(id), let edit = unique(edits[id]) { report.integrals[i].assignedH = edit.assignedH }
        }

        let beforeRows = Dictionary(grouping: base.rows, by: \.id)
        let savedRows = Dictionary(grouping: saved.rows, by: \.id)
        for i in report.rows.indices {
            var n = source.rows[i]
            guard let p = unique(beforeRows[n.id]), let e = unique(savedRows[n.id]) else { continue }
            let sameMeasurement = sameFrame && p.shift == n.shift &&
                p.origin?.analysisID == n.origin?.analysisID && p.origin?.sourceApproval == n.origin?.sourceApproval &&
                p.origin?.blocked == n.origin?.blocked
            let legacy = old && p.approved && n.origin?.sourceApproval != nil && n.origin?.blocked == nil
            guard sameMeasurement || legacy else { continue }
            if e.include != p.include { n.include = e.include }
            guard n.origin?.blocked == nil else { report.rows[i] = n; continue }

            let linksOK = sameRegion(p.integralID) && sameRegion(e.integralID)
            if sameMeasurement && p == source.rows[i] && linksOK &&
                base.integrals == source.integrals {
                // 所有依据未变时，包括老编辑器手动核对的值，原样往返。
                var exact = e
                exact.origin = n.origin
                report.rows[i] = exact
                continue
            }
            if sameMeasurement && e.shift != p.shift { n.shift = e.shift }
            if e.multiplicity != p.multiplicity { n.multiplicity = e.multiplicity }
            if e.jHz != p.jHz || e.jReview != p.jReview {
                n.jHz = e.jHz; n.jBasisMHz = e.jBasisMHz
                n.jReview = e.jReview == .unresolved ? .unresolved : .unreviewed
            }
            if linksOK {
                if e.integralID != p.integralID { n.integralID = e.integralID }
                if e.omitUnassignedH != p.omitUnassignedH { n.omitUnassignedH = e.omitUnassignedH }
                if sameMeasurement && e.explicitH != p.explicitH { n.explicitH = e.explicitH }
            }
            if n != source.rows[i] {
                n.approved = false; n.multiplicityApproved = false
                if n.jReview == .approved { n.jReview = .unreviewed }
            }
            report.rows[i] = n
        }
        return report
    }

    static func companion(url: URL, sampleID: UUID, excluding acquisition: UUID,
                          nucleus: NMRReportNucleus) throws -> NMRSpectrum {
        let p = try StudioProject.load(from: url)
        guard let id = p.spectrumID, id != acquisition else {
            throw NMRError("请选择独立采集的另一份工程，不能把本谱加入两次。")
        }
        let native = p.dataset.nucleus
        let known = nucleus == .proton ? native == .proton : native == .carbon13
        let primary = p.textReport?.spectra.first
        let userIdentified = native == .unknown && primary?.id == id && primary?.nucleus == nucleus
        guard known || userIdentified else {
            throw NMRError("请选择 \(nucleus.symbol) 工程。未知核种须先在该工程选择核种并保存草稿。")
        }
        let doc = try StudioImport.replay(p.dataset, settings: p.settings, id: id)
        let draft = try makeDraft(dataset: p.dataset, id: id, sampleID: sampleID, nucleus: nucleus,
                                  marks: p.marks, displayed: doc.spectrum, referenceDelta: doc.settings.offset,
                                  file: p.peaks, trace: doc.peakTrace, traceKey: p.traceKey,
                                  reference: p.reference, from: p.textReport)
        var result = draft.spectra[0]
        result.selected = false
        return result
    }
}
