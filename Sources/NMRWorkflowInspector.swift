import Foundation
import SwiftUI

private enum NMRPanel { case advanced, child(NMRChildPage) }
private struct NMRPresentation: Identifiable {
    let panel: NMRPanel
    let ticket: NMRTicket
    var id: UUID { ticket.id }
}
private struct NMRReplacement: Identifiable {
    let ticket: NMRTicket
    let pass: NMRPass
    let reason: String
    var id: UUID { ticket.id }
}

// Owns only presentation and the manual editor's lifetime. The host owns spectra, tool selection,
// inline analysis drafts, processing, file panels and undo. Instantiate once per window.
struct NMRWorkflowShell<Plot: View, ContextBar: View, ChildSheet: View>: View {
    let state: NMRWorkflowState
    let calibrationRequest: UUID?
    @Binding private var activeTool: NMRPostTool?
    private let handle: (NMRTicket, NMRRequest) -> Bool
    private let previewPhase: (NMRTicket, NMRPhase) -> Void
    private let endPreview: (NMRTicket) -> Void
    private let onLockChange: (Bool) -> Void
    private let plot: (NMRPostTool?, Bool) -> Plot
    private let contextualToolbar: (NMRPostTool) -> ContextBar
    private let childSheet: (NMRChildPage, NMRSheetSession) -> ChildSheet

    @State private var deep = false
    @State private var manual: NMRTicket?
    @State private var page: NMRPresentation?
    @State private var replacement: NMRReplacement?

    init(state: NMRWorkflowState, activeTool: Binding<NMRPostTool?>, calibrationRequest: UUID? = nil,
         handle: @escaping (NMRTicket, NMRRequest) -> Bool,
         previewPhase: @escaping (NMRTicket, NMRPhase) -> Void,
         endPreview: @escaping (NMRTicket) -> Void,
         onLockChange: @escaping (Bool) -> Void = { _ in },
         @ViewBuilder plot: @escaping (NMRPostTool?, Bool) -> Plot,
         @ViewBuilder contextualToolbar: @escaping (NMRPostTool) -> ContextBar,
         @ViewBuilder childSheet: @escaping (NMRChildPage, NMRSheetSession) -> ChildSheet) {
        self.state = state; _activeTool = activeTool; self.calibrationRequest = calibrationRequest
        self.handle = handle; self.previewPhase = previewPhase; self.endPreview = endPreview
        self.onLockChange = onLockChange; self.plot = plot
        self.contextualToolbar = contextualToolbar; self.childSheet = childSheet
    }

    private var unoccupied: Bool {
        state.activity == .idle && manual == nil && page == nil && replacement == nil
    }
    private var free: Bool { unoccupied && state.inlineDraft == .none }
    private var toolInput: Bool {
        guard unoccupied, state.hasSpectrum, let t = activeTool else { return false }
        return state.inlineDraft != .none || state.availableTools.contains(t)
    }
    private var ui: NMRWorkflowControls {
        NMRWorkflowControls(quickTitle: state.quickPass.title, deep: deep, tool: activeTool, allows: allows, send: send)
    }
    private func allows(_ c: NMRWorkflowCommand) -> Bool {
        guard free else { return false }
        switch c {
        case .open, .depth: return true
        case .save: return state.canSave
        case .undo: return state.canUndo
        case .redo: return state.canRedo
        case .history: return state.hasHistory || state.canUndo || state.canRedo
        case .quick, .baselineOnly, .calibrate: return state.hasSpectrum
        case .phaseOnly: return state.kind == .complex
        case .tool(let t): return state.hasSpectrum && (t.map { state.availableTools.contains($0) } ?? true)
        case .export(let e):
            guard state.hasSpectrum else { return false }
            switch e {
            case .selectionCSV: return state.hasSelection
            case .measurements: return state.hasMeasurements
            default: return true
            }
        }
    }
    private func request(_ r: NMRRequest) { _ = handle(NMRTicket(state.revision), r) }
    private func present(_ panel: NMRPanel) {
        guard free else { return }
        page = NMRPresentation(panel: panel, ticket: NMRTicket(state.revision))
    }
    private func run(_ pass: NMRPass) {
        if let why = state.replacementWarnings[pass] {
            replacement = NMRReplacement(ticket: NMRTicket(state.revision), pass: pass, reason: why)
        } else { request(.process(pass)) }
    }
    private func send(_ c: NMRWorkflowCommand) {
        guard allows(c) else { return }
        switch c {
        case .open: request(.open)
        case .save: request(.save)
        case .undo: request(.undo)
        case .redo: request(.redo)
        case .history: present(.child(.history))
        case .quick: run(state.quickPass)
        case .phaseOnly: run(.phaseOnly)
        case .baselineOnly: run(.baselineOnly)
        case .calibrate: present(.child(.calibration))
        case .depth: deep.toggle()
        case .tool(let t): activeTool = t
        case .export(let e): request(.export(e))
        }
    }
    private func confirm(_ r: NMRReplacement) {
        replacement = nil
        guard free, r.ticket.revision == state.revision, state.hasSpectrum,
              r.pass == .baselineOnly || state.kind == .complex else { return }
        _ = handle(r.ticket, .process(r.pass))
    }
    private var status: String {
        if let message = state.activity.message { return message }
        if manual != nil { return "手动相位预览 · 请应用或放弃" }
        if state.inlineDraft != .none { return "工具草稿 · 请应用或放弃" }
        if !state.notice.isEmpty { return state.notice }
        return state.hasSpectrum ? "就绪" : "未打开频谱"
    }

