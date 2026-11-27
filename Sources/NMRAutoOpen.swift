import Foundation

// All host work in this file is synchronous work on the import task, not on the UI actor.
// Pass the checkpoint down into long reads, loops and iterative solvers.
public struct NMRCheckpoint: Sendable {
    public init() {}
    public func callAsFunction() throws { try Task<Never, Never>.checkCancellation() }
}

// A *recoverable numerical rejection*. Do not map I/O, decoding, unsupported-version
// or cancellation errors to this type. A rejection during stored replay is an error.
public struct NMRDeclined: LocalizedError, Sendable {
    public let reason: String
    public init(_ reason: String) {
        let s = reason.trimmingCharacters(in: .whitespacesAndNewlines)
        self.reason = s.isEmpty ? "估计不可靠" : s
    }
    public var errorDescription: String? { reason }
}

private struct NMROpenProblem: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

// An import policy, NOT a replacement for the host's processing-settings type.
public struct NMRFreshRawPolicy: Codable, Sendable {
    public let nucleusLabel: String?
    public let exponentialLBHz: Double
    public let zeroFillFactor: Int

    public init(nucleusLabel: String?) {
        self.nucleusLabel = nucleusLabel
        let trim = CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "<>[]^"))
        let key = (nucleusLabel ?? "").precomposedStringWithCompatibilityMapping
            .trimmingCharacters(in: trim).uppercased()
        switch key {
        case "13C", "C13", "C-13": exponentialLBHz = 1.0
        default: exponentialLBHz = 0.3 // includes 1H and unrecognised/missing nuclei
        }
        zeroFillFactor = 2
    }

    public func paddedCount(complexPointCount n: Int) throws -> Int {
        let (count, overflow) = n.multipliedReportingOverflow(by: zeroFillFactor)
        guard n > 0, zeroFillFactor > 0, !overflow else { throw NMROpenProblem("无效的补零长度") }
        return count
    }
}

public enum NMRDecision<Value: Codable & Sendable>: Codable, Sendable {
    case applied(method: String, parameters: Value)
    case abstained(reason: String)
    case skipped(reason: String)

    public var appliedParameters: Value? {
        if case let .applied(_, p) = self { return p }
        return nil
    }
    fileprivate var auditText: String {
        switch self {
        case let .applied(id, _): return "已应用 (\(id))"
        case let .abstained(reason): return "未采用：\(reason)"
        case let .skipped(reason): return "未运行：\(reason)"
        }
    }
}

// Immutable provenance. Live editable parameters remain in the host document.
public struct NMRRawImportRecord<P: Codable & Sendable, B: Codable & Sendable>: Codable, Sendable {
    public let recordVersion: Int
    public let policy: NMRFreshRawPolicy
    public let phase: NMRDecision<P>
    public let baseline: NMRDecision<B>
    public let auditNote: String

    fileprivate init(policy: NMRFreshRawPolicy, phase: NMRDecision<P>, baseline: NMRDecision<B>) {
        recordVersion = 1
        self.policy = policy
        self.phase = phase
        self.baseline = baseline
        let label = policy.nucleusLabel ?? "?"
        auditNote = "打开 fid (\(label))：指数 LB \(policy.exponentialLBHz) Hz → \(policy.zeroFillFactor)× 补零 → FFT；相位\(phase.auditText)；基线\(baseline.auditText)"
    }

    public var status: String {
        func brief(_ s: String) -> String {
            let t = s.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
            return t.count <= 72 ? t : String(t.prefix(71)) + "…"
        }
        switch phase {
        case .abstained(let why), .skipped(let why):
            return "显示未校相 FFT，未扣基线：\(brief(why))"
        case .applied:
            switch baseline {
            case let .applied(method, _): return "已应用自动相位，已扣基线（\(brief(method))）"
            case .abstained(let why): return "已应用自动相位，未扣基线：\(brief(why))"
            case .skipped(let why): return "已应用自动相位，未运行基线：\(brief(why))"
            }
        }
    }
}

