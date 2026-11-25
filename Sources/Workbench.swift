import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct Mark: Identifiable, Codable {
    var id = UUID()
    let lo, hi: Double // Stored on the original reference scale.
    var isPeak: Bool { lo == hi }
}
@MainActor final class Workbench: ObservableObject {
    @Published var dataset = Dataset.demo
    @Published var spectrum: Spectrum
    @Published var settings = Settings()
    @Published var applied = Settings()
    @Published var window: ClosedRange<Double>
    @Published var marks = [Mark]() {
        didSet {
            if let id = selectedAnnotationID, !marks.contains(where: { $0.id == id }) {
                selectedAnnotationID = nil
            }
            peakWorkspace?.hostMarksChanged()
        }
    }
    @Published var tool = Tool.zoom
    @Published var error: String?
    @Published var busy = false
    @Published var status = "模拟谱已载入"
    @Published private(set) var documentRevision = UUID()
    @Published private(set) var calibration: ShiftCalibrationRecord?
    @Published private(set) var analysis = NMRAnalysisRecord()
    @Published private(set) var traceKey = UUID().uuidString
    @Published private(set) var peakWorkspace: NMRPeakWorkspace?
    @Published private(set) var peakIndex: NRPeakIndex?
    @Published private(set) var originalPPM: [Double]
    @Published private(set) var spectrumID = UUID()
    @Published private(set) var selectedAnnotationID: UUID? {
        didSet { if selectedAnnotationID != oldValue { peakWorkspace?.hostMarksChanged() } }
    }
    var selectedAnnotation: Mark? {
        guard let id = selectedAnnotationID else { return nil }
        return marks.first { $0.id == id }
    }
    var selectedIntegralID: UUID? {
        get { selectedAnnotation.flatMap { $0.isPeak ? nil : $0.id } }
        set {
            selectedAnnotationID = newValue.flatMap { id in
                marks.first { $0.id == id && !$0.isPeak }?.id
            }
        }
    }
    func pickAnnotation(_ id: UUID?, at version: StudioAnnotationVersion) {
        guard accepts(version) else { return }
        if let id, !marks.contains(where: { $0.id == id }) { return }
        if id != selectedAnnotationID { selectedAnnotationID = id }
    }

    private(set) var peakBinding = UUID()
    private var unmountedFile: NMRPeakFile?
    private var peakFileForStorage: NMRPeakFile? { peakWorkspace?.file ?? unmountedFile }
    var unmountedGroupCount: Int { unmountedFile?.groups.count ?? 0 }
    @Published private(set) var referenceEdit: NRReferenceEdit?
    @Published private(set) var textReport: NMRReportDraft?
    private var referenceHistoryID: UUID?
    private var rawImport: StudioRawImport?
    private let importer = NMRAutoOpen(host: StudioImport())
    private var job = UUID()
    private var projectURL: URL?
    @Published private(set) var reference: IntegrationReference?
    @Published private(set) var journal = SessionJournal()
    @Published private(set) var previewSpectrum: Spectrum?
    private var previewOffset = 0.0
    @Published var showHistory = false
    @Published var pngWidth = 2400
    private var phaseCache: (lb: Double, fill: Int, data: Spectrum)?
    private var previewTask: Task<Void, Never>?
    private var savedMarker: SessionJournal.SaveMarker?
    var dirty: Bool {
        savedMarker != journal.saveMarker
    }
    private var snapshot: SessionSnapshot {
        SessionSnapshot(settings: applied, marks: marks, reference: reference,
                        calibration: calibration, analysis: analysis, peakFile: peakFileForStorage,
                        referenceEdit: referenceEdit, referenceHistoryID: referenceHistoryID, textReport: textReport,
                        traceKey: traceKey,
                        window: NMRBand(window.lowerBound, window.upperBound))
    }
    var hasDraft: Bool { settings != applied }
    private func record(_ text: String) { journal.record(before:snapshot, description:text) }
    var displayOffset: Double { previewSpectrum == nil ? applied.offset : previewOffset }


