import SwiftUI
import Foundation

// Publishes a peak-group transaction only after the host accepts it.
@MainActor final class NMRPeakWorkspace: ObservableObject {
    @Published private(set) var file: NMRPeakFile
    @Published private(set) var trace: NMRSpectrum1D
    @Published private(set) var referenceDelta: Double
    @Published var selection: UUID?
    @Published var marking = false { didSet { if oldValue != marking { geometryEpoch = UUID() } } }
    @Published var message = ""
    private(set) var geometryEpoch = UUID()
    let selectedMark: () -> NMRMarkSnapshot?
    let lookupMark: (String) -> NMRMarkSnapshot?
    private let willCommit: (String) throws -> Void
    init(trace: NMRSpectrum1D, referenceDelta: Double, file: NMRPeakFile,
         selectedMark: @escaping () -> NMRMarkSnapshot?,
         lookupMark: @escaping (String) -> NMRMarkSnapshot?,
         willCommit: @escaping (String) throws -> Void) {
        self.file = file; self.trace = trace; self.referenceDelta = referenceDelta
        self.selectedMark = selectedMark; self.lookupMark = lookupMark; self.willCommit = willCommit
        selection = file.groups.first?.id
    }

    func restore(_ file: NMRPeakFile) {
        self.file = file
        if !file.groups.contains(where: { $0.id == selection }) { selection = file.groups.first?.id }
    }
    func install(_ t: NMRSpectrum1D, referenceDelta: Double) throws {
        guard t.stamp.spectrumID == file.spectrumID && referenceDelta.isFinite else { throw NMRProblem("Use a separate workspace for another acquisition") }
        geometryEpoch = UUID(); trace = t; self.referenceDelta = referenceDelta
    }
    func setReferenceDelta(_ d: Double) throws {
        guard d.isFinite else { throw NMRProblem("Nonfinite reference delta") }; if d != referenceDelta { geometryEpoch = UUID(); referenceDelta = d }
    }
    func hostMarksChanged() { objectWillChange.send() }
    func edit(_ body: (inout NMRPeakFile) throws -> Void) throws {
        var next = file
        try body(&next)
        try willCommit("更新峰组")
        file = next
    }
    func perform(_ action: () throws -> Void) { do { try action(); message = "已更新" } catch { message = error.localizedDescription } }
    func commit(_ b: NMRRawBox, clipped: Bool) throws {
        var id: UUID?; try edit { id = try $0.add(b,clipped:clipped,trace:trace) }; selection = id; message = "已标峰，请审阅峰形和 J 值"
    }
    func why(_ g: NMRPeakGroup) -> String? { file.blockingReason(g,trace:trace,lookup:lookupMark) }
    var overlayGroups: [NMROverlayGroup] { file.groups.map { NMROverlayGroup(group:$0,selected:$0.id == selection,stale:why($0) != nil) } }
    func exportRows() throws -> [NMRExportGroup] { try file.exportGroups(trace:trace,referenceDelta:referenceDelta,lookup:lookupMark) }
}

private func fmt(_ x: Double) -> String { String(format:"%.7g",locale:Locale(identifier:"en_US_POSIX"),x) }
private func est(_ e: NMREstimate) -> String { fmt(e.value) + " ± " + fmt(e.uncertainty) }
private func spanLabel(_ r: NMRSpan) -> String { fmt(r.low) + " … " + fmt(r.high) }
private func shiftLabel(_ s: NMRChemicalShift) -> String {
    switch s { case .point(let x): return fmt(x); case .range(let r): return spanLabel(r) }
}
private func readNumber(_ s: String) throws -> Double {
    guard let x = Double(s.trimmingCharacters(in:.whitespacesAndNewlines)), x.isFinite else { throw NMRProblem("Enter a finite number (decimal point '.')") }; return x
}

