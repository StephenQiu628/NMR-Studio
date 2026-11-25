import SwiftUI
import Foundation
#if canImport(NMRProcessing)
import NMRProcessing
#endif

fileprivate enum MeasureMode: Hashable { case picked, typed }
fileprivate enum TargetMode: Hashable { case table, manual }

// Host keeps this binding during the round trip to the plot. Use a fresh draft
// for a NEW calibration so an old typed display coordinate is never reused.
public struct SolventReferenceDraft {
    fileprivate var chosenNucleus: NMRNucleus = .unknown
    fileprivate var measureMode: MeasureMode = .picked
    fileprivate var typed = ""
    fileprivate var targetMode: TargetMode = .table
    fileprivate var search = ""
    fileprivate var solventID = ""
    fileprivate var lineID = ""
    fileprivate var standard: ManualStandard = .custom
    fileprivate var manualPPM = ""
    fileprivate var detail = ""
    public init() {}
}

public struct SolventReferenceSheet: View {
    @Binding private var draft: SolventReferenceDraft
    private let fileNucleus: NMRNucleus
    private let axis: CalibrationAxis
    private let currentOffset: Double
    private let pick: ReferencePick?
    private let brukerSOLVENT: String?
    private let requestPick: (() -> Void)?
    private let apply: (ShiftCalibrationRecord) throws -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var showError = false
    @State private var applyError = ""

    // requestPick: host closes this modal, arms explicit selection on the plot,
    // then presents a new sheet with the same draft and the chosen raw point.
    // apply: synchronous single workbench transaction, or throw without mutation.
    public init(draft: Binding<SolventReferenceDraft>, nucleus: NMRNucleus, axis: CalibrationAxis, currentOffset: Double, pick: ReferencePick?, brukerSOLVENT: String? = nil, requestPick: (() -> Void)? = nil, apply: @escaping (ShiftCalibrationRecord) throws -> Void) {
        self._draft = draft
        self.fileNucleus = nucleus; self.axis = axis; self.currentOffset = currentOffset
        self.pick = pick; self.brukerSOLVENT = brukerSOLVENT; self.requestPick = requestPick; self.apply = apply
    }

    private var nucleus: NMRNucleus { fileNucleus == .unknown ? draft.chosenNucleus : fileNucleus }
    private var solvents: [ReferenceSolvent] { SolventReferences.search(draft.search, nucleus: nucleus) }
    private var solvent: ReferenceSolvent? { solvents.first { $0.id == draft.solventID } }
    private var line: ReferenceLine? { solvent?.lines(for: nucleus).first { $0.id == draft.lineID } }
    private let posix = Locale(identifier: "en_US_POSIX")
    private func number(_ x: Double, signed: Bool = false) -> String {
        String(format: signed ? "%+.12g" : "%.12g", locale: posix, x)
    }
    private func chooseSolvent(_ id: String) { draft.solventID = id; draft.lineID = "" }
    private var query: Binding<String> {
        Binding(get: { draft.search }, set: { q in
            draft.search = q
            if !SolventReferences.search(q, nucleus: nucleus).contains(where: { $0.id == draft.solventID }) { chooseSolvent("") }
        })
    }

    private func proposal() throws -> ShiftCalibrationRecord {
        _ = try axis.displayedRange(offset: currentOffset)
        guard nucleus != .unknown else { throw CalibrationIssue("谱文件未指定支持的核种。请选择 ¹H 或 ¹³C 后继续。") }
        let observation: CalibrationObservation
        switch draft.measureMode {
        case .typed:
            observation = .typedDisplay(try ShiftCalibration.parsePPM(draft.typed, field: "当前显示轴上的实测值"))
        case .picked:
            guard let p = pick else { throw CalibrationIssue("尚无所选峰或中心。请到谱图选点，或切换到「输入 ppm」。") }
            observation = .selected(p)
        }
        let target: CalibrationTarget
        switch draft.targetMode {
        case .table: target = .tabulated(line?.id ?? "")
        case .manual:
            let ppm = try ShiftCalibration.parsePPM(draft.manualPPM, field: "手工目标值")
            target = .manual(draft.standard, ppm: ppm, detail: draft.detail)
        }
        return try ShiftCalibration.propose(axis: axis, nucleus: nucleus, currentOffset: currentOffset, observation: observation, target: target)
    }

