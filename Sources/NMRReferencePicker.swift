import Foundation
import SwiftUI
import AppKit

struct NRFailure: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

private func nrNucleusKey(_ n: NMRNucleus) -> String {
    switch n { case .proton: return "1H"; case .carbon13: return "13C"; default: return "unknown" }
}
private func nrTrim(_ s: String) -> String { s.trimmingCharacters(in: .whitespacesAndNewlines) }
private func nrNumber(_ s: String) -> Double? {
    guard let v = Double(nrTrim(s)), v.isFinite else { return nil }; return v
}
private func nrSigned(_ v: Double) -> String { String(format: "%+.12g", locale: Locale(identifier: "en_US_POSIX"), v) }

// Offline additions only. IDs, not localized strings or positions in a Picker,
// are the join keys. Alias lookup is exact after trim + POSIX case folding.
enum NRTFA {
    static let defaultID = "tfa-d"
    static let aliases = ["TFA-d", "TFA", "CF3COOD", "trifluoroacetic acid-d", "氘代三氟乙酸"]
    static let source = "Cambridge Isotope Laboratories, NMR Solvent Data Chart: https://utswphysicianconnect.com/research/core-facilities/nmrcf/assets/nmr-solvent-data-chart.pdf ; Merck, NMR Deuterated Solvent Properties Reference: https://www.merckmillipore.com/GW/en/technical-documents/technical-article/analytical-chemistry/nuclear-magnetic-resonance/nmr-deuterated-solvent-properties-reference"
    static func key(_ s: String) -> String { nrTrim(s).lowercased(with: Locale(identifier: "en_US_POSIX")) }
    static func acid(_ id: String) -> String { id + ".1h.acid" }
    static func carbonyl(_ id: String) -> String { id + ".13c.co" }
    static func cf3(_ id: String) -> String { id + ".13c.cf3" }

    // Run at catalog load. Pass the existing canonical ID if this solvent
    // already has one. On a conflicting key/row, fail BEFORE changing anything.
    static func install(solventID id: String = defaultID, displayByID: inout [String: String], aliasToID: inout [String: String], lines: inout [ReferenceLine]) throws {
        let keys = Set(aliases.map { key($0) })
        guard !key(id).isEmpty, key(id) != "tfe-d3" else { throw NRFailure("Invalid TFA-d ID") }
        if let name = displayByID[id], !keys.contains(key(name)) { throw NRFailure("Solvent ID already used by " + name) }
        for (other, name) in displayByID where other != id && keys.contains(key(name)) { throw NRFailure("Use existing TFA-d ID: " + other) }
        for (k, v) in aliasToID {
            if keys.contains(key(k)) && v != id { throw NRFailure("Conflicting solvent alias: " + k) }
            if key(k) == "tfe-d3" && v == id { throw NRFailure("TFE-d3 is not TFA-d") }
        }
        let wanted = [
            ReferenceLine(id: acid(id), solventID: id, material: "TFA-d", nucleus: .proton, site: "酸性残余氢", ppm: 11.50, note: "酸性氢可交换，峰位随样品条件变化，请先核对归属。", source: source),
            ReferenceLine(id: carbonyl(id), solventID: id, material: "TFA-d", nucleus: .carbon13, site: "羰基碳 · 四重峰中心", ppm: 164.2, note: "¹³C–¹⁹F 裂分，使用四重峰中心。", source: source),
            ReferenceLine(id: cf3(id), solventID: id, material: "TFA-d", nucleus: .carbon13, site: "CF₃ 碳 · 四重峰中心", ppm: 116.6, note: "¹³C–¹⁹F 裂分，使用四重峰中心。", source: source)
        ]
        var add: [ReferenceLine] = []
        for w in wanted {
            let existing = lines.filter { $0.id == w.id }
            if let e = existing.first {
                guard existing.count == 1, e.solventID == w.solventID, nrNucleusKey(e.nucleus) == nrNucleusKey(w.nucleus), e.material == w.material, e.ppm == w.ppm, e.site == w.site, e.note == w.note, e.source == w.source else { throw NRFailure("Conflicting reference line ID: " + w.id) }
            } else { add.append(w) }
        }
        if displayByID[id] == nil { displayByID[id] = "TFA-d" }
        for alias in aliases { aliasToID[key(alias)] = id }
        lines.append(contentsOf: add)
    }
}

