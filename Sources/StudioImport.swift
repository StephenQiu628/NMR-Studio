import Foundation

struct StudioPhase: Codable, Sendable {
    let p0: Double
    let p1: Double
}

typealias StudioRawImport = NMRRawImportRecord<StudioPhase, NMRBaselineReceipt>

struct StudioImportSnapshot: Sendable {
    let dataset: Dataset
    let settings: Settings
    let spectrum: Spectrum
    let originalPPM: [Double]
    let peakTrace: NMRSpectrum1D?
    let peakIndex: NRPeakIndex?
    let spectrumID: UUID
    var project: StudioProject?
    var rawImport: StudioRawImport?

    init(dataset: Dataset, settings: Settings, spectrum: Spectrum,
         originalPPM: [Double], spectrumID: UUID) {
        self.dataset = dataset
        self.settings = settings
        self.spectrum = spectrum
        self.originalPPM = originalPPM
        self.spectrumID = spectrumID
        peakTrace = try? NMRSpectrum1D(spectrumID: spectrumID.uuidString, shapeRevision: "processing-1",
                                       nucleus: dataset.nucleus.rawNMRName, observedMHz: dataset.observeMHz,
                                       originPPM: originalPPM, phasedReal: spectrum.real)
        // Use local extrema in screen space. A small fraction of the measured
        // noise rejects tiny sample fluctuations without masking weak lines.
        let relief = (peakTrace?.estimatedNoise ?? 0) * 0.25
        peakIndex = try? NRPeakIndex(ppm: originalPPM, intensity: spectrum.real, minimumAdjacentRelief: relief)
    }
}

extension NMRNucleus {
    var rawNMRName: String {
        switch self {
        case .proton: return "1H"
        case .carbon13: return "13C"
        case .unknown: return "unknown"
        }
    }
}

typealias StudioSpectrum = Spectrum

struct StudioImport: NMRAutoOpenHost {
    typealias Raw = Dataset
    typealias Settings = NMRProcessingSettings
    typealias Spectrum = StudioSpectrum
    typealias Phase = StudioPhase
    typealias Endpoints = NMRBaselineReceipt
    typealias Document = StudioImportSnapshot

    let kernels = NMRReplay<Dataset, NMRProcessingSettings, Spectrum, StudioPhase, NMRBaselineReceipt>(windowPadFFT: { dataset, settings, check in
        try check()
        guard case .fid(let fid) = dataset.input else { throw NMRError("需要原始 FID。") }
        return try fid.transform(lb: settings.lb, fill: settings.fill)
    }, applyPhase: { fft, phase, check in
        try check()
        let spectrum = try PhasePreview.render(fft, p0: phase.p0, p1: phase.p1, offset: 0, baseline: false)
        if NMRFloor.inverted(spectrum.real) { throw NMRDeclined("自动相位仍有明显倒峰") }
        return spectrum
    }, subtractEndpoints: { phased, receipt, check in
        try check()
        if case let .skipped(why) = receipt.decision { throw NMRDeclined(why.title) }
        return Spectrum(ppm: phased.ppm, real: try receipt.applying(to: phased.real))
    }, isUsable: { s, check in
        try check()
        return s.ppm.count >= 2 && s.ppm.count == s.real.count &&
            s.real.allSatisfy(\.isFinite) && s.ppm.allSatisfy(\.isFinite) &&
            zip(s.ppm, s.ppm.dropFirst()).allSatisfy(>)
    })

    func isProject(_ url: URL, directory: Bool, check: NMRCheckpoint) throws -> Bool {
        try check()
        return url.pathExtension.lowercased() == "nmrstudio"
    }

    func folderMatch(_ folder: URL, check: NMRCheckpoint) throws -> NMRFolderMatch {
        try check()
        func first(_ names: [String]) -> URL? {
            names.map { folder.appendingPathComponent($0) }.first { FileManager.default.fileExists(atPath: $0.path) }
        }
        return NMRFolderMatch(preferredProcessed: first(["1r", "pdata/1/1r", "1i", "pdata/1/1i"]),
                              fid: first(["fid"]), table: first(["spectrum.csv"]))
    }

