import Foundation

enum PhasePreview {
    // Start each preview from the cached unphased complex samples. offset is
    // the additive ppm reference offset, not part of the phase ramp.
    static func render(_ complex: Spectrum, p0: Double, p1: Double,
                       offset: Double, baseline: Bool) throws -> Spectrum {
        guard p0.isFinite, p1.isFinite, offset.isFinite else {
            throw NMRError("Phase angles and ppm offset must be finite.")
        }
        let n = complex.ppm.count
        guard n >= 2, complex.real.count == n else {
            throw NMRError("Expected matching nonempty ppm and real arrays.")
        }
        if let imag=complex.imag, imag.count != n { throw NMRError("复数谱的实部和虚部长度不同。") }
        var real = complex.real
        var ppm = complex.ppm
        let highFirst = ppm[0] >= ppm[n - 1]
        let denominator = Double(max(1, n - 1))
        let radiansPerDegree = Double.pi / 180
        if let imag=complex.imag, p0 != 0 || p1 != 0 {
            for i in 0..<n {
                let j=highFirst ? i : n-1-i
                let phi=(p0+p1*Double(j)/denominator)*radiansPerDegree
                real[i]=real[i]*cos(phi)-imag[i]*sin(phi)
            }
        }
        if baseline { try subtractBaseline(from:&real,ppm:ppm) }
        if offset != 0 { ppm=ppm.map { $0 + offset } }
        guard real.allSatisfy(\.isFinite), ppm.allSatisfy(\.isFinite), ppm.first! > ppm.last! else {
            throw NMRError("谱图处理结果超出数值范围。")
        }
        let result=Spectrum(ppm:ppm,real:real,imag:nil)
        return result
    }

    private static func median(_ band: ArraySlice<Double>) -> Double {
        let ordered = band.sorted()
        let mid = ordered.count / 2
        return ordered[mid]
    }

    static func subtractBaseline(from real: inout [Double], ppm: [Double]) throws {
        let n = real.count
        if n == 1 { real[0] = 0; return }  // Only a constant baseline is defined.
        let k = max(1, n / 50)
        let a = median(real.prefix(k)), b = median(real.suffix(k))
        let x0 = ppm[k / 2], x1 = ppm[n - 1 - k / 2]
        let dx = x1 - x0
        guard dx.isFinite, dx != 0 else { throw NMRError("Degenerate baseline anchor coordinates.") }
        let dy = b - a
        for i in real.indices {
            let t = (ppm[i] - x0) / dx
            let corrected = real[i] - (a + t * dy)
            guard corrected.isFinite else { throw NMRError("Non-finite baseline correction.") }
            real[i] = corrected
        }
    }
}
