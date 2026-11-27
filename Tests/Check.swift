import Foundation
import AppKit
import PDFKit

@main struct Check {
    static func require(_ ok: Bool, _ message: String) throws {
        if !ok { throw NMRError("CHECK FAILED: " + message) }
    }
    static func floorDiagnostics() throws {
        let n = 1536, den = Double(n - 1)
        let ppm = (0..<n).map { 12 - 15 * Double($0) / den }
        let peak = (0..<n).map { (736..<768).contains($0) ? 1.0 : 0.0 }
        func a(_ v: [Double]) -> NMRArrays { NMRArrays(ppm: ppm, real: v) }
        func d(_ v: [Double]) -> NMRAutoDecision { NMRFloor.decide(a(v)) }
        let small = peak.map { $0 + 0.0007 }
        let shelf = peak.indices.map { i in
            peak[i] + 0.0007 * Double(min(64, min(i, n - 1 - i))) / 64
        }
        try require([peak, small, shelf].allSatisfy { d($0) == .skipped(.floorBelowThreshold) },
                    "flat, sub-guard offset, and genuine low broad pedestal")
        try require(d(Array(repeating: 0, count: n)) == .skipped(.noPositiveSignal) &&
                    d(Array(repeating: 1, count: n)) == .skipped(.noPositiveSignal), "zero and DC-only")

        let drift = peak.indices.map { i in peak[i] + (0.01 + 0.008 * Double(i) / den) }
        let input = NMRProcessingInput.processed(nucleus: .proton, spectrum: a(drift))
        let hit = try NMRProcessingWorkflow.run(input, settings: .init(), action: .baselineOnly)
        guard case let .automatic(.affine(l, r, _, _)) = hit.baseline else { throw NMRError("Lost affine control") }
        let shrink = 0.0004 * drift.max()!
        try require(abs(l - (0.01 - shrink)) < 1e-12 && abs(r - (0.018 - shrink)) < 1e-12 &&
                    zip(hit.spectrum.real, peak).allSatisfy { abs($0 - $1 - shrink) < 1e-12 },
                    "same affine subtraction including conservative shrink")
        let saved = try JSONDecoder().decode(NMRProcessingSettings.self, from: JSONEncoder().encode(hit.settings))
        let replay = try NMRProcessingWorkflow.run(input, settings: saved, action: .replay)
        try require(replay.spectrum == hit.spectrum && replay.baseline == hit.baseline, "exact affine replay")
        var signed = drift; signed[128] -= 0.2; signed[129] -= 0.2
        try require(d(signed) == .skipped(.negative), "residual negative veto above amplitude guard")

        // Independent absorption lines, one explicitly negative. No imaginary samples.
        let pair = a(peak.indices.map { i -> Double in
            let u = Double(i - 448) / 1.3, v = Double(i - 1104) / 1.5
            return 1 / (1 + u*u) - 0.4 / (1 + v*v)
        })
        let realOnly = NMRProcessingInput.processed(nucleus: .proton, spectrum: pair)
        let keep = try NMRProcessingWorkflow.run(realOnly, settings: .init(), action: .baselineOnly)
        try require(keep.spectrum == pair && !keep.shouldJournal && !keep.phaseApplicable, "preserve signed fixture")
        do {
            _ = try NMRProcessingWorkflow.run(realOnly, settings: .init(), action: .phaseAndBaseline)
            throw NMRError("Phased a real-only spectrum")
        } catch NMRProcessingError.quadrature {}

        let json = #"{"baselinePolicy":"automatic","automaticBaselineV1":{"count":1536,"decision":{"skipped":{"_0":"weak"}}}}"#
        let old = try JSONDecoder().decode(NMRProcessingSettings.self, from: Data(json.utf8))
        let skip = try NMRProcessingWorkflow.run(input, settings: old, action: .replay)
        try require(skip.spectrum == a(drift) && skip.baseline == .automatic(.skipped(.weak)), "do not reinterpret V1")
        struct V1Fields: Decodable { let count: Int; let decision: NMRAutoDecision }
        for why in [NMRBaselineReason.floorBelowThreshold, .noPositiveSignal] {
            let receipt = NMRBaselineReceipt(count: n, decision: .skipped(why))
            let data = try JSONEncoder().encode(receipt)
            let plain = try JSONDecoder().decode(V1Fields.self, from: data)
            let rich = try JSONDecoder().decode(NMRBaselineReceipt.self, from: data)
            try require(plain.count == n && plain.decision == .skipped(.weak) && rich == receipt, "V1 skip + detail")
        }
    }
    @MainActor static func main() throws {
        try IntegralDragCheck.run()
        try textReportChecks()
        try floorDiagnostics()
        try ProcessingRegression.checkRegionalPhase()
        try ProcessingRegression.checkCurvedBaseline()
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at:tmp,withIntermediateDirectories:true)
        defer { try? FileManager.default.removeItem(at:tmp) }
        let points = tmp.appendingPathComponent("test.csv")
        try "ppm,intensity\n0,0\n0.3,0.6\n1,2\n2,4\n".write(to:points,atomically:true,encoding:.utf8)
        let table = try Reader.open(points)
        let direct = try process(table,Settings())
        try require(direct.ppm == [2,1,0.3,0], "CSV orientation")
        try require(abs(direct.area(0.2...1.5) - 2.21) < 1e-10, "partial trapezoids on a nonuniform axis")
        var settings = Settings(); settings.baseline = true; settings.offset = 1.25
        let corrected = try process(table,settings)
        try require(corrected.real.allSatisfy { abs($0) < 1e-8 } && corrected.ppm.first == 3.25, "baseline and referencing")
        try direct.csv().write(to:points,atomically:true,encoding:.utf8)
        let again = try process(Reader.open(points),Settings())
        try require(again.real == direct.real && again.ppm == direct.ppm,"CSV round trip")
        for text in ["ppm,intensity\n1,3\n1,4", "1,2\n0,nan", "ppm,intensity\n1,3\noops"] {
            try text.write(to:points,atomically:true,encoding:.utf8)
            do { _ = try Reader.open(points) } catch { continue }
            throw NMRError("Accepted a malformed spectrum.")
        }
        let n = 256, skip = 3.25
        let phases = (0..<(n+3)).map { 2 * Double.pi * (Double($0)-skip) / 8 }
        let fid = FID(r:phases.map(cos),i:phases.map(sin),width:4000,mhz:400,centerPPM:5,delay:skip)
        let ft = try fid.transform(lb:0,fill:1)
        let bin = ft.nearest(6.25)
        try require(abs(ft.real[bin]-255.5)<1e-8 && abs(ft.imag![bin])<1e-8, "complex transform, axis, fractional delay")
        var phase = Settings(); phase.fill = 1; phase.lb = 0; phase.p0 = 180
        let phased = try process(Dataset(name:"test",format:"complex",input:.fid(fid)),phase)
        try require(abs(phased.real[bin]+255.5)<1e-8, "phase rotation")
        let demo = try process(.demo,Settings())
        let a = demo.area(4.0...4.24), b = demo.area(1.95...2.15)
        try require(abs(a/b - 2.0/3.0) < 0.02,"demo quartet/singlet areas")
        let pdf = tmp.appendingPathComponent("spectrum.pdf")
        try PlotView.pdf(PlotState(spectrum:demo,window:0.8...4.5,peaks:[2.05],bands:[4.0...4.24],title:"Ethyl acetate"),to:pdf)
        let doc = PDFDocument(url:pdf)
        try require(doc?.pageCount == 1 && doc?.string?.contains("ppm") == true, "vector plot PDF with axis label")
        let pngState = PlotState(spectrum:demo,window:0.8...4.5,peaks:[2.05],bands:[4.0...4.24],title:"PNG check",bandLabels:["2"])
        for width in PlotExport.pngWidths {
            let url = tmp.appendingPathComponent("spectrum-\(width).png")
            try PlotExport.png(pngState,width:width,to:url)
            guard let bitmap = NSBitmapImageRep(data:try Data(contentsOf:url)) else { throw NMRError("Invalid PNG") }
            try require(bitmap.pixelsWide == width && bitmap.pixelsHigh == width / 2, "pixel dimensions")
            // The horizontal axis crosses both probes. A centered 900-point
            // plot inside an otherwise empty high-resolution bitmap fails here.
            for x in [width / 12, width * 11 / 12] {
                let hasInk = (0..<bitmap.pixelsHigh).contains { y in
                    guard let rgb = bitmap.colorAt(x:x,y:y)?.usingColorSpace(.deviceRGB) else { return false }
                    return min(rgb.redComponent, rgb.greenComponent, rgb.blueComponent) < 0.72
                }
                try require(hasInk, "plot spans requested PNG width")
            }
        }
        let count=8192, trueP0=115.0, trueP1 = -79.0
        var xx=[Double](), rr=[Double](), ii=[Double]()
        for i in 0..<count {
            let f=Double(i)/Double(count-1)
            var r=0.0, im=0.0
            for (center,height) in [(0.16,8.0),(0.32,1.5),(0.62,0.9),(0.84,0.6)] {
                let u=(f-center)/0.0014, h=height/(1+u*u)
                r += h; im += u*h
            }
            let phi = -(trueP0+trueP1*f)*Double.pi/180
            xx.append(12-15*f); rr.append(r*cos(phi)-im*sin(phi)); ii.append(r*sin(phi)+im*cos(phi))
        }
        let lineSpectrum=Spectrum(ppm:xx,real:rr,imag:ii)
        let estimate=try estimateSpectralPhase(lineSpectrum,initialFirstOrder:0)
        print("Known-phase test",estimate)
        try require(abs(estimate.p0-trueP0)<9 && abs(estimate.p1-trueP1)<14 && estimate.regions>=2 && estimate.fittedFirstOrder,
                    "multi-region zero and first-order phase estimation")
        // A compact pair has enough sign and line-shape information to phase
        // even when its spacing cannot constrain a credible full-band slope.
        let clusterLocations = [0.53, 0.57]
        let cluster = xx.indices.map { j -> (Double, Double) in
            let x = Double(j) / Double(count - 1)
            let left = (x - clusterLocations[0]) / 0.0007
            let right = (x - clusterLocations[1]) / 0.0009
            let a = 0.7 / (1 + left * left)
            let b = 1 / (1 + right * right)
            let theta = -(105.0 + 7.0 * x) * Double.pi / 180
            let absorption = a + b
            let dispersion = left * a + right * b
            return (absorption * cos(theta) - dispersion * sin(theta),
                    absorption * sin(theta) + dispersion * cos(theta))
        }
        let keptP1 = 12.0
        let compact = try estimateByEntropy(real:cluster.map { $0.0 }, imag:cluster.map { $0.1 },
                                            initialFirstOrder:keptP1)
        try require(!compact.fittedFirstOrder && compact.p1 == keptP1 && clusterLocations.allSatisfy { x in
            abs((compact.p0 + compact.p1 * x - 105 - 7 * x).remainder(dividingBy:360)) < 6
        }, "ACME recovers positive clustered absorption while retaining the supplied ramp")
        let blank = [Double](repeating:0,count:count)
        try require((try? estimateByEntropy(real:blank,imag:blank,initialFirstOrder:0)) == nil,
                    "ACME must abstain on a blank spectrum")
        let manual=try PhasePreview.render(lineSpectrum,p0:trueP0,p1:trueP1,offset:0.5,baseline:true)
        var set=Settings();set.p0=trueP0;set.p1=trueP1;set.offset=0.5;set.baseline=true
        let committed=try process(Dataset(name:"preview",format:"complex",input:.spectrum(lineSpectrum)),set)
        try require(manual.ppm==committed.ppm && zip(manual.real,committed.real).allSatisfy { abs($0-$1)<1e-9 },
                    "manual preview matches committed phase and baseline")
        let marks = [Mark(lo:4,hi:4),Mark(lo:1,hi:3),Mark(lo:2,hi:2)]
        var savedSettings = Settings(); savedSettings.p0 = -23; savedSettings.offset = 0.12
        let saved = try StudioProject(dataset:.demo,settings:savedSettings,marks:marks,window:0.7...5)
        let file = tmp.appendingPathComponent("roundtrip.nmrstudio")
        try saved.save(to:file)
        try saved.save(to:file)
        let restored = try StudioProject.load(from:file)
        try require(restored.settings == savedSettings && restored.marks.map(\.id) == marks.map(\.id) &&
                    restored.marks.map(\.hi) == marks.map(\.hi) && restored.zoomLow == 0.7 && restored.zoomHigh == 5,
                    "project settings, overlapping annotations, UUIDs and zoom")
        let reopened = try process(restored.dataset,restored.settings)
        let expected = try process(.demo,savedSettings)
        try require(reopened.real == expected.real && reopened.ppm == expected.ppm,"round-tripped full raw dataset")
        print("Passed project save, overwrite, reopen, annotations and fast phasing checks.")
        print("Passed FFT, fractional group delay, phase, baseline, referencing, signed integration, CSV and vector PDF checks.")
        let args = Array(CommandLine.arguments.dropFirst())
        if args.count >= 2 {
            let raw = try Reader.open(URL(fileURLWithPath:args[0]))
            let vendor = try process(Reader.open(URL(fileURLWithPath:args[1])),Settings())
            guard case .fid(let f) = raw.input else { throw NMRError("Expected the aspirin FID.") }
            let ftd = try f.transform(lb:0.3,fill:4)
            var diffs: [Double] = []
            for region in [2.1...2.5, 7.0...7.3, 7.3...7.5, 7.5...7.8, 8.0...8.3] {
                let hi = vendor.nearest(region.upperBound), lo = vendor.nearest(region.lowerBound)
                let ref = (hi...lo).max { vendor.real[$0] < vendor.real[$1] }!
                let bounds = ftd.nearest(region.upperBound)...ftd.nearest(region.lowerBound)
                let quad = ftd.imag!
                let rawPeak = bounds.max { hypot(ftd.real[$0],quad[$0]) < hypot(ftd.real[$1],quad[$1]) }!
                diffs.append(abs(vendor.ppm[ref]-ftd.ppm[rawPeak]))
            }
            print("Aspirin regional peak differences (ppm):",diffs)
            try require(diffs.allSatisfy { $0 < 0.015 },"raw/vendor peak registration")
        }
        for path in args.dropFirst(2) {
            let s = try process(Reader.open(URL(fileURLWithPath:path)),Settings())
            print("Read",s.ppm.count,"points from",URL(fileURLWithPath:path).deletingLastPathComponent().lastPathComponent)
        }
    }
}

