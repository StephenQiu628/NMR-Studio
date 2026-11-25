import Foundation
import SwiftUI

// UI contract. Put both files in the same macOS target. No processor or document singleton.
enum NMRSpectrumKind: Equatable { case none, realOnly, complex }
enum NMRActivity: Equatable {
    case idle, loading, busy(String)
    var message: String? {
        switch self {
        case .idle: return nil
        case .loading: return "正在打开…"
        case .busy(let operation): return operation.isEmpty ? "正在处理…" : operation
        }
    }
}

enum NMRPass: Hashable {
    case phaseThenBaseline, phaseOnly, baselineOnly
    var title: String {
        switch self {
        case .phaseThenBaseline: return "相位＋基线"
        case .phaseOnly: return "仅相位校正"
        case .baselineOnly: return "仅基线校正"
        }
    }
}

enum NMRPostTool: String, CaseIterable, Hashable, Identifiable {
    case region = "选区域", normalize = "归一化", integrate = "积分"
    case deconvolve = "去卷积", markPeaks = "标峰", coupling = "J 值/峰形"
    var id: Self { self }
}

enum NMRExport: String, CaseIterable, Hashable, Identifiable {
    case fullCSV = "全谱 CSV…", selectionCSV = "选区 CSV…"
    case png = "PNG · 2400 px…", png1200 = "PNG · 1200 px…", png3600 = "PNG · 3600 px…"
    case pdf = "PDF…", measurements = "测量结果…", analysis = "区域分析 CSV…"
    var id: Self { self }
}

struct NMRPhase: Equatable {
    var ph0: Double = 0       // degrees; absolute settings, not increments
    var ph1: Double = 0       // degrees across the host's spectral width
    var pivotPPM: Double = 0  // in the displayed ppm coordinate system
}

struct NMRWorkflowOptionsDraft: Equatable {
    var exponentialLBHz: Double? = nil  // nil = resolve using nucleus at processing time
    var zeroFillFactor: Double = 2
    var endpointLinearBaseline = false
}

enum NMRInlineDraft: Equatable { case none, invalid, valid }

struct NMRWorkflowState {
    // Stable across redraws/previews. Replace on document replacement or committed edit/undo.
    var revision = UUID()
    var kind: NMRSpectrumKind = .none
    var activity: NMRActivity = .idle
    var hasSourceFID = false
    var nucleus = "—"
    var offsetPPM: Double = 0
    var phase = NMRPhase()
    var options = NMRWorkflowOptionsDraft()
    var nucleusDefaultLBHz: Double? = nil
    var canSave = false
    var canUndo = false
    var canRedo = false
    var hasHistory = false
    var hasSelection = false
    var hasMeasurements = false
    var availableTools = Set(NMRPostTool.allCases)
    var inlineDraft: NMRInlineDraft = .none // belongs to the explicitly active tool
    var replacementWarnings: [NMRPass: String] = [:] // non-nil for a pass that replaces user work
    var optionsImpact = "应用后按这些设置更新频谱；取消不更改工程。"
    var notice = "" // e.g. last result or recoverable error

    var hasSpectrum: Bool { kind != .none }
    var quickPass: NMRPass { kind == .realOnly ? .baselineOnly : .phaseThenBaseline }
    var offsetTitle: String { String(format: "%+.5f", locale: Locale.current, offsetPPM) + " ppm" }
    static let calibrationHelp = "独立调整 ppm 轴的加性偏移。可参考已知的溶质峰，或与样品条件相符的残余溶剂峰；请核对参考值。"
}

struct NMRTicket: Identifiable, Equatable {
    let id = UUID()
    let revision: UUID
    init(_ revision: UUID) { self.revision = revision }
}

// The host returns true if it accepted the request, not necessarily if background work is finished.
enum NMRRequest {
    case open, save, undo, redo
    case process(NMRPass), applyPhase(NMRPhase), applyOptions(NMRWorkflowOptionsDraft)
    case applyToolDraft(NMRPostTool), discardToolDraft(NMRPostTool)
    case export(NMRExport)
}

enum NMRChildPage: Hashable {
    case calibration, tool(NMRPostTool), history
    var title: String {
        switch self {
        case .calibration: return "化学位移定标"
        case .tool(let t): return t.rawValue
        case .history: return "处理历史"
        }
    }
}

struct NMRSheetSession {
    let ticket: NMRTicket
    let canApply: Bool
    // Invoked by the child's explicit Apply button. Refusal keeps the sheet open.
    let apply: (_ write: () -> Bool) -> Void
    let cancel: () -> Void
}

enum NMRWorkflowCommand: Hashable {
    case open, save, undo, redo, history, quick, phaseOnly, baselineOnly, calibrate, depth
    case tool(NMRPostTool?), export(NMRExport)
}

struct NMRWorkflowControls {
    let quickTitle: String
    let deep: Bool
    let tool: NMRPostTool?
    let allows: (NMRWorkflowCommand) -> Bool
    let send: (NMRWorkflowCommand) -> Void
}

private struct NMRControlsKey: FocusedValueKey { typealias Value = NMRWorkflowControls }
extension FocusedValues {
    var nmrWorkflow: NMRWorkflowControls? {
        get { self[NMRControlsKey.self] }
        set { self[NMRControlsKey.self] = newValue }
    }
}

