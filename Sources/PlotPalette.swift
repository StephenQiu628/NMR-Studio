import SwiftUI
import AppKit

struct PlotPalette {
    let background: NSColor
    let trace: NSColor
    let text: NSColor
    let axis: NSColor
    let grid: NSColor
    let peak: NSColor
    let integral: NSColor
    let selection: NSColor

    init(dark: Bool, highContrast: Bool, forPDF: Bool) {
        if forPDF {
            // The independent PDF renderer must not inherit the window appearance.
            background = Self.rgb(0xFFFFFF)
            trace = Self.rgb(0x006D73)
            text = Self.rgb(0x171C1E)
            axis = Self.rgb(0x20282A)
            grid = Self.rgb(highContrast ? 0x899497 : 0xD9E0E2)
            peak = Self.rgb(0x80320C)
            integral = Self.rgb(0x493978)
            selection = Self.rgb(0x224B75)
            return
        }

        let appearance: NSAppearance.Name
        if dark {
            appearance = highContrast ? .accessibilityHighContrastDarkAqua : .darkAqua
        } else {
            appearance = highContrast ? .accessibilityHighContrastAqua : .aqua
        }
        let label = Self.resolved(.labelColor, appearance: appearance,
                                  fallback: dark ? 0xF1F3F4 : 0x212527)
        background = Self.rgb(dark ? 0x191C1E : 0xFFFFFF)
        trace = Self.rgb(dark ? 0x71DBD4 : 0x006D73)
        text = label
        axis = label
        if highContrast {
            grid = Self.rgb(dark ? 0x718085 : 0x899497)
        } else {
            grid = Self.resolved(.separatorColor, appearance: appearance,
                                 fallback: dark ? 0x3B4245 : 0xDADFE1)
        }
        if dark {
            peak = Self.rgb(highContrast ? 0xFFD0AA : 0xFFAD80)
            integral = Self.rgb(highContrast ? 0xE7DCFF : 0xC8BCFF)
            selection = Self.rgb(highContrast ? 0xE8F4FF : 0xA8D5FF)
        } else {
            peak = Self.rgb(highContrast ? 0x74290B : 0x90390F)
            integral = Self.rgb(highContrast ? 0x392665 : 0x534186)
            selection = Self.rgb(highContrast ? 0x173D65 : 0x24527E)
        }
    }

    private static func resolved(_ color: NSColor, appearance name: NSAppearance.Name,
                                 fallback: UInt32) -> NSColor {
        var result: NSColor?
        if let appearance = NSAppearance(named: name) {
            appearance.performAsCurrentDrawingAppearance {
                result = color.usingColorSpace(.sRGB)
            }
        }
        return result ?? rgb(fallback)
    }

    private static func rgb(_ hex: UInt32) -> NSColor {
        NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
                green: CGFloat((hex >> 8) & 0xFF) / 255,
                blue: CGFloat(hex & 0xFF) / 255,
                alpha: 1)
    }
}
