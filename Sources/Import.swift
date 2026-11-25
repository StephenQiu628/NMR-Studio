import Foundation

enum Reader {
    static let limit = 4_194_304
    static func open(_ url: URL) throws -> Dataset {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: url.path, isDirectory: &isDir) else { throw NMRError("The selected file could not be found.") }
        if isDir.boolValue {
            for name in ["1r", "pdata/1/1r", "fid", "spectrum.csv"] {
                let member = url.appendingPathComponent(name)
                if fm.fileExists(atPath: member.path) { return try open(member) }
            }
            throw NMRError("Choose a 1D experiment folder containing fid, pdata/1/1r, or spectrum.csv.")
        }
        switch url.lastPathComponent {
        case "fid": return try bruker(url, raw: true)
        case "1r": return try bruker(url, raw: false)
        default:
            guard ["txt","csv","tsv"].contains(url.pathExtension.lowercased()) else {
                throw NMRError("Open a Bruker fid or 1r, or a two-column ppm/intensity CSV, TSV or TXT file.")
            }
            return try table(url)
        }
    }

    static func table(_ url: URL) throws -> Dataset {
        let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size <= 128 * 1024 * 1024 else { throw NMRError("Text spectrum exceeds the 128 MB import limit.") }
        let contents = try String(contentsOf: url, encoding: .utf8)
        var x = [Double](), y = [Double](), hadHeader = false
        for (index,row) in contents.split(whereSeparator: \.isNewline).enumerated() {
            let line = row.trimmingCharacters(in: .whitespaces.union(CharacterSet(charactersIn: "\u{feff}")))
            if line.isEmpty || line.hasPrefix("#") { continue }
            let fields = line.split { $0 == "," || $0 == ";" || $0.isWhitespace }
            guard fields.count == 2, let a = Double(fields[0]), let b = Double(fields[1]), a.isFinite, b.isFinite else {
                if !hadHeader && x.isEmpty && line.lowercased().contains("ppm") {
                    hadHeader = true
                    continue
                }
                throw NMRError("Expected two finite numbers at data line \(index+1). The first column must be in ppm.")
            }
            if let last = x.last, a == last || (x.count > 1 && ((a > last) != (x[1] > x[0]))) {
                throw NMRError("The ppm column must increase or decrease throughout the file.")
            }
            guard x.count < limit else { throw NMRError("Spectrum exceeds the 4-million-point limit.") }
            x.append(a); y.append(b)
        }
        guard x.count >= 2 else { throw NMRError("At least two spectrum points are required.") }
        if x[0] < x[1] { x.reverse(); y.reverse() }
        let name = url.deletingPathExtension().lastPathComponent
        return Dataset(name: name == "spectrum" ? url.deletingLastPathComponent().lastPathComponent : name,
                       format: "Processed spectrum · text", input: .spectrum(Spectrum(ppm: x, real: y)))
    }

    static func parameters(_ url: URL) throws -> [String:String] {
        let bytes = try Data(contentsOf: url)
        var result: [String:String] = [:]
        for line in String(decoding: bytes, as: UTF8.self).split(whereSeparator: \.isNewline) where line.hasPrefix("##$") {
            guard let cut = line.firstIndex(of: "=") else { continue }
            result[String(line.dropFirst(3).prefix(upTo: cut))] = line[line.index(after: cut)...].trimmingCharacters(in: .whitespaces)
        }
        return result
    }

    static func binary(_ url: URL, count: Int, type: Int, order: Int) throws -> [Double] {
        guard [0,2].contains(type), [0,1].contains(order) else { throw NMRError("Unsupported Bruker data type or byte order.") }
        let bytes = try Data(contentsOf: url, options: .mappedIfSafe)
        let stride = type == 0 ? 4 : 8
        guard count >= 2, count <= 2 * limit, bytes.count >= count * stride else {
            throw NMRError("The Bruker file is truncated or its size is unsupported.")
        }
        return try bytes.withUnsafeBytes { (memory: UnsafeRawBufferPointer) in
            try (0..<count).map { i -> Double in
                if type == 0 {
                    let raw = memory.loadUnaligned(fromByteOffset: i*4, as: Int32.self)
                    return Double(order == 0 ? Int32(littleEndian: raw) : Int32(bigEndian: raw))
                }
                let raw = memory.loadUnaligned(fromByteOffset: i*8, as: UInt64.self)
                let v = Double(bitPattern: order == 0 ? UInt64(littleEndian: raw) : UInt64(bigEndian: raw))
                guard v.isFinite else { throw NMRError("The Bruker file contains nonfinite samples.") }
                return v
            }
        }
    }

    static func bruker(_ url: URL, raw: Bool) throws -> Dataset {
        let folder = url.deletingLastPathComponent()
        let p = try parameters(folder.appendingPathComponent(raw ? "acqus" : "procs"))
        func number(_ key: String) throws -> Double {
            guard let v = Double(p[key] ?? ""), v.isFinite else { throw NMRError("Missing or invalid Bruker parameter \(key).") }
            return v
        }
        func integer(_ key: String, fallback: Int? = nil) throws -> Int {
            if p[key] == nil, let fallback { return fallback }
            guard let v = Int(p[key] ?? "") else { throw NMRError("Invalid Bruker parameter \(key).") }
            return v
        }
        if raw {
            guard [1,3].contains(try integer("AQ_mod")) else { throw NMRError("This reader supports complex QSIM and DQD 1D FIDs. Open the processed 1r for this acquisition mode.") }
            let td = try integer("TD"), width = try number("SW_h"), obs = try number("SFO1")
            let ref = try p["BF1"] == nil ? obs : number("BF1")
            guard td >= 4, td % 2 == 0, width > 0, obs > 0, ref > 0 else { throw NMRError("Invalid acquisition dimensions or frequency.") }
            let values = try binary(url, count: td, type: integer("DTYPA", fallback: 0), order: integer("BYTORDA"))
            let delay = try filterDelay(p)
            guard delay.isFinite, delay >= 0, delay <= Double(td/2 - 2) else { throw NMRError("Invalid digital filter group delay.") }
            var re = [Double](), im = [Double]()
            for j in stride(from: 0, to: td, by: 2) { re.append(values[j]); im.append(values[j+1]) }
            let fid = try FID(r: re, i: im, width: width, mhz: ref, centerPPM: number("O1") / ref, delay: delay)
            return Dataset(name: folder.lastPathComponent, format: "Bruker FID · \(p["NUC1"]?.trimmingCharacters(in: CharacterSet(charactersIn: "<>")) ?? "1D") · \(Int(min(obs, 1e6).rounded())) MHz", input: .fid(fid), nucleus: NMRNucleus.identify(nuc1: p["NUC1"]), solvent: p["SOLVENT"], observeMHz: obs)
        }
        let n = try integer("SI"), sf = try number("SF"), sw = try number("SW_p"), offset = try number("OFFSET")
        guard n >= 2, n <= limit, sf > 0, sw > 0 else { throw NMRError("Invalid processed spectrum dimensions.") }
        if let stored = Int(p["STSI"] ?? ""), stored != 0 && stored != n || (Int(p["STSR"] ?? "0") ?? 0) != 0 {
            throw NMRError("Partial Bruker processing windows are unsupported. Export the full spectrum or a ppm table.")
        }
        let type = try integer("DTYPP", fallback: 0), order = try integer("BYTORDP"), scale = try pow(2, number("NC_proc"))
        func channel(_ u: URL) throws -> [Double] { try binary(u, count: n, type: type, order: order).map { $0 * scale } }
        let real = try channel(url), imagURL = folder.appendingPathComponent("1i")
        let imag = try FileManager.default.fileExists(atPath: imagURL.path) ? channel(imagURL) : nil
        let ppm = (0..<n).map { offset - Double($0) * (sw / sf / Double(n)) }
        let exp = folder.deletingLastPathComponent().deletingLastPathComponent()
        let acquisition = try? parameters(exp.appendingPathComponent("acqus"))
        let observed = acquisition?["SFO1"].flatMap(Double.init) ?? sf
        let nucleus = NMRNucleus.identify(nuc1: acquisition?["NUC1"], processedObserved: p["AXNUC"])
        return Dataset(name: exp.lastPathComponent + " · proc " + folder.lastPathComponent, format: "Bruker processed · 1r" + (imag == nil ? "" : " + 1i"), input: .spectrum(Spectrum(ppm: ppm, real: real, imag: imag)), nucleus: nucleus, solvent: acquisition?["SOLVENT"], observeMHz: observed)
    }

    static func filterDelay(_ p: [String:String]) throws -> Double {
        if let v = Double(p["GRPDLY"] ?? ""), v > 0 { return v }
        let decim = Int(p["DECIM"] ?? ""), version = Int(p["DSPFVS"] ?? "")
        if p["DIGMOD"] == "0" || decim == 1 { return 0 }
        // Legacy digital filter calibration, tap-count / (2 * decimation).
        // DSPFVS 10 coefficients tabulated by Westler and Abildgaard.
        let taps = [2:179,3:201,4:533,6:709,8:1097,12:1449,16:2225,24:2929,32:4481,48:5889,64:8993,96:11809,128:18017,192:23649,256:36065,384:47329,512:72161,768:94689,1024:144353,1536:189409,2048:288737]
        if version == 10, let d = decim, let t = taps[d] { return Double(t)/(2*Double(d)) }
        if p["GRPDLY"] == "0" || (version ?? 0) >= 14 { return 0 }
        throw NMRError("Unknown digital filter delay for this receiver. Open the vendor-processed 1r spectrum.")
    }
}
