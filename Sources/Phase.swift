import Foundation

func suggestedZeroPhase(_ spectrum: Spectrum, firstOrder: Double) throws -> Double {
    let r = spectrum.real
    let i = spectrum.imag
    let ppm = spectrum.ppm
    let n = r.count
    guard n >= 2, firstOrder.isFinite else { throw NMRError("Empty spectrum") }
    guard ppm.count == n else { throw NMRError("PPM and real data length mismatch") }
    if let i = i {
        guard i.count == n else { throw NMRError("Imag data length mismatch") }
        // Find strongest finite magnitude peak
        var maxMag = -Double.infinity
        var minMag = Double.infinity
        var maxIndex: Int? = nil
        for j in 0..<n {
            let re = r[j]
            let im = i[j]
            if re.isFinite && im.isFinite {
                let mag = hypot(re, im)
                guard mag.isFinite else { continue }
                minMag = min(minMag, mag)
                if mag > maxMag {
                    maxMag = mag
                    maxIndex = j
                }
            }
        }
        guard let anchor = maxIndex, minMag < maxMag else { throw NMRError("No finite complex points found") }
        // Compute complex phase angle at anchor
        let re = r[anchor]
        let im = i[anchor]
        if re == 0 && im == 0 {
            throw NMRError("Anchor point zero magnitude")
        }
        // Rotating by minus the measured angle makes this peak real and positive.
        let angleCurrent = atan2(im, re) * 180 / Double.pi
        let total = -angleCurrent - firstOrder * Double(anchor) / Double(n - 1)
        let wrapped = (total + 180).truncatingRemainder(dividingBy:360)
        let p0 = (wrapped >= 0 ? wrapped : wrapped + 360) - 180
        return p0
    } else {
        throw NMRError("Imaginary part missing, cannot determine zero phase")
    }
}
