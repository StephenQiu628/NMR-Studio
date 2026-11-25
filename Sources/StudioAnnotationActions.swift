import SwiftUI
import Foundation

// A presentation/interaction ticket, not project data. The event ID distinguishes
// "undo back to revision R" from the original visit to revision R.
struct StudioAnnotationVersion: Hashable {
    let document: UUID
    let spectrum: UUID
    let binding: UUID
    let transaction: UUID
    let lastEvent: UUID?
    let trace: String
    let offset: Double
}

@MainActor
extension Workbench {
    var annotationVersion: StudioAnnotationVersion {
        let marker = journal.saveMarker
        return StudioAnnotationVersion(document: documentRevision, spectrum: spectrumID,
                                       binding: peakBinding, transaction: marker.revision,
                                       lastEvent: marker.lastRecordID, trace: traceKey,
                                       offset: displayOffset)
    }

    func accepts(_ version: StudioAnnotationVersion) -> Bool {
        !busy && annotationVersion == version
    }

    // Both export and screen call this builder. Only the screen supplies a selection.
    func annotationPlot(selecting id: UUID?) -> PlotState {
        let offset = displayOffset
        let delta = offset - applied.offset
        let visible = (window.lowerBound + delta)...(window.upperBound + delta)
        var display = previewSpectrum ?? spectrum
        let gain = analysis.displayGain.flatMap { $0.isFinite && $0 > 0 ? $0 : nil } ?? 1
        if gain != 1 { display.real = display.real.map { $0 * gain } }

        var result = PlotState(spectrum: display, window: visible,
                               title: dataset.name + "   /   " + dataset.format, gain: gain)

        // Share an on-plot label when an older point mark and a fitted
        // component identify the same sampled line. Keep both source records.
        let sid = spectrumID.uuidString
        var fittedBySample: [Int: Double] = [:]
        if let groups = peakWorkspace, groups.file.spectrumID == sid,
           groups.trace.stamp.spectrumID == sid {
            for group in groups.file.groups where group.analysis.stamp == groups.trace.stamp {
                for component in group.analysis.components {
                    let ppm = component.ppm + offset
                    guard ppm.isFinite else { continue }
                    result.peaks.append(ppm)
                    fittedBySample[display.nearest(ppm)] = ppm
                }
            }
        }

        // Areas always come from the applied, unamplified spectrum. Integrate
        // the anchor once, not once per bracket. Reuse the journal's signed math.
        let anchor: (area: Double, target: Double)? = reference.flatMap { ref in
            guard let m = marks.first(where: { $0.id == ref.markID && $0.lo < $0.hi }) else {
                return nil
            }
            return (spectrum.area(bounds(m)), ref.target)
        }

        for mark in marks {
            let lo = mark.lo + offset
            let hi = mark.hi + offset
            guard lo.isFinite, hi.isFinite, lo <= hi else { continue }

            if mark.isPeak {
                let fitted = display.range.contains(lo) ? fittedBySample[display.nearest(lo)] : nil
                if fitted == nil { result.peaks.append(lo) }
                if mark.id == id { result.selectedPeak = fitted ?? lo }
            } else {
                let band = lo...hi
                let area = spectrum.area(bounds(mark))
                let relative = anchor.flatMap {
                    SessionJournal.relativeArea(area, referenceArea: $0.area, target: $0.target)
                }
                let label: String
                if let relative {
                    label = String(format: "%.3g", relative)
                } else {
                    label = area.isFinite ? String(format: "%+.3g a.u.·ppm", area) : "面积不可用"
                }

                result.bands.append(band)
                result.bandIDs.append(mark.id)
                result.bandLabels.append(label)
                if mark.id == id { result.selectedBand = band }
            }
        }

        return result
    }
}

func studioMarkBounds(_ mark: Mark, offset: Double) -> String {
    if mark.isPeak { return String(format: "%.5f ppm", mark.lo + offset) }
    return String(format: "%.5f–%.5f ppm", mark.hi + offset, mark.lo + offset)
}

@MainActor
struct StudioAnnotationPicker: View {
    @ObservedObject var w: Workbench
    let version: StudioAnnotationVersion
    var integralsOnly = false

