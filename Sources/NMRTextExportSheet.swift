import SwiftUI
import AppKit
import UniformTypeIdentifiers
import Foundation

struct NMRUTF8Document: FileDocument {
    static var readableContentTypes: [UTType] { [.plainText] }
    let text: String
    var bytes: Data { Data(text.utf8) }

    init(text: String) { self.text = text }
    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents,
              let value = String(data: data, encoding: .utf8) else { throw CocoaError(.fileReadCorruptFile) }
        text = value
    }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: bytes)
    }

    func writeTXT(to url: URL) throws {
        guard url.isFileURL, !url.hasDirectoryPath, url.pathExtension.lowercased() == "txt" else {
            throw NMRError("请选择本地 .txt 文件，不要选择目录或工程文件。")
        }
        try bytes.write(to: url, options: .atomic)
    }
}

private let detailFont = Font.system(size: 14)

private func shortID(_ id: UUID) -> String { String(id.uuidString.prefix(8)) }

private func number(_ x: Double?) -> String {
    guard let x, x.isFinite else { return "—" }
    return String(format: "%.8g", locale: Locale(identifier: "en_US_POSIX"), x)
}

private func positionLabel(_ shift: NMRShift) -> String {
    switch shift {
    case let .center(x): return number(x)
    case let .bounds(a?, b?): return number(max(a, b)) + "–" + number(min(a, b))
    case let .bounds(a, b): return number(a) + " / " + number(b)
    }
}

private func regionName(_ b: NMRIntegral) -> String {
    (b.label.isEmpty ? "积分" : b.label) + " · " + shortID(b.id)
}

private struct NMRNumberField<V: Equatable>: View {
    let title: String
    @Binding var value: V?
    @State private var raw: String
    let display: (V) -> String
    let parse: (String) -> V?

    init(_ title: String, value: Binding<V?>, display: @escaping (V) -> String, parse: @escaping (String) -> V?) {
        self.title = title
        _value = value
        self.display = display
        self.parse = parse
        _raw = State(initialValue: value.wrappedValue.map(display) ?? "")
    }

    private func trim(_ s: String) -> String { s.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        HStack {
            Text(title)
            TextField(title, text: Binding(get: { raw }, set: { s in
                raw = s; value = parse(trim(s))
            })).textFieldStyle(.roundedBorder)
            if !trim(raw).isEmpty && parse(trim(raw)) == nil {
                Text("无效（按空值）").font(detailFont).foregroundColor(.red)
            }
        }
        .onChange(of: value) { next in
            if parse(trim(raw)) != next { raw = next.map(display) ?? "" }
        }
    }
}

private extension NMRNumberField where V == Double {
    init(_ title: String, _ value: Binding<Double?>) {
        self.init(title, value: value, display: { String($0) }, parse: {
            guard let d = Double($0), d.isFinite else { return nil }
            return d
        })
    }
}

private extension NMRNumberField where V == Int {
    init(_ title: String, _ value: Binding<Int?>) {
        self.init(title, value: value, display: { String($0) }, parse: { Int($0) })
    }
}

// 不编辑源 Mark / PeakFile。一个区域的所有草稿视图看到同一个显式 H。
private func assignment(_ spectrum: Binding<NMRSpectrum>, _ i: Int) -> Binding<Int?> {
    let id = spectrum.wrappedValue.integrals[i].id
    return Binding(get: {
        let s = spectrum.wrappedValue
        guard s.integrals.indices.contains(i), s.integrals[i].id == id else { return nil }
        return s.integrals[i].assignedH
    }, set: { h in
        var s = spectrum.wrappedValue
        guard s.integrals.indices.contains(i), s.integrals[i].id == id else { return }
        s.integrals[i].assignedH = h
        for k in s.rows.indices where s.rows[k].integralID == id { s.rows[k].approved = false }
        spectrum.wrappedValue = s
    })
}