// Increment revision on data replacement, axis/offset/history edits (including
// undo). Pans, zooms and changes to the plot rectangle aren't data edits.
struct NRScope: Equatable, Codable {
    let spectrumID: String, axisID: String, revision: UInt64, nucleusKey: String
    let offsetPPM: Double
    let sampleSolventID: String?, sampleSolventDisplay: String?
    init(spectrumID: String, axisID: String, revision: UInt64, nucleus: NMRNucleus, offsetPPM: Double, sampleSolventID: String?, sampleSolventDisplay: String?) {
        self.spectrumID = spectrumID; self.axisID = axisID; self.revision = revision
        nucleusKey = nrNucleusKey(nucleus); self.offsetPPM = offsetPPM
        self.sampleSolventID = sampleSolventID; self.sampleSolventDisplay = sampleSolventDisplay
    }
}

struct NRTarget: Identifiable, Codable {
    let id: String, solventID: String?, solventDisplay: String?, material: String
    let nucleusKey: String, site: String, ppm: Double, note: String, source: String
    let center: Bool, conditionSensitive: Bool, custom: Bool
    var groupKey: String { solventID.map { "s:" + $0 } ?? ("m:" + material) }
    var groupName: String { solventDisplay ?? material }
    var review: String {
        var s: [String] = []
        if center { s.append("我确认已选择多重峰中心。") }
        if conditionSensitive { s.append("我确认该峰适用于当前样品条件。") }
        return s.joined(separator: " ")
    }
    func permits(_ method: NRMethod) -> Bool { !center || method == .midpoint || method == .typed }

    // Include all existing tabulated C–D (and other multiplet) center IDs in
    // centerIDs. This policy is per SITE, not a guess based on solvent spelling.
    static func catalog(_ l: ReferenceLine, displayByID: [String: String], centerIDs: Set<String>, conditionSensitiveIDs: Set<String> = [], tfaID: String = NRTFA.defaultID) -> NRTarget {
        let tfa = l.solventID == tfaID
        return NRTarget(id: l.id, solventID: l.solventID, solventDisplay: l.solventID.map { displayByID[$0] ?? $0 }, material: l.material, nucleusKey: nrNucleusKey(l.nucleus), site: l.site, ppm: l.ppm, note: l.note, source: l.source, center: centerIDs.contains(l.id) || (tfa && (l.id == NRTFA.carbonyl(tfaID) || l.id == NRTFA.cf3(tfaID))), conditionSensitive: conditionSensitiveIDs.contains(l.id) || (tfa && l.id == NRTFA.acid(tfaID)), custom: false)
    }
}

enum NRMethod: String, Codable, CaseIterable, Hashable {
    case extremum, freeClick, midpoint, typed
    var label: String {
        switch self {
        case .extremum: return "吸附到附近峰顶"
        case .freeClick: return "自由选点"
        case .midpoint: return "两条对称谱线的中点"
        case .typed: return "输入实测 ppm"
        }
    }
}
struct NRMark: Codable {
    let rawPPM: Double, ordinate: Double, peak: NRPeak?
    static func on(_ p: NRPeak) -> NRMark { NRMark(rawPPM: p.rawPPM, ordinate: p.ordinate, peak: p) }
}
struct NRPick: Codable {
    let method: NRMethod, marks: [NRMark], observedPPM: Double
    static func measure(_ method: NRMethod, marks: [NRMark] = [], typedDisplayed: Double? = nil, offset: Double) throws -> NRPick {
        guard offset.isFinite, marks.allSatisfy({ $0.rawPPM.isFinite && $0.ordinate.isFinite }) else { throw NRFailure("Nonfinite coordinate") }
        let v: Double
        switch method {
        case .typed:
            guard marks.isEmpty, let d = typedDisplayed else { throw NRFailure("Enter measured ppm on the displayed axis") }; v = d
        case .extremum, .freeClick:
            guard marks.count == 1, (marks[0].peak != nil) == (method == .extremum) else { throw NRFailure("Invalid single pick") }; v = marks[0].rawPPM + offset
        case .midpoint:
            guard marks.count == 2, let a = marks[0].peak, let b = marks[1].peak, a.first != b.first, a.rawPPM != b.rawPPM, a.maximum == b.maximum else { throw NRFailure("Click two distinct, like-polarity symmetric endpoints of the same multiplet") }
            v = nrMidpoint(a.rawPPM, b.rawPPM) + offset
        }
        guard v.isFinite, (v - offset).isFinite else { throw NRFailure("Invalid measured ppm") }
        return NRPick(method: method, marks: marks, observedPPM: v)
    }
}