private struct NMRItem: View {
    let title: String
    let command: NMRWorkflowCommand
    let ui: NMRWorkflowControls?
    let symbol: String?
    init(_ title: String, _ command: NMRWorkflowCommand, _ ui: NMRWorkflowControls?, symbol: String? = nil) {
        self.title = title; self.command = command; self.ui = ui; self.symbol = symbol
    }
    var body: some View {
        Button {
            if let ui = ui, ui.allows(command) { ui.send(command) }
        } label: {
            if let symbol = symbol { Label(title, systemImage: symbol) } else { Text(title) }
        }
        .disabled(!(ui?.allows(command) ?? false))
    }
}

private struct NMRToolItems: View {
    let ui: NMRWorkflowControls?
    var body: some View {
        ForEach(NMRPostTool.allCases) { t in
            NMRItem(t.rawValue, .tool(t), ui, symbol: ui?.tool == t ? "checkmark" : nil)
        }
        Divider()
        NMRItem("退出当前工具", .tool(nil), ui).disabled(ui?.tool == nil)
    }
}

private struct NMRExportItems: View {
    let ui: NMRWorkflowControls?
    var body: some View {
        ForEach(NMRExport.allCases) { e in NMRItem(e.rawValue, .export(e), ui) }
    }
}

struct NMRWorkflowToolbar: ToolbarContent {
    let ui: NMRWorkflowControls
    var body: some ToolbarContent {
        ToolbarItem(placement: .navigation) {
            Menu {
                NMRItem("打开…", .open, ui)
                NMRItem("保存", .save, ui)
                Divider()
                NMRItem("撤销", .undo, ui)
                NMRItem("处理历史…", .history, ui)
            } label: {
                Label("打开", systemImage: "folder").labelStyle(.titleAndIcon)
            } primaryAction: {
                ui.send(.open)
            }
            .disabled(!ui.allows(.open))
            .help("打开 FID、频域谱或工程。菜单另有保存、撤销及处理历史。")
        }
        ToolbarItemGroup(placement: .primaryAction) {
            HStack(spacing: 3) {
                NMRItem(ui.quickTitle, .quick, ui)
                    .buttonStyle(.borderedProminent)
                    .fixedSize()
                    .help(ui.quickTitle == NMRPass.baselineOnly.title ? "实数谱：只校正基线。" : "一次处理：先校正相位，再校正基线。")
                Menu {
                    NMRItem(NMRPass.phaseOnly.title, .phaseOnly, ui)
                    NMRItem(NMRPass.baselineOnly.title, .baselineOnly, ui)
                } label: { Image(systemName: "ellipsis.circle") }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .disabled(!ui.allows(.quick))
                .accessibilityLabel("单项校正")
                .help("选择单项校正")
            }
            NMRItem("化学位移定标", .calibrate, ui).fixedSize().help(NMRWorkflowState.calibrationHelp)
            Menu("后处理工具") { NMRToolItems(ui: ui) }
                .disabled(!ui.allows(.tool(nil)))
                .help("选择当前工具；工具之间没有规定顺序。")
            Menu { NMRExportItems(ui: ui) } label: { Label("导出", systemImage: "square.and.arrow.up") }
                .disabled(!ui.allows(.export(.fullCSV)))
                .accessibilityLabel("导出")
                .help("导出已应用的频谱、图像或测量结果")
        }
    }
}

// Per-window commands, including when focus is in a child of the content view.
struct NMRWorkflowCommands: Commands {
    @FocusedValue(\.nmrWorkflow) private var ui
    var body: some Commands {
        CommandMenu("工作流") {
            NMRItem(ui?.quickTitle ?? NMRPass.phaseThenBaseline.title, .quick, ui)
                .keyboardShortcut(.return, modifiers: [.command, .shift])
            NMRItem(NMRPass.phaseOnly.title, .phaseOnly, ui).keyboardShortcut("p", modifiers: [.command, .option])
            NMRItem(NMRPass.baselineOnly.title, .baselineOnly, ui)
            Divider()
            NMRItem("化学位移定标…", .calibrate, ui).keyboardShortcut("k", modifiers: [.command, .option])
            Menu("后处理工具") { NMRToolItems(ui: ui) }
            Menu("导出") { NMRExportItems(ui: ui) }
            Divider()
            NMRItem((ui?.deep ?? false) ? "隐藏深度处理" : "显示深度处理", .depth, ui)
                .keyboardShortcut("i", modifiers: [.command, .shift])
            NMRItem("处理历史…", .history, ui)
        }
    }
}

// Optional for a standalone WindowGroup. Do not install over an existing document app's File/Edit commands.
struct NMRStandaloneDocumentCommands: Commands {
    @FocusedValue(\.nmrWorkflow) private var ui
    var body: some Commands {
        CommandGroup(replacing: .newItem) { NMRItem("打开…", .open, ui).keyboardShortcut("o") }
        CommandGroup(replacing: .saveItem) { NMRItem("保存", .save, ui).keyboardShortcut("s") }
        CommandGroup(replacing: .undoRedo) {
            NMRItem("撤销", .undo, ui).keyboardShortcut("z")
            NMRItem("重做", .redo, ui).keyboardShortcut("z", modifiers: [.command, .shift])
        }
    }
}