    init() {
        let prepared = try! StudioImport.replay(.demo)
        spectrum = prepared.spectrum; window = prepared.spectrum.range
        originalPPM = prepared.originalPPM
        installDocument(prepared, url: nil, message: "模拟氢谱已载入")
    }
    var raw: Bool { if case .fid = dataset.input { return true }; return false }
    var complex: Bool { if case .spectrum(let s) = dataset.input { return s.imag != nil }; return true }
    var plot: PlotState { annotationPlot(selecting: selectedAnnotationID) }
    func bounds(_ m: Mark) -> ClosedRange<Double> { (m.lo+applied.offset)...(m.hi+applied.offset) }
    func openPanel() {
        let p = NSOpenPanel()
        p.canChooseDirectories = true; p.canChooseFiles = true
        p.prompt = "打开"; p.message = "选择 Bruker 实验文件夹、fid、1r、双列谱图或 NMR Studio 工程。"
        if p.runModal() == .OK, let u = p.url { requestLoad(u) }
    }
    func mayReplace() -> Bool {
        guard !busy else { return false }
        guard dirty || hasDraft else { return true }
        let alert = NSAlert()
        alert.messageText = "保存当前工程的更改？"
        alert.informativeText = hasDraft ? "当前仍有未应用的参数。取消后可应用参数，再保存工程。" : "工程包含尚未保存的处理或测量记录。"
        if !hasDraft { alert.addButton(withTitle:"保存工程") }
        let cancel = alert.addButton(withTitle:"取消"); cancel.keyEquivalent = "\u{1b}"
        let discard = alert.addButton(withTitle:"放弃更改")
        let choice = alert.runModal().rawValue - NSApplication.ModalResponse.alertFirstButtonReturn.rawValue
        guard alert.buttons.indices.contains(choice) else { return false }
        if alert.buttons[choice] === discard { return true }
        if alert.buttons[choice] === cancel { return false }
        return save()
    }
    func requestLoad(_ url: URL?) { if mayReplace() { load(url) } }
    func load(_ url: URL?) {
        cancelPreview()
        importer.cancel()
        let id = UUID()
        job = id; busy = true; error = nil
        if let url {
            importer.open(NMROpenRequest(url), commit: { [weak self] opened in
                guard let self, self.job == id else { return }
                self.installDocument(opened.document, url: url, message: opened.status)
                self.busy = false
            }, failure: { [weak self] reason in
                guard let self, self.job == id else { return }
                self.error = reason
                self.busy = false
            })
        } else {
            Task {
                do {
                    let doc = try await Task.detached(priority: .userInitiated) { try StudioImport.replay(.demo) }.value
                    guard job == id else { return }
                    installDocument(doc, url: nil, message: "模拟氢谱已载入")
                } catch { if job == id { self.error = error.localizedDescription } }
                if job == id { busy = false }
            }
        }
    }

    private func installDocument(_ doc: StudioImportSnapshot, url: URL?, message: String) {
        let project = doc.project
        dataset = doc.dataset; spectrum = doc.spectrum; originalPPM = doc.originalPPM
        spectrumID = doc.spectrumID; peakIndex = doc.peakIndex
        window = spectrum.range
        settings = doc.settings; applied = doc.settings
        marks = project?.marks ?? []; tool = .zoom
        selectedIntegralID = nil
        documentRevision = UUID()
        calibration = project?.calibration; referenceEdit = project?.referenceEdit; referenceHistoryID = nil
        textReport = project?.textReport
        if let stored = project?.analysis { analysis = stored }
        else {
            var initial = NMRAnalysisRecord()
            initial.marksOriginalPPM = marks.filter(\.isPeak).map(\.lo)
            analysis = initial
        }
        traceKey = project?.traceKey ?? UUID().uuidString
        projectURL = project == nil ? nil : url
        phaseCache = nil
        reference = project?.reference
        rawImport = doc.rawImport
        installPeakWorkspace(trace: doc.peakTrace, file: project?.peaks)
        let events = project?.history ?? doc.rawImport.map { [OperationRecord(id: UUID(), date: Date(), text: $0.auditNote)] } ?? []
        journal.start(history: events)
        savedMarker = journal.saveMarker
        if let p = project {
            let lo = max(p.zoomLow, spectrum.range.lowerBound), hi = min(p.zoomHigh, spectrum.range.upperBound)
            if lo < hi { window = lo...hi }
        }
        status = message
    }