private struct NMRSolventField: View {
    @Binding var solvent: String?
    @FocusState private var typing: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("样品溶剂")
                Menu("选择溶剂…") {
                    ForEach(StudioReferences.reportSolvents, id: \.self) { name in
                        Button {
                            solvent = name
                        } label: {
                            if solvent == name { Label(name, systemImage: "checkmark") }
                            else { Text(verbatim: name) }
                        }
                    }
                    Divider()
                    Button("自定义 / 输入混合溶剂…") { typing = true }
                    Button("清除") { solvent = nil }
                }
            }
            TextField("实际溶剂（也可直接输入）", text: Binding(
                get: { solvent ?? "" }, set: { solvent = $0.isEmpty ? nil : $0 }
            )).textFieldStyle(.roundedBorder).focused($typing)
        }
    }
}

private struct NMRBandList: View {
    @Binding var spectrum: NMRSpectrum

    var body: some View {
        DisclosureGroup("测量积分与归属（\(spectrum.integrals.count)）") {
            VStack(alignment: .leading, spacing: 8) {
                if spectrum.integrals.isEmpty { Text("没有记录积分。可只报告峰位。") }
                ForEach(spectrum.integrals.indices, id: \.self) { j in
                    let b = spectrum.integrals[j]
                    let links = spectrum.rows.indices.filter { spectrum.rows[$0].integralID == b.id }
                    VStack(alignment: .leading, spacing: 4) {
                        Text(verbatim: regionName(b)).bold()
                        Text("有符号面积 \(number(b.signedArea)) a.u.·ppm；相对 \(number(b.relativeArea))")
                        Text(links.isEmpty ? "未关联峰行" :
                                "关联：" + links.map { k in
                                    "行 \(k + 1)" + (spectrum.rows[k].origin?.quantitativeRegionID == b.id ? "（一对一）" : "")
                                }.joined(separator: "、"))
                        if let target = b.referenceTarget {
                            Text("手动归一的参考段，目标 \(number(target))。相对值本身没有 H 单位。")
                        }
                        if let note = b.note { Text(note).foregroundColor(.orange) }
                        if spectrum.nucleus == .proton {
                            NMRNumberField("段的已知 H", assignment($spectrum, j))
                            if let n = NMRTextReport.wholeTarget(b.referenceTarget), b.assignedH == nil {
                                Button("此参考值确为已知 \(n)H") { assignment($spectrum, j).wrappedValue = n }
                                    .help("仅在本草稿指派参考段；适用的归一建议随预览更新。")
                            }
                        }
                    }
                    Divider()
                }
            }.padding(.vertical, 5).font(detailFont)
        }
    }
}

private struct NMRPeakEditor: View {
    @Binding var spectrum: NMRSpectrum
    let k: Int
    private var r: NMRRow { spectrum.rows[k] }

    private func edit(_ f: (inout NMRRow) -> Void) {
        var n = r
        n.approved = false
        n.multiplicityApproved = false
        f(&n)
        spectrum.rows[k] = n
    }

    private var band: Bool { if case .bounds = r.shift { return true }; return false }

    private func coordinate(_ second: Bool) -> Binding<Double?> {
        Binding(get: {
            switch r.shift {
            case let .center(x): return x
            case let .bounds(a, b): return second ? b : a
            }
        }, set: { x in
            edit { row in
                switch row.shift {
                case .center: row.shift = .center(x)
                case let .bounds(a, b): row.shift = second ? .bounds(a, x) : .bounds(x, b)
                }
            }
        })
    }

    private func slot(_ i: Int) -> Binding<Double?> {
        Binding(get: { r.jHz.indices.contains(i) ? r.jHz[i] : nil }, set: { x in
            guard r.jHz.indices.contains(i) else { return }
            edit { $0.jHz[i] = x; $0.jBasisMHz = nil; $0.jReview = .unreviewed }
        })
    }

    private var kind: String {
        guard let o = r.origin else { return "工程报表行" }
        if o.blocked != nil { return "来源失效" }
        if o.shadowOf != nil { return "与组同位的旧点" }
        if o.analysisID == nil { return "点标（仅位置）" }
        if o.sourceApproval != nil { return "已有源审批" }
        return o.reviewNotes.isEmpty ? "实测建议" : "实测／需注意"
    }

