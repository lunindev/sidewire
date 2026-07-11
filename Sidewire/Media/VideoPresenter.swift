import AppKit
import AVFoundation
import CoreMedia

/// Hosts an AVSampleBufferDisplayLayer that presents decoded frames immediately.
/// Ported from the previous app's DisplayLayerView. A Metal/CAMetalLayer present
/// path (to shave the ~1-frame ASBDL buffering) is a Phase 2 option — see docs/04 § Present.
final class VideoPresenterView: NSView {
    let displayLayer = AVSampleBufferDisplayLayer()

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer = CALayer()
        displayLayer.videoGravity = .resizeAspect
        displayLayer.preventsDisplaySleepDuringVideoPlayback = true
        layer?.addSublayer(displayLayer)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        displayLayer.frame = bounds
        CATransaction.commit()
    }

    func enqueue(_ sampleBuffer: CMSampleBuffer) {
        // After any decode interruption the renderer refuses to decode until flushed;
        // missing this freezes the video permanently after a single glitch (macOS 11+).
        if displayLayer.status == .failed || displayLayer.requiresFlushToResumeDecoding {
            displayLayer.flush()
        }
        displayLayer.enqueue(sampleBuffer)
    }

    func flush() { displayLayer.flush() }
}
