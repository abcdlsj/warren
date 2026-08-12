import AppKit
import BurrowDesktop
import BurrowDomain
import Foundation
import SwiftUI
import Vision

/// A headless UI observer.
///
/// Renders the real desktop shell (not a screenshot) to a bitmap, runs Vision
/// OCR with bounding boxes, samples semantic pixel regions, and emits a JSON
/// report. This is the substitute for eyeballing screenshots in an automated
/// loop.
@MainActor
struct UIProbe {
    static func main() throws {
        let outputDirectory = URL(fileURLWithPath: "/tmp/burrow-ui-report", isDirectory: true)
        try FileManager.default.createDirectory(
            at: outputDirectory,
            withIntermediateDirectories: true
        )

        let frames: [(width: CGFloat, height: CGFloat, name: String)] = [
            (1280, 800, "main"),
            (1024, 700, "compact"),
        ]

        var report = ProbeReport(frames: [])
        for frame in frames {
            let observation = try renderAndObserve(
                width: frame.width,
                height: frame.height
            )
            let pngURL = outputDirectory.appendingPathComponent("frame-\(frame.name).png")
            try observation.png.write(to: pngURL)
            report.frames.append(observation.report)
            print("Rendered \(frame.name) \(Int(frame.width))x\(Int(frame.height)) -> \(pngURL.path)")
        }

        let jsonURL = outputDirectory.appendingPathComponent("report.json")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(report).write(to: jsonURL)
        print("Report -> \(jsonURL.path)")
    }

    private static func renderAndObserve(
        width: CGFloat,
        height: CGFloat
    ) throws -> (png: Data, report: FrameObservation) {
        let root = BurrowDesktopRoot(
            projection: BurrowDesktopFixture.preview.projection,
            actions: BurrowDesktopActions()
        ) { context in
            ProbeTerminalSurface(context: context)
        }
        .environment(\.colorScheme, .dark)
        .frame(width: width, height: height)

        let hostingView = NSHostingView(rootView: root)
        hostingView.frame = NSRect(x: 0, y: 0, width: width, height: height)
        hostingView.layoutSubtreeIfNeeded()

        guard let bitmap = hostingView.bitmapImageRepForCachingDisplay(
            in: hostingView.bounds
        ) else {
            throw ProbeError.bitmapUnavailable
        }
        hostingView.cacheDisplay(in: hostingView.bounds, to: bitmap)
        guard let png = bitmap.representation(using: .png, properties: [:]) else {
            throw ProbeError.pngUnavailable
        }

        let scale = CGFloat(bitmap.pixelsWide) / width
        let ocr = try recognizeText(in: bitmap, scale: scale)
        let pixels = samplePixels(bitmap: bitmap, scale: scale)
        let layout = scanLayout(bitmap: bitmap, scale: scale)
        let topBarTextY = ocr.filter { $0.y < 80 }.map(\.y).min() ?? -1
        return (
            png,
            FrameObservation(
                width: Int(width),
                height: Int(height),
                ocr: ocr,
                pixels: pixels,
                layout: layout,
                topBarTextY: topBarTextY
            )
        )
    }

    private static func recognizeText(
        in bitmap: NSBitmapImageRep,
        scale: CGFloat
    ) throws -> [TextObservation] {
        guard let cgImage = bitmap.cgImage else {
            throw ProbeError.cgImageUnavailable
        }
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        try VNImageRequestHandler(cgImage: cgImage).perform([request])

        let width = CGFloat(bitmap.pixelsWide)
        let height = CGFloat(bitmap.pixelsHigh)
        return (request.results ?? []).compactMap { observation in
            guard let candidate = observation.topCandidates(1).first else { return nil }
            let box = observation.boundingBox
            return TextObservation(
                text: candidate.string,
                x: Int(box.origin.x * width / scale),
                y: Int((1 - box.origin.y - box.size.height) * height / scale),
                width: Int(box.size.width * width / scale),
                height: Int(box.size.height * height / scale)
            )
        }
    }

    private static func samplePixels(
        bitmap: NSBitmapImageRep,
        scale: CGFloat
    ) -> PixelObservation {
        PixelObservation(
            topLeft: hex(at: 10, 10, in: bitmap, scale: scale),
            topBar: hex(at: 1100, 20, in: bitmap, scale: scale),
            sidebar: hex(at: 20, 760, in: bitmap, scale: scale),
            content: hex(at: 700, 400, in: bitmap, scale: scale)
        )
    }