public struct NMREstimator<S: Sendable, V: Sendable>: Sendable {
    public typealias Estimate = @Sendable (S, NMRCheckpoint) throws -> V
    public let id: String // stable, e.g. a solver name + algorithm revision
    public let estimate: Estimate
    public let appliedName: (@Sendable (V) -> String)?
    public init(id: String, appliedName: (@Sendable (V) -> String)? = nil, estimate: @escaping Estimate) {
        self.id = id
        self.appliedName = appliedName
        self.estimate = estimate
    }
}

// Bind existing DSP kernels once. Inputs, including the complex FFT, must have value
// semantics (or be immutable). A rejected correction must not modify its input buffer.
public struct NMRReplay<R: Sendable, Settings: Sendable, S: Sendable, P: Sendable, B: Sendable>: Sendable {
    public typealias Transform = @Sendable (R, Settings, NMRCheckpoint) throws -> S
    public typealias Rotate = @Sendable (S, P, NMRCheckpoint) throws -> S
    public typealias SubtractLine = @Sendable (S, B, NMRCheckpoint) throws -> S
    public typealias Usable = @Sendable (S, NMRCheckpoint) throws -> Bool
    private let frontEnd: Transform
    private let rotate: Rotate
    private let subtractLine: SubtractLine
    private let usable: Usable

    public init(windowPadFFT: @escaping Transform, applyPhase: @escaping Rotate,
                subtractEndpoints: @escaping SubtractLine, isUsable: @escaping Usable) {
        frontEnd = windowPadFFT
        rotate = applyPhase
        subtractLine = subtractEndpoints
        usable = isUsable
    }

    // Just the acquisition/transform path specified by Settings. No automatic or
    // stored phase, baseline, referencing, document installation or saving here.
    public func transformed(_ raw: R, _ settings: Settings, _ check: NMRCheckpoint) throws -> S {
        try check()
        let s = try frontEnd(raw, settings, check)
        try check()
        let ok = try usable(s, check)
        try check()
        guard ok else { throw NMROpenProblem("未得到可显示的 FFT") }
        return s
    }

    private func checkedCorrection(_ s: S, _ check: NMRCheckpoint) throws -> S {
        try check()
        let ok = try usable(s, check)
        try check()
        guard ok else { throw NMRDeclined("校正结果不可用") }
        return s
    }
    public func phased(_ s: S, _ parameters: P, _ check: NMRCheckpoint) throws -> S {
        try check()
        return try checkedCorrection(rotate(s, parameters, check), check)
    }
    public func baselined(_ s: S, _ endpoints: B, _ check: NMRCheckpoint) throws -> S {
        try check()
        return try checkedCorrection(subtractLine(s, endpoints, check), check)
    }

    // For archives backed by raw data. Explicit zeros and disabled steps are distinct.
    // In particular an old stored baseline does not require a stored phase to exist.
    public func stored(_ raw: R, settings: Settings, phase: P?, endpoints: B?, check: NMRCheckpoint) throws -> S {
        var s = try transformed(raw, settings, check)
        if let p = phase { s = try phased(s, p, check) }
        if let b = endpoints { s = try baselined(s, b, check) }
        return s
    }
}

public struct NMRFolderMatch: Sendable {
    // Discovery only, in the host's established experiment/procno scope. nil means
    // absent, NOT that decoding an existing preferred file failed.
    public let preferredProcessed: URL?
    public let fid: URL?
    public let table: URL?
    public init(preferredProcessed: URL?, fid: URL?, table: URL? = nil) {
        self.preferredProcessed = preferredProcessed
        self.fid = fid; self.table = table
    }
}

public protocol NMRAutoOpenHost: Sendable {
    associatedtype Raw: Sendable
    associatedtype Settings: Sendable
    associatedtype Spectrum: Sendable
    associatedtype Phase: Codable & Sendable
    associatedtype Endpoints: Codable & Sendable
    associatedtype Document: Sendable // a detached, fully prepared document snapshot
    typealias Kernels = NMRReplay<Raw, Settings, Spectrum, Phase, Endpoints>
    typealias ImportRecord = NMRRawImportRecord<Phase, Endpoints>

