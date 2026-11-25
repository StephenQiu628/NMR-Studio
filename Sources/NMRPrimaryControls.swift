import SwiftUI
import AppKit

public enum NMRSimpleTool: String, CaseIterable, Hashable, Identifiable, Sendable {
    case zoom, solventReference, integral, markPeaks

    public var id: Self { self }

    public var title: String {
        switch self {
        case .zoom:             return "缩放"
        case .solventReference: return "溶剂参考"
        case .integral:         return "积分"
        case .markPeaks:        return "标峰"
        }
    }

    public var hint: String {
        switch self {
        case .zoom:             return "横向拖选要放大的范围，按 ⌘0 恢复全谱。"
        case .solventReference: return "点选可见的溶剂峰，检查吸附位置后确认参考值。"
        case .integral:         return "横向拖选积分区间；点选下方括线可编辑该积分。"
        case .markPeaks:        return "框选 ppm 和强度范围。可连续标峰，再打开峰组审阅。"
        }
    }

    fileprivate var symbol: String {
        switch self {
        case .zoom:             return "magnifyingglass"
        case .solventReference: return "scope"
        case .integral:         return "sum"
        case .markPeaks:        return "pencil.tip"
        }
    }

    fileprivate var key: Character {
        switch self {
        case .zoom:             return "1"
        case .solventReference: return "2"
        case .integral:         return "3"
        case .markPeaks:        return "4"
        }
    }
}

public struct NMRToolCallbacks<Scope> {
    public typealias Arm = @MainActor (Scope) -> Void
    public let zoom: Arm
    public let solventReference: Arm
    public let integral: Arm
    public let markPeaks: Arm

    public init(zoom: @escaping Arm, solventReference: @escaping Arm,
                integral: @escaping Arm, markPeaks: @escaping Arm) {
        self.zoom = zoom
        self.solventReference = solventReference
        self.integral = integral
        self.markPeaks = markPeaks
    }

    @MainActor fileprivate func activate(_ tool: NMRSimpleTool, in scope: Scope) {
        switch tool {
        case .zoom:             zoom(scope)
        case .solventReference: solventReference(scope)
        case .integral:         integral(scope)
        case .markPeaks:        markPeaks(scope)
        }
    }
}

public struct NMRPrimaryExportItem<Scope>: Identifiable {
    public let id: String
    public let title: String
    public let perform: @MainActor (Scope) -> Void

    public init(id: String, title: String, perform: @escaping @MainActor (Scope) -> Void) {
        self.id = id
        self.title = title
        self.perform = perform
    }
}

private struct StudioPrimaryLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        Label(configuration)
            .labelStyle(.titleAndIcon)
            .font(.system(size: 14))
            .padding(.vertical, 1)
    }
}

@MainActor
public struct NMRPrimaryControls<Scope, Workspace: View>: View {
    @Binding private var tool: NMRSimpleTool
    private let hasDocument: Bool
    private let status: String
    private let isBusy: Bool
    private let liveScope: @MainActor () -> Scope?
    private let openDocument: @MainActor () -> Void
    private let saveDocument: @MainActor (Scope) -> Void
    private let existingExports: [NMRPrimaryExportItem<Scope>]
    private let professionalText: @MainActor (Scope) -> Void
    private let tools: NMRToolCallbacks<Scope>
    private let workspace: @MainActor (NMRSimpleTool) -> Workspace

    public init(tool: Binding<NMRSimpleTool>, hasDocument: Bool, status: String,
                isBusy: Bool = false,
                liveScope: @escaping @MainActor () -> Scope?, open: @escaping @MainActor () -> Void,
                save: @escaping @MainActor (Scope) -> Void, existingExports: [NMRPrimaryExportItem<Scope>],
                professionalText: @escaping @MainActor (Scope) -> Void, tools: NMRToolCallbacks<Scope>,
                @ViewBuilder workspace: @escaping @MainActor (NMRSimpleTool) -> Workspace) {
        _tool = tool
        self.hasDocument = hasDocument
        self.status = status
        self.isBusy = isBusy
        self.liveScope = liveScope
        self.openDocument = open
        self.saveDocument = save
        self.existingExports = existingExports
        self.professionalText = professionalText
        self.tools = tools
        self.workspace = workspace
    }

