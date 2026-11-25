import Foundation
import Accelerate

struct NMRError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

struct Spectrum: Codable {
    // All axes descend. Imported nonuniform ppm coordinates are preserved.
    var ppm: [Double]
    var real: [Double]
    var imag: [Double]?
    var range: ClosedRange<Double> { ppm.last!...ppm.first! }

    func nearest(_ target: Double) -> Int {
        var lo = 0, hi = ppm.count - 1
        while lo < hi {
            let mid = (lo + hi) / 2
            if ppm[mid] > target { lo = mid + 1 } else { hi = mid }
        }
        if lo > 0 && abs(ppm[lo-1] - target) < abs(ppm[lo] - target) { return lo - 1 }
        return lo
    }

    func area(_ bounds: ClosedRange<Double>) -> Double {
        var sum = 0.0
        let from = max(0, nearest(bounds.upperBound) - 1)
        let to = min(ppm.count - 1, nearest(bounds.lowerBound) + 1)
        guard from < to else { return 0 }
        for i in from..<to {
            let high = min(bounds.upperBound, ppm[i])
            let low = max(bounds.lowerBound, ppm[i+1])
            guard high > low else { continue }
            let slope = (real[i+1] - real[i]) / (ppm[i+1] - ppm[i])
            sum += (high - low) * (real[i] + slope * ((low + high) / 2 - ppm[i]))
        }
        return sum
    }

    func csv() -> String {
        var result = "ppm,intensity\n"
        for i in ppm.indices { result += "\(ppm[i]),\(real[i])\n" }
        return result
    }
}

struct FID: Codable {
    let r, i: [Double]
    let width, mhz, centerPPM, delay: Double

    func transform(lb: Double, fill: Int) throws -> Spectrum {
        let skip = Int(floor(delay))
        let usable = r.count - skip
        var n = 2
        while n < usable { n *= 2 }
        n *= fill
        guard n <= 4_194_304 else { throw NMRError("Choose a smaller zero fill. The FFT limit is 4 million points.") }
        var re = [Double](repeating: 0, count: n), im = re
        for j in 0..<usable {
            let window = exp(-Double.pi * lb * Double(j) / width) * (j == 0 ? 0.5 : 1)
            re[j] = r[j+skip] * window
            im[j] = i[j+skip] * window
        }
        let logN = vDSP_Length(n.trailingZeroBitCount)
        guard let plan = vDSP_create_fftsetupD(logN, FFTRadix(kFFTRadix2)) else { throw NMRError("Could not allocate the FFT.") }
        defer { vDSP_destroy_fftsetupD(plan) }
        re.withUnsafeMutableBufferPointer { rb in
            im.withUnsafeMutableBufferPointer { ib in
                var split = DSPDoubleSplitComplex(realp: rb.baseAddress!, imagp: ib.baseAddress!)
                vDSP_fft_zipD(plan, &split, 1, logN, FFTDirection(FFT_INVERSE))
            }
        }
        var ppm = [Double](repeating: 0, count: n), out = ppm, quad = ppm
        for j in 0..<n {
            let k = (j + n/2) % n
            let bin = Double(j - n/2) / Double(n)
            let phase = -2 * Double.pi * bin * (delay - Double(skip))
            out[j] = re[k] * cos(phase) - im[k] * sin(phase)
            quad[j] = re[k] * sin(phase) + im[k] * cos(phase)
            ppm[j] = centerPPM - bin * width / mhz
        }
        return Spectrum(ppm: ppm, real: out, imag: quad)
    }
}

enum Input: Codable { case fid(FID), spectrum(Spectrum) }
struct Dataset: Codable {
    let name, format: String
    let input: Input
    let acquiredNucleus: NMRNucleus?
    let solvent: String?
    private let observedMHz: Double?