    private var linkage: some View {
        VStack(alignment: .leading) {
            Picker("积分关联", selection: Binding(get: { r.integralID }, set: { id in
                edit { $0.integralID = id; $0.explicitH = nil; $0.omitUnassignedH = nil }
            })) {
                Text("未关联").tag(Optional<UUID>.none)
                if let id = r.integralID, !spectrum.integrals.contains(where: { $0.id == id }) {
                    Text("缺失 · " + shortID(id)).tag(Optional(id))
                }
                ForEach(spectrum.integrals.indices, id: \.self) { i in
                    Text(verbatim: regionName(spectrum.integrals[i])).tag(Optional(spectrum.integrals[i].id))
                }
            }
            if let id = r.integralID {
                let matches = spectrum.integrals.indices.filter { spectrum.integrals[$0].id == id }
                if matches.count == 1, let j = matches.first {
                    NMRNumberField("段的已知 H", assignment($spectrum, j)).id(id)
                }
            } else {
                NMRNumberField("直接指派 H", Binding(get: { r.explicitH }, set: { h in edit { $0.explicitH = h } }))
            }
            Toggle("本行不列 H", isOn: Binding(get: { r.omitUnassignedH == true },
                                              set: { omit in edit { $0.omitUnassignedH = omit ? true : nil } }))
        }
    }

    private var protonFields: some View {
        VStack(alignment: .leading) {
            Picker("裂分", selection: Binding(get: { r.multiplicity }, set: { m in
                guard r.multiplicity != m else { return }
                edit {
                    $0.multiplicity = m
                    // 换了类型不能默用上一类型的 Hz。
                    $0.jHz = []; $0.jBasisMHz = nil; $0.jReview = .unreviewed
                }
            })) {
                Text("未定，不列").tag(Optional<NMRMultiplicity>.none)
                ForEach(NMRMultiplicity.allCases, id: \.self) { Text($0.rawValue).tag(Optional($0)) }
            }
            ForEach(r.jHz.indices, id: \.self) { j in NMRNumberField("J\(j + 1)（Hz）", slot(j)) }
            HStack {
                Button("添加 J") { edit { $0.jHz.append(nil); $0.jReview = .unreviewed } }
                    .disabled(r.multiplicity?.permitsResolvedJ != true)
                Button("删除末项") { edit { _ = $0.jHz.popLast(); $0.jReview = .unreviewed } }
                    .disabled(r.jHz.isEmpty)
            }
            if !r.jHz.isEmpty {
                Toggle("不列这些 J", isOn: Binding(get: { r.jReview == .unresolved },
                                                set: { omit in edit { $0.jReview = omit ? .unresolved : .unreviewed } }))
            }
            linkage
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Toggle("纳入行 \(k + 1) · \(kind) · δ \(positionLabel(r.shift))",
                   isOn: Binding(get: { r.include }, set: { v in edit { $0.include = v } }))
            if let reason = r.origin?.blocked {
                Text("未列：" + reason).foregroundColor(.orange)
            } else {
                if let o = r.origin, !o.reviewNotes.isEmpty {
                    Text(o.reviewNotes.joined(separator: "；")).foregroundColor(.secondary)
                }
                if let id = r.integralID {
                    Text("关联积分 " + shortID(id) +
                         (r.origin?.suggestedLink == true ? "（初始为区间建议，可改）" : ""))
                }
                DisclosureGroup("编辑峰位与报告字段…") {
                    VStack(alignment: .leading, spacing: 5) {
                        Picker("位移", selection: Binding(get: { band }, set: { v in
                            guard v != band else { return }
                            edit { $0.shift = v ? .bounds(nil, nil) : .center(nil) }
                        })) {
                            Text("中心").tag(false); Text("区间").tag(true)
                        }.pickerStyle(.segmented)
                        NMRNumberField(band ? "端点 A（ppm）" : "中心（ppm）", coordinate(false))
                        if band { NMRNumberField("端点 B（ppm）", coordinate(true)) }
                        if spectrum.nucleus == .proton { protonFields }
                    }.padding(.vertical, 4)
                }
            }
        }.font(detailFont).frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct NMRSpectrumEditor: View {
    @Binding var spectrum: NMRSpectrum
    let index: Int
    let remove: () -> Void

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text((index == 0 ? "本谱 · " : "可选附谱 · ") + spectrum.nucleus.symbol).bold()
                    Spacer()
                    if index != 0 { Button("移除附谱", action: remove) }
                }
                Toggle(index == 0 ? "纳入本谱" : "我已核对为同一样品，纳入此附谱快照", isOn: $spectrum.selected)
                if spectrum.selected {
                    NMRSolventField(solvent: $spectrum.solventDisplayName)
                    NMRNumberField("本核观测 MHz", Binding(get: { spectrum.observedMHz }, set: { f in
                        guard spectrum.observedMHz != f else { return }
                        var s = spectrum
                        s.observedMHz = f
                        for k in s.rows.indices where !s.rows[k].jHz.isEmpty {
                            s.rows[k].approved = false
                            // 对缺少依据标记的旧计算建议也采用保守处理。
                            if s.rows[k].jBasisMHz == nil, s.rows[k].origin?.sourceApproval == nil,
                               s.rows[k].origin?.analysisID != nil, s.rows[k].jReview == .unreviewed,
                               spectrum.sourceOffsetPPM == nil {
                                s.rows[k].jBasisMHz = spectrum.observedMHz
                            }
                        }
                        spectrum = s
                    }))
                    NMRBandList(spectrum: $spectrum)
                    DisclosureGroup("草稿编辑：\(spectrum.rows.filter(\.include).count) / \(spectrum.rows.count) 行纳入") {
                        VStack(alignment: .leading, spacing: 8) {
                            ForEach(spectrum.rows.indices, id: \.self) { k in
                                NMRPeakEditor(spectrum: $spectrum, k: k)
                                Divider()
                            }
                        }.padding(.vertical, 4)
                    }
                }
            }.padding(3).frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

struct NMRTextExportSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var draft: NMRReportDraft
    @State private var status = ""
    @State private var showCompanion = false
    @State private var loadingCompanion = false
    let save: (NMRReportDraft) -> Void
    let additionalSpectrum: ((URL, UUID, NMRReportNucleus) async throws -> NMRSpectrum)?