extension Check {
    @MainActor static func textReportChecks() throws {
        let sample = UUID(), acquisition = UUID()
        // 人工测试信号：一个孤立峰与四条 1:3:3:1 的线。J 由实际分析器测出，
        // 不在报表适配器中塞入预期的 quartet 或 J。
        let x = (0...2048).map { 6 - Double($0) / 1024 }
        let centers = [5.75, 4.953125, 4.984375, 5.015625, 5.046875]
        let weights = [1.0, 1, 3, 3, 1]
        let y = x.map { u -> Double in
            var sum = 0.0
            for i in centers.indices {
                let z = (u - centers[i]) / 0.0035
                sum += weights[i] * exp(-0.5 * z * z)
            }
            return sum
        }
        func trace(_ revision: String) throws -> NMRSpectrum1D {
            try NMRSpectrum1D(spectrumID: acquisition.uuidString, shapeRevision: revision,
                              nucleus: "1H", observedMHz: 400, originPPM: x, phasedReal: y)
        }
        let t = try trace("v1"), offset = 0.25
        let display = Spectrum(ppm: x.map { $0 + offset }, real: y)
        let singlet = Mark(lo: 5.7, hi: 5.8), quartet = Mark(lo: 4.9, hi: 5.1)
        let marks = [singlet, quartet]
        func lookup(_ token: String) -> NMRMarkSnapshot? {
            guard let id = UUID(uuidString: token), let m = marks.first(where: { $0.id == id }) else { return nil }
            return NMRMarkSnapshot(id: token, spectrumID: acquisition.uuidString,
                                   signedArea: display.area((m.lo + offset)...(m.hi + offset)))
        }

        var f = NMRPeakFile(spectrumID: acquisition.uuidString)
        let sID = try f.add(NMRRawBox(ppm: NMRSpan(5.72, 5.78), intensity: NMRSpan(0.6, 1.1)),
                            clipped: false, trace: t)
        let qID = try f.add(NMRRawBox(ppm: NMRSpan(4.93, 5.07), intensity: NMRSpan(0.7, 3.2)),
                            clipped: false, trace: t)
        func build(_ active: NMRSpectrum1D, _ saved: NMRReportDraft? = nil) throws -> NMRReportDraft {
            try StudioReport.makeDraft(dataset: .demo, id: acquisition, sampleID: sample, nucleus: .proton,
                                       marks: marks, displayed: display, referenceDelta: offset, file: f,
                                       trace: active, traceKey: nil, from: saved)
        }
        try f.link(sID, to: lookup(singlet.id.uuidString), lookup: lookup)
        try f.setH(3, for: sID, trace: t, lookup: lookup)
        try f.approve(sID, trace: t, lookup: lookup, rawShiftOverride: nil, multOverride: nil, jsOverrideHz: nil)
        let excluded = try build(t)
        try require(excluded.spectra[0].rows[0].include && !f.groups[0].included,
                    "整稿从所有标记开始；不改变原生纳入位")
        try f.setIncluded(true, id: sID, trace: t, lookup: lookup)

        let native = try f.exportGroups(trace: t, referenceDelta: offset, lookup: lookup)
        try require(native[0].included && native[0].approvedShift != nil &&
                    !native[1].included && native[1].approvedShift == nil && native[1].approvedJsHz == nil,
                    "原生接口：已有审批与新框不同，新框不是已批准的导出值")

        var d = try build(t)
        try require(d.spectra.count == 1 && d.spectra[0].selected && d.spectra[0].nucleus == .proton,
                    "主谱单独，不生成附谱")
        var h = d.spectra[0]
        h.observedMHz = 400
        h.solventDisplayName = "CDCl₃"
        let proposed = h.rows[1]
        try require(h.rows[0].id == sID && h.rows[0].multiplicity == .s && h.rows[0].approved &&
                    proposed.id == qID && proposed.include && !proposed.approved &&
                    proposed.multiplicity == .q && proposed.jReview == .unreviewed &&
                    proposed.jHz.count == 1 && abs((proposed.jHz[0] ?? 0) - 12.5) < 0.01 &&
                    proposed.integralID == quartet.id && proposed.origin?.suggestedLink == true,
                    "实测 q 和 J 只作建议；整段积分仍须核对")
        d.spectra = [h]
        let quick = NMRTextReport.preview(d)
        let pendingText = "¹H NMR (400 MHz, CDCl₃) δ 6.00 (s, 3H), 5.25 (q, J = 12.5 Hz)."
        try require(quick.preview == pendingText && quick.exportText == quick.preview &&
                    !h.rows[1].approved && f.groups[1].approval == nil, "当前实测 q/J，无 H 也能确认整稿")

        var edited = d
        guard let tfa = StudioReferences.solventName("TFA-d"),
              StudioReferences.reportSolvents.contains(tfa) else { throw NMRError("缺少 TFA-d 菜单项") }
        edited.spectra[0].solventDisplayName = tfa
        try require(NMRTextReport.preview(edited).exportText == pendingText.replacingOccurrences(of: "CDCl₃", with: tfa)
                    && edited.spectra[0].rows == d.spectra[0].rows, "明确改溶剂只改谱头")
        edited.spectra[0].solventDisplayName = "自配 A/B"
        let expectedBytes = Data(pendingText.replacingOccurrences(of: "CDCl₃", with: "自配 A/B").utf8)
        let txt = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".txt")
        defer { try? FileManager.default.removeItem(at: txt) }
        let view = NMRTextReport.preview(edited)
        guard let payload = view.exportText else { throw NMRError("未得到已显示的正文") }
        let document = NMRUTF8Document(text: payload)
        try document.writeTXT(to: txt)
        try require(try Data(contentsOf: txt) == expectedBytes && Data(view.preview.utf8) == expectedBytes,
                    "真实写盘路径与预览逐字节一致，无 BOM、尾换行或注释")
        try require((try? document.writeTXT(to: txt.appendingPathExtension("nmrstudio"))) == nil, "拒绝非 TXT 路径")
        edited.spectra[0].observedMHz = nil
        edited.spectra[0].solventDisplayName = nil
        let waiting = NMRTextReport.preview(edited)
        try require(waiting.exportText == nil && waiting.preview.contains("临时谱头") &&
                    waiting.preview.contains("δ 6.00 (s, 3H), 5.25 (q)") &&
                    !waiting.preview.contains("CDCl"), "谱头不全仍有真实峰表")
        edited = d
        edited.spectra[0].rows[0].shift = .center(nil)
        edited.spectra[0].rows[1].jHz = [-12.5]
        let mixed = NMRTextReport.preview(edited)
        try require(mixed.exportText == "¹H NMR (400 MHz, CDCl₃) δ 5.25 (q)." &&
                    Set(mixed.issues.compactMap { $0.location?.row }) == Set([0, 1]),
                    "无位置的行与不可用的负 J 均提示，不阻断有效行也不取绝对值")
        edited.spectra[0].rows[1].include = false
        try require(NMRTextReport.preview(edited).exportText == nil, "没有可用标记不能导出")