struct NMRPeakGroupEditor: View {
    @ObservedObject var workspace: NMRPeakWorkspace
    var body: some View {
        VStack(alignment:.leading) {
            HStack { Text("峰组审阅").font(.headline); Spacer(); Text(workspace.trace.stamp.nucleus); Text(workspace.trace.stamp.observedMHz.map { fmt($0) + " MHz" } ?? "观测频率未知") }
            HSplitView {
                List(selection:$workspace.selection) {
                    ForEach(workspace.file.groups) { g in
                        VStack(alignment:.leading) {
                            Text(shiftLabel((g.approval?.rawShift ?? g.analysis.suggestedShift).shifted(by:workspace.referenceDelta)) + " ppm")
                            Text(workspace.why(g) != nil ? "待复核" : (g.included ? "已确认 · 纳入导出" : (g.approval == nil ? "待确认" : "已确认 · 未纳入"))).font(.caption)
                        }.tag(g.id)
                    }
                }.frame(minWidth:145,idealWidth:190)
                if let g = workspace.file.groups.first(where: { $0.id == workspace.selection }) {
                    NMRGroupDetail(w:workspace,g:g).id(g.id).frame(minWidth:340,maxWidth:.infinity)
                } else { Text("可在谱图上拖出矩形以标峰。").padding().frame(maxWidth:.infinity,maxHeight:.infinity) }
            }
            Text(workspace.message).font(.callout).textSelection(.enabled)
        }.padding(8)
    }
}