    var body: some View {
        let rows = w.marks.filter { !integralsOnly || !$0.isPeak }
        let hasLegacy = !integralsOnly && rows.contains(where: \.isPeak)
        let prompt = hasLegacy ? "选择积分或旧峰标…" : "选择积分…"
        Picker("所选标注", selection: Binding<UUID?>(
            get: { integralsOnly ? w.selectedIntegralID : w.selectedAnnotationID },
            set: { w.pickAnnotation($0, at: version) }
        )) {
            Text(prompt).tag(nil as UUID?)
            ForEach(Array(rows.enumerated()), id: \.element.id) { entry in
                let m = entry.element
                let kind = m.isPeak ? "旧峰标" : (w.reference?.markID == m.id ? "参考积分" : "积分")
                Text("\(entry.offset + 1) · \(kind)  \(studioMarkBounds(m, offset: version.offset))")
                    .tag(Optional(m.id))
            }
        }
        .pickerStyle(.menu)
        .labelsHidden()
        .frame(minWidth: 208, maxWidth: 224)
        .disabled(rows.isEmpty)
        .accessibilityLabel(Text(integralsOnly ? "选择用于峰组链接的积分" : "选择积分或旧峰标"))
        .help(integralsOnly ? "可用键盘选择要链接的积分。" : "可用键盘展开选择。旧峰标是谱图中的单点测量。")
    }
}

@MainActor
struct StudioAnnotationBar: View {
    @ObservedObject var w: Workbench
    let version: StudioAnnotationVersion
    let plot: PlotState
    let groupCount: Int
    let canReview: Bool
    let edit: (Mark) -> Void
    let remove: (Mark) -> Void
    let review: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            StudioAnnotationPicker(w: w, version: version)

            if let mark = w.selectedAnnotation {
                if mark.isPeak {
                    Text("旧峰标 · 单点测量").foregroundStyle(.secondary)
                } else {
                    if let i = plot.bandIDs.firstIndex(of: mark.id), plot.bandLabels.indices.contains(i) {
                        let prefix = w.reference?.markID == mark.id ? "参考 · " : ""
                        Text(prefix + plot.bandLabels[i])
                            .monospacedDigit().lineLimit(1)
                            .help("有有效参考时为归一积分；带 a.u.·ppm 的数值为有符号面积。两者均非峰组的赋氢数。")
                    }
                    Button("编辑积分…") { edit(mark) }
                        .keyboardShortcut("i", modifiers: [.command, .option])
                        .help("编辑边界、设置或取消参考积分")
                }
                Button { remove(mark) } label: { Image(systemName: "trash") }
                    .keyboardShortcut(.delete, modifiers: .command)
                    .accessibilityLabel(Text(mark.isPeak ? "删除所选旧峰标" : "删除所选积分"))
                    .help("删除所选标注…")
            } else if w.marks.contains(where: \.isPeak) {
                Text("可在此选择积分或旧峰标。").foregroundStyle(.secondary).lineLimit(1)
            } else {
                Text("点选谱图括线可编辑积分。").foregroundStyle(.secondary).lineLimit(1)
            }

            Spacer(minLength: 4)
            Button(action: review) {
                Label(canReview || groupCount == 0 ? "审阅峰组 (\(groupCount))…" : "已保留 \(groupCount) 个峰组",
                      systemImage: "list.bullet.rectangle")
            }
            .fixedSize(horizontal: true, vertical: false)
            .disabled(!canReview || groupCount == 0)
            .keyboardShortcut("g", modifiers: [.command, .option])
            .help(canReview ? "检查分量、链接积分、赋氢、确认或移除峰组" : "当前数据没有可供审阅的峰组轨迹")
        }
        .font(.body)
        .controlSize(.regular)
        .padding(.horizontal, 14)
        .padding(.vertical, 5)
    }
}

@MainActor
struct StudioGroupReview: View {
    @ObservedObject var w: Workbench
    @ObservedObject var groups: NMRPeakWorkspace
    let document: UUID
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let current = document == w.documentRevision && w.peakWorkspace === groups
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                if current {
                    Text("链接用积分").font(.body.weight(.semibold))
                    StudioAnnotationPicker(w: w, version: w.annotationVersion, integralsOnly: true)
                        .disabled(w.busy)
                } else {
                    Text("工作区已更新，请关闭后重新打开审阅。")
                }
                Spacer()
                Button("完成") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            .padding(12)
            Divider()
            if current {
                NMRPeakGroupEditor(workspace: groups).disabled(w.busy)
            } else {
                Spacer()
            }
        }
        .frame(minWidth: 680, idealWidth: 800, minHeight: 465, idealHeight: 610)
    }
}
