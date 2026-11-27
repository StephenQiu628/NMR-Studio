import SwiftUI
import AppKit

@MainActor
struct StudioView: View {
    @ObservedObject var w: Workbench
    let initialTool: NMRSimpleTool
    @AppStorage("NMRStudio.appearance") private var storedAppearance = "dark"
    @Environment(\.colorScheme) private var colorScheme

    init(w: Workbench, initialTool: NMRSimpleTool = .zoom) {
        self.w = w
        self.initialTool = initialTool
    }

    private var appearance: StudioAppearance {
        StudioAppearance(rawValue: storedAppearance) ?? .dark
    }

    var body: some View {
        let colors = StudioColors(dark: (appearance.colorScheme ?? colorScheme) == .dark)
        DocumentStudio(w: w, document: w.documentRevision, initialTool: initialTool)
            // Even reopening the same saved project is a new UI lifetime.
            .id(w.documentRevision)
            .font(.system(size: 17))
            .foregroundStyle(colors.text)
            .frame(minWidth: 1040, idealWidth: 1280, minHeight: 700, idealHeight: 820)
            .background(colors.background)
            .background(StudioWindowAppearance(appearance: appearance).frame(width: 0, height: 0))
            .onOpenURL { url in
                if !w.busy, url.isFileURL { w.requestLoad(url) }
            }
            .sheet(isPresented: $w.showHistory) {
                OperationHistoryView(w: w).studioTheme()
            }
            .alert("操作未完成", isPresented: Binding(
                get: { w.error != nil },
                set: { if !$0 { w.error = nil } }
            )) {
                Button("确定", role: .cancel) { w.error = nil }
            } message: {
                Text(w.error ?? "")
            }
            .tint(colors.accent)
            .preferredColorScheme(appearance.colorScheme)
    }
}

// Workbench and its nested peak workspace publish independently. Build the
// plot inside this observation, not upstream with a stale PlotState.
@MainActor
private struct PeakFileReader<Content: View>: View {
    @ObservedObject var groups: NMRPeakWorkspace
    let content: (NMRPeakWorkspace) -> Content
    var body: some View { content(groups) }
}

@MainActor
private struct DocumentStudio: View {
    private typealias Version = StudioAnnotationVersion

    private struct IntegralRequest: Identifiable {
        let id = UUID()
        let version: Version
        let markID: UUID
        let bounds: ClosedRange<Double>
        let limits: ClosedRange<Double>
        let target: Double?
    }

    private struct ReviewRequest: Identifiable {
        let id = UUID()
        let workspace: NMRPeakWorkspace
    }

    private final class ReportRequest: Identifiable {
        let id = UUID()
        let draft: NMRReportDraft
        var version: Version

        init(draft: NMRReportDraft, version: Version) {
            self.draft = draft
            self.version = version
        }
    }

    private enum Question {
        case reportNucleus(Version)
        case delete(Version, UUID, String)

        var title: String {
            switch self {
            case .reportNucleus: return "选择报表核种"
            case .delete: return "删除所选标注？"
            }
        }
    }

    private struct InteractionID: Hashable {
        let version: Version
        let appliedWindow: ClosedRange<Double>
        let mode: NMRSimpleTool
        let integralRevision: UUID
    }

    @ObservedObject var w: Workbench
    let document: UUID
    @Environment(\.colorScheme) private var colorScheme
    @State private var tool: NMRSimpleTool
    @State private var armedInitialTool = false
    @State private var referenceNucleus = NMRNucleus.proton
    @State private var integralRequest: IntegralRequest?
    @State private var reviewRequest: ReviewRequest?
    @State private var reportRequest: ReportRequest?
    @State private var question: Question?
    @State private var dropTargeted = false

    init(w: Workbench, document: UUID, initialTool: NMRSimpleTool = .zoom) {
        self.w = w
        self.document = document
        _tool = State(initialValue: initialTool)
    }

    private var colors: StudioColors { StudioColors(dark: colorScheme == .dark) }