    var kernels: Kernels { get }
    func isProject(_ url: URL, directory: Bool, check: NMRCheckpoint) throws -> Bool
    func folderMatch(_ folder: URL, check: NMRCheckpoint) throws -> NMRFolderMatch
    func readFID(_ fid: URL, check: NMRCheckpoint) throws -> Raw
    func nucleusLabel(_ raw: Raw) -> String?
    func freshSettings(_ raw: Raw, policy: NMRFreshRawPolicy) throws -> Settings
    func phaseEstimators(_ raw: Raw, settings: Settings) -> [NMREstimator<Spectrum, Phase>]
    func conservativeBaselines(_ raw: Raw, settings: Settings) -> [NMREstimator<Spectrum, Endpoints>]
    func assembleRaw(_ fid: URL, raw: Raw, settings: Settings, spectrum: Spectrum,
                     record: ImportRecord, check: NMRCheckpoint) throws -> Document
    func readProcessed(_ selectedComponent: URL, check: NMRCheckpoint) throws -> Document
    func readCSV(_ url: URL, check: NMRCheckpoint) throws -> Document
    func readProject(_ url: URL, replay: Kernels, check: NMRCheckpoint) throws -> Document
}

public struct NMROpenRequest: Sendable {
    public let selected: URL
    public let accessRoots: [URL] // additional user-authorised security-scoped URLs, if needed
    public init(_ selected: URL, accessRoots: [URL] = []) {
        self.selected = selected
        self.accessRoots = accessRoots
    }
}

public enum NMROpenSource: Sendable {
    case rawFID(URL), processed(URL), csv(URL), project(URL)
}

public struct NMROpened<Document: Sendable>: Sendable {
    public let selected: URL
    public let source: NMROpenSource
    public let document: Document
    public let status: String
}