// Persist the snapshot, not a row number, a hover position, or a pointer back
// into a mutable catalog. The host can embed its JSON in a record or sidecar.
struct NRReferenceEdit: Identifiable, Codable {
    let schemaVersion: Int, id: UUID, date: Date
    let scope: NRScope, target: NRTarget, pick: NRPick, acknowledged: Bool, deltaPPM: Double
    init(scope: NRScope, target: NRTarget, pick: NRPick, acknowledged: Bool) throws {
        guard target.nucleusKey == scope.nucleusKey, target.custom || scope.nucleusKey != "unknown", target.permits(pick.method) else { throw NRFailure("Incompatible target or center measurement") }
        guard target.review.isEmpty || acknowledged else { throw NRFailure("Explicit assignment confirmation required") }
        let checked = try NRPick.measure(pick.method, marks: pick.marks, typedDisplayed: pick.observedPPM, offset: scope.offsetPPM)
        let d = target.ppm - pick.observedPPM
        guard checked.observedPPM == pick.observedPPM, d.isFinite, (scope.offsetPPM + d).isFinite else { throw NRFailure("Invalid calibration coordinates") }
        schemaVersion = 1; id = UUID(); date = Date(); self.scope = scope; self.target = target; self.pick = pick; self.acknowledged = acknowledged; deltaPPM = d
    }
    var report: String {
        let sample = scope.sampleSolventDisplay ?? scope.sampleSolventID ?? "Not specified"
        let medium = target.solventDisplay.map { "; reference medium: " + $0 } ?? ""
        return "Sample solvent: \(sample) | \(scope.nucleusKey) reference: \(target.material), \(target.site) [\(target.id)]\(medium); \(pick.observedPPM) → \(target.ppm) ppm; Δ \(nrSigned(deltaPPM)) ppm"
    }
}

struct NREditActions {
    let commit: (NRReferenceEdit) throws -> Void
    let undo: (NRScope, UUID) throws -> Void
}

// Synchronous serialized host operations. read must read the LIVE scope.
// append/restore are transaction boundaries: check expected scope there too
// if there are other writers. makeRecord must be side-effect free.
func nrAdditiveActions<Axis, Record>(read: @escaping (String, String) throws -> (Axis, NRScope, UUID?), makeRecord: @escaping (Axis, NRReferenceEdit, Data) throws -> Record, append: @escaping (Axis, Record, UUID, Double, NRScope) throws -> Void, restoreHead: @escaping (Axis, UUID, NRScope) throws -> Void) -> NREditActions {
    NREditActions(commit: { e in
        let (axis, live, _) = try read(e.scope.spectrumID, e.scope.axisID)
        guard live == e.scope else { throw NRFailure("Axis/data changed. Pick again.") }
        let bytes = try JSONEncoder().encode(e)
        let record = try makeRecord(axis, e, bytes)
        try append(axis, record, e.id, e.deltaPPM, live) // the ONLY apply call
    }, undo: { scope, id in
        let (axis, live, head) = try read(scope.spectrumID, scope.axisID)
        guard live == scope, head == id else { throw NRFailure("That reference is no longer the undoable head") }
        try restoreHead(axis, id, live)
    })
}