    var body: some View {
        let version = w.annotationVersion
        NMRPrimaryControls(
            tool: $tool, hasDocument: true,
            status: w.busy ? "正在读取或处理谱图…" : w.status + (w.dirty ? " · 未保存" : ""),
            isBusy: w.busy,
            liveScope: { w.accepts(version) && document == version.document ? version : nil },
            open: { if !w.busy, w.documentRevision == document { w.openPanel() } },
            save: { _ in _ = w.save() },
            existingExports: exports,
            professionalText: { openReport(at: $0) },
            tools: NMRToolCallbacks(
                zoom: { _ in w.tool = .zoom },
                solventReference: { _ in armReference() },
                integral: { _ in w.tool = .integral },
                markPeaks: { _ in armGroups() }
            )
        ) { mode in
            if let groups = w.peakWorkspace {
                PeakFileReader(groups: groups) { current in
                    workArea(mode: mode, groups: current)
                }
            } else {
                workArea(mode: mode, groups: nil)
            }
        }
        .onAppear {
            guard !armedInitialTool else { return }
            armedInitialTool = true
            switch tool {
            case .zoom: w.tool = .zoom
            case .solventReference: armReference()
            case .integral: w.tool = .integral
            case .markPeaks: armGroups()
            }
        }
        .onChange(of: w.peakBinding) { _ in
            if (tool == .markPeaks && w.peakWorkspace == nil)
                || (tool == .solventReference && w.peakIndex == nil) {
                tool = .zoom
                w.tool = .zoom
            }
        }
        .sheet(item: $integralRequest) { request in
            QuantitationSheet(initial: request.bounds, limits: request.limits,
                              initialTarget: request.target) { bounds, target in
                guard validate(request.version), !w.hasDraft,
                      w.selectedAnnotationID == request.markID,
                      let m = w.marks.first(where: { $0.id == request.markID && !$0.isPeak }) else { return }
                w.editIntegral(m, bounds: bounds, target: target)
            }
            .disabled(w.busy || w.hasDraft)
            .studioTheme()
        }
        .sheet(item: $reviewRequest) { request in
            StudioGroupReview(w: w, groups: request.workspace, document: document)
                .studioTheme()
        }
        .sheet(item: $reportRequest) { request in
            NMRTextExportSheet(report: request.draft, save: { draft in
                guard validate(request.version) else { return }
                guard !w.hasDraft else {
                    w.error = "请先应用或放弃预览参数，再保存报表草稿。"
                    return
                }
                w.saveTextReport(draft)
                // Also supports a sheet that saves more than once while open.
                request.version = w.annotationVersion
            }, additionalSpectrum: { url, primary, nucleus in
                try await Task.detached(priority: .userInitiated) {
                    try StudioReport.companion(url: url, sampleID: primary,
                                               excluding: primary, nucleus: nucleus)
                }.value
            })
            .studioTheme()
        }
        .confirmationDialog(question?.title ?? "", isPresented: Binding(
            get: { question != nil },
            set: { if !$0 { question = nil } }
        ), titleVisibility: .visible, presenting: question) { prompt in
            switch prompt {
            case .reportNucleus(let v):
                Button("¹H NMR") { openReport(at: v, nucleus: .proton) }
                Button("¹³C NMR") { openReport(at: v, nucleus: .carbon13) }
            case .delete(let v, let id, _):
                Button("删除标注", role: .destructive) {
                    guard validate(v), !w.hasDraft, w.selectedAnnotationID == id,
                          let m = w.selectedAnnotation else { return }
                    w.delete(m)
                }
            }
            Button("取消", role: .cancel) {}
        } message: { prompt in
            if case .delete(_, _, let description) = prompt {
                Text(description)
            }
        }
    }

    private func validate(_ v: Version) -> Bool {
        guard document == w.documentRevision, document == v.document else { return false }
        guard w.accepts(v) else {
            w.error = "谱图或标注已变更，请重新执行此操作。"
            return false
        }
        return true
    }

    private func armReference() {
        w.tool = .zoom
        if w.peakIndex == nil {
            tool = .zoom
            w.error = "当前谱图没有可用于溶剂参考的峰索引。"
        }
    }

    private func armGroups() {
        w.tool = .zoom
        if w.peakWorkspace == nil {
            tool = .zoom
            w.error = "当前谱图没有可用于框选峰组的分析轨迹。"
        }
    }

    private var exports: [NMRPrimaryExportItem<Version>] {
        var items = [
            NMRPrimaryExportItem<Version>(id: "csv", title: "全谱 CSV…") { _ in w.export("csv") },
            NMRPrimaryExportItem<Version>(id: "range", title: "当前范围 CSV…") { _ in w.export("range") },
            NMRPrimaryExportItem<Version>(id: "pdf", title: "矢量 PDF…") { _ in w.export("pdf") }
        ]
        // Menu presets only; the encoder's supported widths are unchanged.
        items += [1200, 3600].map { width in
            NMRPrimaryExportItem<Version>(id: "png-\(width)", title: "PNG · \(width) px…") { _ in
                w.pngWidth = width
                w.export("png")
            }
        }
        return items
    }

