import AppKit
import AVFoundation
import CoreMedia

/// Hosts an AVSampleBufferDisplayLayer that presents decoded frames immediately.
/// Ported from the previous app's DisplayLayerView. A Metal/CAMetalLayer present
/// path (to shave the ~1-frame ASBDL buffering) is a Phase 2 option — see docs/04 § Present.
final class VideoPresenterView: NSView {
    let displayLayer = AVSampleBufferDisplayLayer()

    /// The decoded video's pixel dimensions (the negotiated stream size). Used to compute the
    /// aspect-fit letterbox rect so input coordinates map onto the video, not the whole view.
    /// Zero until presenting starts.
    var videoSize: CGSize = .zero

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

    /// The aspect-fit rect the video occupies within this view's bounds — matches the layer's
    /// `.resizeAspect` gravity. Falls back to the full bounds when the video size is unknown.
    var videoRect: CGRect {
        let b = bounds
        guard videoSize.width > 0, videoSize.height > 0, b.width > 0, b.height > 0 else { return b }
        let scale = min(b.width / videoSize.width, b.height / videoSize.height)
        let w = videoSize.width * scale
        let h = videoSize.height * scale
        return CGRect(x: b.midX - w / 2, y: b.midY - h / 2, width: w, height: h)
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