    var body: some View {
        VStack(spacing: 0) {
            // Keep this subtree mounted. A tool change is input, not a new plot identity.
            plot(activeTool, toolInput).frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            NMRWorkflowInspector(state: state, status: status, ui: ui, context: contextRow, detail: detailRow)
        }
        .frame(minWidth: 760, minHeight: 320)
        .toolbar { NMRWorkflowToolbar(ui: ui) }
        .focusedSceneValue(\.nmrWorkflow, ui)
        .sheet(item: $page) { p in
            sheetBody(p).id(p.id).interactiveDismissDisabled(true)
                .onDisappear { endPreview(p.ticket) }
        }
        .alert(item: $replacement) { r in
            Alert(title: Text("替换现有校正？"), message: Text(r.pass.title + "：" + r.reason),
                  primaryButton: .destructive(Text("替换并处理")) { confirm(r) }, secondaryButton: .cancel(Text("取消")))
        }
        .onChange(of: calibrationRequest) { _ in if free { present(.child(.calibration)) } }
        .onChange(of: state.revision) { v in
            if let t = manual, t.revision != v { endManual(t) }
            if let p = page, p.ticket.revision != v { close(p) }
            if let r = replacement, r.ticket.revision != v { replacement = nil }
        }
        .onAppear { onLockChange(!free) }
        .onChange(of: free) { onLockChange(!$0) }
        .onDisappear {
            if let t = manual { endManual(t) }
            if let p = page { close(p) }
            onLockChange(false)
        }
    }

    @ViewBuilder private var contextRow: some View {
        if let t = activeTool {
            HStack(spacing: 8) {
                Text(t.rawValue).fontWeight(.medium).fixedSize().accessibilityLabel(Text("当前工具：" + t.rawValue))
                Divider().frame(height: 16)
                ScrollView(.horizontal) {
                    contextualToolbar(t).fixedSize(horizontal: true, vertical: false).padding(.horizontal, 3)
                }.disabled(!toolInput)
                if state.inlineDraft != .none {
                    Button("应用") { if toolInput && state.inlineDraft == .valid { request(.applyToolDraft(t)) } }
                        .disabled(!toolInput || state.inlineDraft != .valid).help("应用当前工具草稿")
                    Button("放弃") { if toolInput && state.inlineDraft != .none { request(.discardToolDraft(t)) } }
                        .disabled(!toolInput).help("放弃当前工具草稿，不写入历史")
                } else {
                    Button(t.rawValue + "面板…") { if allows(.tool(t)) { present(.child(.tool(t))) } }
                        .disabled(!allows(.tool(t))).help("打开当前工具的详细面板")
                    Button { send(.tool(nil)) } label: { Image(systemName: "xmark.circle") }
                        .disabled(!allows(.tool(nil))).accessibilityLabel("退出当前工具").help("退出当前工具")
                }
            }
        } else {
            EmptyView()
        }
    }