    private func openReport(at version: Version, nucleus: NMRReportNucleus? = nil) {
        guard validate(version) else { return }
        var chosen = nucleus
        if chosen == nil, w.dataset.nucleus == .unknown {
            chosen = w.textReport?.spectra.first(where: { $0.id == w.spectrumID })?.nucleus
            if chosen == nil {
                question = .reportNucleus(version)
                return
            }
        }
        do {
            reportRequest = ReportRequest(draft: try w.makeTextReport(nucleus: chosen), version: version)
        } catch {
            w.error = error.localizedDescription
        }
    }

    private func openIntegralSettings(_ mark: Mark, at version: Version) {
        guard validate(version), !w.hasDraft, !mark.isPeak,
              w.selectedAnnotationID == mark.id else { return }
        integralRequest = IntegralRequest(version: version, markID: mark.id,
                                          bounds: w.bounds(mark), limits: w.spectrum.range,
                                          target: w.reference?.markID == mark.id ? w.reference?.target : nil)
    }

    private func confirmDelete(_ mark: Mark, at version: Version) {
        guard validate(version), !w.hasDraft, w.selectedAnnotationID == mark.id else { return }
        var detail = studioMarkBounds(mark, offset: version.offset)
        if !mark.isPeak {
            detail += "。若为参考积分，将取消归一；链接它的峰组需复核。"
        }
        question = .delete(version, mark.id, detail)
    }

    // This is a screen-only copy. Workbench's annotation/export builders and
    // all saved integral records remain untouched when a tool changes.
    private func screenPlot(for mode: NMRSimpleTool) -> PlotState {
        var data = w.plot
        if mode != .integral {
            data.bands.removeAll()
            data.bandIDs.removeAll()
            data.bandLabels.removeAll()
            data.selectedBand = nil
            data.selectedBandID = nil
        }
        return data
    }