    init(name: String, format: String, input: Input, nucleus: NMRNucleus? = nil,
         solvent: String? = nil, observeMHz: Double? = nil) {
        self.name = name; self.format = format; self.input = input
        acquiredNucleus = nucleus; self.solvent = solvent; observedMHz = observeMHz
    }
    var nucleus: NMRNucleus { acquiredNucleus ?? .unknown }
    var observeMHz: Double? {
        if let observedMHz { return observedMHz }
        if case .fid(let fid) = input { return fid.mhz }
        return nil
    }

    static let demo: Dataset = {
        let n = 8192, sw = 4400.0, mhz = 400.0, center = 4.5
        var re = [Double](repeating: 0, count: n), im = re
        // Illustrative ethyl acetate proton signal. Coupling in Hz, areas 2:3:3.
        let groups: [(Double, [Double], Double)] = [(4.12, [1,3,3,1], 2), (2.05,[1],3), (1.26,[1,2,1],3)]
        for (shift, weights, area) in groups {
            let total = weights.reduce(0,+)
            for (j,w) in weights.enumerated() {
                let hz = (shift - center) * mhz + (Double(j) - Double(weights.count-1)/2) * 7.1
                for k in 0..<n {
                    let t = Double(k) / sw
                    let a = area * w / total * exp(-Double.pi * 1.35 * t)
                    re[k] += a * cos(2 * Double.pi * hz * t)
                    im[k] += a * sin(2 * Double.pi * hz * t)
                }
            }
        }
        return Dataset(name: "Ethyl acetate", format: "Simulated ¹H FID · 400 MHz", input: .fid(FID(r: re, i: im, width: sw, mhz: mhz, centerPPM: center, delay: 0)), nucleus: .proton)
    }()
}

typealias Settings = NMRProcessingSettings

extension NMRProcessingSettings {
    // Existing callers and legacy fixtures use these accessors.
    var lb: Double {
        get { options.lbOverride ?? savedAutomaticLB ?? 0.3 }
        set { chooseLB(newValue) }
    }
    var fill: Int {
        get { options.fill }
        set { options.fill = newValue }
    }
    var baseline: Bool {
        get { options.baseline != .off }
        set { options.baseline = newValue ? .legacyEndpoints : .off }
    }
}

extension Spectrum {
    var processingArrays: NMRArrays { NMRArrays(ppm: ppm, real: real, imag: imag) }
}

extension NMRProcessingOutput {
    var displaySpectrum: Spectrum { Spectrum(ppm: spectrum.ppm, real: spectrum.real, imag: nil) }
}

func runProcessing(_ dataset: Dataset, _ settings: Settings,
                   action: NMRProcessingAction = .replay, cachedFFT: Spectrum? = nil) throws -> NMRProcessingOutput {
    let input: NMRProcessingInput
    switch dataset.input {
    case .fid(let fid):
        input = .raw(nucleus: dataset.nucleus, points: fid.r.count - Int(floor(fid.delay))) { lb, fill in
            if let cachedFFT { return cachedFFT.processingArrays }
            return try fid.transform(lb: lb, fill: fill).processingArrays
        }
    case .spectrum(let spectrum):
        input = .processed(nucleus: dataset.nucleus, spectrum: spectrum.processingArrays)
    }

    guard (0...10000).contains(settings.lb), [1,2,4].contains(settings.fill),
          abs(settings.p0) <= 1e5, abs(settings.p1) <= 1e5, abs(settings.offset) <= 1e5 else {
        throw NMRError("处理参数超出范围。")
    }
    return try NMRProcessingWorkflow.run(input, settings: settings, action: action, estimate: { fft, prior in
        let result = try estimateSpectralPhase(Spectrum(ppm: fft.ppm, real: fft.real, imag: fft.imag),
                                              initialFirstOrder: prior)
        return NMRPhaseFit(p0: result.p0, p1: result.p1, regions: result.regions, fittedFirstOrder: result.fittedFirstOrder)
    }, legacy: { fft in
        var real = fft.real
        try PhasePreview.subtractBaseline(from: &real, ppm: fft.ppm)
        return real
    })
}

func process(_ dataset: Dataset, _ settings: Settings) throws -> Spectrum {
    try runProcessing(dataset, settings).displaySpectrum
}