    private func manualOK(_ t: NMRTicket) -> Bool {
        manual == t && t.revision == state.revision && state.kind == .complex && state.activity == .idle && state.inlineDraft == .none
    }
    private func endManual(_ t: NMRTicket) {
        guard manual == t else { return }
        manual = nil; endPreview(t)
    }
    @ViewBuilder private var detailRow: some View {
        if !deep {
            Text(detailRowHintKey)
                .foregroundStyle(.secondary)
        } else if let t = manual {
            let editor = NMRManualPhaseEditor(
                initial: state.phase,
                enabled: manualOK(t),
                preview: { value in
                    if manualOK(t) { previewPhase(t, value) }
                },
                apply: { value in
                    if manualOK(t), handle(t, .applyPhase(value)) { endManual(t) }
                },
                discard: { endManual(t) }
            )
            editor.id(t.id)
        } else {
            detailRowControls
        }
    }

    private var detailRowHintKey: LocalizedStringKey {
        if !state.hasSpectrum {
            return "打开 FID、频域谱或工程以开始。"
        }
        if state.kind == .realOnly {
            return "实数频域谱 · 可直接校正基线"
        }
        return "频域处理 · 先校正相位，再校正基线"
    }

    private var detailRowControls: some View {
        HStack(spacing: 10) {
            detailRowPhaseStatus
            Spacer(minLength: 4)
            detailRowManualButton
            detailRowAdvancedButton
        }
    }

    @ViewBuilder private var detailRowPhaseStatus: some View {
        if state.kind == .complex {
            Text(detailRowPhaseText)
                .monospacedDigit()
                .lineLimit(1)
                .help("当前已应用的绝对相位及一阶相位支点")
        } else {
            let status: LocalizedStringKey = state.hasSpectrum ? "实数谱没有相位通道" : "无频谱"
            Text(status)
                .foregroundStyle(.secondary)
        }
    }

    private var detailRowPhaseText: String {
        let ph0: String = NMRNumber.brief(state.phase.ph0)
        let ph1: String = NMRNumber.brief(state.phase.ph1)
        let pivot: String = NMRNumber.brief(state.phase.pivotPPM)
        return "ph0 \(ph0)°   ph1 \(ph1)°   pivot \(pivot) ppm"
    }

    private var detailRowManualButton: some View {
        Button("手动相位…") {
            if allows(.phaseOnly) { manual = NMRTicket(state.revision) }
        }
        .disabled(!allows(.phaseOnly))
        .help("编辑 ph0、ph1 和 pivot；先预览，再应用。")
    }

    private var detailRowAdvancedButton: some View {
        Button("高级设置…") {
            if free && state.hasSpectrum { present(.advanced) }
        }
        .disabled(!free || !state.hasSpectrum)
        .help("指数展宽、补零及兼容选项")
    }

    private func sheetOK(_ p: NMRPresentation) -> Bool {
        page?.id == p.id && state.revision == p.ticket.revision && state.activity == .idle && state.inlineDraft == .none
    }
    private func close(_ p: NMRPresentation) {
        guard page?.id == p.id else { return }
        page = nil; endPreview(p.ticket)
    }
    @ViewBuilder private func sheetBody(_ p: NMRPresentation) -> some View {
        switch p.panel {
        case .advanced:
            NMRAdvancedSheet(state: state, enabled: sheetOK(p), apply: { options in
                if sheetOK(p), handle(p.ticket, .applyOptions(options)) { close(p) }
            }, cancel: { close(p) })
        case .child(let kind):
            let session = NMRSheetSession(ticket: p.ticket, canApply: sheetOK(p), apply: { write in
                guard sheetOK(p) else { return }
                if write() { close(p) }
            }, cancel: { close(p) })
            childSheet(kind, session).disabled(!session.canApply)
        }
    }
}