// Transparent native tracking layer, mounted ONLY in reference mode. Consumes
// primary clicks; don't attach a simultaneous annotation gesture to its parent.
// Conversion from window coordinates honors view transforms; isFlipped makes
// the result agree with the overlaid SwiftUI Canvas. No backingScaleFactor.
private struct NRPad: NSViewRepresentable {
    let move: (CGPoint?) -> Void, click: (CGPoint) -> Void
    final class Pad: NSView {
        var move: (CGPoint?) -> Void = { _ in }, click: (CGPoint) -> Void = { _ in }
        private var tracking: NSTrackingArea?, down: CGPoint?
        override var isFlipped: Bool { true }
        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            if let t = tracking { removeTrackingArea(t) }
            let t = NSTrackingArea(rect: .zero, options: [.inVisibleRect, .activeInKeyWindow, .mouseEnteredAndExited, .mouseMoved], owner: self, userInfo: nil)
            addTrackingArea(t); tracking = t
        }
        private func point(_ e: NSEvent) -> CGPoint { convert(e.locationInWindow, from: nil) }
        private func nearDown(_ p: CGPoint) -> Bool { guard let q = down else { return false }; return abs(p.x - q.x) <= 3 && abs(p.y - q.y) <= 3 }
        override func mouseEntered(with event: NSEvent) { move(point(event)) }
        override func mouseMoved(with event: NSEvent) { move(point(event)) }
        override func mouseExited(with event: NSEvent) { move(nil) }
        override func mouseDown(with event: NSEvent) { down = point(event) }
        override func mouseDragged(with event: NSEvent) { let p = point(event); if !nearDown(p) { down = nil }; move(p) }
        override func mouseUp(with event: NSEvent) { let p = point(event); let ok = nearDown(p); down = nil; if ok { click(p) } }
    }
    func makeNSView(context: Context) -> Pad { let v = Pad(frame: .zero); v.move = move; v.click = click; return v }
    func updateNSView(_ v: Pad, context: Context) { v.move = move; v.click = click }
}

private struct NRSurface: View {
    let index: NRPeakIndex, radii: NRRadii, offset: Double
    let makeMap: (CGSize) -> NRPlotMap?, live: Bool, snap: Bool
    let marks: [NRMark], measured: Double?, clicked: (NRProbe) -> Void
    @State private var pointer: CGPoint?

    var body: some View {
        GeometryReader { geo in
            let map = makeMap(geo.size)
            ZStack {
                if let m = map, m.offsetPPM == offset {
                    let probe = live ? pointer.flatMap { index.probe($0, in: m, radii: radii, snapping: snap) } : nil
                    Canvas { context, _ in
                        var c = context; c.clip(to: Path(m.rect))
                        func ring(_ p: CGPoint, _ r: CGFloat, _ color: Color) {
                            let box = CGRect(x: p.x - r, y: p.y - r, width: 2*r, height: 2*r)
                            c.stroke(Path(ellipseIn: box), with: .color(color), lineWidth: 1.5)
                        }
                        func line(_ a: CGPoint, _ b: CGPoint, _ color: Color) {
                            var path = Path(); path.move(to: a); path.addLine(to: b); c.stroke(path, with: .color(color), lineWidth: 1)
                        }
                        if let d = measured {
                            let x = m.x(d - offset)
                            if x >= m.rect.minX && x <= m.rect.maxX { line(CGPoint(x: x, y: m.rect.minY), CGPoint(x: x, y: m.rect.maxY), .accentColor) }
                        }
                        for mark in marks {
                            let p = CGPoint(x: m.x(mark.rawPPM), y: m.y(mark.ordinate)); if m.contains(p) { ring(p, 6, .accentColor) }
                        }
                        if let h = probe {
                            if h.peak != nil { line(h.pointer, h.marker, .orange.opacity(0.55)) }
                            ring(h.marker, 4, h.peak == nil ? .secondary : .orange)
                        }
                    }.allowsHitTesting(false)
                }
                NRPad(move: { pointer = live ? $0 : nil }, click: { p in
                    // Re-query the CLICK, never promote the last hover result.
                    guard live, let m = map, m.offsetPPM == offset, let h = index.probe(p, in: m, radii: radii, snapping: snap) else { return }; clicked(h)
                })
            }.frame(width: geo.size.width, height: geo.size.height)
        }
    }
}

private struct NRFrozen { let scope: NRScope, target: NRTarget }
private struct NRGroup: Identifiable { let id: String, name: String }

