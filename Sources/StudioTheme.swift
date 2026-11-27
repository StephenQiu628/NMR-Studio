import SwiftUI
import AppKit

struct StudioColors {
    static let sidebarWidth: CGFloat = 352
    let background, panel, raised, text, secondary, border, accent, selection: Color

    init(dark: Bool) {
        background = Self.rgb(dark ? 0x111D26 : 0xFFFFFF)
        panel = Self.rgb(dark ? 0x192630 : 0xEDF2F7)
        raised = Self.rgb(dark ? 0x223542 : 0xFFFFFF)
        text = Self.rgb(dark ? 0xEDF5FA : 0x17314A)
        secondary = Self.rgb(dark ? 0xAABCC8 : 0x526575)
        border = Self.rgb(dark ? 0x304451 : 0xCCD8E1)
        accent = Self.rgb(dark ? 0x41D5D4 : 0x007E86)
        selection = Self.rgb(dark ? 0x164F5A : 0xD8F0F3)
    }

    private static func rgb(_ value: UInt32) -> Color {
        Color(.sRGB, red: Double((value >> 16) & 255) / 255,
              green: Double((value >> 8) & 255) / 255,
              blue: Double(value & 255) / 255, opacity: 1)
    }
}

enum StudioAppearance: String, CaseIterable, Identifiable {
    case dark, light, system
    var id: Self { self }

    var title: String {
        switch self {
        case .dark: return "深色"
        case .light: return "浅色"
        case .system: return "跟随系统"
        }
    }

    var colorScheme: ColorScheme? {
        switch self {
        case .dark: return .dark
        case .light: return .light
        case .system: return nil
        }
    }

    var appKitAppearance: NSAppearance? {
        switch self {
        case .dark: return NSAppearance(named: .darkAqua)
        case .light: return NSAppearance(named: .aqua)
        case .system: return nil
        }
    }
}

struct StudioAppearanceMenu: View {
    @AppStorage("NMRStudio.appearance") private var storedAppearance = "dark"
    @Environment(\.colorScheme) private var colorScheme

    private var selection: StudioAppearance {
        StudioAppearance(rawValue: storedAppearance) ?? .dark
    }

    var body: some View {
        Menu {
            ForEach(StudioAppearance.allCases) { choice in
                Button {
                    storedAppearance = choice.rawValue
                } label: {
                    if choice == selection {
                        Label(choice.title, systemImage: "checkmark")
                    } else {
                        Text(choice.title)
                    }
                }
            }
        } label: {
            Label("外观", systemImage: "circle.lefthalf.filled")
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(StudioColors(dark: colorScheme == .dark).text)
        }
        .menuStyle(.borderlessButton)
        .controlSize(.large)
        .fixedSize()
        .accessibilityLabel("外观")
        .accessibilityValue(Text(selection.title))
        .help("切换深色、浅色或跟随系统")
    }
}

// Sheets are separate presentation roots. Read the same local preference there,
// rather than copying appearance into the document or a sheet request.
private struct StudioSheetTheme: ViewModifier {
    @AppStorage("NMRStudio.appearance") private var storedAppearance = "dark"
    @Environment(\.colorScheme) private var colorScheme

    func body(content: Content) -> some View {
        let choice = StudioAppearance(rawValue: storedAppearance) ?? .dark
        let colors = StudioColors(dark: (choice.colorScheme ?? colorScheme) == .dark)
        return content
            .font(.system(size: 17))
            .foregroundStyle(colors.text)
            .tint(colors.accent)
            .background(colors.background)
            .preferredColorScheme(choice.colorScheme)
    }
}

extension View {
    func studioTheme() -> some View { modifier(StudioSheetTheme()) }
}

// Also update AppKit chrome and native open/save panels. Plot applies its own
// drawing appearance; this bridge does not touch PlotState or project data.
struct StudioWindowAppearance: NSViewRepresentable {
    let appearance: StudioAppearance

    final class Host: NSView {
        var choice = StudioAppearance.dark

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            applyAppearance()
        }

        func applyAppearance() {
            let desired = choice.appKitAppearance
            let app = NSApplication.shared
            if app.appearance?.name != desired?.name { app.appearance = desired }
            if window?.appearance?.name != desired?.name { window?.appearance = desired }
        }
    }

    func makeNSView(context: Context) -> Host {
        let view = Host(frame: .zero)
        view.choice = appearance
        return view
    }

    func updateNSView(_ view: Host, context: Context) {
        view.choice = appearance
        view.applyAppearance()
    }
}