    func readFID(_ fid: URL, check: NMRCheckpoint) throws -> Dataset {
        try check()
        return try Reader.bruker(fid, raw: true)
    }

    func nucleusLabel(_ raw: Dataset) -> String? { raw.nucleus == .unknown ? nil : raw.nucleus.rawNMRName }

    func freshSettings(_ raw: Dataset, policy: NMRFreshRawPolicy) throws -> Settings {
        Settings(options: NMRProcessingOptions(lbOverride: policy.exponentialLBHz, fill: policy.zeroFillFactor))
    }

    func phaseEstimators(_ raw: Dataset, settings: Settings) -> [NMREstimator<Spectrum, StudioPhase>] {
        [NMREstimator(id: "多峰自动调相") { signal, check in
            try check()
            do {
                let fit = try estimateSpectralPhase(signal, initialFirstOrder: settings.p1)
                return StudioPhase(p0: fit.p0, p1: fit.p1)
            } catch { throw NMRDeclined(error.localizedDescription) }
        }]
    }

    func conservativeBaselines(_ raw: Dataset, settings: Settings) -> [NMREstimator<Spectrum, NMRBaselineReceipt>] {
        [NMREstimator(id: "自动基线", appliedName: { receipt in
            switch receipt.decision {
            case .affine: return "直线基线"
            case .smoothV1: return "Whittaker 平滑基线"
            case .skipped(let reason): return reason.title
            }
        }) { phased, check in
            try check()
            let decision = NMRFloor.decide(NMRArrays(ppm: phased.ppm, real: phased.real))
            if case .skipped(let why) = decision { throw NMRDeclined(why.title) }
            return NMRBaselineReceipt(count: phased.real.count, decision: decision)
        }]
    }

    func assembleRaw(_ fid: URL, raw: Dataset, settings: Settings, spectrum: Spectrum,
                     record: StudioRawImport, check: NMRCheckpoint) throws -> Document {
        try check()
        var settings = settings
        if let phase = record.phase.appliedParameters {
            settings.p0 = phase.p0
            settings.p1 = phase.p1
        }
        settings.installImportedBaseline(record.baseline.appliedParameters)
        let display = Spectrum(ppm: spectrum.ppm, real: spectrum.real)
        var document = Document(dataset: raw, settings: settings, spectrum: display, originalPPM: spectrum.ppm, spectrumID: UUID())
        document.rawImport = record
        return document
    }

    static func replay(_ dataset: Dataset, settings: Settings = Settings(), id: UUID = UUID()) throws -> Document {
        let result = try runProcessing(dataset, settings)
        return Document(dataset: dataset, settings: result.settings, spectrum: result.displaySpectrum,
                        originalPPM: result.originalPPM, spectrumID: id)
    }

    func readProcessed(_ selectedComponent: URL, check: NMRCheckpoint) throws -> Document {
        try check()
        let selected = selectedComponent.lastPathComponent.lowercased() == "1i"
            ? selectedComponent.deletingLastPathComponent().appendingPathComponent("1r") : selectedComponent
        return try Self.replay(Reader.bruker(selected, raw: false))
    }

    func readCSV(_ url: URL, check: NMRCheckpoint) throws -> Document {
        try check()
        return try Self.replay(Reader.table(url))
    }

    func readProject(_ url: URL, replay: NMRReplay<Dataset, NMRProcessingSettings, Spectrum, StudioPhase, NMRBaselineReceipt>, check: NMRCheckpoint) throws -> Document {
        try check()
        let project = try StudioProject.load(from: url)
        var document = try Self.replay(project.dataset, settings: project.settings, id: project.spectrumID ?? UUID())
        document.project = project
        document.rawImport = project.rawImport
        return document
    }
}
