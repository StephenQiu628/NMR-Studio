import Foundation

enum ProcessingRegression {
    // Each asymmetric group is a sum of three physical complex Lorentzians.
    // The negative group and either quadrature convention have the same imposed phase ramp.
    static func checkRegionalPhase() throws {
        let count = 8192
        let centers = [0.14, 0.34, 0.56, 0.72, 0.85]
        let heights = [1.0, 0.72, 0.3]
        let axis = (0..<count).map { 15 - 19 * Double($0) / Double(count - 1) }
        let expectedP0 = -82.0, expectedP1 = 116.0
        for hand in [-1.0, 1.0] {
            for spacing in [0.9, 1.4, 2.0, 2.8] {
                var real = [Double](), imag = [Double]()
                for i in axis.indices {
                    let x = Double(i) / Double(count - 1)
                    var absorption = 0.002 + 0.006 * x * x, dispersion = 0.004 * x
                    for (k, center) in centers.enumerated() {
                        let width = 0.0012 + 0.0002 * Double(k)
                        let amplitude = (k == 2 ? -0.6 : 1.0) * (1 - 0.09 * Double(k))
                        for j in heights.indices {
                            let delta = x - center - Double(j) * width * spacing
                            let u = delta / (width * (1 + 0.3 * Double(j)))
                            let line = amplitude * heights[j] / (1 + u * u)
                            absorption += line
                            dispersion += hand * u * line
                        }
                    }
                    let theta = -(expectedP0 + expectedP1 * x) * Double.pi / 180
                    real.append(absorption * cos(theta) - dispersion * sin(theta))
                    imag.append(absorption * sin(theta) + dispersion * cos(theta))
                }
                let spectrum = Spectrum(ppm: axis, real: real, imag: imag)
                let fit = try estimateSpectralPhase(spectrum, initialFirstOrder: 0)
                let errors = centers.map { x in
                    abs((fit.p0 - expectedP0 + (fit.p1 - expectedP1) * x).remainder(dividingBy: 360))
                }
                try Check.require(fit.fittedFirstOrder && errors.allSatisfy { $0 < 2 },
                                  "regional phase on asymmetric signed groups, errors \(errors)")
            }
        }
    }

    static func checkCurvedBaseline() throws {
        let count = 8192
        let x = (0..<count).map { Double($0) / Double(count - 1) }
        let peaks: [(center: Double, height: Double, width: Double)] = [
            (0.158, 1, 0.0014), (0.431, 0.18, 0.008), (0.49, 0.7, 0.001),
            (0.786, 0.35, 0.004), (0.62, 0.07, 0.015)
        ]
        let clean = x.map { t in peaks.reduce(0.0) { sum, peak in
            let u = (t - peak.center) / peak.width
            return sum + peak.height * exp(-0.5 * u * u)
        } }
        let ppm = x.map { 15 - 19 * $0 }
        let background = x.indices.filter { i in peaks.allSatisfy { abs(x[i] - $0.center) > 4 * $0.width } }
        for sign in [-1.0, 1.0] {
            let broadBand = x.map { t -> Double in
                let u = (t - 0.52) / 0.065, narrow = (t - 0.15) / 0.001
                return sign * 0.08 * exp(-0.5 * u * u) + exp(-0.5 * narrow * narrow)
            }
            let decision = NMRFloor.decide(NMRArrays(ppm: ppm, real: broadBand))
            let corrected = try NMRBaselineReceipt(count: count, decision: decision).applying(to: broadBand)
            try Check.require(corrected == broadBand, "isolated signed broad band must be preserved")
        }
        for sign in [0.0, -1.0, 1.0, 0.16] {
            let observed = x.indices.map { i -> Double in
                let drift = 0.025 * cos(2 * .pi * (x[i] + 0.15)) + 0.016 * x[i] - 0.002
                return clean[i] + sign * drift + 0.00015 * sin(Double(i) * 1.421)
            }
            let input = NMRProcessingInput.processed(nucleus: .proton, spectrum: NMRArrays(ppm: ppm, real: observed))
            let result = try NMRProcessingWorkflow.run(input, settings: Settings(), action: .baselineOnly)
            let y = result.spectrum.real
            if sign == 0 {
                try Check.require(y == observed, "flat control must retain broad and weak lines")
                continue
            }
            let mse = background.reduce(0.0) { sum, i in
                let residual = y[i] - clean[i]
                return sum + residual * residual
            } / Double(background.count)
            try Check.require(sqrt(mse) < 0.001, "known curved background RMS \(sqrt(mse))")
            for peak in peaks {
                let ids = x.indices.filter { abs(x[$0] - peak.center) < 2.5 * peak.width }
                let expected = ids.reduce(0.0) { $0 + clean[$1] }
                let actual = ids.reduce(0.0) { $0 + y[$1] }
                try Check.require(abs(actual - expected) < 0.02 * expected, "area for line at \(peak.center)")
            }
            let stored = try JSONEncoder().encode(result.settings)
            let decoded = try JSONDecoder().decode(Settings.self, from: stored)
            let replay = try NMRProcessingWorkflow.run(input, settings: decoded, action: .replay)
            try Check.require(replay.spectrum == result.spectrum, "round-trip curved baseline")
        }
    }
}