    private func installPeakWorkspace(trace: NMRSpectrum1D?, file: NMRPeakFile?) {
        let token = UUID(), doc = documentRevision, sid = spectrumID.uuidString
        peakBinding = token
        guard let trace, trace.stamp.spectrumID == sid,
              file == nil || file?.spectrumID == sid else {
            unmountedFile = file
            peakWorkspace = nil
            return
        }
        unmountedFile = nil
        let current: () -> Workbench? = { [weak self] in
            guard let self, self.peakBinding == token, self.documentRevision == doc,
                  self.spectrumID.uuidString == sid, self.peakWorkspace?.file.spectrumID == sid else { return nil }
            return self
        }
        peakWorkspace = NMRPeakWorkspace(trace: trace, referenceDelta: applied.offset,
            file: file ?? NMRPeakFile(spectrumID: sid),
            selectedMark: {
                guard let host = current(), let id = host.selectedIntegralID else { return nil }
                return host.integralSnapshot(id.uuidString)
            }, lookupMark: { current()?.integralSnapshot($0) }, willCommit: { title in
                guard let host = current(), !host.busy, !host.hasDraft else {
                    throw NMRError("峰组工作区已变更，或谱图正在更新。")
                }
                host.record(title)
            })
    }

    func integralSnapshot(_ token: String) -> NMRMarkSnapshot? {
        guard let id = UUID(uuidString: token), let mark = marks.first(where: { $0.id == id && !$0.isPeak }) else { return nil }
        return NMRMarkSnapshot(id: token, spectrumID: spectrumID.uuidString, signedArea: spectrum.area(bounds(mark)))
    }

    private func installSpectrum(_ new: Spectrum, settings: Settings) {
        let delta = settings.offset - applied.offset
        let lo = max(new.range.lowerBound, window.lowerBound + delta)
        let hi = min(new.range.upperBound, window.upperBound + delta)
        window = lo < hi ? lo...hi : new.range
        if new.ppm != spectrum.ppm || new.real != spectrum.real { traceKey = UUID().uuidString }
        applied = settings; self.settings = settings; spectrum = new
        try? peakWorkspace?.setReferenceDelta(settings.offset)
    }

    func apply(_ new: Settings, action: String = "处理", operation: NMRProcessingAction = .applySettings) {
        guard !busy else { return }
        cancelPreview()
        let id = UUID(), d = dataset
        job = id; busy = true
        Task {
            do {
                let result = try await Task.detached(priority: .userInitiated) {
                    try runProcessing(d, new, action: operation)
                }.value
                guard job == id else { return }
                if result.shouldJournal && applied != result.settings {
                    let diff = SessionJournal.changeDescription(from: applied, to: result.settings)
                    record(action + " · " + diff + " · " + result.message)
                    if applied.offset != result.settings.offset { calibration = nil }
                    let oldFile = peakFileForStorage
                    originalPPM = result.originalPPM
                    installSpectrum(result.displaySpectrum, settings: result.settings)
                    let updated = StudioImportSnapshot(dataset: dataset, settings: applied, spectrum: spectrum,
                                                       originalPPM: originalPPM, spectrumID: spectrumID)
                    peakIndex = updated.peakIndex
                    installPeakWorkspace(trace: updated.peakTrace, file: oldFile)
                } else {
                    settings = applied
                }
                status = result.message
                if let fit = result.fit {
                    status = "调相已应用（\(fit.regions) 个峰区" + (fit.fittedFirstOrder ? "）" : "，保留 ph1）")
                    if operation == .phaseAndBaseline { status += " · " + result.baseline.title }
                }
            } catch {
                if job == id { self.error = error.localizedDescription; settings = applied }
            }
            if job == id { busy = false }
        }
    }