        let unknownTrace = try NMRSpectrum1D(spectrumID: acquisition.uuidString, shapeRevision: "no-hz",
                                              nucleus: "1H", observedMHz: nil, originPPM: x, phasedReal: y)
        var pendingFile = NMRPeakFile(spectrumID: acquisition.uuidString)
        _ = try pendingFile.add(f.groups[0].rawBox, clipped: true, trace: unknownTrace)
        _ = try pendingFile.add(f.groups[1].rawBox, clipped: false, trace: unknownTrace)
        let peak = Mark(lo: centers[0], hi: centers[0])
        let fresh = Dataset(name: "fixture", format: "table", input: .spectrum(display))
        var rawDraft = try StudioReport.makeDraft(dataset: fresh, id: acquisition, sampleID: sample, nucleus: .proton,
                                                  marks: marks + [peak], displayed: display, referenceDelta: offset,
                                                  file: pendingFile, trace: unknownTrace, traceKey: nil, from: nil)
        try require(rawDraft.spectra[0].solventDisplayName == nil && rawDraft.spectra[0].rows.count == 3 &&
                    rawDraft.spectra[0].rows[2].origin?.shadowOf != nil && !rawDraft.spectra[0].rows[2].include,
                    "无样品溶剂时不预设，分峰与旧点不双列")
        rawDraft.spectra[0].solventDisplayName = "D₂O"
        rawDraft.spectra[0].observedMHz = 500
        try require(NMRTextReport.preview(rawDraft).exportText == "¹H NMR (500 MHz, D₂O) δ 6.03–5.97, 5.25 (q)." &&
                    rawDraft.spectra[0].rows[0].multiplicity == nil && rawDraft.spectra[0].rows[1].jHz.isEmpty,
                    "未审阅：不确定框用实测建议范围；未知 Hz 不按手填频率编 J，不把面积写成 H")