private struct NMRGroupDetail: View {
    @ObservedObject var w: NMRPeakWorkspace
    let g: NMRPeakGroup
    @State private var hText = ""
    @State private var referenceID: UUID?
    @State private var manualShift = false
    @State private var asRange = false
    @State private var firstText = ""
    @State private var secondText = ""
    @State private var manualMult = false
    @State private var chosen = NativeNMRPeakMultiplicity.m
    @State private var manualJs = false
    @State private var jText = ""
    @State private var confirmingDelete = false
    private var a: NMRPeakAnalysis { g.analysis }
    private var delta: Double { w.referenceDelta }
    private var why: String? { w.why(g) }
    private func loadDraft() {
        hText = g.assignedH.map { String($0) } ?? ""
        let v = g.approval
        manualShift = v?.shiftSource == .userEntered; manualMult = v?.multiplicitySource == .userEntered; manualJs = v?.jsSource == .userEntered
        switch (v?.rawShift ?? a.suggestedShift).shifted(by:delta) {
        case .point(let x): asRange = false; firstText = String(x); secondText = String(g.rawBox.ppm.high+delta)
        case .range(let r): asRange = true; firstText = String(r.low); secondText = String(r.high)
        }
        chosen = v?.multiplicity ?? a.suggestedMultiplicity
        jText = (v?.jsHz ?? a.computedJsHz.map { $0.value }).map { String($0) }.joined(separator:", ")
    }
    private func approve() throws {
        var shift: NMRChemicalShift?, js: [Double]?
        if manualShift {
            let x = try readNumber(firstText)-delta
            if asRange {
                let y = try readNumber(secondText)-delta
                guard x < y else { throw NMRProblem("Range requires low < high") }; shift = .range(NMRSpan(x,y))
            } else { shift = .point(x) }
        }
        if manualJs {
            let s = jText.trimmingCharacters(in:.whitespacesAndNewlines)
            js = s.isEmpty ? [] : try s.components(separatedBy:",").map { try readNumber($0) }
        }
        try w.edit { try $0.approve(g.id,trace:w.trace,lookup:w.lookupMark,rawShiftOverride:shift,multOverride:manualMult ? chosen : nil,jsOverrideHz:js) }
    }
    private func componentText(_ p: NativeNMRPeakComponent) -> String {
        var text = fmt(p.ppm+delta) + " ± " + fmt(p.positionErrorPPM) + " ppm; raw " + fmt(p.intensity) + "; S/N " + fmt(p.snr) + "; " + p.shape.rawValue
        if let r = p.halfWidthRatio { text += " (half-width ratio " + fmt(r) + ")" }
        if let v = p.apparentFWHM {
            text += "; apparent FWHM " + est(v) + " ppm"
            if let f = a.stamp.observedMHz { text += " / " + est(v.scaled(f)) + " Hz" }
        } else { text += "; FWHM unavailable" }; return text
    }
    private var measurements: some View {
        GroupBox("Measured on saved analysis · apparent, not a spin assignment") {
            VStack(alignment:.leading,spacing:5) {
                Text("Raw box: " + spanLabel(g.rawBox.ppm) + " original ppm × " + spanLabel(g.rawBox.intensity))
                Text("Envelope: " + spanLabel(NMRSpan(a.envelope.low+delta,a.envelope.high+delta)) + " ppm; noise scale " + fmt(a.noiseScale))
                Text("Mid-extrema: " + est(NMREstimate(value:a.midExtremaPPM.value+delta,uncertainty:a.midExtremaPPM.uncertainty)) + " ppm")
                ForEach(a.components, id:\.sample) { c in Text(componentText(c)).font(.caption) }
                Text("Adjacent Δppm: " + a.adjacentPPM.map(est).joined(separator:"; "))
                Text("Δ / mean Δ: " + a.gapOverMean.map(fmt).joined(separator:", "))
                Text("Computed: " + a.suggestedMultiplicity.rawValue + " · " + shiftLabel(a.suggestedShift.shifted(by:delta)) + " ppm")
                Text(a.computedJsHz.isEmpty ? (a.stamp.observedMHz == nil ? "No computed J (MHz unavailable)" : "No computed J") : "Apparent J (Hz): " + a.computedJsHz.map(est).joined(separator:"; "))
                Text(a.reviewReasons.isEmpty ? "Passed supported local profile checks; review required." : a.reviewReasons.joined(separator:"; ")).foregroundColor(.secondary)
            }.frame(maxWidth:.infinity,alignment:.leading).textSelection(.enabled)
        }
    }
    private var integrals: some View {
        GroupBox("Host integral and user H assignment") {
            VStack(alignment:.leading) {
                Text("Linked Mark: " + (g.linkedMarkID ?? "none" )).textSelection(.enabled)
                if let id = g.linkedMarkID, let m = w.lookupMark(id), m.id == id && m.spectrumID == w.file.spectrumID { Text("Signed area: " + fmt(m.signedArea)) }
                HStack {
                    Button("Link selected integral") { w.perform {
                        guard let m = w.selectedMark() else { throw NMRProblem("Select an integral in the host first") }; try w.edit { try $0.link(g.id,to:m,lookup:w.lookupMark) }
                    } }
                    Button("Unlink") { w.perform { try w.edit { try $0.link(g.id,to:nil,lookup:w.lookupMark) } } }.disabled(g.linkedMarkID == nil)
                }
                HStack {
                    TextField("Assigned H",text:$hText).frame(width:95)
                    Button("Save H") { w.perform {
                        guard let h = Int(hText.trimmingCharacters(in:.whitespacesAndNewlines)), h > 0 else { throw NMRProblem("H must be a positive integer") }
                        try w.edit { try $0.setH(h,for:g.id,trace:w.trace,lookup:w.lookupMark) }
                    } }.disabled(g.linkedMarkID == nil || w.trace.stamp.nucleus != "1H" || why != nil)
                    Button("Clear H") { w.perform { try w.edit { try $0.setH(nil,for:g.id,trace:w.trace,lookup:w.lookupMark) } } }.disabled(g.assignedH == nil)
                }
                Picker("Compare area to",selection:$referenceID) {
                    Text("None").tag(nil as UUID?)
                    ForEach(w.file.groups.filter { $0.id != g.id && $0.assignedH != nil && w.why($0) == nil }) { b in
                        Text(shiftLabel(b.analysis.suggestedShift.shifted(by:delta)) + " ppm · " + String(b.assignedH ?? 0) + " H").tag(Optional(b.id))
                    }
                }
                if let id = referenceID {
                    if let value = w.file.suggestedH(for:g.id,relativeTo:id,trace:w.trace,lookup:w.lookupMark) { Text("Relative H suggestion only: " + String(value)) }
                    else { Text("No comparable same-sign linked areas") }
                }
            }.frame(maxWidth:.infinity,alignment:.leading)
        }
    }
    private var review: some View {
        GroupBox("审阅峰组") {
            VStack(alignment: .leading) {
                Text("Unchecked overrides use the computed field. Manual Js require independent justification.")
                    .font(.caption)
                reviewShiftControls
                reviewMultiplicityControls
                reviewJsControls
                reviewButtons
                reviewSavedApproval
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private var reviewShiftControls: some View {
        Toggle("手动指定峰位或范围（ppm）", isOn: $manualShift)
        if manualShift {
            HStack {
                Toggle("范围", isOn: $asRange)
                TextField(asRange ? "低 ppm" : "峰位", text: $firstText)
                if asRange {
                    TextField("高 ppm", text: $secondText)
                }
            }
        }
    }

    @ViewBuilder
    private var reviewMultiplicityControls: some View {
        Toggle("手动指定裂分类型", isOn: $manualMult)
        if manualMult {
            Picker("裂分类型", selection: $chosen) {
                // ForEach needs a RandomAccessCollection; using each case as its ID and tag requires Hashable.
                ForEach(NativeNMRPeakMultiplicity.allCases, id: \.self) { (m: NativeNMRPeakMultiplicity) in
                    Text(m.rawValue).tag(m)
                }
            }
        }
    }

    @ViewBuilder
    private var reviewJsControls: some View {
        Toggle("手动指定 J（Hz）", isOn: $manualJs)
        if manualJs {
            TextField("多个 J 值用逗号分隔", text: $jText)
        }
    }

    // The original .font, .frame and .disabled modifiers are valid as written.
    private var reviewButtons: some View {
        let approvalDisabled: Bool = why != nil
        let showExclude: Bool = g.included && !approvalDisabled
        let inclusionDisabled: Bool = g.approval == nil || approvalDisabled
        return HStack {
            Button("确认峰组", action: reviewApproveTapped)
                .disabled(approvalDisabled)
            Button(showExclude ? "从导出中移除" : "纳入 TXT 导出", action: reviewInclusionTapped)
                .disabled(inclusionDisabled)
        }
    }

    // Button actions must be nonthrowing; keep the throwing work inside perform.
    private func reviewApproveTapped() {
        w.perform { try self.approve() }
    }

    private func reviewInclusionTapped() {
        w.perform {
            try self.w.edit { draft in
                // Pass the function value, not a call to it. The lookupMark signature
                // must match setIncluded's lookup parameter unambiguously.
                try draft.setIncluded(
                    !self.g.included,
                    id: self.g.id,
                    trace: self.w.trace,
                    lookup: self.w.lookupMark
                )
            }
        }
    }

    // Text? contributes no row when nil and avoids if-let inside older Swift 5 ViewBuilders.
    private var reviewSavedApproval: Text? {
        guard let v = g.approval else { return nil }
        let shift: String = shiftLabel(v.rawShift.shifted(by: delta))
        let shiftPart: String = "\(shift) [\(v.shiftSource.rawValue)]"
        let multPart: String = "\(v.multiplicity.rawValue) [\(v.multiplicitySource.rawValue)]"
        let js: String = String(describing: v.jsHz)
        let message: String = "Saved approval: \(shiftPart), \(multPart), J \(js) [\(v.jsSource.rawValue)]"
        return Text(message).font(.caption)
    }
    var body: some View {
        ScrollView { VStack(alignment:.leading,spacing:10) {
            Text("Group " + g.id.uuidString).font(.caption).textSelection(.enabled)
            if let r = why { Text(r + " · not exportable").foregroundColor(.orange) }
            measurements; integrals; review
            HStack {
                Button("Remeasure saved raw box") { w.perform { try w.edit { try $0.remeasure(g.id,trace:w.trace) } } }
                Button("Delete group…") { confirmingDelete = true }
            }.confirmationDialog("Delete this annotation (not the integral)?",isPresented:$confirmingDelete) {
                Button("Delete group",role:.destructive) { w.perform { try w.edit { try $0.remove(g.id) }; w.selection = w.file.groups.first?.id } }
            }
        }.padding(8) }.onAppear { loadDraft() }.onChange(of:g) { _ in loadDraft() }.onChange(of:delta) { _ in loadDraft() }
    }
}