    func calibrate(_ proposed: ShiftCalibrationRecord) throws {
        guard !busy, !hasDraft, proposed.previousOffsetPPM == applied.offset,
              proposed.offsetPPM.isFinite, abs(proposed.offsetPPM) <= 1e5 else {
            throw NMRError("谱图状态已改变或偏移超出可用范围，请重新定标。")
        }
        guard calibration != proposed || applied.offset != proposed.offsetPPM else { return }
        let raw = originalPPM
        _ = try CalibrationAxis(rawDescendingPPM: raw).displayedRange(offset: proposed.offsetPPM)
        let axis = raw.map { $0 + proposed.offsetPPM }
        let result = Spectrum(ppm: axis, real: spectrum.real)
        var new = applied
        new.offset = proposed.offsetPPM
        record(String(format: "化学位移定标 · %@ · %.5f → %.5f ppm",
                      proposed.reference.material, proposed.measuredDisplayPPM, proposed.targetPPM))
        calibration = proposed
        referenceEdit = nil; referenceHistoryID = nil
        installSpectrum(result, settings: new)
        status = String(format: "定标已应用 · 累计偏移 %+.5f ppm", new.offset)
    }

    func resetCalibration() {
        guard !busy, !hasDraft, applied.offset != 0 || calibration != nil else { return }
        let axis = originalPPM
        guard (try? CalibrationAxis(rawDescendingPPM: axis).displayedRange(offset: 0)) != nil else {
            error = "原始 ppm 轴无法恢复。"; return
        }
        var new = applied; new.offset = 0
        record("重置化学位移定标")
        calibration = nil
        referenceEdit = nil; referenceHistoryID = nil
        installSpectrum(Spectrum(ppm: axis, real: spectrum.real), settings: new)
        status = "化学位移定标已重置"
    }

    func applyAnalysis(_ next: NMRAnalysisRecord) {
        guard !busy, !hasDraft else { return }
        if let gain = next.displayGain {
            let maxMagnitude = spectrum.real.reduce(0) { max($0, abs($1)) }
            guard gain.isFinite, gain > 0, maxMagnitude * gain < Double.greatestFiniteMagnitude / 4 else {
                error = "缩放后的强度超出显示范围。"; return
            }
        }
        let oldBand = analysisViewRecord.cropOriginalPPM
        record("更新区域分析")
        // The analysis view appends the evidence after its validation callbacks.
        // Commit the evidence and main-list mark in this same undo step.
        for evidence in next.integrals.dropFirst(analysis.integrals.count) where evidence.traceKey == traceKey {
            let mark = Mark(lo: evidence.originalPPM.lo, hi: evidence.originalPPM.hi)
            marks.append(mark)
            if evidence.setsReference, let target = evidence.relative?.reference.target {
                reference = IntegrationReference(markID: mark.id, target: target)
            }
        }
        for ppm in next.marksOriginalPPM where !marks.contains(where: { $0.isPeak && $0.lo == ppm }) {
            marks.append(Mark(lo: ppm, hi: ppm))
        }
        let deleted = Set(analysis.marksOriginalPPM).subtracting(next.marksOriginalPPM)
        marks.removeAll { $0.isPeak && deleted.contains($0.lo) }
        if next.cropOriginalPPM != oldBand {
            if let band = next.cropOriginalPPM {
                let lo = max(spectrum.range.lowerBound, band.lo + applied.offset)
                let hi = min(spectrum.range.upperBound, band.hi + applied.offset)
                if lo < hi { window = lo...hi }
            } else { window = spectrum.range }
        }
        analysis = next
        status = "区域分析已更新"
    }