    private var files: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("文件").font(.callout.weight(.semibold)).foregroundStyle(.secondary)
            HStack(spacing: 5) {
                // ⌘O / ⌘S belong to the scene commands; don't register duplicates here.
                Button(action: openDocument) { Label("打开", systemImage: "folder") }
                    .help("打开谱图或工程（⌘O）")
                Button {
                    if let scope = liveScope() { saveDocument(scope) }
                } label: {
                    Label("保存", systemImage: "square.and.arrow.down")
                }
                .disabled(!hasDocument)
                .help("保存工程（⌘S）")

                Menu {
                    ForEach(existingExports) { item in
                        Button(item.title) {
                            if let scope = liveScope() { item.perform(scope) }
                        }
                    }
                } label: {
                    Label("导出", systemImage: "square.and.arrow.up")
                }
                .fixedSize()
                .disabled(!hasDocument || existingExports.isEmpty)
                .help("选择谱图数据或图像的导出格式")

                Button {
                    if let scope = liveScope() { professionalText(scope) }
                } label: {
                    Label("专业 TXT…", systemImage: "doc.plaintext")
                }
                .disabled(!hasDocument)
                .keyboardShortcut("t", modifiers: [.command, .shift])
                .help("编排并导出专业谱图文本")
            }
        }
    }

    private var toolBank: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("谱图工具   ⌘1–4").font(.callout.weight(.semibold)).foregroundStyle(.secondary)
            HStack(spacing: 5) {
                ForEach(NMRSimpleTool.allCases) { item in
                    Toggle(isOn: Binding(
                        get: { tool == item },
                        set: { on in
                            guard on, let scope = liveScope() else { return }
                            tool = item
                            tools.activate(item, in: scope)
                        }
                    )) {
                        Label(item.title, systemImage: item.symbol)
                    }
                    .toggleStyle(.button)
                    .keyboardShortcut(KeyEquivalent(item.key), modifiers: .command)
                    .help("\(item.title)（⌘\(item.key)）\n\(item.hint)")
                    .accessibilityLabel(Text(item.title))
                    .accessibilityValue(Text(tool == item ? "已选定" : "未选定"))
                    .accessibilityHint(Text(item.hint))
                }
            }
            .disabled(!hasDocument)
        }
    }

    public var body: some View {
        GeometryReader { proxy in
            let narrow = proxy.size.width < 880
            let layout = narrow
                ? AnyLayout(VStackLayout(alignment: .leading, spacing: 6))
                : AnyLayout(HStackLayout(alignment: .center, spacing: 14))
            VStack(spacing: 0) {
                layout {
                    files
                    if !narrow { Divider().frame(height: 33) }
                    toolBank
                }
                .labelStyle(StudioPrimaryLabelStyle())
                .controlSize(.regular)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 14)
                .padding(.vertical, 6)
                .disabled(isBusy)

                Divider()
                workspace(tool)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .disabled(isBusy)
                Divider()

                let line = status.isEmpty ? (hasDocument ? "就绪" : "未载入谱图") : status
                HStack(spacing: 7) {
                    if isBusy {
                        ProgressView().controlSize(.small).accessibilityHidden(true)
                    }
                    Text(line).lineLimit(1).truncationMode(.tail)
                    Spacer(minLength: 0)
                }
                .font(.callout)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 14)
                .padding(.vertical, 4)
                .help(line)
                .accessibilityElement(children: .combine)
            }
            .background(Color(nsColor: .windowBackgroundColor))
        }
    }
}
