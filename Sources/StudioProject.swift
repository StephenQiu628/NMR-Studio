import Foundation

struct StudioProject: Codable, Sendable {
    let version: Int
    let dataset: Dataset
    let settings: Settings
    let marks: [Mark]
    let history: [OperationRecord]?
    let reference: IntegrationReference?
    let calibration: ShiftCalibrationRecord?
    let analysis: NMRAnalysisRecord?
    let traceKey: String?
    let spectrumID: UUID?
    let rawImport: StudioRawImport?
    let peaks: NMRPeakFile?
    let referenceEdit: NRReferenceEdit?
    let textReport: NMRReportDraft?
    let zoomLow: Double
    let zoomHigh: Double

    enum ValidationError: LocalizedError {
        case invalidVersion
        case invalidSpectrumPoints
        case invalidPPMOrder
        case invalidComplexLengths
        case invalidPhaseSettings
        case invalidGroupDelay
        case invalidFill
        case invalidZoomRange
        case invalidMarkers

        var errorDescription: String? {
            switch self {
            case .invalidVersion:
                return "不支持的工程版本"
            case .invalidSpectrumPoints:
                return "谱点数量超过限制或包含无穷大/NaN"
            case .invalidPPMOrder:
                return "PPM 轴必须严格递减且有限"
            case .invalidComplexLengths:
                return "实部和虚部的数据长度不匹配或无效"
            case .invalidPhaseSettings:
                return "相位或其他设置超出合理范围"
            case .invalidGroupDelay:
                return "群延迟超出合理范围"
            case .invalidFill:
                return "填充参数应为1、2或4"
            case .invalidZoomRange:
                return "缩放区间无效或不按顺序"
            case .invalidMarkers:
                return "标记范围无效或不按顺序"
            }
        }
    }

    init(dataset: Dataset, settings: Settings, marks: [Mark], window: ClosedRange<Double>,
         history: [OperationRecord] = [], reference: IntegrationReference? = nil,
         calibration: ShiftCalibrationRecord? = nil, analysis: NMRAnalysisRecord? = nil,
         traceKey: String? = nil, spectrumID: UUID? = nil, rawImport: StudioRawImport? = nil,
         peaks: NMRPeakFile? = nil, referenceEdit: NRReferenceEdit? = nil, textReport: NMRReportDraft? = nil) throws {
        self.version = 4
        self.spectrumID = spectrumID; self.rawImport = rawImport
        self.peaks = peaks; self.referenceEdit = referenceEdit; self.textReport = textReport
        if let peaks { try peaks.validate(spectrumID: spectrumID?.uuidString ?? "") }
        self.calibration = calibration
        self.analysis = analysis
        self.traceKey = traceKey
        self.history = history
        self.reference = reference
        try Self.validateReference(reference, marks: marks)
        self.dataset = dataset
        self.settings = settings
        self.marks = marks
        self.zoomLow = window.lowerBound
        self.zoomHigh = window.upperBound

        try Self.validate(
            dataset: dataset,
            settings: settings,
            marks: marks,
            zoomLow: zoomLow,
            zoomHigh: zoomHigh
        )
    }

    func save(to url: URL) throws {
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        let data = try encoder.encode(self)

        try data.write(to: url, options: .atomic)
    }

    static func load(from url: URL) throws -> StudioProject {
        let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size <= 256 * 1024 * 1024 else { throw NMRError("工程文件超过 256 MB。") }
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        let decoder = PropertyListDecoder()
        let project = try decoder.decode(StudioProject.self, from: data)

        // Validate loaded project
        guard (1...4).contains(project.version) else {
            throw ValidationError.invalidVersion
        }

        try validate(
            dataset: project.dataset,
            settings: project.settings,
            marks: project.marks,
            zoomLow: project.zoomLow,
            zoomHigh: project.zoomHigh
        )

        try validateReference(project.reference, marks: project.marks)
        if let peaks = project.peaks { try peaks.validate(spectrumID: project.spectrumID?.uuidString ?? "") }
        return project
    }

    private static func validateReference(_ ref: IntegrationReference?, marks: [Mark]) throws {
        guard let ref else { return }
        guard ref.target.isFinite, ref.target > 0, marks.contains(where: { $0.id == ref.markID && !$0.isPeak }) else {
            throw NMRError("工程中的参考积分无效。")
        }
    }

    private static func validate(
        dataset: Dataset,
        settings: Settings,
        marks: [Mark],
        zoomLow: Double,
        zoomHigh: Double
    ) throws {
        // Validate dataset
        switch dataset.input {
        case .fid(let fid):
            // r and i lengths must match and not empty
            guard fid.r.count == fid.i.count && fid.r.count >= 2 else {
                throw ValidationError.invalidComplexLengths
            }
            guard fid.r.count <= 4_194_304 else {
                throw ValidationError.invalidSpectrumPoints
            }
            // All finite
            guard fid.r.allSatisfy(\.isFinite), fid.i.allSatisfy(\.isFinite) else { throw ValidationError.invalidSpectrumPoints }
            // Reasonable group delay: 0 <= delay <= n-2
            guard fid.delay >= 0 && fid.delay <= Double(fid.r.count - 2) else {
                throw ValidationError.invalidGroupDelay
            }
            // widths and other doubles finite
            guard fid.width.isFinite && fid.width > 0 && fid.mhz.isFinite && fid.mhz > 0 && fid.centerPPM.isFinite else {
                throw ValidationError.invalidSpectrumPoints
            }

        case .spectrum(let spec):
            let count = spec.ppm.count
            guard count >= 2 && count <= 4_194_304 else { throw ValidationError.invalidSpectrumPoints }

            // check all ppm finite and strictly descending
            var prev = Double.infinity
            for v in spec.ppm {
                guard v.isFinite && v < prev else {
                    throw ValidationError.invalidPPMOrder
                }
                prev = v
            }

            // real count matches ppm
            guard spec.real.count == count else {
                throw ValidationError.invalidComplexLengths
            }

            // imag counts if present
            if let imag = spec.imag {
                guard imag.count == count else {
                    throw ValidationError.invalidComplexLengths
                }
                for v in imag {
                    guard v.isFinite else { throw ValidationError.invalidSpectrumPoints }
                }
            }

            for v in spec.real {
                guard v.isFinite else { throw ValidationError.invalidSpectrumPoints }
            }
        }

        // Settings validation bounds
        let s = settings
        guard (0...10000).contains(s.lb) && abs(s.p0) <= 1e5 && abs(s.p1) <= 1e5 && abs(s.offset) <= 1e5 else {
            throw ValidationError.invalidPhaseSettings
        }

        // fill must be 1,2,4
        guard [1,2,4].contains(s.fill) else {
            throw ValidationError.invalidFill
        }

        // baseline boolean no validation needed

        // marks ordered and finite
        guard Set(marks.map(\.id)).count == marks.count else { throw ValidationError.invalidMarkers }
        for m in marks {
            guard m.lo.isFinite && m.hi.isFinite && m.lo <= m.hi else {
                throw ValidationError.invalidMarkers
            }
        }

        // zoom range finite and ordered
        guard zoomLow.isFinite && zoomHigh.isFinite && zoomLow < zoomHigh else {
            throw ValidationError.invalidZoomRange
        }
    }
}