    private var observationPanel: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                if fileNucleus == .unknown {
                    Picker("观测核种", selection: $draft.chosenNucleus) {
                        Text("请选择").tag(NMRNucleus.unknown)
                        Text("¹H").tag(NMRNucleus.proton)
                        Text("¹³C").tag(NMRNucleus.carbon13)
                    }.pickerStyle(.menu)
                } else { Text("观测核种：" + nucleus.symbol) }
                if let r = try? axis.displayedRange(offset: currentOffset) {
                    Text("显示全谱：\(number(r.upperBound)) → \(number(r.lowerBound)) ppm　·　当前 offset：\(number(currentOffset, signed: true)) ppm").font(.callout).monospacedDigit()
                }
                Picker("实测值来源", selection: $draft.measureMode) {
                    Text("谱图选点").tag(MeasureMode.picked)
                    Text("输入 ppm").tag(MeasureMode.typed)
                }.pickerStyle(.segmented)
                if draft.measureMode == .typed {
                    TextField("当前显示轴上的峰或中心（ppm）", text: $draft.typed)
                    Text("输入本次平移前的显示读数，可保留全部小数位。不要输入未加 offset 的原始坐标。")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    HStack {
                        if let p = pick {
                            VStack(alignment: .leading) {
                                Text(p.label.isEmpty ? "手选位置" : p.label)
                                Text((p.kind == .center ? "中心：" : "选点：") + number(p.rawPPM + currentOffset) + " ppm（显示轴）").monospacedDigit()
                            }
                        } else { Text("尚未选择峰或中心").foregroundStyle(.secondary) }
                        Spacer()
                        if let action = requestPick { Button("到谱图选点…", action: action) }
                    }
                    if requestPick == nil && pick == nil { Text("可取消并在谱图选点后重新打开，或直接输入 ppm。").font(.caption) }
                }
            }.padding(4).frame(maxWidth: .infinity, alignment: .leading)
        } label: { Text("1　指定实测位置").font(.headline) }
    }

    private var tableFields: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField("搜索溶剂名称、缩写或化学式", text: query)
            if let s = SolventReferences.suggestion(brukerSOLVENT: brukerSOLVENT, nucleus: nucleus) {
                HStack {
                    Text("SOLVENT 名称提示：" + s.name).font(.callout)
                    Spacer()
                    Button("选用此名称") { draft.search = ""; chooseSolvent(s.id) }
                }
            }
            Picker("溶剂", selection: Binding(get: { draft.solventID }, set: { chooseSolvent($0) })) {
                Text("请选择溶剂").tag("")
                ForEach(solvents) { s in Text(s.name).tag(s.id) }
            }.pickerStyle(.menu)
            if solvents.isEmpty { Text("无匹配名称。请更改搜索词，或切换到手工目标。").font(.callout) }
            if let s = solvent {
                Picker("参考线", selection: $draft.lineID) {
                    Text("请选择位点和目标 δ").tag("")
                    ForEach(s.lines(for: nucleus)) { l in
                        Text(l.site + "　" + String(format: "%.2f", locale: posix, l.ppm) + " ppm").tag(l.id)
                    }
                }.pickerStyle(.menu)
            }
            if let l = line {
                Text(l.note).font(.callout)
                Text(l.id + "  ·  " + l.source).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            }
        }
    }

    private var targetPanel: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                if nucleus == .unknown { Text("选择核种后可指定参考。").foregroundStyle(.secondary) }
                else {
                    Picker("目标来源", selection: $draft.targetMode) {
                        Text("溶剂表值").tag(TargetMode.table)
                        Text("手工目标 / 标准").tag(TargetMode.manual)
                    }.pickerStyle(.segmented)
                    if draft.targetMode == .table { tableFields }
                    else {
                        Picker("标准", selection: $draft.standard) {
                            ForEach(ManualStandard.allCases, id: \.self) { s in Text(s.title).tag(s) }
                        }.pickerStyle(.menu)
                        Text(draft.standard.note).font(.callout)
                        TextField("目标 δ（ppm，允许 0.00）", text: $draft.manualPPM)
                        TextField("标准名称、位点或方法备注（自定义时必填）", text: $draft.detail)
                    }
                    if nucleus == .carbon13 {
                        Label("碳多重峰：请指定整组分量的中心，而非最强分量。", systemImage: "info.circle").font(.callout)
                    }
                }
            }.padding(4).frame(maxWidth: .infinity, alignment: .leading)
        } label: { Text("2　选择目标 δ").font(.headline) }
    }

    private func metric(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.headline).monospacedDigit().textSelection(.enabled)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }

    private func preview(_ result: Result<ShiftCalibrationRecord, Error>) -> some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                switch result {
                case .failure(let error):
                    Label(error.localizedDescription, systemImage: "exclamationmark.circle").foregroundStyle(.orange)
                case .success(let r):
                    HStack(alignment: .top) {
                        metric("实测 / ppm", number(r.measuredDisplayPPM))
                        metric("参考 / ppm", number(r.targetPPM))
                        metric("Δ = 参考 − 实测 / ppm", number(r.deltaPPM, signed: true))
                    }
                    Divider()
                    Text("总 offset：\(number(r.previousOffsetPPM, signed: true)) → \(number(r.offsetPPM, signed: true)) ppm").monospacedDigit()
                    if let range = try? axis.displayedRange(offset: r.offsetPPM) {
                        Text("平移后全谱：\(number(range.upperBound)) → \(number(range.lowerBound)) ppm").font(.callout).monospacedDigit()
                    }
                    if let old = try? axis.displayedRange(offset: currentOffset), !old.contains(r.targetPPM) {
                        Text("目标在旧全谱范围外；应用前请核对位点、符号和单位。").foregroundStyle(.orange)
                    }
                    if r.deltaPPM == 0 { Text("已在目标位置；应用仅记录本次参考，不再移动坐标。").font(.callout) }
                }
            }.padding(4).frame(maxWidth: .infinity, alignment: .leading)
        } label: { Text("3　预览刚性平移").font(.headline) }
    }

    public var body: some View {
        let result: Result<ShiftCalibrationRecord, Error> = Result { try proposal() }
        return VStack(alignment: .leading, spacing: 12) {
            Label("化学位移定标", systemImage: "scope").font(.title2.bold())
            Text("选定参考信号后，核对表值与平移量。谱图选点读取点击位置附近的峰顶。").foregroundStyle(.secondary)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    observationPanel
                    targetPanel
                    preview(result)
                    Text("表值受样品组成、温度等条件影响。其他溶剂中的水峰不是规定参考线。\n" + SolventReferences.original).font(.caption).foregroundStyle(.secondary)
                }.frame(maxWidth: .infinity, alignment: .leading).padding(2)
            }
            Divider()
            HStack {
                Text("未应用前不修改谱图").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("取消") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("应用定标") {
                    do { try apply(proposal()); dismiss() }
                    catch { applyError = error.localizedDescription; showError = true }
                }.keyboardShortcut(.defaultAction).disabled((try? result.get()) == nil)
            }
        }
        .padding(16).frame(width: 612, height: 576).textFieldStyle(.roundedBorder)
        .onChange(of: nucleus) { _ in chooseSolvent(""); draft.manualPPM = ""; draft.detail = "" }
        .onChange(of: draft.standard) { _ in draft.manualPPM = ""; draft.detail = "" }
        .alert("未应用定标", isPresented: $showError) { Button("好", role: .cancel) {} } message: { Text(applyError) }
    }
}
