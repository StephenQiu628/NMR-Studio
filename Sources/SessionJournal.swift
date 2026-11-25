import Foundation

struct IntegrationReference: Codable, Equatable {
    let markID: UUID
    let target: Double

    /// Apply a sheet result for one mark. Also pass nil when deleting that mark.
    static func updating(_ previous: IntegrationReference?, for markID: UUID,
                         target: Double?) -> IntegrationReference? {
        guard let target = target else {
            return previous?.markID == markID ? nil : previous
        }
        guard target.isFinite, target > 0 else { return previous }
        return IntegrationReference(markID: markID, target: target)
    }
}

struct OperationRecord: Identifiable, Codable {
    let id: UUID
    let date: Date
    let text: String
}

struct SessionSnapshot {
    let settings: Settings
    let marks: [Mark]
    let reference: IntegrationReference?
    let calibration: ShiftCalibrationRecord?
    let analysis: NMRAnalysisRecord
    let peakFile: NMRPeakFile?
    let referenceEdit: NRReferenceEdit?
    let referenceHistoryID: UUID?
    let textReport: NMRReportDraft?
    let traceKey: String
    let window: NMRBand
}

struct SessionJournal {
    struct SaveMarker: Equatable {
        let revision: UUID
        let lastRecordID: UUID?
    }

    private struct Step {
        let before: SessionSnapshot
        let priorRevision: UUID
        let text: String
    }

    private static let undoLimit = 64
    private var steps: [Step] = []
    private(set) var history: [OperationRecord] = []
    private(set) var revision: UUID = UUID()

    init() {}

    var canUndo: Bool { !steps.isEmpty }

    /// Capture after opening or successfully saving. Compare markers, not just
    /// revisions: undo restores a revision but appends a persistent history entry.
    var saveMarker: SaveMarker {
        SaveMarker(revision: revision, lastRecordID: history.last?.id)
    }

    mutating func start(history: [OperationRecord]) {
        steps.removeAll()
        self.history = history
        revision = UUID()
    }

    private mutating func log(_ text: String) {
        history.append(OperationRecord(id: UUID(), date: Date(), text: text))
    }

    /// Call once per committed edit with the applied state from before that edit.
    mutating func record(before: SessionSnapshot, description: String) {
        let trimmed = description.trimmingCharacters(in: .whitespacesAndNewlines)
        let text = trimmed.isEmpty ? "修改工作区" : trimmed
        if steps.count >= Self.undoLimit { steps.removeFirst() }
        steps.append(Step(before: before, priorRevision: revision, text: text))
        revision = UUID()
        log(text)
    }

    mutating func undo() -> SessionSnapshot? {
        // Backward steps only; do not retain current as a redo step.
        guard let step = steps.popLast() else { return nil }
        revision = step.priorRevision
        log("撤销：" + step.text)
        return step.before
    }

    static func changeDescription(from old: Settings, to new: Settings) -> String {
        var parts: [String] = []
        func scalar(_ name: String, _ a: Double, _ b: Double, _ unit: String) {
            if a != b { parts.append("\(name)：\(a) → \(b)\(unit)") }
        }
        scalar("校准偏移", old.offset, new.offset, " ppm")
        scalar("零阶相位 P0", old.p0, new.p0, "°")
        scalar("一阶相位 P1", old.p1, new.p1, "°")
        if old.options.lbOverride != new.options.lbOverride {
            let a = old.options.lbOverride.map { "\($0) Hz" } ?? "按核种"
            let b = new.options.lbOverride.map { "\($0) Hz" } ?? "按核种"
            parts.append("指数展宽：\(a) → \(b)")
        }
        if old.fill != new.fill {
            parts.append("补零：\(old.fill) → \(new.fill)")
        }
        if old.options.baseline != new.options.baseline {
            parts.append("基线校正：\(old.options.baseline.title) → \(new.options.baseline.title)")
        }
        return parts.isEmpty ? "设置未变" : parts.joined(separator: "；")
    }

    static func markDescription(for mark: Mark, adding: Bool, offset: Double) -> String {
        let verb = adding ? "添加" : "删除"
        let a = mark.lo + offset
        if mark.lo == mark.hi { return "\(verb)峰：\(a) ppm" }
        let b = mark.hi + offset
        return "\(verb)积分区间：\(min(a, b)) 至 \(max(a, b)) ppm"
    }

    static func relativeArea(_ raw: Double, referenceArea: Double, target: Double) -> Double? {
        guard raw.isFinite, referenceArea.isFinite, referenceArea != 0,
              target.isFinite, target > 0 else { return nil }
        if raw == 0 { return 0 }
        // (raw / referenceArea) * target, retaining the signs of the areas.
        // Separate the binary scale to avoid overflow/underflow of the intermediate ratio.
        let s = (raw.magnitude.significand / referenceArea.magnitude.significand) * target.significand
        let e = raw.exponent - referenceArea.exponent + target.exponent
        let value = Double(sign: raw.sign == referenceArea.sign ? .plus : .minus,
                           exponent: e, significand: s)
        return value.isFinite ? value : nil
    }

}