struct NMRReferencePicker<Plot: View>: View {
    @Binding var isReferencing: Bool
    let scope: NRScope, index: NRPeakIndex, targets: [NRTarget], radii: NRRadii
    let undoableID: UUID?, edits: NREditActions, map: (CGSize) -> NRPlotMap?, plot: () -> Plot
    init(isReferencing: Binding<Bool>, scope: NRScope, index: NRPeakIndex, targets: [NRTarget], radii: NRRadii = NRRadii(), undoableID: UUID?, edits: NREditActions, map: @escaping (CGSize) -> NRPlotMap?, @ViewBuilder plot: @escaping () -> Plot) {
        _isReferencing = isReferencing; self.scope = scope; self.index = index; self.targets = targets; self.radii = radii; self.undoableID = undoableID; self.edits = edits; self.map = map; self.plot = plot
    }

    @State private var group = ""
    @State private var lineID = ""
    @State private var customName = ""
    @State private var customSolvent = ""
    @State private var customValue = ""
    @State private var measuredText = ""
    @State private var customCenter = false
    @State private var acknowledged = false
    @State private var draftID = UUID()
    @State private var method = NRMethod.extremum
    @State private var frozen: NRFrozen?
    @State private var first: NRMark?
    @State private var pick: NRPick?
    @State private var message = ""

    private var available: [NRTarget] { targets.filter { !$0.custom && $0.nucleusKey == scope.nucleusKey && scope.nucleusKey != "unknown" && $0.ppm.isFinite } }
    private var groups: [NRGroup] {
        var seen = Set<String>()
        return available.compactMap { t in seen.insert(t.groupKey).inserted ? NRGroup(id: t.groupKey, name: t.groupName) : nil }
    }
    private var target: NRTarget? {
        if let f = frozen { return f.target }
        if group == "custom" {
            let n = nrTrim(customName), s = nrTrim(customSolvent)
            guard !n.isEmpty, let v = nrNumber(customValue) else { return nil }
            return NRTarget(id: "manual:" + draftID.uuidString, solventID: nil, solventDisplay: s.isEmpty ? nil : s, material: n, nucleusKey: scope.nucleusKey, site: "User-defined target", ppm: v, note: "", source: "User entry", center: customCenter, conditionSensitive: false, custom: true)
        }
        return available.first { $0.groupKey == group && $0.id == lineID }
    }
    private var effective: NRMethod { target?.permits(method) == false ? .midpoint : method }
    private func clearPick() { frozen = nil; first = nil; pick = nil; acknowledged = false; draftID = UUID() }
    private func currentTarget() throws -> NRTarget {
        guard isReferencing, pick == nil, frozen == nil || frozen?.scope == scope else { throw NRFailure("Discard the old pick and try again") }
        guard let t = target else { throw NRFailure("Choose a reference line or complete the custom target first") }; return t
    }
    private func hold(_ t: NRTarget) { if frozen == nil { frozen = NRFrozen(scope: scope, target: t) } }
    private func click(_ h: NRProbe) {
        do {
            let t = try currentTarget(), mode = effective
            guard mode != .typed else { return }
            let mark: NRMark
            if mode == .freeClick { mark = NRMark(rawPPM: h.cursorRawPPM, ordinate: h.cursorOrdinate, peak: nil) }
            else { guard let e = h.peak else { throw NRFailure("No eligible extremum here. Move closer, or explicitly choose a manual method.") }; mark = .on(e) }
            if mode == .midpoint && first == nil { hold(t); first = mark; message = "First endpoint held. Click its symmetric partner."; return }
            let marks = first.map { [$0, mark] } ?? [mark]
            let measured = try NRPick.measure(mode, marks: marks, offset: scope.offsetPPM)
            hold(t); pick = measured; first = nil; acknowledged = false; message = ""
        } catch { message = error.localizedDescription }
    }
    private func stageTyped() {
        do {
            let t = try currentTarget()
            let p = try NRPick.measure(.typed, typedDisplayed: nrNumber(measuredText), offset: scope.offsetPPM)
            hold(t); pick = p; acknowledged = false; message = ""
        } catch { message = error.localizedDescription }
    }
    private func apply() {
        do {
            guard isReferencing, let f = frozen, let p = pick, f.scope == scope else { throw NRFailure("Stale pick") }
            let e = try NRReferenceEdit(scope: f.scope, target: f.target, pick: p, acknowledged: acknowledged)
            try edits.commit(e); clearPick(); isReferencing = false; message = e.report
        } catch { message = error.localizedDescription }
    }
    private func undo() {
        guard let id = undoableID else { return }
        do { try edits.undo(scope, id); clearPick(); message = "Last reference undone." } catch { message = error.localizedDescription }
    }