        let ref = IntegrationReference(markID: singlet.id, target: 3)
        var normalized = try StudioReport.makeDraft(dataset: .demo, id: acquisition, sampleID: sample, nucleus: .proton,
                                                     marks: marks, displayed: display, referenceDelta: offset,
                                                     file: f, trace: t, traceKey: nil, reference: ref, from: nil)
        normalized.spectra[0].observedMHz = 400; normalized.spectra[0].solventDisplayName = "D₂O"
        // 合成线面积之比 8:1；此处仅检验比例和归属，不代表化学指派。
        let normalizedText = NMRTextReport.preview(normalized)
        try require(normalizedText.exportText?.contains("12.5 Hz, 24H") == true &&
                    normalizedText.issues.contains { $0.message.contains("归一建议") } &&
                    normalized.spectra[0].integrals[1].assignedH == nil, "已知参考下的一对一建议不是永久指派")
        normalized.spectra[0].integrals[0].assignedH = nil
        try require(NMRTextReport.preview(normalized).exportText?.contains("24H") == false,
                    "单有相对归一值不能证明 H 单位")
        normalized.spectra[0].integrals[0].assignedH = 3
        normalized.spectra[0].rows[1].shift = .center(3.1)
        try require(NMRTextReport.preview(normalized).exportText?.contains("24H") == false, "移出区间不转移建议")

