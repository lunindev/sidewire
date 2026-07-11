import Foundation
import ScreenCaptureKit
import CoreMedia

/// Captures a display via ScreenCaptureKit. Phase 0 change from the old app:
/// pixelFormat is 420v (NV12, video-range) so the captured IOSurface feeds the
/// HEVC encoder with no RGB→YUV conversion (see docs/04-media-pipeline.md § Capture).
final class ScreenCapture: NSObject, ObservableObject, SCStreamOutput {
    private var stream: SCStream?
    private var isRunning = false

    @Published var fps: Double = 0
    @Published var captureStatus = "Idle"
    @Published var availableDisplays: [SCDisplay] = []

    /// Called on the capture queue with each complete frame's sample buffer.
    var onSampleBuffer: ((CMSampleBuffer) -> Void)?

    private var frameCount = 0
    private var fpsTimer: Timer?
    private let captureQueue = DispatchQueue(label: "com.kinocoder.sidewire.capture")

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
            // 420v: hand YUV straight to the encoder, no color conversion.
            config.pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
            config.colorSpaceName = CGColorSpace.sRGB
            config.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(fps))
            config.queueDepth = 5
            config.showsCursor = true

            let stream = SCStream(filter: filter, configuration: config, delegate: nil)
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
        try? await stream?.stopCapture()
        stream = nil
        isRunning = false
        await MainActor.run {
            self.captureStatus = "Stopped"
            self.fpsTimer?.invalidate(); self.fpsTimer = nil; self.fps = 0
        }
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, sampleBuffer.imageBuffer != nil else { return }
        // Phase 0: forward complete frames. Phase 1 adds explicit SCFrameStatus.idle
        // gating + the static-screen keep-alive (see docs/03, docs/04).
        frameCount += 1
        onSampleBuffer?(sampleBuffer)
    }

    private func startFPSCounter() {
        frameCount = 0
        fpsTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.fps = Double(self.frameCount)
            self.frameCount = 0
        }
    }
}
