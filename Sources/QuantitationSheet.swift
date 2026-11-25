import Foundation
import SwiftUI

/// Inputs and the saved interval are in displayed ppm. When writing the mark,
/// keep its ID and subtract the applied offset from each displayed endpoint.
struct QuantitationSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.locale) private var locale

    private let initial: ClosedRange<Double>
    private let limits: ClosedRange<Double>
    private let initialTarget: Double?
    private let onSave: (ClosedRange<Double>, Double?) -> Void

    // nil means untouched: use the original Double directly on save.
    @State private var aDraft: String? = nil
    @State private var bDraft: String? = nil
    @State private var targetDraft: String? = nil
    @State private var useReference: Bool

    init(initial: ClosedRange<Double>, limits: ClosedRange<Double>, initialTarget: Double?,
         onSave: @escaping (ClosedRange<Double>, Double?) -> Void) {
        self.initial = initial
        self.limits = limits
        self.initialTarget = initialTarget
        self.onSave = onSave
        _useReference = State(initialValue: initialTarget != nil)
    }

    private var decimalSeparator: String { locale.decimalSeparator ?? "." }

    private func display(_ n: Double) -> String {
        // Start with the round-tripping decimal representation, not a rounded UI format.
        String(n).replacingOccurrences(of: ".", with: decimalSeparator)
    }

    private func editing(_ draft: Binding<String?>, original: Double) -> Binding<String> {
        let originalText = display(original)
        return Binding(get: { draft.wrappedValue ?? originalText },
                       set: { draft.wrappedValue = $0 })
    }

    /// Parse the whole field, using the same locale as display. No grouping or
    /// prefix parses: ambiguous pasted numbers must not silently change an endpoint.
    private func value(_ draft: String?, original: Double) -> Double? {
        guard let draft = draft else { return original.isFinite ? original : nil }
        var s = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        let separator = decimalSeparator
        if separator != "." {
            guard !s.contains(".") else { return nil }
            s = s.replacingOccurrences(of: separator, with: ".")
        }
        var ascii = ""
        for ch in s {
            switch ch {
            case ".", "+", "-", "e", "E": ascii.append(ch)
            case "−": ascii.append("-")
            default:
                guard ch.unicodeScalars.count == 1, let scalar = ch.unicodeScalars.first,
                      CharacterSet.decimalDigits.contains(scalar),
                      let digit = ch.wholeNumberValue else { return nil }
                ascii += String(digit)
            }
        }
        guard let n = Double(ascii), n.isFinite else { return nil }
        return n
    }

    private enum Validation {
        case valid(ClosedRange<Double>, Double?)
        case invalid(String)

        var isValid: Bool {
            if case .valid = self { return true }
            return false
        }
    }

    private var validation: Validation {
        guard let a = value(aDraft, original: initial.lowerBound) else {
            return .invalid("端点 A 必须是有限数值。")
        }
        guard let b = value(bDraft, original: initial.upperBound) else {
            return .invalid("端点 B 必须是有限数值。")
        }
        let lo = min(a, b), hi = max(a, b)
        guard lo < hi else { return .invalid("两个端点不能相同。") }
        guard limits.contains(lo), limits.contains(hi) else {
            return .invalid("两个端点均须在允许范围内。")
        }
        guard (hi - lo).isFinite else { return .invalid("区间跨度过大。") }
        if useReference {
            guard let target = value(targetDraft, original: initialTarget ?? 1), target > 0 else {
                return .invalid("参考值必须是有限正数。")
            }
            return .valid(lo...hi, target)
        }
        return .valid(lo...hi, nil)
    }

    var body: some View {
        let checked = validation
        return VStack(alignment: .leading, spacing: 10) {
            Text("编辑积分区间").font(.headline)
            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 7) {
                GridRow {
                    Text("端点 A（ppm）").accessibilityHidden(true)
                    TextField("端点 A", text: editing($aDraft, original: initial.lowerBound))
                        .accessibilityLabel(Text("端点 A，单位 ppm"))
                }
                GridRow {
                    Text("端点 B（ppm）").accessibilityHidden(true)
                    TextField("端点 B", text: editing($bDraft, original: initial.upperBound))
                        .accessibilityLabel(Text("端点 B，单位 ppm"))
                }
            }
            Text("允许范围：\(display(limits.lowerBound)) 至 \(display(limits.upperBound)) ppm。")
                .font(.caption)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Divider()
            Toggle("将本积分设为定量参照", isOn: $useReference)
            if useReference {
                HStack(spacing: 10) {
                    Text("参考值").accessibilityHidden(true)
                    TextField("例如 1 或 2", text: editing($targetDraft, original: initialTarget ?? 1))
                        .accessibilityLabel(Text("参照积分的参考值"))
                }
            }
            if case let .invalid(message) = checked {
                Text(verbatim: message)
                    .font(.caption)
                    .foregroundColor(.red)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityLabel(Text("输入错误：\(message)"))
            }
            HStack {
                Spacer()
                Button("取消") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("保存") {
                    guard case let .valid(region, target) = validation else { return }
                    onSave(region, target)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!checked.isValid)
            }
        }
        .textFieldStyle(.roundedBorder)
        .frame(width: 388, alignment: .leading)
        .padding(16)
    }
}
