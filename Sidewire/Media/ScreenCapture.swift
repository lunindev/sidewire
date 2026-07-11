import Foundation
import ScreenCaptureKit
import CoreMedia

/// Captures a display via ScreenCaptureKit (420v so the IOSurface feeds the HEVC encoder
/// with no color conversion). The sample handler is mutated only on the capture queue to
/// avoid a torn read of the closure while a frame is being delivered.
final class ScreenCapture: NSObject, ObservableObject, SCStreamOutput, SCStreamDelegate {
    private var stream: SCStream?
    private var isRunning = false

    @Published var fps: Double = 0
    @Published var captureStatus = "Idle"
    @Published var availableDisplays: [SCDisplay] = []

    /// Fired if the capture stops on its own (SCStream error) — a real capture death the
    /// source must react to (reconnect), distinct from a legitimately static screen.
    var onStopped: ((Error) -> Void)?

    // Touched only on captureQueue.
    private var sampleHandler: ((CMSampleBuffer) -> Void)?
    private var frameCount = 0
    private var fpsTimer: Timer?
    private let captureQueue = DispatchQueue(label: "com.kinocoder.sidewire.capture")

    /// Set/replace the per-frame handler safely (serialized on the capture queue).
    func setSampleHandler(_ handler: ((CMSampleBuffer) -> Void)?) {
        captureQueue.async { self.sampleHandler = handler }
    }

    func fetchAvailableDisplays() async {
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
            await MainActor.run {
                self.availableDisplays = content.displays
                self.captureStatus = "Found \(content.displays.count) display(s)"
            }
        } catch {
            await MainActor.run { self.captureStatus = "Error: \(error.localizedDescription)" }
        }
    }

    func startCapture(displayID: CGDirectDisplayID?, fps: Int, pixelWidth: Int?, pixelHeight: Int?) async {
        guard !isRunning else { return }
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)

            let display: SCDisplay
            if let displayID, let match = content.displays.first(where: { $0.displayID == displayID }) {
                display = match
            } else if let first = content.displays.first {
                display = first
            } else {
                await MainActor.run { self.captureStatus = "No display found" }
                return
            }

            let filter = SCContentFilter(display: display, excludingWindows: [])
            let captureW = pixelWidth ?? display.width
            let captureH = pixelHeight ?? display.height

            let config = SCStreamConfiguration()
            config.width = captureW
            config.height = captureH
            config.pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
            config.colorSpaceName = CGColorSpace.sRGB
            config.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(fps))
            config.queueDepth = 5
            config.showsCursor = true

            let stream = SCStream(filter: filter, configuration: config, delegate: self)
            try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: captureQueue)
            try await stream.startCapture()
            self.stream = stream
            isRunning = true

            await MainActor.run {
                self.captureStatus = "Capturing \(captureW)×\(captureH) @\(fps)fps"
                self.startFPSCounter()
            }
        } catch {
            await MainActor.run { self.captureStatus = "Capture error: \(error.localizedDescription)" }
        }
    }

    func stopCapture() async {
        guard isRunning else { return }
        isRunning = false
        try? await stream?.stopCapture()
        stream = nil
        await MainActor.run {
            self.captureStatus = "Stopped"
            self.fpsTimer?.invalidate(); self.fpsTimer = nil; self.fps = 0
        }
    }

    // SCStreamOutput — on captureQueue.
    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, sampleBuffer.imageBuffer != nil else { return }
        // Only forward .complete frames; a static screen yields .idle (no new surface).
        guard isCompleteFrame(sampleBuffer) else { return }
        frameCount += 1
        sampleHandler?(sampleBuffer)
    }

    // SCStreamDelegate — capture stopped with an error (real death).
    func stream(_ stream: SCStream, didStopWithError error: Error) {
        Task { @MainActor in
            self.isRunning = false
            self.captureStatus = "Capture stopped: \(error.localizedDescription)"
            self.onStopped?(error)
        }
    }

    private func isCompleteFrame(_ sampleBuffer: CMSampleBuffer) -> Bool {
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false)
                as? [[SCStreamFrameInfo: Any]],
              let raw = attachments.first?[.status] as? Int,
              let status = SCFrameStatus(rawValue: raw) else {
            return true // no status info → treat as a real frame (conservative)
        }
        return status == .complete
    }

    private func startFPSCounter() {
        captureQueue.async { self.frameCount = 0 }
        fpsTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.captureQueue.async {
                let c = self.frameCount
                self.frameCount = 0
                Task { @MainActor in self.fps = Double(c) }
            }
        }
    }
}
