import Foundation
import VideoToolbox
import CoreMedia

/// Negotiated codec. Phase 0 implements HEVC (the M4 Max source path). H.264 is a
/// Phase-2 addition needed only if an Intel Mac ever becomes the source
/// (HEVC low-latency is Apple-Silicon-only) — see docs/00 D4 / docs/04.
enum VideoCodec: String {
    case hevc
    case h264
}

/// Hardware HEVC encoder (VideoToolbox low-latency). Emits Annex-B NAL units.
/// Ported from the previous app; LTR + adaptive-rate refinements land in Phase 2.
final class VideoEncoder {
    // encode() runs on the capture queue; forceKeyframe/updateBitrate/invalidate/flush are
    // called from the main actor. This lock serializes all session + flag access to avoid a
    // data race (and a use-after-invalidate on the VTCompressionSession).
    private let lock = NSLock()
    private var session: VTCompressionSession?
    private var forceNextKeyframe = false
    let codec: VideoCodec

    /// (nalData, isKeyframe, ltrToken). ltrToken is reserved for a future LTR/loss-recovery
    /// path (currently always 0 — recovery is keyframe-based; see docs/04 § Encoder).
    var onEncodedFrame: ((Data, Bool, UInt16) -> Void)?

    /// Codecs this machine can actually create an encode session for, in preference order
    /// (HEVC first, then H.264). Probed once via a cheap trial VTCompressionSessionCreate —
    /// an Intel Mac with no HEVC hardware encoder reports only h264. Cached (static let is
    /// lazy + thread-safe). Advertised in HELLO via AppConstants so we never negotiate a
    /// codec this machine can't produce.
    static let supportedCodecs: [VideoCodec] = {
        let probed = [VideoCodec.hevc, .h264].filter { canCreateSession(for: $0) }
        return probed.isEmpty ? [.h264] : probed // defensive: never advertise nothing
    }()

    private static func canCreateSession(for codec: VideoCodec) -> Bool {
        let codecType: CMVideoCodecType = codec == .hevc ? kCMVideoCodecType_HEVC : kCMVideoCodecType_H264
        var session: VTCompressionSession?
        // Small trial size, no low-latency spec (that's tried per-session at real init): this
        // only asks "does a usable encoder for this codec exist on this Mac?".
        let status = VTCompressionSessionCreate(
            allocator: nil, width: 640, height: 480, codecType: codecType,
            encoderSpecification: nil, imageBufferAttributes: nil,
            compressedDataAllocator: nil, outputCallback: nil, refcon: nil,
            compressionSessionOut: &session)
        if let session { VTCompressionSessionInvalidate(session) }
        return status == noErr && session != nil
    }