        let lostTrace = try StudioReport.makeDraft(dataset: .demo, id: acquisition, sampleID: sample, nucleus: .proton,
                                                   marks: marks + [peak], displayed: display, referenceDelta: offset,
                                                   file: f, trace: nil, traceKey: "unmounted", from: d)
        var lost = lostTrace.spectra[0]
        lost.solventDisplayName = "D₂O"; lost.observedMHz = 400
        try require(lost.rows.count == 3 && lost.rows[0].origin?.blocked != nil &&
                    NMRTextReport.preview(NMRReportDraft(spectra: [lost])).exportText == "¹H NMR (400 MHz, D₂O) δ 6.00.",
                    "失效组仍可见；独立点只有位置，不借用失效组的 H/裂分")

        // 缺新键的旧格式。严格路径不是新 sheet 的导出门槛。
        let legacyJSON = """
        {"spectra":[{"id":"\(acquisition.uuidString)","nucleus":"proton","selected":true,
        "observedMHz":400,"solventDisplayName":"D₂O","integrals":[],"rows":[{
        "id":"\(sID.uuidString)","include":true,"approved":false,"shift":{"center":{"_0":-0.1}},
        "multiplicityApproved":false,"jReview":"unreviewed","jHz":[]}]}],
        "style":{"protonPlaces":2,"carbonPlaces":1,"jPlaces":1,"mhzPlaces":0}}
        """
        let legacyDraft = try JSONDecoder().decode(NMRReportDraft.self, from: Data(legacyJSON.utf8))
        try require(NMRTextReport.preview(legacyDraft).exportText == "¹H NMR (400 MHz, D₂O) δ -0.10." &&
                    NMRTextReport.render(legacyDraft).text == nil, "旧 Codable、负 ppm、未逐行确认的单氢谱")

