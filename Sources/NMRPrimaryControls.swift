import SwiftUI
import AppKit

public enum NMRSimpleTool: String, CaseIterable, Hashable, Identifiable, Sendable {
    case zoom, solventReference, integral, markPeaks

    public var id: Self { self }

    public var title: String {
        switch self {
        case .zoom: return "缩放"
        case .solventReference: return "溶剂参考"
        case .integral: return "积分"
        case .markPeaks: return "标峰"
        }
    }

    public var hint: String {
        switch self {
        case .zoom: return "拖选放大，⌘0 恢复全谱。"
        case .solventReference: return "点选溶剂峰并确认参考值。"
        case .integral: return "拖选区间；点选括线，拖动端点。"
        case .markPeaks: return "框选峰组，可连续标峰后审阅。"
        }
    }

    fileprivate var symbol: String {
        switch self {
        case .zoom: return "magnifyingglass"
        case .solventReference: return "scope"
        case .integral: return "sum"
        case .markPeaks: return "pencil.tip"
        }
    }

    fileprivate var key: Character {
        switch self {
        case .zoom: return "1"
        case .solventReference: return "2"
        case .integral: return "3"
        case .markPeaks: return "4"
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
        case .zoom: zoom(scope)
        case .solventReference: solventReference(scope)
        case .integral: integral(scope)
        case .markPeaks: markPeaks(scope)
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

private struct StudioToolbarFace: View {
    let title: String
    let symbol: String
    let width: CGFloat
    var menu = false

    var body: some View {
        VStack(spacing: 7) {
            Image(systemName: symbol)
                .font(.system(size: 24, weight: .medium))
                .frame(height: 28)
            HStack(spacing: 4) {
                Text(title).font(.system(size: 17, weight: .medium))
                if menu {
                    Image(systemName: "chevron.down").font(.system(size: 9, weight: .semibold))
                }
            }
            .lineLimit(1)
            .fixedSize()
        }
        .frame(width: width, height: 76)
        .contentShape(RoundedRectangle(cornerRadius: 9))
    }
}

private struct StudioToolbarSurface: ViewModifier {
    var selected = false
    var pressed = false
    @State private var hovered = false
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.isEnabled) private var enabled

    func body(content: Content) -> some View {
        let colors = StudioColors(dark: colorScheme == .dark)
        return content
            .foregroundStyle(selected ? colors.accent : colors.text)
            .background {
                RoundedRectangle(cornerRadius: 9)
                    .fill(selected ? colors.selection : (hovered || pressed ? colors.raised : Color.clear))
            }
            .overlay {
                RoundedRectangle(cornerRadius: 9)
                    .strokeBorder(selected ? colors.accent.opacity(0.65) :
                                    (hovered ? colors.border : Color.clear), lineWidth: 1)
            }
            .opacity(enabled ? (pressed ? 0.75 : 1) : 0.42)
            .onHover { hovered = $0 }
            .animation(.easeOut(duration: 0.12), value: hovered)
            .animation(.easeOut(duration: 0.12), value: selected)
    }
}

private struct StudioToolbarButtonStyle: ButtonStyle {
    var selected = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.modifier(StudioToolbarSurface(selected: selected, pressed: configuration.isPressed))
    }
}

@MainActor
public struct NMRPrimaryControls<Scope, Workspace: View>: View {
    @Binding private var tool: NMRSimpleTool
    @State private var showingExports = false
    @Environment(\.colorScheme) private var colorScheme
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

    private func files(width: CGFloat) -> some View {
        HStack(spacing: 4) {
            // Scene commands own ⌘O and ⌘S; don't register duplicate shortcuts.
            Button(action: openDocument) {
                StudioToolbarFace(title: "打开", symbol: "folder", width: width)
            }
            .help("打开谱图或工程（⌘O）")
            .accessibilityLabel("打开")

            Button {
                if let scope = liveScope() { saveDocument(scope) }
            } label: {
                StudioToolbarFace(title: "保存", symbol: "square.and.arrow.down", width: width)
            }
            .disabled(!hasDocument)
            .help("保存工程（⌘S）")
            .accessibilityLabel("保存")

            Button { showingExports.toggle() } label: {
                StudioToolbarFace(title: "导出", symbol: "square.and.arrow.up", width: width, menu: true)
            }
            .popover(isPresented: $showingExports, arrowEdge: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(existingExports) { item in
                        Button {
                            showingExports = false
                            if let scope = liveScope() { item.perform(scope) }
                        } label: {
                            Text(item.title)
                                .font(.system(size: 17))
                                .frame(maxWidth: .infinity, minHeight: 36, alignment: .leading)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(14).frame(width: 250)
                .studioTheme()
            }
            .disabled(!hasDocument || existingExports.isEmpty)
            .help("导出谱图数据或图像")
            .accessibilityLabel("导出")

            Button {
                if let scope = liveScope() { professionalText(scope) }
            } label: {
                StudioToolbarFace(title: "专业TXT", symbol: "doc.plaintext", width: width)
            }
            .disabled(!hasDocument)
            .keyboardShortcut("t", modifiers: [.command, .shift])
            .help("专业文本报表（⇧⌘T）")
            .accessibilityLabel("专业 TXT")
        }
        .buttonStyle(StudioToolbarButtonStyle())
        .disabled(isBusy)
    }

    private func toolBank(width: CGFloat) -> some View {
        HStack(spacing: 4) {
            ForEach(NMRSimpleTool.allCases) { item in
                Button {
                    guard let scope = liveScope() else { return }
                    tool = item
                    tools.activate(item, in: scope)
                } label: {
                    StudioToolbarFace(title: item.title, symbol: item.symbol, width: width)
                }
                .buttonStyle(StudioToolbarButtonStyle(selected: tool == item))
                .keyboardShortcut(KeyEquivalent(item.key), modifiers: .command)
                .help("\(item.title)（⌘\(item.key)）· \(item.hint)")
                .accessibilityLabel(Text(item.title))
                .accessibilityValue(Text(tool == item ? "已选定" : "未选定"))
                .accessibilityHint(Text(item.hint))
            }
        }
        .disabled(!hasDocument || isBusy)
    }

    public var body: some View {
        GeometryReader { proxy in
            let colors = StudioColors(dark: colorScheme == .dark)
            let width = min(CGFloat(110), max(CGFloat(82), (proxy.size.width - 192) / 8))
            VStack(spacing: 0) {
                HStack(spacing: 0) {
                    files(width: width)
                    Divider().frame(height: 52).padding(.horizontal, 14)
                    toolBank(width: width)
                    Spacer(minLength: 12)
                    StudioAppearanceMenu().frame(width: 92)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .background(colors.panel)

                Rectangle().fill(colors.border).frame(height: 1)
                workspace(tool)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .disabled(isBusy)
                Rectangle().fill(colors.border).frame(height: 1)

                let line = status.isEmpty ? (hasDocument ? "就绪" : "未载入谱图") : status
                HStack(spacing: 10) {
                    if isBusy {
                        ProgressView().controlSize(.small).accessibilityHidden(true)
                    }
                    Text(line).lineLimit(1).truncationMode(.tail)
                        .help(line).layoutPriority(1)
                    Spacer(minLength: 12)
                    if hasDocument && !isBusy {
                        Text(tool.hint).lineLimit(1).help(tool.hint)
                    }
                }
                .font(.system(size: 15))
                .foregroundStyle(colors.secondary)
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .background(colors.panel)
                .accessibilityElement(children: .combine)
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
            .background(colors.background)
        }
    }
}
