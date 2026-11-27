import SwiftUI
import Foundation

@MainActor
struct StudioIntegralInspector: View {
    @ObservedObject var w: Workbench
    let version: StudioAnnotationVersion
    let configure: (Mark) -> Void
    let remove: (Mark) -> Void
    @Environment(\.colorScheme) private var colorScheme

    private var colors: StudioColors { StudioColors(dark: colorScheme == .dark) }
    private var rows: [Mark] { w.marks.filter { !$0.isPeak } }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .firstTextBaseline) {
                    Text("积分").font(.system(size: 22, weight: .semibold))
                    Spacer()
                    Text("\(rows.count) 个区间")
                        .font(.system(size: 15)).foregroundStyle(colors.secondary)
                }

                if rows.isEmpty {
                    VStack(alignment: .leading, spacing: 12) {
                        Image(systemName: "sum").font(.system(size: 30)).foregroundStyle(colors.accent)
                        Text("在谱图上横向拖选一个区间，开始积分。")
                        Text("点选括线或结果行后，可拖动端点或输入精确边界。")
                            .font(.system(size: 15)).foregroundStyle(colors.secondary)
                    }
                    .padding(.vertical, 18)
                } else {
                    results
                    Divider()
                    if let mark = w.selectedAnnotation, !mark.isPeak {
                        let context = StudioIntegralEditContext(
                            version: version, markID: mark.id,
                            epoch: w.integralInteractionRevision,
                            bounds: w.bounds(mark), limits: w.spectrum.range,
                            target: w.reference?.markID == mark.id ? w.reference?.target : nil)
                        StudioIntegralEditor(w: w, context: context, configure: configure, remove: remove)
                            // A new selection, drag, processing state or transaction
                            // discards drafts; row positions are never edit identities.
                            .id(context)
                    } else {
                        Text("选择一行或点选谱图括线以编辑。")
                            .foregroundStyle(colors.secondary)
                    }
                }

                if w.hasDraft {
                    Text("请先应用或放弃处理预览，再编辑积分。")
                        .font(.system(size: 15)).foregroundStyle(colors.secondary)
                }
            }
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .font(.system(size: 17))
        .foregroundStyle(colors.text)
        .frame(width: StudioColors.sidebarWidth)
        .frame(maxHeight: .infinity)
        .background(colors.panel)
        .accessibilityLabel("积分检查器")
    }

    private var results: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                Text("#").frame(width: 28, alignment: .leading).accessibilityLabel("区间序号")
                Text("范围 ppm").frame(width: 140, alignment: .leading)
                Text("相对积分").frame(maxWidth: .infinity, alignment: .trailing)
            }
            .font(.system(size: 15, weight: .semibold))
            .foregroundStyle(colors.secondary)
            .padding(.horizontal, 8)

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach(Array(rows.enumerated()), id: \.element.id) { entry in
                            resultRow(entry.element, number: entry.offset + 1)
                                .id(entry.element.id)
                        }
                    }
                }
                .frame(height: min(216, CGFloat(rows.count) * 50))
                .onAppear {
                    if let id = w.selectedIntegralID { proxy.scrollTo(id, anchor: .center) }
                }
                .onChange(of: w.selectedIntegralID) { id in
                    guard let id else { return }
                    withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo(id, anchor: .center) }
                }
            }
        }
    }

    private func resultRow(_ mark: Mark, number: Int) -> some View {
        let bounds = w.bounds(mark)
        let relative = w.relativeArea(mark)
        let area = w.spectrum.area(bounds)
        let selected = w.selectedIntegralID == mark.id
        return Button {
            w.pickAnnotation(mark.id, at: version)
        } label: {
            HStack(alignment: .center, spacing: 8) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(String(number)).fontWeight(.medium)
                }
                .frame(width: 28, alignment: .leading)

                ViewThatFits(in: .horizontal) {
                    Text(String(format: "%.4f–%.4f", bounds.upperBound, bounds.lowerBound))
                        .fixedSize()
                    VStack(alignment: .leading, spacing: 2) {
                        Text(String(format: "%.5f", bounds.upperBound))
                        Text(String(format: "%.5f", bounds.lowerBound))
                    }
                }
                .monospacedDigit()
                .frame(width: 140, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)

                VStack(alignment: .trailing, spacing: 3) {
                    if let relative {
                        Text(String(format: "%.5g", relative)).fontWeight(.medium)
                    } else {
                        Text(area.isFinite ? String(format: "%+.5g", area) : "不可用")
                        Text("a.u.·ppm").foregroundStyle(colors.secondary)
                    }
                }
                .monospacedDigit()
                .frame(maxWidth: .infinity, alignment: .trailing)
                .fixedSize(horizontal: false, vertical: true)
            }
            .font(.system(size: 15))
            .foregroundStyle(colors.text)
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .frame(minHeight: 46)
            .background(selected ? colors.selection : colors.raised.opacity(0.45))
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay {
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(selected ? colors.accent : Color.clear, lineWidth: 1)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text("积分 \(number)，\(studioMarkBounds(mark, offset: w.applied.offset))"))
        .accessibilityValue(Text(selected ? "已选定" : "未选定"))
        .help((w.reference?.markID == mark.id ? "参考积分 · " : "") + studioMarkBounds(mark, offset: w.applied.offset))
    }
}