        var shifted = d
        shifted.spectra[0].rows[1].shift = .center(8)
        let moved = Spectrum(ppm: x.map { $0 + offset + 1 }, real: y)
        let rebased = try StudioReport.makeDraft(dataset: .demo, id: acquisition, sampleID: sample, nucleus: .proton,
                                                 marks: marks, displayed: moved, referenceDelta: offset + 1,
                                                 file: f, trace: t, traceKey: nil, from: shifted)
        try require(rebased.spectra[0].rows[1].shift == .center(6.25) && !rebased.spectra[0].rows[1].approved,
                    "参考坐标改变后不恢复旧位置或确认")

        try require(NMRTextReport.render(d).text == nil && NMRTextReport.confirmRow(1, in: &h, style: d.style) != nil,
                    "新行和未指派的积分不能悄悄通过")
        guard let qi = h.integrals.firstIndex(where: { $0.id == quartet.id }) else { throw NMRError("缺少原始积分") }
        h.integrals[qi].assignedH = 2
        try require(NMRTextReport.confirmRow(1, in: &h, style: d.style) == nil, "显式核对所列 J 与整行")
        d.spectra = [h]
        let hText = "¹H NMR (400 MHz, CDCl₃) δ 6.00 (s, 3H), 5.25 (q, J = 12.5 Hz, 2H)."
        func exact(_ draft: NMRReportDraft, _ expected: String) throws {
            guard let payload = NMRTextReport.render(draft).text else { throw NMRError("未得到正文：" + expected) }
            try require(NMRUTF8Document(text: payload).bytes == Data(expected.utf8),
                        "预览 / 文档 UTF-8 字节；不加 BOM、尾换行或其他核种")
        }
        try exact(d, hText)
        try require(f.groups[1].approval == nil && !f.groups[1].included, "未篡改原生审批记录")

