import Foundation
import FBSimulatorControl
@preconcurrency import FBControlCore
import ImageIO
#if os(macOS)
import AppKit
#endif

actor CancellationFlag {
    private(set) var value = false
    /// Number of `cancel()` calls, so a second Ctrl+C can escalate.
    private(set) var count = 0

    func cancel() {
        value = true
        count += 1
    }

    func isCancelled() -> Bool {
        value
    }

    func cancellationCount() -> Int {
        count
    }
}

final class SignalObserver {
    private var sources: [DispatchSourceSignal] = []
    private let signals: [Int32]

    init(signals: [Int32], handler: @escaping @Sendable () -> Void) {
        self.signals = signals
        for signalValue in signals {
            signal(signalValue, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: signalValue, queue: .main)
            source.setEventHandler(handler: handler)
            source.resume()
            sources.append(source)
        }
    }

    func invalidate() {
        sources.forEach { $0.cancel() }
        sources.removeAll()
        for signalValue in signals {
            signal(signalValue, SIG_DFL)
        }
    }

    deinit {
        invalidate()
    }
}

enum VideoProcessingError: LocalizedError, UserFacingError {
    case failedToDecodeImage
    case failedToAllocatePixelBuffer

    var userFacingDescription: String {
        switch self {
        case .failedToDecodeImage:
            return "AXe could not decode a simulator video frame."
        case .failedToAllocatePixelBuffer:
            return "AXe could not allocate memory for a simulator video frame."
        }
    }

    var errorDescription: String? {
        userFacingDescription
    }
}

struct VideoFrameUtilities {
    /// A PNG of the active display, interface-rotated.
    static func captureScreenshotData(from simulator: Simulator) async throws -> Data {
        try await simulator.screenshot.take(
            configuration: ScreenshotConfiguration(encoding: .png, display: .active)
        ).imageData
    }

    static func makeCGImage(from data: Data) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else {
            return nil
        }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }

    static func processJPEGData(_ data: Data, scale: Double, quality: Int) async throws -> Data {
        if scale < 1.0 {
            return try await scaleJPEGData(data, scale: scale, quality: quality)
        } else if quality != 80 {
            return try await reencodeJPEGData(data, quality: quality)
        }
        return data
    }

    private static func scaleJPEGData(_ data: Data, scale: Double, quality: Int) async throws -> Data {
        #if os(macOS)
        guard let image = makeCGImage(from: data) else {
            throw VideoProcessingError.failedToDecodeImage
        }
        let width = max(1, Int(Double(image.width) * scale))
        let height = max(1, Int(Double(image.height) * scale))
        return try encodeJPEG(image, width: width, height: height, quality: quality)
        #else
        return data
        #endif
    }

    private static func reencodeJPEGData(_ data: Data, quality: Int) async throws -> Data {
        #if os(macOS)
        guard let image = makeCGImage(from: data) else {
            throw VideoProcessingError.failedToDecodeImage
        }
        return try encodeJPEG(image, width: image.width, height: image.height, quality: quality)
        #else
        return data
        #endif
    }

    #if os(macOS)
    private static func encodeJPEG(
        _ image: CGImage,
        width: Int,
        height: Int,
        quality: Int
    ) throws -> Data {
        guard let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: width,
            pixelsHigh: height,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ), let context = NSGraphicsContext(bitmapImageRep: bitmap) else {
            throw VideoProcessingError.failedToAllocatePixelBuffer
        }

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        context.imageInterpolation = .high
        context.cgContext.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        context.flushGraphics()
        NSGraphicsContext.restoreGraphicsState()

        guard let data = bitmap.representation(
            using: .jpeg,
            properties: [.compressionFactor: Double(quality) / 100.0]
        ) else {
            throw VideoProcessingError.failedToDecodeImage
        }
        return data
    }
    #endif
}