    init(report: NMRReportDraft, save: @escaping (NMRReportDraft) -> Void,
         additionalSpectrum: ((URL, UUID, NMRReportNucleus) async throws -> NMRSpectrum)? = nil) {
        _draft = State(initialValue: report)
        self.save = save
        self.additionalSpectrum = additionalSpectrum
    }

    private func importCompanion(_ result: Result<URL, Error>) {
        guard let load = additionalSpectrum, let primary = draft.spectra.first,
              draft.spectra.count == 1, !loadingCompanion else { return }
        let other: NMRReportNucleus = primary.nucleus == .proton ? .carbon13 : .proton
        loadingCompanion = true
        Task { @MainActor in
            defer { loadingCompanion = false }
            do {
                let url = try result.get()
                let scoped = url.startAccessingSecurityScopedResource()
                defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                var s = try await load(url, primary.id, other)
                guard s.nucleus == other, s.id != primary.id else { throw NMRError("不是另一核种的独立采集。") }
                guard draft.spectra.count == 1, draft.spectra.first?.id == primary.id else { return }
                s.selected = false
                draft.spectra.append(s)
                status = "已载入附谱，尚未纳入。仅在确认为同一样品时勾选。"
            } catch {
                let e = error as NSError
                if e.domain != NSCocoaErrorDomain || e.code != NSUserCancelledError {
                    status = "附谱未载入：" + error.localizedDescription
                }
            }
        }
    }

    private func binding(_ i: Int, _ original: NMRSpectrum) -> Binding<NMRSpectrum> {
        Binding(get: {
            guard draft.spectra.indices.contains(i), draft.spectra[i].id == original.id else { return original }
            return draft.spectra[i]
        }, set: { next in
            guard draft.spectra.indices.contains(i), draft.spectra[i].id == original.id else { return }
            draft.spectra[i] = next
        })
    }

    private var precision: some View {
        DisclosureGroup("显示精度…") {
            VStack(alignment: .leading) {
                Stepper("¹H ppm：\(draft.style.protonPlaces)", value: $draft.style.protonPlaces, in: 0...6)
                Stepper("¹³C ppm：\(draft.style.carbonPlaces)", value: $draft.style.carbonPlaces, in: 0...6)
                Stepper("J Hz：\(draft.style.jPlaces)", value: $draft.style.jPlaces, in: 1...6)
                Stepper("MHz：\(draft.style.mhzPlaces)", value: $draft.style.mhzPlaces, in: 0...6)
                Button("恢复默认精度") { draft.style = NMRTextStyle() }
            }.font(detailFont)
        }
    }