    var analysisViewRecord: NMRAnalysisRecord {
        var result = analysis
        if result.cropOriginalPPM == nil && window != spectrum.range {
            result.cropOriginalPPM = NMRBand(window.lowerBound - applied.offset, window.upperBound - applied.offset)
        }
        return result
    }

    func select(_ tool: Tool, region: ClosedRange<Double>) {
        guard !busy else { return }
        switch tool {
        case .zoom:
            let delta = displayOffset - applied.offset
            let lo = max(spectrum.range.lowerBound, region.lowerBound - delta)
            let hi = min(spectrum.range.upperBound, region.upperBound - delta)
            guard lo < hi, spectrum.nearest(hi) != spectrum.nearest(lo) else { return }
            window = lo...hi
        case .peak:
            let range = spectrum.nearest(region.upperBound)...spectrum.nearest(region.lowerBound)
            guard let index = range.max(by:{ abs(spectrum.real[$0]) < abs(spectrum.real[$1]) }) else { return }
            let value = spectrum.ppm[index]-applied.offset
            guard !marks.contains(where:{ $0.isPeak && $0.lo == value }) else { return }
            record(String(format:"标峰 %.5f ppm", spectrum.ppm[index]))
            marks.append(Mark(lo:value,hi:value))
            analysis.marksOriginalPPM.append(value)
        case .integral:
            guard region.lowerBound < region.upperBound else { return }
            record(String(format:"新增积分 %.5f 至 %.5f ppm", region.upperBound, region.lowerBound))
            marks.append(Mark(lo:region.lowerBound-applied.offset,hi:region.upperBound-applied.offset))
        }
    }
    @discardableResult func save(asNew: Bool = false) -> Bool {
        guard !busy else { return false }
        guard !hasDraft else { error = "请先应用或放弃预览参数，再保存工程。"; return false }
        var dest = asNew ? nil : projectURL
        if dest == nil {
            let p = NSSavePanel()
            p.allowedContentTypes = [UTType(filenameExtension:"nmrstudio") ?? .data]
            p.nameFieldStringValue = dataset.name + ".nmrstudio"
            guard p.runModal() == .OK else { return false }
            dest = p.url
        }
        guard let url = dest else { return false }
        do {
            try saveProject(to:url)
            status = "工程已保存 · " + url.lastPathComponent
            return true
        } catch { self.error = error.localizedDescription; return false }
    }
    func saveProject(to url: URL) throws {
        let p = try StudioProject(dataset:dataset,settings:applied,marks:marks,window:window,history:journal.history,reference:reference,
                                  calibration:calibration, analysis:analysis, traceKey:traceKey, spectrumID:spectrumID,
                                  rawImport:rawImport, peaks:peakFileForStorage, referenceEdit:referenceEdit, textReport:textReport)
        try p.save(to:url)
        projectURL = url; savedMarker = journal.saveMarker
    }
    func quickPhase() { apply(applied, action: "相位校正", operation: .phaseOnly) }
    func quickProcess() { apply(applied, action: "相位＋基线", operation: .phaseAndBaseline) }
    func correctBaseline() { apply(applied, action: "基线校正", operation: .baselineOnly) }