private struct StudioIntegralEditContext: Hashable {
    let version: StudioAnnotationVersion
    let markID: UUID
    let epoch: UUID
    let bounds: ClosedRange<Double>
    let limits: ClosedRange<Double>
    let target: Double?
}

@MainActor
private struct StudioIntegralEditor: View {
    @ObservedObject var w: Workbench
    let context: StudioIntegralEditContext
    let configure: (Mark) -> Void
    let remove: (Mark) -> Void
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.locale) private var locale
    @State private var leftDraft: String?
    @State private var rightDraft: String?
    @FocusState private var focused: Endpoint?

    private enum Endpoint: Hashable { case left, right }
    private enum Validation {
        case valid(ClosedRange<Double>)
        case invalid(String)
        var bounds: ClosedRange<Double>? {
            if case .valid(let bounds) = self { return bounds }
            return nil
        }
    }

    private var colors: StudioColors { StudioColors(dark: colorScheme == .dark) }
    private var separator: String { locale.decimalSeparator ?? "." }
    private var mark: Mark? { w.marks.first { $0.id == context.markID && !$0.isPeak } }
    private var canEdit: Bool {
        w.accepts(context.version) && !w.hasDraft &&
            w.selectedAnnotationID == context.markID &&
            w.integralInteractionRevision == context.epoch &&
            mark.map { w.bounds($0) == context.bounds } == true
    }

    private func display(_ number: Double) -> String {
        String(number).replacingOccurrences(of: ".", with: separator)
    }

    private func editing(_ draft: Binding<String?>, original: Double) -> Binding<String> {
        Binding(get: { draft.wrappedValue ?? display(original) }, set: { draft.wrappedValue = $0 })
    }

    // Parse the entire field. An untouched endpoint uses its original Double,
    // never the rounded table label or a formatted-and-parsed approximation.
    private func value(_ draft: String?, original: Double) -> Double? {
        guard let draft else { return original.isFinite ? original : nil }
        var text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        if separator != "." {
            guard !text.contains(".") else { return nil }
            text = text.replacingOccurrences(of: separator, with: ".")
        }
        var ascii = ""
        for character in text {
            switch character {
            case ".", "+", "-", "e", "E": ascii.append(character)
            case "−": ascii.append("-")
            default:
                guard character.unicodeScalars.count == 1,
                      let scalar = character.unicodeScalars.first,
                      CharacterSet.decimalDigits.contains(scalar),
                      let digit = character.wholeNumberValue else { return nil }
                ascii += String(digit)
            }
        }
        guard let number = Double(ascii), number.isFinite else { return nil }
        return number
    }

    private var validation: Validation {
        guard let high = value(leftDraft, original: context.bounds.upperBound),
              let low = value(rightDraft, original: context.bounds.lowerBound) else {
            return .invalid("边界必须是有限数值。")
        }
        guard low < high, (high - low).isFinite else {
            return .invalid("左边界须大于右边界（ppm 轴从高到低）。")
        }
        guard context.limits.contains(low), context.limits.contains(high) else {
            return .invalid("两个边界均须在当前谱图范围内。")
        }
        let bounds = low...high
        if let target = context.target {
            let area = w.spectrum.area(bounds)
            guard SessionJournal.relativeArea(area, referenceArea: area, target: target) != nil else {
                return .invalid("参考积分的面积须非零且有限。")
            }
        }
        return .valid(bounds)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            endpoint("左边界", field: .left,
                     text: editing($leftDraft, original: context.bounds.upperBound))
            endpoint("右边界", field: .right,
                     text: editing($rightDraft, original: context.bounds.lowerBound))

            if let mark {
                measurement(mark)
            }

            if case .invalid(let message) = validation {
                Label(message, systemImage: "exclamationmark.circle")
                    .font(.system(size: 15))
                    .foregroundStyle(colors.text)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Button(action: apply) {
                Text("应用边界").frame(maxWidth: .infinity, minHeight: 30)
            }
            .buttonStyle(.borderedProminent)
            .tint(colors.accent)
            .foregroundStyle(colorScheme == .dark ? colors.background : Color.white)
            .controlSize(.large)
            .disabled(!canEdit || validation.bounds == nil || validation.bounds == context.bounds)
            .help("应用边界；输入后也可按 Return")

            Divider()
            HStack(spacing: 8) {
            Button {
                guard canEdit, let mark else { return }
                configure(mark)
            } label: {
                Label("参考设置…", systemImage: "slider.horizontal.3")
                    .frame(maxWidth: .infinity, minHeight: 30)
            }
            .keyboardShortcut("i", modifiers: [.command, .option])
            .help("设置或取消所选区间的归一参考")

            Button(role: .destructive) {
                guard canEdit, let mark else { return }
                remove(mark)
            } label: {
                Label("删除积分…", systemImage: "trash")
                    .frame(maxWidth: .infinity, minHeight: 30)
            }
            .keyboardShortcut(.delete, modifiers: .command)
            .help("删除前确认")
            }
        }
        .font(.system(size: 17))
        .controlSize(.large)
        .disabled(!canEdit)
        .onSubmit { apply() }
    }

    private func endpoint(_ title: String, field: Endpoint, text: Binding<String>) -> some View {
        HStack(spacing: 10) {
            Text(title).foregroundStyle(colors.secondary).frame(width: 58, alignment: .leading)
            TextField(title, text: text)
                .textFieldStyle(.plain)
                .font(.system(size: 22, weight: .medium, design: .monospaced))
                .padding(.horizontal, 10)
                .frame(minHeight: 48)
                .background(colors.raised)
                .clipShape(RoundedRectangle(cornerRadius: 7))
                .overlay {
                    RoundedRectangle(cornerRadius: 7)
                        .strokeBorder(focused == field ? colors.accent : colors.border,
                                      lineWidth: focused == field ? 2 : 1)
                }
                .focused($focused, equals: field)
                .accessibilityLabel(Text(title + (field == .left ? "（高 ppm）" : "（低 ppm）")))
                .help(text.wrappedValue + " ppm")
            Text("ppm").font(.system(size: 15)).foregroundStyle(colors.secondary)
        }
    }

    private func measurement(_ mark: Mark) -> some View {
        let relative = w.relativeArea(mark)
        let area = w.spectrum.area(w.bounds(mark))
        return VStack(alignment: .leading, spacing: 6) {
            Text(relative == nil ? "有符号原始面积" : "相对积分")
                .foregroundStyle(colors.secondary)
            VStack(alignment: .leading, spacing: 3) {
                Text(relative.map { String(format: "%.8g", $0) } ??
                     (area.isFinite ? String(format: "%+.8g", area) : "面积不可用"))
                    .font(.system(size: 26, weight: .semibold, design: .monospaced))
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                if relative == nil {
                    Text("a.u.·ppm").font(.system(size: 17)).foregroundStyle(colors.secondary)
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity, minHeight: 48, alignment: .leading)
            .background(colors.raised)
            .clipShape(RoundedRectangle(cornerRadius: 7))
            if relative == nil {
                Text("通过参考设置可归一化积分。")
                    .font(.system(size: 15)).foregroundStyle(colors.secondary)
            }
        }
    }

    private func apply() {
        guard canEdit, w.accepts(context.version),
              w.selectedAnnotationID == context.markID,
              let mark, case .valid(let bounds) = validation else { return }
        guard bounds != context.bounds else {
            leftDraft = nil
            rightDraft = nil
            return
        }
        // One explicit transaction. Preserve the existing normalization target
        // when this mark is the reference; typing never commits anything.
        w.editIntegral(mark, bounds: bounds, target: context.target)
    }
}
