import Foundation
import VideoToolbox
import CoreMedia

final class VideoEncoder {
    private var session: VTCompressionSession?
    private var forceNextKeyframe = false
    private let width: Int32
    private let height: Int32

    var onEncodedFrame: ((Data, Bool) -> Void)?

    init(width: Int32, height: Int32, fps: Int = 60, bitrate: Int = 30_000_000) {
        self.width = width
        self.height = height

        let encoderSpec: [CFString: Any] = [
            kVTVideoEncoderSpecification_EnableLowLatencyRateControl: true
        ]

        let callback: VTCompressionOutputCallback = { refcon, _, status, flags, sampleBuffer in
            guard let refcon else { return }
            let encoder = Unmanaged<VideoEncoder>.fromOpaque(refcon).takeUnretainedValue()
            encoder.handleEncodedFrame(status: status, flags: flags, sampleBuffer: sampleBuffer)
        }

        var sessionOut: VTCompressionSession?
        let status = VTCompressionSessionCreate(
            allocator: nil,
            width: width,
            height: height,
            codecType: kCMVideoCodecType_HEVC,
            encoderSpecification: encoderSpec as CFDictionary,
            imageBufferAttributes: nil,
            compressedDataAllocator: nil,
            outputCallback: callback,
            refcon: Unmanaged.passUnretained(self).toOpaque(),
            compressionSessionOut: &sessionOut
        )

        guard status == noErr, let session = sessionOut else {
            print("[Encoder] Failed to create session: \(status)")
            return
        }

        self.session = session

        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_RealTime, value: kCFBooleanTrue)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_ProfileLevel, value: kVTProfileLevel_HEVC_Main_AutoLevel)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AverageBitRate, value: bitrate as CFNumber)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_ExpectedFrameRate, value: fps as CFNumber)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_MaxKeyFrameInterval, value: fps as CFNumber)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration, value: 1.0 as CFNumber)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AllowFrameReordering, value: kCFBooleanFalse)

        VTCompressionSessionPrepareToEncodeFrames(session)
    }

    func encode(pixelBuffer: CVPixelBuffer, presentationTime: CMTime) {
        guard let session else { return }

        var properties: [CFString: Any]? = nil
        if forceNextKeyframe {
            properties = [kVTEncodeFrameOptionKey_ForceKeyFrame: true]
            forceNextKeyframe = false
        }

        VTCompressionSessionEncodeFrame(
            session,
            imageBuffer: pixelBuffer,
            presentationTimeStamp: presentationTime,
            duration: .invalid,
            frameProperties: properties as CFDictionary?,
            sourceFrameRefcon: nil,
            infoFlagsOut: nil
        )
    }

    func forceKeyframe() {
        forceNextKeyframe = true
    }

    func updateBitrate(_ newBitrate: Int) {
        guard let session else { return }
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AverageBitRate, value: newBitrate as CFNumber)
    }

    func flush() {
        guard let session else { return }
        VTCompressionSessionCompleteFrames(session, untilPresentationTimeStamp: .invalid)
    }

    func invalidate() {
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
        let blockStatus = CMBlockBufferGetDataPointer(dataBuffer, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: &totalLength, dataPointerOut: &dataPointer)

        guard blockStatus == noErr, let dataPointer else { return }

        var nalData = Data()

        if isKeyframe {
            if let formatDesc = sampleBuffer.formatDescription {
                nalData.append(extractParameterSets(from: formatDesc))
            }
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

        onEncodedFrame?(nalData, isKeyframe)
    }

    private func extractParameterSets(from formatDescription: CMFormatDescription) -> Data {
        var data = Data()

        var vpsSize = 0
        var vpsCount = 0
        var vpsPointer: UnsafePointer<UInt8>?

        if CMVideoFormatDescriptionGetHEVCParameterSetAtIndex(formatDescription, parameterSetIndex: 0, parameterSetPointerOut: &vpsPointer, parameterSetSizeOut: &vpsSize, parameterSetCountOut: &vpsCount, nalUnitHeaderLengthOut: nil) == noErr, let vpsPointer {
            data.append(contentsOf: [0x00, 0x00, 0x00, 0x01])
            data.append(Data(bytes: vpsPointer, count: vpsSize))
        }

        var spsSize = 0
        var spsPointer: UnsafePointer<UInt8>?
        if CMVideoFormatDescriptionGetHEVCParameterSetAtIndex(formatDescription, parameterSetIndex: 1, parameterSetPointerOut: &spsPointer, parameterSetSizeOut: &spsSize, parameterSetCountOut: nil, nalUnitHeaderLengthOut: nil) == noErr, let spsPointer {
            data.append(contentsOf: [0x00, 0x00, 0x00, 0x01])
            data.append(Data(bytes: spsPointer, count: spsSize))
        }

        var ppsSize = 0
        var ppsPointer: UnsafePointer<UInt8>?
        if CMVideoFormatDescriptionGetHEVCParameterSetAtIndex(formatDescription, parameterSetIndex: 2, parameterSetPointerOut: &ppsPointer, parameterSetSizeOut: &ppsSize, parameterSetCountOut: nil, nalUnitHeaderLengthOut: nil) == noErr, let ppsPointer {
            data.append(contentsOf: [0x00, 0x00, 0x00, 0x01])
            data.append(Data(bytes: ppsPointer, count: ppsSize))
        }

        return data
    }

    deinit {
        invalidate()
    }
}