    func export(_ kind: String) {
        guard !busy else { return }
        guard !hasDraft else { error = "请先应用或放弃预览参数，再导出。"; return }
        let version = annotationVersion, visible = window, width = pngWidth
        let usesWindow = kind == "range" || kind == "pdf" || kind == "png"
        let panel = NSSavePanel()
        panel.allowedContentTypes = [kind == "png" ? .png : kind == "pdf" ? .pdf : .commaSeparatedText]
        panel.nameFieldStringValue = dataset.name.replacingOccurrences(of:"/",with:"-") + (kind == "analysis" ? "-analysis.csv" : kind == "marks" ? "-measurements.csv" : kind == "range" ? "-range.csv" : "." + kind)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard accepts(version), !hasDraft, !usesWindow || window == visible,
              kind != "png" || width == pngWidth else {
            error = "导出期间谱图或范围已改变，请重新导出。"
            return
        }
        do {
            try writeExport(kind, to:url)
            status = "已导出 · \(url.lastPathComponent)"
        } catch { self.error = error.localizedDescription }
    }
    private var annotatedPlot: PlotState { annotationPlot(selecting: nil) }
    func writeExport(_ kind:String, to url:URL) throws {
        switch kind {
        case "png": try PlotExport.png(annotatedPlot,width:pngWidth,to:url)
        case "pdf": try PlotView.pdf(annotatedPlot,to:url)
        case "analysis": try analysis.analysisCSV(currentKey: traceKey).write(to: url, atomically: true, encoding: .utf8)
        case "csv", "range", "marks":
            let text = kind == "csv" ? spectrum.csv() : kind == "range" ? PlotExport.csv(spectrum,in:window) : measurementCSV()
            try text.write(to:url,atomically:true,encoding:.utf8)
        default: throw NMRError("未知导出格式。")
        }
    }
    func measurementCSV() -> String {
        var csv = "type,high_ppm,low_ppm,intensity,area_au_ppm,relative_area,is_reference\n"
        for m in marks {
            let b = bounds(m)
            if m.isPeak {
                csv += "peak,\(b.upperBound),\(b.lowerBound),\(spectrum.real[spectrum.nearest(b.upperBound)]),,,\n"
            } else {
                csv += "integral,\(b.upperBound),\(b.lowerBound),,\(spectrum.area(b)),\(relativeArea(m).map { String($0) } ?? ""),\(reference?.markID == m.id)\n"
            }
        }
        return csv
    }

    func delete(_ mark:Mark) {
        guard !busy, marks.contains(where: { $0.id == mark.id }) else { return }
        record(SessionJournal.markDescription(for:mark,adding:false,offset:applied.offset))
        marks.removeAll { $0.id == mark.id }
        if reference?.markID == mark.id { reference = nil }
        if mark.isPeak { analysis.marksOriginalPPM.removeAll { $0 == mark.lo } }
        status = "已删除测量"
    }

    func relativeArea(_ mark:Mark) -> Double? {
        guard !mark.isPeak, let ref = reference, let anchor = marks.first(where: { $0.id == ref.markID }) else { return nil }
        return SessionJournal.relativeArea(spectrum.area(bounds(mark)), referenceArea:spectrum.area(bounds(anchor)), target:ref.target)
    }

    func editIntegral(_ mark:Mark, bounds b:ClosedRange<Double>, target:Double?) {
        guard !busy, !mark.isPeak, let i = marks.firstIndex(where:{ $0.id == mark.id }),
              b.lowerBound < b.upperBound, spectrum.range.contains(b.lowerBound), spectrum.range.contains(b.upperBound) else { return }
        if let t = target, SessionJournal.relativeArea(spectrum.area(b),referenceArea:spectrum.area(b),target:t) == nil {
            error = "参考积分面积必须非零且有限，归一值须为正数。"; return
        }
        var next = Mark(lo:b.lowerBound-applied.offset,hi:b.upperBound-applied.offset)
        next.id = mark.id
        let originalBounds = bounds(mark)
        let previousRef = reference
        let newRef = IntegrationReference.updating(previousRef, for:mark.id, target:target)
        guard originalBounds != b || previousRef != newRef else { return }
        var message = String(format:"积分 %.5f…%.5f → %.5f…%.5f ppm",originalBounds.upperBound,originalBounds.lowerBound,b.upperBound,b.lowerBound)
        if let t = target { message += String(format:"；参考积分 = %.5g",t) }
        else if previousRef?.markID == mark.id { message += "；取消参考积分" }
        record(message); marks[i] = next; reference = newRef; status = "积分已更新"
    }

