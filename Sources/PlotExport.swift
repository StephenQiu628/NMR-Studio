import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

enum PlotExport {
    static let pngWidths = [1200, 2400, 3600]

    // The vector exporter belongs to an NSView subclass. No view instance or
    // window is needed to rasterize its output.
    @MainActor
    static func png(_ plot: PlotState, width: Int, to url: URL) throws {
        guard pngWidths.contains(width) else {
            throw NMRError("PNG width must be 1200, 2400, or 3600 pixels.")
        }
        guard url.isFileURL else { throw NMRError("Expected a local PNG file URL.") }

        let fm = FileManager.default
        let scratch = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fm.createDirectory(at: scratch, withIntermediateDirectories: false,
                               attributes: [.posixPermissions: 0o700])
        defer { try? fm.removeItem(at: scratch) }

        let pdfURL = scratch.appendingPathComponent("plot.pdf")
        try PlotView.pdf(plot, to: pdfURL)
        guard let document = CGPDFDocument(pdfURL as CFURL), let page = document.page(at: 1) else {
            throw NMRError("Could not read the exported plot page.")
        }

        let height = width / 2  // PlotView.pdf has a 900 by 450 point page.
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let bitmap = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                     bytesPerRow: width * 4, space: space,
                                     bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else {
            throw NMRError("Could not allocate the plot bitmap.")
        }
        let pixels = CGRect(x: 0, y: 0, width: CGFloat(width), height: CGFloat(height))
        bitmap.setFillColor(red: 1, green: 1, blue: 1, alpha: 1)
        bitmap.fill(pixels)
        bitmap.setShouldAntialias(true)
        bitmap.interpolationQuality = .high
        // We own the unrotated PDF page. Scale it explicitly, including when
        // the requested bitmap is larger than the page in points.
        let pageBox = page.getBoxRect(.mediaBox)
        guard pageBox.width > 0, pageBox.height > 0 else { throw NMRError("谱图页面尺寸无效。") }
        bitmap.scaleBy(x: pixels.width / pageBox.width, y: pixels.height / pageBox.height)
        bitmap.translateBy(x: -pageBox.minX, y: -pageBox.minY)
        bitmap.drawPDFPage(page)
        guard let image = bitmap.makeImage() else { throw NMRError("Could not create the plot image.") }

        let bytes = NSMutableData()
        guard let writer = CGImageDestinationCreateWithData(bytes as CFMutableData,
                                                            UTType.png.identifier as CFString, 1, nil) else {
            throw NMRError("Could not create a PNG encoder.")
        }
        CGImageDestinationAddImage(writer, image, nil)
        guard CGImageDestinationFinalize(writer) else { throw NMRError("PNG encoding failed.") }
        try (bytes as Data).write(to: url, options: .atomic)
    }

    static func csv(_ spectrum: Spectrum, in range: ClosedRange<Double>) -> String {
        var text = "ppm,intensity\n"
        for (i,x) in spectrum.ppm.enumerated() where range.contains(x) {
            text += "\(x),\(spectrum.real[i])\n"
        }
        return text
    }
}