    private var chooser: some View {
        VStack(alignment: .leading) {
            HStack {
                Picker("参考溶剂", selection: $group) {
                    Text("请选择…").tag(""); ForEach(groups) { g in Text(g.name).tag(g.id) }; Text("自定义…").tag("custom")
                }.onChange(of: group) { _ in lineID = "" }
                if group != "custom" {
                    Picker("参考位点", selection: $lineID) {
                        Text("请选择…").tag("")
                        ForEach(available.filter { $0.groupKey == group }) { t in Text("\(t.material): \(t.site) (\(String(t.ppm)) ppm)").tag(t.id) }
                    }
                }
            }
            if group == "custom" {
                HStack { TextField("标准名称", text: $customName); TextField("参考溶剂（可选）", text: $customSolvent); TextField("目标 ppm", text: $customValue) }
                Toggle("目标值对应多重峰中心", isOn: $customCenter)
            }
            if let t = target, !t.note.isEmpty { Text(t.note).font(.callout) }
        }.disabled(frozen != nil)
    }
    private var acquisition: some View {
        VStack(alignment: .leading) {
            Picker("实测位置来源", selection: Binding(get: { effective }, set: { method = $0 })) {
                ForEach(NRMethod.allCases.filter { target?.permits($0) != false }, id: \.self) { m in Text(m.label).tag(m) }
            }.disabled(frozen != nil)
            if effective == .typed {
                HStack { TextField("实测 ppm（当前坐标）", text: $measuredText); Button("预览偏移") { stageTyped() } }.disabled(frozen != nil || target == nil)
            } else if effective == .midpoint {
                Text("点选同一多重峰两端的对称谱线，以中点定标。")
            } else if effective == .freeClick { Text("按点击位置取 ppm。") }
            else { Text("橙色圆环表示已吸附峰顶，点一下预览偏移。") }
        }
    }
    private var confirmation: some View {
        VStack(alignment: .leading) {
            if let f = frozen, let p = pick {
                let d = f.target.ppm - p.observedPPM
                let bins = p.marks.compactMap { $0.peak }.map { "[\($0.first)…\($0.last)]" }.joined(separator: ", ")
                Text("\(p.method.label) \(bins): \(String(p.observedPPM)) → \(String(f.target.ppm)) ppm (\(f.target.material), \(f.target.site)). Add Δ \(nrSigned(d)) ppm.")
                if !f.target.review.isEmpty { Toggle(f.target.review, isOn: $acknowledged) }
                Button("应用定标") { apply() }.disabled(f.scope != scope || !d.isFinite || !(scope.offsetPPM + d).isFinite || (!f.target.review.isEmpty && !acknowledged))
            }
            if frozen != nil { Button("重新选点") { clearPick(); message = "" } }
        }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            plot().overlay {
                if isReferencing {
                    NRSurface(index: index, radii: radii, offset: scope.offsetPPM, makeMap: map, live: pick == nil && effective != .typed, snap: effective != .freeClick, marks: pick?.marks ?? first.map { [$0] } ?? [], measured: pick?.observedPPM, clicked: click)
                }
            }
            HStack { Toggle("正在选参考峰", isOn: $isReferencing); Spacer(); Button("撤销上次定标") { undo() }.disabled(undoableID == nil) }
            if isReferencing { chooser; acquisition; confirmation }
            if !message.isEmpty { Text(message).font(.callout).textSelection(.enabled) }
        }
        .onChange(of: scope) { _ in
            let hadPick = frozen != nil; clearPick(); measuredText = ""
            if hadPick { message = "Spectrum or axis changed; staged pick discarded." } else { message = "" }
        }
        .onChange(of: isReferencing) { on in if !on { clearPick() } }
    }
}