    private func issueMessage(_ issue: NMRIssue) -> String {
        guard let location = issue.location else { return issue.message }
        let row = location.row.map { " 行 \($0 + 1)" } ?? ""
        return "谱 \(location.spectrum + 1)\(row)：" + issue.message
    }

    private func previewPane(_ result: NMRDraftText) -> some View {
        let blockers = result.issues.filter { $0.kind != .warning }
        let warnings = result.issues.filter { $0.kind == .warning }
        let items = blockers + warnings
        return VStack(alignment: .leading, spacing: 8) {
            Text("TXT 正文预览").bold()
            ScrollView {
                Text(verbatim: result.preview)
                    .font(.system(size: 15, design: .monospaced)).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(8).frame(minHeight: 90, maxHeight: 210)
            .background(Color(nsColor: .textBackgroundColor))
            Text(result.exportText == nil ? "导出前需处理" : "可确认整份预览").bold()
            ScrollView {
                VStack(alignment: .leading, spacing: 7) {
                    ForEach(items.indices, id: \.self) { i in
                        let item = items[i]
                        Text(issueMessage(item))
                            .foregroundColor(item.kind == .warning ? Color.secondary : Color.red)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }.font(detailFont).frame(maxWidth: .infinity, alignment: .leading)
            }
        }.padding(.leading, 8)
    }

    @MainActor private func export(_ result: NMRDraftText) {
        guard let text = result.exportText else { return }
        let snapshot = NMRUTF8Document(text: text)
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "txt") ?? .plainText]
        panel.allowsOtherFileTypes = false
        panel.nameFieldStringValue = "NMR Report.txt"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        do {
            try snapshot.writeTXT(to: url)
            status = "已导出当时确认的整份预览 · " + url.lastPathComponent
        } catch {
            status = "未保存 TXT：" + error.localizedDescription
        }
    }

    var body: some View {
        let result = NMRTextReport.preview(draft)
        return VStack(alignment: .leading, spacing: 8) {
            Text("专业谱图文本").font(.title2.bold())
            Text("核对整份预览后导出；只用本谱即可。溶剂选择只改谱头，不定标。")
            HSplitView {
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(draft.spectra.indices, id: \.self) { i in
                            let s = draft.spectra[i]
                            NMRSpectrumEditor(spectrum: binding(i, s), index: i, remove: {
                                guard i != 0, draft.spectra.indices.contains(i), draft.spectra[i].id == s.id else { return }
                                draft.spectra.remove(at: i)
                            }).id(s.id.uuidString + ":\(i)")
                        }
                        if additionalSpectrum != nil, draft.spectra.count == 1 {
                            Button(loadingCompanion ? "正在载入…" : "可选：加入另一核种的工程…") {
                                showCompanion = true
                            }.disabled(loadingCompanion)
                        }
                        precision
                        Text("Notes · 不确定的裂分、J、H 可以不列。标点不等于单峰；有符号面积和相对值不是氢数。导出表示确认这份文字，不审批源峰组。")
                            .font(detailFont).foregroundColor(.secondary)
                    }.padding(.trailing, 8)
                }.frame(minWidth: 370, idealWidth: 465)
                previewPane(result).frame(minWidth: 270, maxWidth: .infinity)
            }
            Divider()
            if !status.isEmpty { Text(status).font(detailFont).textSelection(.enabled) }
            HStack {
                Button("关闭") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("保存草稿到工程") {
                    save(draft)
                    status = "已提交草稿；以工作台提示为准，保存工程文件后写盘。"
                }
                Spacer()
                Button("复制正文") {
                    guard let text = result.exportText else { return }
                    let board = NSPasteboard.general
                    board.clearContents()
                    status = board.setString(text, forType: .string) ? "已复制预览正文。" : "复制失败。"
                }.disabled(result.exportText == nil)
                Button("确认并导出…") { export(result) }
                    .keyboardShortcut(.defaultAction).disabled(result.exportText == nil)
            }
        }
        .font(.system(size: 15))
        .padding().frame(minWidth: 735, idealWidth: 930, minHeight: 475, idealHeight: 635)
        .fileImporter(isPresented: $showCompanion,
                      allowedContentTypes: [UTType(filenameExtension: "nmrstudio") ?? .data],
                      onCompletion: importCompanion)
    }
}