        var c = NMRSpectrum(id: UUID(), sampleID: sample, nucleus: .carbon13, selected: true,
                            observedMHz: 100.61, solventDisplayName: "CDCl₃")
        c.rows = [NMRRow(id: UUID(), include: true, approved: true, shift: .center(18.22)),
                  NMRRow(id: UUID(), include: true, approved: true, shift: .center(173.83))]
        let cText = "¹³C NMR (101 MHz, CDCl₃) δ 173.8, 18.2."
        try exact(NMRReportDraft(spectra: [c]), cText)
        try exact(NMRReportDraft(spectra: [c, h]), hText + "\n" + cText)

        var optional = NMRSpectrum(id: UUID(), sampleID: nil, nucleus: .carbon13)
        try exact(NMRReportDraft(spectra: [h, optional]), hText)
        try require(NMRTextReport.preview(NMRReportDraft(spectra: [h, optional])).exportText == hText &&
                    NMRTextReport.preview(NMRReportDraft(spectra: [c, h])).exportText == hText + "\n" + cText,
                    "整稿：未选附谱不参与校验；选中同一样品时按核种顺序合并")
        try require(NMRTextReport.preview(NMRReportDraft(spectra: [h, h])).exportText == nil,
                    "重复采集或核种不能合并")
        optional.selected = true
        try require(NMRTextReport.preview(NMRReportDraft(spectra: [h, optional])).exportText == nil,
                    "不能确认不同或未知样品的双谱文本")
        try require(NMRTextReport.render(NMRReportDraft(spectra: [h, optional])).text == nil,
                    "选择了不同 / 未确认样品，阻止合并")
        var incomplete = c
        incomplete.rows = []; incomplete.observedMHz = nil; incomplete.solventDisplayName = nil
        try require(NMRTextReport.render(NMRReportDraft(spectra: [h, incomplete])).text == nil, "所选附谱不完整")
        incomplete.selected = false
        try exact(NMRReportDraft(spectra: [h, incomplete]), hText)
        var savedPair = d
        savedPair.spectra.append(c)
        let reopened = try build(t, savedPair)
        try require(reopened.spectra.count == 2 && !reopened.spectra[1].selected &&
                    reopened.spectra[1].rows == c.rows, "保留附谱内容，不继承双谱选择")
        try exact(reopened, hText)