    func undo() {
        guard !busy, !hasDraft, journal.canUndo else { return }
        var nextJournal = journal
        guard let previous = nextJournal.undo() else { return }
        let d=dataset, id=UUID(), old=applied; job=id; busy=true; cancelPreview()
        let existing=spectrum
        Task {
            do {
                var oldShape = old
                var previousShape = previous.settings
                oldShape.offset = 0; previousShape.offset = 0
                let replacement: StudioImportSnapshot?
                let next: Spectrum
                if previousShape == oldShape {
                    replacement = nil
                    next = previous.settings.offset == old.offset ? existing :
                        Spectrum(ppm: originalPPM.map { $0 + previous.settings.offset }, real: existing.real)
                } else {
                    let currentID = spectrumID
                    let restoredSettings = previous.settings
                    let doc = try await Task.detached(priority: .userInitiated) {
                        try StudioImport.replay(d, settings: restoredSettings, id: currentID)
                    }.value
                    replacement = doc
                    next = doc.spectrum
                }
                guard job == id else { return }
                if let replacement {
                    originalPPM = replacement.originalPPM; peakIndex = replacement.peakIndex
                    applied = previous.settings
                    installPeakWorkspace(trace: replacement.peakTrace, file: previous.peakFile)
                } else {
                    // An editor retained across undo must not commit into the
                    // restored file, even if both files contain the same IDs.
                    installPeakWorkspace(trace: peakWorkspace?.trace, file: previous.peakFile)
                    try? peakWorkspace?.setReferenceDelta(previous.settings.offset)
                }
                let lo = max(next.range.lowerBound, previous.window.lo)
                let hi = min(next.range.upperBound, previous.window.hi)
                window = lo < hi ? lo...hi : next.range
                spectrum=next; settings=previous.settings; applied=previous.settings
                marks=previous.marks; reference=previous.reference; journal=nextJournal
                calibration=previous.calibration; analysis=previous.analysis; traceKey=previous.traceKey
                referenceEdit=previous.referenceEdit; referenceHistoryID=previous.referenceHistoryID
                textReport=previous.textReport
                status="已撤销上一步"
            } catch { if job == id { self.error=error.localizedDescription } }
            if job == id { busy=false }
        }
    }

    func cancelPreview() {
        previewTask?.cancel(); previewTask=nil; previewSpectrum=nil
    }

    func refreshPreview(enabled:Bool) {
        previewTask?.cancel()
        guard enabled, complex, !busy, settings.p0 != applied.p0 || settings.p1 != applied.p1 else {
            previewSpectrum=nil; return
        }
        let draft=settings, d=dataset, id=job, cached=phaseCache
        let lb = draft.options.lbOverride ?? draft.savedAutomaticLB ?? d.nucleus.defaultLBHz
        guard (0...10000).contains(draft.lb), abs(draft.offset) <= 1e5,
              abs(draft.p0) <= 1e5, abs(draft.p1) <= 1e5 else { previewSpectrum=nil; return }
        previewTask = Task {
            do {
                try await Task.sleep(nanoseconds:45_000_000)
                let (quad,result) = try await Task.detached(priority:.userInitiated) {
                    let quad:Spectrum
                    if let cached, cached.lb == lb, cached.fill == draft.fill { quad=cached.data }
                    else {
                        switch d.input {
                        case .spectrum(let s): quad=s
                        case .fid(let f): quad=try f.transform(lb:lb,fill:draft.fill)
                        }
                    }
                    return try (quad,runProcessing(d, draft, action: .applySettings, cachedFFT: quad).displaySpectrum)
                }.value
                try Task.checkCancellation()
                guard id == job, draft == settings else { return }
                phaseCache=(lb,draft.fill,quad)
                previewOffset=draft.offset; previewSpectrum=result
            } catch is CancellationError { }
              catch { if !Task.isCancelled, id == job { self.error=error.localizedDescription } }
        }
    }
}

@MainActor
extension Workbench {
    var referenceScope: NRScope { referenceScope(nucleus: dataset.nucleus) }