// A fixed utility deck, not a sidebar competing for ppm-axis width. Only the injected strip scrolls.
struct NMRWorkflowInspector<Context: View, Detail: View>: View {
    let state: NMRWorkflowState
    let status: String
    let ui: NMRWorkflowControls
    let context: Context
    let detail: Detail
    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 8) {
                Text(state.nucleus + " · 偏移 " + state.offsetTitle).monospacedDigit().fixedSize()
                    .help("当前核种与加性偏移：显示 ppm = 原 ppm + 偏移。")
                Divider().frame(height: 14)
                if state.activity != .idle { ProgressView().controlSize(.small).accessibilityLabel(Text(status)) }
                Text(status).foregroundStyle(.secondary).lineLimit(1).help(status)
                Spacer(minLength: 4)
                Button(ui.deep ? "隐藏深度处理" : "显示深度处理") { ui.send(.depth) }
                    .disabled(!ui.allows(.depth)).help("显示或隐藏手动相位与高级设置入口，不改变频谱。")
            }.frame(height: 26)
            context.frame(maxWidth: .infinity, alignment: .leading).frame(height: 30)
            detail.frame(maxWidth: .infinity, alignment: .leading).frame(height: 30)
        }
        .controlSize(.small).padding(.horizontal, 12).frame(height: 108)
    }
}

private enum NMRNumber {
    // Round-trip the editing value. No grouping, snapping to a preset, or rounding on sheet open.
    static func edit(_ x: Double) -> String {
        String(x).replacingOccurrences(of: ".", with: Locale.current.decimalSeparator ?? ".")
    }
    static func parse(_ s: String) -> Double? {
        let text = s.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: Locale.current.decimalSeparator ?? ".", with: ".")
        guard let v = Double(text), v.isFinite else { return nil }
        return v
    }
    static func brief(_ x: Double) -> String { String(format: "%.6g", locale: Locale.current, x) }
}

private struct NMRManualPhaseEditor: View {
    let initial: NMRPhase
    let enabled: Bool
    let preview: (NMRPhase) -> Void
    let apply: (NMRPhase) -> Void
    let discard: () -> Void
    @State private var p0: String
    @State private var p1: String
    @State private var pivot: String
    @FocusState private var focused: Int?
    init(initial: NMRPhase, enabled: Bool, preview: @escaping (NMRPhase) -> Void,
         apply: @escaping (NMRPhase) -> Void, discard: @escaping () -> Void) {
        self.initial = initial; self.enabled = enabled; self.preview = preview; self.apply = apply; self.discard = discard
        _p0 = State(initialValue: NMRNumber.edit(initial.ph0)); _p1 = State(initialValue: NMRNumber.edit(initial.ph1))
        _pivot = State(initialValue: NMRNumber.edit(initial.pivotPPM))
    }
    private var value: NMRPhase? {
        guard let a = NMRNumber.parse(p0), let b = NMRNumber.parse(p1), let c = NMRNumber.parse(pivot) else { return nil }
        return NMRPhase(ph0: a, ph1: b, pivotPPM: c)
    }
    private func field(_ name: String, _ text: Binding<String>, _ key: Int, _ tip: String) -> some View {
        HStack(spacing: 3) {
            Text(name).fixedSize()
            TextField(name, text: text).labelsHidden().textFieldStyle(.roundedBorder)
                .frame(width: key == 2 ? 78 : 64).focused($focused, equals: key)
                .accessibilityLabel(Text(name + "，" + tip)).disabled(!enabled)
        }.help(tip)
    }
    var body: some View {
        HStack(spacing: 8) {
            field("ph0", $p0, 0, "零阶相位（°），全谱一致。")
            field("ph1", $p1, 1, "一阶相位（°），跨谱宽线性变化。")
            field("pivot (ppm)", $pivot, 2, "一阶相位在此 ppm 处为零。")
            if value == nil { Text("数值无效").foregroundStyle(.secondary).help("保持上次有效预览；不能应用。") }
            Spacer(minLength: 2)
            Button("应用") { if enabled, let v = value, v != initial { apply(v) } }
                .disabled(!enabled || value == nil || value == initial).keyboardShortcut(.defaultAction)
                .help("应用手动相位，一次撤销可还原。")
            Button("放弃", action: discard).keyboardShortcut(.cancelAction).help("返回已应用的频谱，不写入历史。")
        }
        .onAppear { focused = 0 }
        .onChange(of: value) { v in if enabled, let v = v { preview(v) } }
    }
}