    init(width: Int32, height: Int32, codec: VideoCodec = .hevc, fps: Int = 60, bitrate: Int = 30_000_000) {
        self.codec = codec

        let codecType: CMVideoCodecType = codec == .hevc ? kCMVideoCodecType_HEVC : kCMVideoCodecType_H264

        let callback: VTCompressionOutputCallback = { refcon, _, status, flags, sampleBuffer in
            guard let refcon else { return }
            let encoder = Unmanaged<VideoEncoder>.fromOpaque(refcon).takeUnretainedValue()
            encoder.handleEncodedFrame(status: status, flags: flags, sampleBuffer: sampleBuffer)
        }

        // Low-latency rate control is Apple-Silicon-only. Passing it on an Intel Mac makes
        // VTCompressionSessionCreate find no matching encoder — for BOTH codecs — so the
        // session stays nil and encode() silently no-ops forever. Try it, then fall back to
        // a plain session (still RealTime) so Intel Macs can encode.
        let lowLatencySpec: [CFString: Any] = [
            kVTVideoEncoderSpecification_EnableLowLatencyRateControl: true
        ]
        var sessionOut: VTCompressionSession?
        var status = VTCompressionSessionCreate(
            allocator: nil, width: width, height: height, codecType: codecType,
            encoderSpecification: lowLatencySpec as CFDictionary, imageBufferAttributes: nil,
            compressedDataAllocator: nil, outputCallback: callback,
            refcon: Unmanaged.passUnretained(self).toOpaque(), compressionSessionOut: &sessionOut)
        var lowLatency = true
        if status != noErr || sessionOut == nil {
            lowLatency = false
            status = VTCompressionSessionCreate(
                allocator: nil, width: width, height: height, codecType: codecType,
                encoderSpecification: nil, imageBufferAttributes: nil,
                compressedDataAllocator: nil, outputCallback: callback,
                refcon: Unmanaged.passUnretained(self).toOpaque(), compressionSessionOut: &sessionOut)
        }

        guard status == noErr, let session = sessionOut else {
            print("[Encoder] Failed to create \(codec.rawValue) session: \(status)")
            return
        }
        self.session = session
        print("[Encoder] \(codec.rawValue) session created (low-latency rate control: \(lowLatency ? "on" : "off"))")

        let profile: CFString = codec == .hevc ? kVTProfileLevel_HEVC_Main_AutoLevel
                                               : kVTProfileLevel_H264_High_AutoLevel
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_RealTime, value: kCFBooleanTrue)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_ProfileLevel, value: profile)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AverageBitRate, value: bitrate as CFNumber)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_ExpectedFrameRate, value: fps as CFNumber)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_MaxKeyFrameInterval, value: (fps * 5) as CFNumber)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AllowFrameReordering, value: kCFBooleanFalse)
        VTCompressionSessionPrepareToEncodeFrames(session)
    }

    func encode(pixelBuffer: CVPixelBuffer, presentationTime: CMTime) {
        lock.lock()
        defer { lock.unlock() }
        guard let session else { return }
        var properties: [CFString: Any]?
        if forceNextKeyframe {
            properties = [kVTEncodeFrameOptionKey_ForceKeyFrame: true]
            forceNextKeyframe = false
        }
        VTCompressionSessionEncodeFrame(session, imageBuffer: pixelBuffer,
                                        presentationTimeStamp: presentationTime, duration: .invalid,
                                        frameProperties: properties as CFDictionary?,
                                        sourceFrameRefcon: nil, infoFlagsOut: nil)
    }

    func forceKeyframe() {
        lock.lock(); forceNextKeyframe = true; lock.unlock()
    }

    func updateBitrate(_ newBitrate: Int) {
        lock.lock(); defer { lock.unlock() }
        guard let session else { return }
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AverageBitRate, value: newBitrate as CFNumber)
    }

    func flush() {
        lock.lock(); defer { lock.unlock() }
        guard let session else { return }
        VTCompressionSessionCompleteFrames(session, untilPresentationTimeStamp: .invalid)
    }

    func invalidate() {
        lock.lock(); defer { lock.unlock() }
        guard let session else { return }
        VTCompressionSessionInvalidate(session)
        self.session = nil
    }

    private func handleEncodedFrame(status: OSStatus, flags: VTEncodeInfoFlags, sampleBuffer: CMSampleBuffer?) {
        guard status == noErr, let sampleBuffer else { return }

        let isKeyframe: Bool
        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[CFString: Any]],
           let first = attachments.first {
            isKeyframe = !(first[kCMSampleAttachmentKey_NotSync] as? Bool ?? false)
        } else {
            isKeyframe = true
        }

        guard let dataBuffer = sampleBuffer.dataBuffer else { return }
        var totalLength = 0
        var dataPointer: UnsafeMutablePointer<Int8>?
        let blockStatus = CMBlockBufferGetDataPointer(dataBuffer, atOffset: 0, lengthAtOffsetOut: nil,
                                                      totalLengthOut: &totalLength, dataPointerOut: &dataPointer)
        guard blockStatus == noErr, let dataPointer else { return }

        var nalData = Data()
        if isKeyframe, let formatDesc = sampleBuffer.formatDescription {
            nalData.append(extractParameterSets(from: formatDesc))
        }

        var offset = 0
        while offset + 4 <= totalLength {
            var naluLength: UInt32 = 0
            memcpy(&naluLength, dataPointer.advanced(by: offset), 4)
            naluLength = naluLength.bigEndian
            offset += 4
            guard naluLength > 0, offset + Int(naluLength) <= totalLength else { break }
            nalData.append(contentsOf: [0x00, 0x00, 0x00, 0x01])
            nalData.append(Data(bytes: dataPointer.advanced(by: offset), count: Int(naluLength)))
            offset += Int(naluLength)
        }
        onEncodedFrame?(nalData, isKeyframe, 0)
    }

    private func extractParameterSets(from formatDescription: CMFormatDescription) -> Data {
        var data = Data()
        let startCode: [UInt8] = [0x00, 0x00, 0x00, 0x01]
        // HEVC has 3 parameter sets (VPS/SPS/PPS); H.264 has 2 (SPS/PPS).
        let count = codec == .hevc ? 3 : 2
        for i in 0..<count {
            var ptr: UnsafePointer<UInt8>?
            var size = 0
            let status: OSStatus
            if codec == .hevc {
                status = CMVideoFormatDescriptionGetHEVCParameterSetAtIndex(
                    formatDescription, parameterSetIndex: i, parameterSetPointerOut: &ptr,
                    parameterSetSizeOut: &size, parameterSetCountOut: nil, nalUnitHeaderLengthOut: nil)
            } else {
                status = CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
                    formatDescription, parameterSetIndex: i, parameterSetPointerOut: &ptr,
                    parameterSetSizeOut: &size, parameterSetCountOut: nil, nalUnitHeaderLengthOut: nil)
            }
            if status == noErr, let ptr {
                data.append(contentsOf: startCode)
                data.append(Data(bytes: ptr, count: size))
            }
        }
        return data
    }

    deinit { invalidate() }
}