    private func workArea(mode: NMRSimpleTool, groups: NMRPeakWorkspace?) -> some View {
        let v = w.annotationVersion
        let data = screenPlot(for: mode)
        return Group {
            if mode == .solventReference {
                spectrum(mode: mode, groups: groups, data: data, version: v)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                HStack(spacing: 0) {
                    VStack(spacing: 0) {
                        header(data, at: v)
                        Divider()
                        spectrum(mode: mode, groups: groups, data: data, version: v)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                    if mode == .integral {
                        Divider()
                        StudioIntegralInspector(w: w, version: v,
                            configure: { openIntegralSettings($0, at: v) },
                            remove: { confirmDelete($0, at: v) })
                    } else if mode == .markPeaks {
                        Divider()
                        peakInspector(groups: groups, at: v)
                    }
                }
            }
        }
        .background(colors.background)
        .dropDestination(for: URL.self) { urls, _ in
            guard !w.busy, w.documentRevision == document,
                  let url = urls.first(where: \.isFileURL) else { return false }
            dropTargeted = false
            w.requestLoad(url)
            return true
        } isTargeted: { dropTargeted = $0 }
        .overlay {
            if dropTargeted && !w.busy {
                Rectangle().strokeBorder(colors.accent, lineWidth: 2)
                    .allowsHitTesting(false).accessibilityHidden(true)
            }
        }
    }

    private func header(_ data: PlotState, at v: Version) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "waveform")
                .font(.system(size: 22)).foregroundStyle(colors.accent)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 5) {
                Text(w.dataset.name)
                    .font(.system(size: 22, weight: .semibold))
                    .lineLimit(1).truncationMode(.middle)
                    .help(w.dataset.name)
                HStack(spacing: 10) {
                    Text(w.dataset.format)
                    if v.offset != 0 {
                        Text(String(format: "偏移 %+.5f ppm", v.offset)).monospacedDigit()
                    }
                    if data.gain != 1 {
                        Text(String(format: "强度 ×%.4g", data.gain)).monospacedDigit()
                    }
                }
                .font(.system(size: 15)).foregroundStyle(colors.secondary)
                .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            HStack(spacing: 5) {
                Button { zoom(by: 0.5, at: v) } label: {
                    Image(systemName: "plus.magnifyingglass").frame(minWidth: 25, minHeight: 28)
                }
                .keyboardShortcut("=", modifiers: .command)
                .accessibilityLabel("放大当前范围").help("放大（⌘=）")
                Button { zoom(by: 2, at: v) } label: {
                    Image(systemName: "minus.magnifyingglass").frame(minWidth: 25, minHeight: 28)
                }
                .disabled(w.window == w.spectrum.range)
                .keyboardShortcut("-", modifiers: .command)
                .accessibilityLabel("缩小当前范围").help("缩小（⌘−）")
                Button {
                    if w.accepts(v) { w.window = w.spectrum.range }
                } label: {
                    Text("全谱").frame(minHeight: 28)
                }
                .disabled(w.window == w.spectrum.range)
                .keyboardShortcut("0", modifiers: .command)
                .help("恢复全谱（⌘0）")
            }
            .font(.system(size: 17))
            .controlSize(.regular)
            .fixedSize(horizontal: true, vertical: false)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
        .background(colors.background)
    }

    private func peakInspector(groups: NMRPeakWorkspace?, at v: Version) -> some View {
        let count = groups?.file.groups.count ?? w.unmountedGroupCount
        let legacy = w.marks.filter(\.isPeak)
        return ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack(alignment: .firstTextBaseline) {
                    Text("标峰").font(.system(size: 22, weight: .semibold))
                    Spacer()
                    Text("\(count) 个峰组").font(.system(size: 15)).foregroundStyle(colors.secondary)
                }
                Text("在谱图上框选 ppm 与强度范围，可连续添加峰组。")
                    .fixedSize(horizontal: false, vertical: true)
                Button {
                    guard validate(v), let groups, w.peakWorkspace === groups else { return }
                    reviewRequest = ReviewRequest(workspace: groups)
                } label: {
                    Label(groups != nil || count == 0 ? "审阅峰组（\(count)）…" : "已保留 \(count) 个峰组",
                          systemImage: "list.bullet.rectangle")
                        .frame(maxWidth: .infinity, minHeight: 32)
                }
                .disabled(groups == nil || count == 0)
                .keyboardShortcut("g", modifiers: [.command, .option])
                .help("审阅分量、链接与赋氢")

                Divider()
                HStack {
                    Text("旧峰标").font(.system(size: 19, weight: .semibold))
                    Spacer()
                    Text("\(legacy.count) 个").foregroundStyle(colors.secondary)
                }
                if legacy.isEmpty {
                    Text("没有旧峰标。新框选结果保存在峰组中。")
                        .foregroundStyle(colors.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    Picker("所选旧峰标", selection: Binding<UUID?>(
                        get: { w.selectedAnnotation.flatMap { $0.isPeak ? $0.id : nil } },
                        set: { w.pickAnnotation($0, at: v) }
                    )) {
                        Text("选择旧峰标…").tag(nil as UUID?)
                        ForEach(legacy) { mark in
                            Text(studioMarkBounds(mark, offset: v.offset)).tag(Optional(mark.id))
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .frame(maxWidth: .infinity)
                    .accessibilityLabel("选择旧峰标")

                    if let mark = w.selectedAnnotation, mark.isPeak {
                        Text("位置 ppm").foregroundStyle(colors.secondary)
                        Text(String(format: "%.6f", w.bounds(mark).lowerBound))
                            .font(.system(size: 26, weight: .semibold, design: .monospaced))
                            .textSelection(.enabled)
                        Button(role: .destructive) {
                            confirmDelete(mark, at: v)
                        } label: {
                            Label("删除旧峰标…", systemImage: "trash")
                                .frame(maxWidth: .infinity, minHeight: 32)
                        }
                        .disabled(w.hasDraft)
                        .keyboardShortcut(.delete, modifiers: .command)
                    }
                }
            }
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .font(.system(size: 17))
        .foregroundStyle(colors.text)
        .controlSize(.large)
        .frame(width: StudioColors.sidebarWidth)
        .frame(maxHeight: .infinity)
        .background(colors.panel)
    }

    private func zoom(by factor: Double, at v: Version) {
        guard w.accepts(v) else { return }
        let limits = w.spectrum.range
        let old = w.window
        let width = old.upperBound - old.lowerBound
        let total = limits.upperBound - limits.lowerBound
        let next = min(total, width * factor)
        if next >= total { w.window = limits; return }
        let lo = max(limits.lowerBound, min(limits.upperBound - next, old.lowerBound + (width - next) / 2))
        let hi = min(limits.upperBound, lo + next)
        guard lo < hi, w.spectrum.nearest(lo) != w.spectrum.nearest(hi) else { return }
        w.window = lo...hi
    }

    private var referenceNucleusControls: AnyView {
        if w.dataset.nucleus == .unknown {
            return AnyView(
                Picker("参考核种", selection: $referenceNucleus) {
                    Text("¹H").tag(NMRNucleus.proton)
                    Text("¹³C").tag(NMRNucleus.carbon13)
                }
                .pickerStyle(.segmented)
                .font(.system(size: 17))
                .accessibilityLabel("参考核种")
            )
        }
        return AnyView(
            Text(w.dataset.nucleus == .proton ? "核种 · ¹H" : "核种 · ¹³C")
                .font(.system(size: 17, weight: .medium))
        )
    }

    @ViewBuilder
    private func spectrum(mode: NMRSimpleTool, groups: NMRPeakWorkspace?,
                          data: PlotState, version v: Version) -> some View {
        let chart = graph(mode: mode, groups: groups, data: data, version: v)
        if mode == .solventReference, let index = w.peakIndex {
            let nucleus = w.dataset.nucleus == .unknown ? referenceNucleus : w.dataset.nucleus
            NMRReferencePicker(
                isReferencing: Binding(get: { tool == .solventReference }, set: { active in
                    // A successful reference edit itself advances the transaction.
                    if !active, w.documentRevision == document, w.peakBinding == v.binding {
                        tool = .zoom
                        w.tool = .zoom
                    }
                }),
                scope: w.referenceScope(nucleus: nucleus), index: index,
                targets: StudioReferences.targets, undoableID: w.undoableReferenceID,
                edits: NREditActions(commit: { edit in
                    guard w.accepts(v) else { throw NMRError("参考工作区已变更，请重新点选。") }
                    try w.applyReference(edit)
                }, undo: { scope, id in
                    guard w.accepts(v) else { throw NMRError("参考记录已变更。") }
                    try w.undoReference(scope, id: id)
                }),
                nucleusControls: referenceNucleusControls,
                plotHeader: AnyView(header(data, at: v)),
                map: { size in
                    PlotGeometry(field: PlotGeometry.field(size: size), ordinate: data.ordinateSpan)
                        .referenceMap(height: size.height, window: data.window,
                                      offset: v.offset, gain: data.gain)
                },
                plot: { chart }
            )
        } else {
            chart
        }
    }

    private func graph(mode: NMRSimpleTool, groups: NMRPeakWorkspace?,
                       data: PlotState, version v: Version) -> some View {
        let key = InteractionID(version: v, appliedWindow: w.window, mode: mode,
                                integralRevision: w.integralInteractionRevision)
        let current: () -> Bool = {
            w.accepts(v) && w.window == key.appliedWindow && tool == mode &&
                w.integralInteractionRevision == key.integralRevision
        }

        let commit: ((NMRRawBox, Bool) throws -> Void)?
        if mode == .markPeaks, let groups {
            commit = { box, clipped in
                guard current(), w.peakWorkspace === groups else { throw NMRError("谱图已改变，请重新框选。") }
                // Plot's mapping already returned ORIGINAL ppm and raw intensity.
                try groups.commit(box, clipped: clipped)
                w.status = "已添加峰组 · 可继续标峰或审阅"
            }
        } else {
            commit = nil
        }

        let resize: ((UUID) -> PlotIntegralEdit?)?
        if mode == .integral {
            resize = { id in
                guard !w.hasDraft else { return nil }
                return w.beginIntegralEdit(id, at: v, isCurrent: current)
            }
        } else {
            resize = nil
        }

        return Plot(data: data, tool: mode == .integral ? .integral : .zoom, select: { action, region in
            guard current() else { return }
            if mode == .zoom, action == .zoom {
                // Workbench.select(.zoom) expects displayed coordinates.
                w.select(.zoom, region: region)
            } else if mode == .integral, action == .integral, !w.hasDraft {
                // The legacy integral action takes applied-axis coordinates and
                // subtracts applied.offset when storing the new Mark.
                let delta = v.offset - w.applied.offset
                let appliedRegion = (region.lowerBound - delta)...(region.upperBound - delta)
                let n = w.marks.count
                w.select(.integral, region: appliedRegion)
                if w.marks.count > n, let mark = w.marks.last {
                    w.pickAnnotation(mark.id, at: w.annotationVersion)
                }
            }
        }, peakBox: commit, rawOffset: v.offset, axisID: v.trace,
            reportProblem: { message in if w.accepts(v) { w.error = message } },
            onIntegralSelection: { id in
                guard mode == .integral, current(),
                      w.marks.contains(where: { $0.id == id && !$0.isPeak }) else { return }
                w.pickAnnotation(id, at: v)
            }, integralEditing: resize)
        // Don't finish an AppKit drag on a new axis, file revision or tool.
        // A change of selection alone does not replace the NSView.
        .id(key)
        .accessibilityLabel("一维核磁谱图")
        .accessibilityValue(Text(String(format: "%.5f 至 %.5f ppm", data.window.upperBound, data.window.lowerBound)))
        .accessibilityHint(Text(mode.hint))
    }
}