    /// Finds horizontal color transitions to estimate chrome boundaries without
    /// depending on OCR text.
    private static func scanLayout(
        bitmap: NSBitmapImageRep,
        scale: CGFloat
    ) -> LayoutObservation {
        let contentX = 1100
        let topColor = color(at: contentX, 0, in: bitmap, scale: scale)
        var topChromeHeight = 0
        for logicalY in 0..<120 {
            if !isClose(color(at: contentX, logicalY, in: bitmap, scale: scale), topColor) {
                topChromeHeight = logicalY
                break
            }
        }

        let sidebarY = 760
        let sidebarColor = color(at: 20, sidebarY, in: bitmap, scale: scale)
        var sidebarWidth = 0
        for x in 20..<420 {
            if !isClose(color(at: x, sidebarY, in: bitmap, scale: scale), sidebarColor) {
                sidebarWidth = x
                break
            }
        }

        return LayoutObservation(
            topChromeHeight: topChromeHeight,
            sidebarWidth: sidebarWidth,
            topRowColors: (0..<min(60, Int(CGFloat(bitmap.pixelsHigh) / scale))).map { y in
                hex(at: contentX, y, in: bitmap, scale: scale)
            },
            topBarColorSamples: (0..<13).map { index in
                let x = 300 + index * 80
                return "\(x):\(hex(at: x, 20, in: bitmap, scale: scale))"
            }
        )
    }

    private static func color(
        at logicalX: Int,
        _ logicalY: Int,
        in bitmap: NSBitmapImageRep,
        scale: CGFloat
    ) -> NSColor {
        let x = min(Int(CGFloat(logicalX) * scale), bitmap.pixelsWide - 1)
        let y = min(Int(CGFloat(logicalY) * scale), bitmap.pixelsHigh - 1)
        guard let color = bitmap.colorAt(x: x, y: y) else {
            return .clear
        }
        return color.usingColorSpace(.deviceRGB) ?? color
    }

    private static func hex(
        at x: Int,
        _ y: Int,
        in bitmap: NSBitmapImageRep,
        scale: CGFloat
    ) -> String {
        let c = color(at: x, y, in: bitmap, scale: scale)
        return String(
            format: "#%02X%02X%02X",
            Int((c.redComponent * 255).rounded()),
            Int((c.greenComponent * 255).rounded()),
            Int((c.blueComponent * 255).rounded())
        )
    }

    private static func isClose(_ lhs: NSColor, _ rhs: NSColor) -> Bool {
        abs(lhs.redComponent - rhs.redComponent) < 0.03
            && abs(lhs.greenComponent - rhs.greenComponent) < 0.03
            && abs(lhs.blueComponent - rhs.blueComponent) < 0.03
    }
}

private struct ProbeTerminalSurface: View {
    let context: BurrowDesktopTerminalContext

    var body: some View {
        Text("probe:\(context.tab.id)")
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.black)
            .foregroundStyle(Color.green)
            .font(.system(size: 12, design: .monospaced))
    }
}

private struct ProbeReport: Codable {
    var frames: [FrameObservation]
}

private struct FrameObservation: Codable {
    let width: Int
    let height: Int
    let ocr: [TextObservation]
    let pixels: PixelObservation
    let layout: LayoutObservation
    let topBarTextY: Int
}

private struct TextObservation: Codable {
    let text: String
    let x: Int
    let y: Int
    let width: Int
    let height: Int
}

private struct PixelObservation: Codable {
    let topLeft: String
    let topBar: String
    let sidebar: String
    let content: String
}

private struct LayoutObservation: Codable {
    let topChromeHeight: Int
    let sidebarWidth: Int
    let topRowColors: [String]
    let topBarColorSamples: [String]
}

private enum ProbeError: Error, CustomStringConvertible {
    case bitmapUnavailable
    case pngUnavailable
    case cgImageUnavailable

    var description: String {
        switch self {
        case .bitmapUnavailable: "Could not create a bitmap from the hosting view."
        case .pngUnavailable: "Could not encode the bitmap as PNG."
        case .cgImageUnavailable: "Could not create a CGImage from the bitmap."
        }
    }
}

try UIProbe.main()