private struct NMRAdvancedSheet: View {
    let state: NMRWorkflowState
    let enabled: Bool
    let apply: (NMRWorkflowOptionsDraft) -> Void
    let cancel: () -> Void
    @State private var overrideLB: Bool
    @State private var lb: String
    @State private var factor: String
    @State private var endpoint: Bool
    @State private var compatibility = false
    init(state: NMRWorkflowState, enabled: Bool, apply: @escaping (NMRWorkflowOptionsDraft) -> Void, cancel: @escaping () -> Void) {
        self.state = state; self.enabled = enabled; self.apply = apply; self.cancel = cancel
        let o = state.options
        _overrideLB = State(initialValue: o.exponentialLBHz != nil)
        _lb = State(initialValue: (o.exponentialLBHz ?? state.nucleusDefaultLBHz).map(NMRNumber.edit) ?? "")
        _factor = State(initialValue: NMRNumber.edit(o.zeroFillFactor))
        _endpoint = State(initialValue: o.endpointLinearBaseline)
    }
    private var proposal: NMRWorkflowOptionsDraft? {
        var o = state.options
        if state.hasSourceFID {
            guard let z = NMRNumber.parse(factor), [1, 2, 4].contains(z) else { return nil }
            o.zeroFillFactor = z
            if overrideLB {
                guard let width = NMRNumber.parse(lb), (0...10000).contains(width) else { return nil }
                o.exponentialLBHz = width
            } else { o.exponentialLBHz = nil }
        }
        o.endpointLinearBaseline = endpoint
        return o
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("高级处理设置").font(.headline)
            Text(state.hasSourceFID ? "原始 FID · 加窗 → 补零 → FFT" : "没有原始 FID；不能更改加窗和补零。 ").foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 8) {
                Text(state.nucleus + " · 默认指数 LB：" + (state.nucleusDefaultLBHz.map { NMRNumber.brief($0) + " Hz" } ?? "按核种"))
                HStack {
                    Toggle("指定指数 LB", isOn: $overrideLB)
                        .help("关闭时按核种取默认值；显式 0 Hz 与未指定不同。")
                    TextField("LB (Hz)", text: $lb).frame(width: 82).disabled(!overrideLB).accessibilityLabel("显式指数 LB，Hz")
                    Text("Hz")
                }
                HStack {
                    Text("补零系数")
                    TextField("倍数", text: $factor).frame(width: 82).accessibilityLabel("补零系数，倍")
                    Text("×")
                }.help("新数据默认 2×。可用系数为 1、2 或 4。")
            }.disabled(!enabled || !state.hasSourceFID)
            DisclosureGroup("兼容选项", isExpanded: $compatibility) {
                Toggle("端点线性基线", isOn: $endpoint).disabled(!enabled)
                    .help("可选的端点直线处理；新工程默认关闭，不是常规基线校正的开关。")
                    .padding(.top, 4)
            }
            Text(proposal == nil ? "请输入有效数值：LB 为 0…10000 Hz，补零系数为 1、2 或 4。" : state.optionsImpact)
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if !state.notice.isEmpty { Text(state.notice).font(.callout).foregroundStyle(.secondary) }
            Divider()
            HStack {
                Spacer()
                Button("取消", action: cancel).keyboardShortcut(.cancelAction)
                Button("应用设置") { if enabled, let o = proposal, o != state.options { apply(o) } }
                    .disabled(!enabled || proposal == nil || proposal == state.options).keyboardShortcut(.defaultAction)
            }
        }.textFieldStyle(.roundedBorder).padding(16).frame(width: 440)
    }
}
