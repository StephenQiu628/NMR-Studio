import SwiftUI
import AppKit

@MainActor
struct StudioView: View {
    @ObservedObject var w: Workbench

    var body: some View {
        DocumentStudio(w: w, document: w.documentRevision)
            // Even reopening the *same saved project* is a new UI lifetime.
            .id(w.documentRevision)
            .font(.system(size: 13))
            .frame(minWidth: 800, idealWidth: 1140, minHeight: 540, idealHeight: 710)
            .onOpenURL { url in
                if !w.busy, url.isFileURL { w.requestLoad(url) }
            }
            .sheet(isPresented: $w.showHistory) { OperationHistoryView(w: w) }
            .alert("操作未完成", isPresented: Binding(
                get: { w.error != nil },
                set: { if !$0 { w.error = nil } }
            )) {
                Button("确定", role: .cancel) { w.error = nil }
            } message: {
                Text(w.error ?? "")
            }
    }
}

// Workbench and its nested peak workspace publish independently. Build the
// plot *inside* this observation, not upstream and then pass a stale PlotState.
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
            case .delete:        return "删除所选标注？"
            }
        }
    }

    private struct InteractionID: Hashable {
        let version: Version
        let appliedWindow: ClosedRange<Double>
        let mode: NMRSimpleTool
    }

    @ObservedObject var w: Workbench
    let document: UUID

    @State private var tool = NMRSimpleTool.zoom
    @State private var referenceNucleus = NMRNucleus.proton
    @State private var integralRequest: IntegralRequest?
    @State private var reviewRequest: ReviewRequest?
    @State private var reportRequest: ReportRequest?
    @State private var question: Question?
    @State private var dropTargeted = false

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
                guard validate(request.version),
                      let m = w.marks.first(where: { $0.id == request.markID && !$0.isPeak }) else { return }
                w.editIntegral(m, bounds: bounds, target: target)
            }
            .disabled(w.busy)
        }
        .sheet(item: $reviewRequest) { request in
            StudioGroupReview(w: w, groups: request.workspace, document: document)
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
                    guard validate(v), w.selectedAnnotationID == id,
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

    private func workArea(mode: NMRSimpleTool, groups: NMRPeakWorkspace?) -> some View {
        let v = w.annotationVersion
        let data = w.plot
        return VStack(spacing: 0) {
            header(data, at: v)
            Divider()
            spectrum(mode: mode, groups: groups, data: data, version: v)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            StudioAnnotationBar(
                w: w, version: v, plot: data,
                groupCount: groups?.file.groups.count ?? w.unmountedGroupCount,
                canReview: groups != nil,
                edit: { m in
                    guard validate(v), !m.isPeak, w.selectedAnnotationID == m.id else { return }
                    integralRequest = IntegralRequest(version: v, markID: m.id, bounds: w.bounds(m),
                                                      limits: w.spectrum.range,
                                                      target: w.reference?.markID == m.id ? w.reference?.target : nil)
                },
                remove: { m in
                    guard validate(v), w.selectedAnnotationID == m.id else { return }
                    var detail = studioMarkBounds(m, offset: v.offset)
                    if !m.isPeak {
                        detail += "。若为参考积分，将取消归一；链接它的峰组需复核。"
                    }
                    question = .delete(v, m.id, detail)
                },
                review: {
                    guard validate(v), let groups, w.peakWorkspace === groups else { return }
                    reviewRequest = ReviewRequest(workspace: groups)
                }
            )
        }
        .dropDestination(for: URL.self) { urls, _ in
            guard !w.busy, w.documentRevision == document,
                  let url = urls.first(where: \.isFileURL) else { return false }
            dropTargeted = false
            w.requestLoad(url)
            return true
        } isTargeted: { dropTargeted = $0 }
        .overlay {
            if dropTargeted && !w.busy {
                Rectangle().strokeBorder(Color.accentColor, lineWidth: 2)
                    .allowsHitTesting(false).accessibilityHidden(true)
            }
        }
    }

    private func header(_ data: PlotState, at v: Version) -> some View {
        HStack(spacing: 9) {
            Image(systemName: "waveform").foregroundStyle(.secondary).accessibilityHidden(true)
            Text(w.dataset.name).font(.system(size: 14, weight: .semibold)).truncationMode(.middle)
                .help(w.dataset.name)
            Text(w.dataset.format).font(.body).foregroundStyle(.secondary)
            Spacer(minLength: 4)
            if v.offset != 0 {
                Text(String(format: "偏移 %+.5f ppm", v.offset))
                    .font(.callout).monospacedDigit()
            }
            if data.gain != 1 {
                Text(String(format: "强度 ×%.4g", data.gain)).font(.callout).monospacedDigit()
            }
            HStack(spacing: 4) {
                Button { zoom(by: 0.5, at: v) } label: { Image(systemName: "plus.magnifyingglass") }
                    .keyboardShortcut("=", modifiers: .command)
                    .accessibilityLabel("放大当前范围").help("以当前范围中心放大（⌘=）")
                Button { zoom(by: 2, at: v) } label: { Image(systemName: "minus.magnifyingglass") }
                    .disabled(w.window == w.spectrum.range)
                    .keyboardShortcut("-", modifiers: .command)
                    .accessibilityLabel("缩小当前范围").help("缩小（⌘−）")
                Button("全谱") { if w.accepts(v) { w.window = w.spectrum.range } }
                    .disabled(w.window == w.spectrum.range)
                    .keyboardShortcut("0", modifiers: .command)
                    .help("恢复全谱（⌘0）")
            }
            .font(.system(size: 14))
            .controlSize(.regular)
            .fixedSize(horizontal: true, vertical: false)
        }
        .lineLimit(1)
        .padding(.horizontal, 14).padding(.vertical, 5)
        .background(Color(nsColor: .controlBackgroundColor))
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

    @ViewBuilder
    private func spectrum(mode: NMRSimpleTool, groups: NMRPeakWorkspace?,
                          data: PlotState, version v: Version) -> some View {
        let chart = graph(mode: mode, groups: groups, data: data, version: v)
        if mode == .solventReference, let index = w.peakIndex {
            VStack(spacing: 0) {
                if w.dataset.nucleus == .unknown {
                    Picker("参考核种", selection: $referenceNucleus) {
                        Text("¹H").tag(NMRNucleus.proton)
                        Text("¹³C").tag(NMRNucleus.carbon13)
                    }
                    .pickerStyle(.segmented).frame(maxWidth: 205).padding(5)
                }
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
                    map: { size in
                        PlotGeometry(field: PlotGeometry.field(size: size), ordinate: data.ordinateSpan)
                            .referenceMap(height: size.height, window: data.window,
                                          offset: v.offset, gain: data.gain)
                    },
                    plot: { chart }
                )
            }
        } else {
            chart
        }
    }

    private func graph(mode: NMRSimpleTool, groups: NMRPeakWorkspace?,
                       data: PlotState, version v: Version) -> some View {
        let key = InteractionID(version: v, appliedWindow: w.window, mode: mode)
        let current: () -> Bool = { w.accepts(v) && w.window == key.appliedWindow && tool == mode }

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

        return Plot(data: data, tool: mode == .integral ? .integral : .zoom, select: { action, region in
            guard current() else { return }
            if mode == .zoom, action == .zoom {
                // Workbench.select(.zoom) expects displayed coordinates.
                w.select(.zoom, region: region)
            } else if mode == .integral, action == .integral {
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
                guard current(), w.marks.contains(where: { $0.id == id && !$0.isPeak }) else { return }
                w.pickAnnotation(id, at: v)
            })
        // Don't finish an AppKit drag on a new axis, file revision or tool.
        // A change of selection alone does not replace the NSView.
        .id(key)
        .accessibilityLabel("一维核磁谱图")
        .accessibilityValue(Text(String(format: "%.5f 至 %.5f ppm", data.window.upperBound, data.window.lowerBound)))
        .accessibilityHint(Text(mode.hint))
    }
}