    func referenceScope(nucleus: NMRNucleus) -> NRScope {
        NRScope(spectrumID: spectrumID.uuidString, axisID: traceKey, revision: 0,
                nucleus: nucleus, offsetPPM: applied.offset,
                sampleSolventID: StudioReferences.solventID(dataset.solvent),
                sampleSolventDisplay: StudioReferences.solventName(dataset.solvent))
    }

    var undoableReferenceID: UUID? {
        guard journal.canUndo, referenceHistoryID == journal.history.last?.id else { return nil }
        return referenceEdit?.id
    }

    func applyReference(_ edit: NRReferenceEdit) throws {
        let nucleus: NMRNucleus = edit.scope.nucleusKey == "1H" ? .proton : edit.scope.nucleusKey == "13C" ? .carbon13 : .unknown
        guard (dataset.nucleus == .unknown || dataset.nucleus == nucleus),
              edit.scope == referenceScope(nucleus: nucleus), spectrum.range.contains(edit.pick.observedPPM) else {
            throw NMRError("参考点或谱图已变化，请重新选择。")
        }
        let axis = CalibrationAxis(rawDescendingPPM: originalPPM)
        let measure: CalibrationObservation = .typedDisplay(edit.pick.observedPPM)
        let base = try ShiftCalibration.propose(axis: axis, nucleus: nucleus,
            currentOffset: applied.offset, observation: measure,
            target: .manual(.custom, ppm: edit.target.ppm, detail: edit.target.material))
        let target = edit.target
        let line = ReferenceLine(id: target.id, solventID: target.solventID, material: target.material,
                                 nucleus: nucleus, site: target.site, ppm: target.ppm, note: target.note, source: target.source)
        let attributed = ShiftCalibrationRecord(version: base.version, nucleus: base.nucleus, pick: base.pick,
            measuredDisplayPPM: base.measuredDisplayPPM, targetPPM: base.targetPPM, deltaPPM: base.deltaPPM,
            previousOffsetPPM: base.previousOffsetPPM, offsetPPM: base.offsetPPM, reference: line)
        try calibrate(attributed)
        referenceEdit = edit
        referenceHistoryID = journal.history.last?.id
    }

    func undoReference(_ scope: NRScope, id: UUID) throws {
        let nucleus: NMRNucleus = scope.nucleusKey == "1H" ? .proton : scope.nucleusKey == "13C" ? .carbon13 : .unknown
        guard scope == referenceScope(nucleus: nucleus), id == undoableReferenceID, !busy, !hasDraft else {
            throw NMRError("此定标记录已不是可撤销的最后一步。")
        }
        undo()
    }

    func makeTextReport(nucleus: NMRReportNucleus? = nil) throws -> NMRReportDraft {
        guard !busy, !hasDraft else {
            throw NMRError("请等待谱图处理完成，并先应用或放弃预览参数。")
        }
        let native = dataset.nucleus == .proton ? NMRReportNucleus.proton
            : dataset.nucleus == .carbon13 ? .carbon13 : nil
        guard let chosen = native ?? nucleus else { throw NMRError("请先选择报表核种。") }

        return try StudioReport.makeDraft(dataset: dataset, id: spectrumID, sampleID: spectrumID,
                                          nucleus: chosen, marks: marks, displayed: spectrum,
                                          referenceDelta: applied.offset, file: peakFileForStorage,
                                          trace: peakWorkspace?.trace, traceKey: traceKey,
                                          reference: reference, from: textReport)
    }

    func saveTextReport(_ draft: NMRReportDraft) {
        guard let primary = draft.spectra.first, primary.id == spectrumID else {
            error = "已切换谱图，请重新打开专业谱图文本。"
            return
        }
        do {
            let current = try makeTextReport(nucleus: primary.nucleus)
            guard let source = draft.sourceSpectrum, source == current.sourceSpectrum else {
                throw NMRError("源测量或参考坐标已经变化。请关闭报表，重新打开并核对。")
            }
            guard draft != textReport else { return }
            record("保存专业谱图文本草稿")
            textReport = draft
        } catch {
            self.error = error.localizedDescription
        }
    }
}
