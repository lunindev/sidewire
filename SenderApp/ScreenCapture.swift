import Foundation
import ScreenCaptureKit
import CoreMedia

final class ScreenCapture: NSObject, ObservableObject, SCStreamOutput {
    private var stream: SCStream?
    private var isRunning = false

    @Published var fps: Double = 0
    @Published var captureStatus = "Idle"
    @Published var availableDisplays: [SCDisplay] = []

    var onSampleBuffer: ((CMSampleBuffer) -> Void)?

    private var frameCount = 0
    private var fpsTimer: Timer?

    func fetchAvailableDisplays() async {
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
            await MainActor.run {
                self.availableDisplays = content.displays
                self.captureStatus = "Found \(content.displays.count) display(s)"
            }
        } catch {
            await MainActor.run {
                self.captureStatus = "Error: \(error.localizedDescription)"
            }
        }
    }

    func startCapture(displayIndex: Int = 0, displayID: CGDirectDisplayID? = nil, fps: Int = 60, pixelWidth: Int? = nil, pixelHeight: Int? = nil) async {
        guard !isRunning else { return }

        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)

            let display: SCDisplay
            if let displayID, let match = content.displays.first(where: { $0.displayID == displayID }) {
                display = match
            } else {
                guard displayIndex < content.displays.count else {
                    await MainActor.run { self.captureStatus = "Display not found" }
                    return
                }
                display = content.displays[displayIndex]
            }

            let filter = SCContentFilter(display: display, excludingWindows: [])

            let captureW = pixelWidth ?? display.width
            let captureH = pixelHeight ?? display.height

            let config = SCStreamConfiguration()
            config.width = captureW
            config.height = captureH
            config.pixelFormat = kCVPixelFormatType_32BGRA
            config.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(fps))
            config.queueDepth = 3
            config.showsCursor = true

            stream = SCStream(filter: filter, configuration: config, delegate: nil)
            try stream?.addStreamOutput(self, type: .screen, sampleHandlerQueue: DispatchQueue(label: "com.macdisplay.capture"))
            try await stream?.startCapture()
            isRunning = true

            await MainActor.run {
                self.captureStatus = "Capturing \(captureW)×\(captureH) @\(fps)fps"
                self.startFPSCounter()
            }
        } catch {
            await MainActor.run {
                self.captureStatus = "Capture error: \(error.localizedDescription)"
            }
        }
    }

    func stopCapture() async {
        guard isRunning else { return }
        try? await stream?.stopCapture()
        stream = nil
        isRunning = false

        await MainActor.run {
            self.captureStatus = "Stopped"
            self.fpsTimer?.invalidate()
            self.fpsTimer = nil
            self.fps = 0
        }
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen else { return }
        guard sampleBuffer.imageBuffer != nil else { return }

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