        func blocked(_ change: (inout NMRSpectrum) -> Void) throws {
            var v = h
            change(&v)
            try require(NMRTextReport.render(NMRReportDraft(spectra: [v])).text == nil, "无效输入必须无正文")
        }
        try blocked { $0.observedMHz = .infinity }
        try blocked { $0.observedMHz = 0.001 }
        try blocked { $0.solventDisplayName = "A\nB" }
        try blocked { $0.solventDisplayName = nil }
        try blocked { $0.rows[1].shift = .bounds(5.2501, 5.2502) }
        try blocked { $0.rows[1].shift = .center(.nan) }
        try blocked { $0.rows[1].jHz = [nil] }
        try blocked { $0.rows[1].jHz = [0.0001] }
        try blocked { $0.rows[1].jHz = [7, 8] }
        try blocked { $0.rows[1].jReview = .unreviewed }
        try blocked { $0.rows[1].integralID = singlet.id }
        try blocked { $0.rows[1].integralID = UUID(); $0.rows[1].omitUnassignedH = true }
        try blocked { $0.integrals[qi].assignedH = -1; $0.rows[1].omitUnassignedH = true }
        try blocked { $0.rows[1].multiplicityApproved = false }
        try blocked { $0.rows[1].approved = false }
        var without = h
        without.rows[1].integralID = nil
        without.rows[1].omitUnassignedH = true
        without.rows[1].approved = false
        try require(NMRTextReport.render(NMRReportDraft(spectra: [without])).text == nil,
                    "单是允许不列 H 不等于行确认")
        try require(NMRTextReport.confirmRow(1, in: &without, style: d.style) == nil, "明确确认未指派行")
        try exact(NMRReportDraft(spectra: [without]), hText.replacingOccurrences(of: " Hz, 2H", with: " Hz"))
        let stale = try build(try trace("v2"), d)
        try require(stale.spectra[0].rows[0].origin?.blocked != nil && NMRTextReport.render(stale).text == nil,
                    "已过期分析不能通过恢复报表审批绕过")
        var staleSpec = stale.spectra[0]
        try require(NMRTextReport.confirmRow(0, in: &staleSpec, style: d.style) != nil, "报表内也不能确认失效源组")

        // 真实 Workbench 的旧点标记 / 积分路径，未创建任何原生峰组。
        let w = Workbench()
        w.select(.integral, region: 1.95...2.15)
        w.select(.peak, region: 2.0...2.1)
        var manual = try w.makeTextReport(nucleus: .proton)
        var m = manual.spectra[0]
        try require(manual.spectra.count == 1 && m.rows.count == 1 && m.integrals.count == 1 &&
                    m.rows[0].include && !m.rows[0].approved && m.rows[0].multiplicity == nil &&
                    m.rows[0].jHz.isEmpty && m.integrals[0].assignedH == nil, "独立旧点默认列位置，不猜 s、J 或 H")
        m.observedMHz = 400; m.solventDisplayName = "CDCl₃"
        m.rows[0].include = true
        try require(NMRTextReport.confirmRow(0, in: &m, style: manual.style) != nil, "手工点未核对")
        m.rows[0].multiplicity = .s
        m.rows[0].integralID = m.integrals[0].id
        m.integrals[0].assignedH = 3
        try require(NMRTextReport.confirmRow(0, in: &m, style: manual.style) == nil, "有意纳入并确认手工点")
        manual.spectra[0] = m
        w.saveTextReport(manual)
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".nmrstudio")
        defer { try? FileManager.default.removeItem(at: file) }
        try w.saveProject(to: file)
        let stored = try StudioProject.load(from: file)
        try require(stored.textReport == manual, "原有工程格式保留报表及原始快照")
        let restored = try w.makeTextReport(nucleus: .proton)
        try require(restored.spectra[0] == m, "不重加偏移，复用手工指派和审批")

        var range = h
        range.rows[0].shift = .bounds(6.25, 6.5)
        try exact(NMRReportDraft(spectra: [range]), hText.replacingOccurrences(of: "6.00", with: "6.50–6.25"))
        print("通过单氢谱、单碳谱、显式配对、峰组 / 手工点、工程复用及 UTF-8 报表检查。")
    }
}