enum NMRImportWorker {
    private static func directoryFlag(_ url: URL) throws -> Bool {
        guard url.isFileURL else { throw NMROpenProblem("请选择本地文件或文件夹") }
        let attrs = try url.resolvingSymlinksInPath().resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey])
        if attrs.isDirectory == true { return true }
        guard attrs.isRegularFile == true else { throw NMROpenProblem("不是普通文件：\(url.lastPathComponent)") }
        return false
    }

    private static func resolve<H: NMRAutoOpenHost>(_ url: URL, _ host: H, _ check: NMRCheckpoint) throws -> NMROpenSource {
        let dir = try directoryFlag(url)
        if !dir {
            switch url.lastPathComponent.lowercased() {
            case "fid": return .rawFID(url)
            case "1r", "1i": return .processed(url)
            default: break
            }
            if ["csv", "tsv", "txt"].contains(url.pathExtension.lowercased()) { return .csv(url) }
        }
        try check()
        if try host.isProject(url, directory: dir, check: check) { return .project(url) }
        guard dir else { throw NMROpenProblem("不支持的文件：\(url.lastPathComponent)") }
        let match = try host.folderMatch(url, check: check)
        try check()
        if let p = match.preferredProcessed {
            guard ["1r", "1i"].contains(p.lastPathComponent.lowercased()), try directoryFlag(p) == false else {
                throw NMROpenProblem("处理谱路径无效：\(p.lastPathComponent)")
            }
            return .processed(p)
        }
        if let f = match.fid {
            guard f.lastPathComponent.lowercased() == "fid", try directoryFlag(f) == false else {
                throw NMROpenProblem("fid 路径无效")
            }
            return .rawFID(f)
        }
        if let table = match.table { return .csv(table) }
        throw NMROpenProblem("文件夹中没有可打开的一维 Bruker 谱")
    }

    // Only estimate/apply rejections are recoverable. Every candidate starts from
    // the SAME input. Never record an estimate as applied until application succeeds.
    private static func correct<S: Sendable, P: Codable & Sendable>(
        _ input: S, using chain: [NMREstimator<S, P>], apply: (S, P, NMRCheckpoint) throws -> S,
        check: NMRCheckpoint
    ) throws -> (S, NMRDecision<P>) {
        var reasons: [String] = []
        for method in chain {
            try check()
            do {
                let p = try method.estimate(input, check)
                try check()
                let s = try apply(input, p, check)
                try check()
                return (s, .applied(method: method.appliedName?(p) ?? method.id, parameters: p))
            } catch let rejection as NMRDeclined {
                try check()
                reasons.append(chain.count == 1 ? rejection.reason : "\(method.id)：\(rejection.reason)")
            }
        }
        try check()
        return (input, .abstained(reason: reasons.isEmpty ? "没有可用估计器" : reasons.joined(separator: "；")))
    }

    static func prepare<H: NMRAutoOpenHost>(_ request: NMROpenRequest, host: H) throws -> NMROpened<H.Document> {
        let check = NMRCheckpoint()
        var started: [URL] = []
        defer { for u in started.reversed() { u.stopAccessingSecurityScopedResource() } }
        for u in [request.selected] + request.accessRoots {
            try check()
            guard u.isFileURL else { throw NMROpenProblem("需要文件 URL") }
            if u.startAccessingSecurityScopedResource() { started.append(u) }
        }
        let source = try resolve(request.selected, host, check)
        try check()
        let doc: H.Document
        let status: String
        switch source {
        case let .project(u):
            doc = try host.readProject(u, replay: host.kernels, check: check)
            status = "已载入工程，沿用保存的相位与基线设置"
        case let .csv(u):
            doc = try host.readCSV(u, check: check)
            status = "已载入 CSV，未重新处理"
        case let .processed(u):
            doc = try host.readProcessed(u, check: check)
            status = "已载入处理谱 \(u.lastPathComponent)，未重新处理"
        case let .rawFID(fid):
            let raw = try host.readFID(fid, check: check)
            try check()
            let policy = NMRFreshRawPolicy(nucleusLabel: host.nucleusLabel(raw))
            let settings = try host.freshSettings(raw, policy: policy)
            let k = host.kernels
            let fft = try k.transformed(raw, settings, check)
            let phase = try correct(fft, using: host.phaseEstimators(raw, settings: settings), apply: k.phased, check: check)
            let base: (H.Spectrum, NMRDecision<H.Endpoints>)
            if case .applied = phase.1 {
                base = try correct(phase.0, using: host.conservativeBaselines(raw, settings: settings), apply: k.baselined, check: check)
            } else {
                base = (fft, .skipped(reason: "没有可靠相位"))
            }
            try check()
            let record = NMRRawImportRecord(policy: policy, phase: phase.1, baseline: base.1)
            doc = try host.assembleRaw(fid, raw: raw, settings: settings, spectrum: base.0, record: record, check: check)
            status = record.status
        }
        try check()
        return NMROpened(selected: request.selected, source: source, document: doc, status: status)
    }
}

// One instance per document host/window. The ticket check AND the commit occur in
// one main-actor turn; even an uninterruptible kernel cannot publish a stale result.
@MainActor
public final class NMRAutoOpen<H: NMRAutoOpenHost> {
    public typealias Commit = @MainActor @Sendable (NMROpened<H.Document>) -> Void
    public typealias Failure = @MainActor @Sendable (String) -> Void
    private let host: H
    private var ticket = UUID()
    private var job: Task<Void, Never>?

    public init(host: H) { self.host = host }
    deinit { job?.cancel() }

    public func cancel() {
        ticket = UUID()
        job?.cancel()
        job = nil
    }

    public func open(_ request: NMROpenRequest, commit: @escaping Commit, failure: @escaping Failure) {
        cancel()
        let id = ticket
        let api = host
        job = Task.detached(priority: .userInitiated) { [weak self] in
            do {
                let next = try NMRImportWorker.prepare(request, host: api)
                try Task<Never, Never>.checkCancellation()
                await self?.finish(id) { commit(next) }
            } catch {
                if Task<Never, Never>.isCancelled || error is CancellationError {
                    await self?.finish(id) {}
                } else {
                    let message = "\(request.selected.lastPathComponent)：\(error.localizedDescription)"
                    await self?.finish(id) { failure(message) }
                }
            }
        }
    }

    private func finish(_ id: UUID, _ action: @MainActor @Sendable () -> Void) {
        guard id == ticket else { return }
        job = nil
        action()
    }
}
