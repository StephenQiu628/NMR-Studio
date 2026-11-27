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
            // The independent export renderer must never inherit the window theme.
            background = Self.rgb(0xFFFFFF)
            trace = Self.rgb(0x00656D)
            text = Self.rgb(0x17314A)
            axis = Self.rgb(0x263E50)
            grid = Self.rgb(highContrast ? 0x98AAB6 : 0xDCE5EB)
            peak = Self.rgb(0x263E50)
            integral = Self.rgb(0x00656D)
            selection = Self.rgb(0x007E86)
            return
        }

        background = Self.rgb(dark ? 0x111D26 : 0xFFFFFF)
        text = Self.rgb(dark ? 0xEDF5FA : 0x17314A)
        trace = Self.rgb(dark ? (highContrast ? 0x8CEBE8 : 0x41D5D4)
                                    : (highContrast ? 0x005C63 : 0x007E86))
        axis = Self.rgb(dark ? (highContrast ? 0xEDF5FA : 0xAABCC8)
                                   : (highContrast ? 0x17314A : 0x526575))
        peak = Self.rgb(dark ? 0xEDF5FA : 0x263E50)
        integral = Self.rgb(dark ? (highContrast ? 0x8CEBE8 : 0x41D5D4)
                                       : (highContrast ? 0x005C63 : 0x007E86))
        selection = Self.rgb(dark ? 0x41D5D4 : 0x007E86)
        if highContrast {
            grid = Self.rgb(dark ? 0x526575 : 0x98AAB6)
        } else {
            grid = Self.rgb(dark ? 0x304451 : 0xCCD8E1).withAlphaComponent(0.55)
        }
    }

    private static func rgb(_ hex: UInt32) -> NSColor {
        NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
                green: CGFloat((hex >> 8) & 0xFF) / 255,
                blue: CGFloat(hex & 0xFF) / 255,
                alpha: 1)
    }
}
