import Foundation
import VideoToolbox
import CoreMedia

/// Hardware HEVC decoder (VideoToolbox). Ported from the previous app.
/// The full recovery ladder (requiresFlush, error-code-specific rebuild, IDR request)
/// is added in Phase 1 (see docs/03 § Decoder recovery ladder).
final class VideoDecoder {
    private var session: VTDecompressionSession?
    private var formatDescription: CMVideoFormatDescription?
    private var reusableBlockData = Data()

    var onDecodedFrame: ((CMSampleBuffer) -> Void)?
    /// Called on a VideoToolbox decode error (drives the recovery ladder in DisplayController).
    var onDecodeError: ((OSStatus) -> Void)?

    func decode(nalData: Data, isKeyframe: Bool) {
        guard nalData.count > 4 else { return }
        nalData.withUnsafeBytes { rawBuffer in
            guard let baseAddress = rawBuffer.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return }
            let bytes = UnsafeBufferPointer(start: baseAddress, count: rawBuffer.count)

            let positions = findNALPositions(bytes: bytes)
            guard !positions.isEmpty else { return }

            if isKeyframe {
                var paramSets: [(start: Int, count: Int)] = []
                for (idx, start) in positions.enumerated() {
                    let end = idx + 1 < positions.count ? findNALEnd(bytes: bytes, nextStart: positions[idx + 1]) : bytes.count
                    guard end > start, bytes[start] != 0 else { continue }
                    let nalType = (bytes[start] >> 1) & 0x3F
                    if nalType == 32 || nalType == 33 || nalType == 34 {
                        paramSets.append((start, end - start))
                    }
                }
                if !paramSets.isEmpty {
                    if let session { VTDecompressionSessionWaitForAsynchronousFrames(session) }
                    updateFormatDescription(bytes: bytes, paramSets: paramSets)
                }
            }

            guard let formatDescription else { return }

            var videoNALRanges: [(start: Int, count: Int)] = []
            for (idx, start) in positions.enumerated() {
                let end = idx + 1 < positions.count ? findNALEnd(bytes: bytes, nextStart: positions[idx + 1]) : bytes.count
                guard end > start + 2 else { continue }
                let nalType = (bytes[start] >> 1) & 0x3F
                if nalType != 32 && nalType != 33 && nalType != 34 {
                    videoNALRanges.append((start, end - start))
                }
            }
            guard !videoNALRanges.isEmpty else { return }
            decodeCombinedNALs(bytes: bytes, ranges: videoNALRanges, formatDescription: formatDescription, isKeyframe: isKeyframe)
        }
    }

    func invalidate() {
        if let session { VTDecompressionSessionInvalidate(session) }
        session = nil
        formatDescription = nil
    }

    private func findNALPositions(bytes: UnsafeBufferPointer<UInt8>) -> [Int] {
        var positions: [Int] = []
        positions.reserveCapacity(8)
        var i = 0
        let count = bytes.count
        while i < count - 2 {
            if bytes[i] == 0 && bytes[i + 1] == 0 {
                if i < count - 3 && bytes[i + 2] == 0 && bytes[i + 3] == 1 {
                    positions.append(i + 4); i += 4
                } else if bytes[i + 2] == 1 {
                    positions.append(i + 3); i += 3
                } else { i += 1 }
            } else { i += 1 }
        }
        return positions
    }

    private func findNALEnd(bytes: UnsafeBufferPointer<UInt8>, nextStart: Int) -> Int {
        if nextStart >= 4 && bytes[nextStart - 4] == 0 && bytes[nextStart - 3] == 0 && bytes[nextStart - 2] == 0 && bytes[nextStart - 1] == 1 {
            return nextStart - 4
        } else if nextStart >= 3 && bytes[nextStart - 3] == 0 && bytes[nextStart - 2] == 0 && bytes[nextStart - 1] == 1 {
            return nextStart - 3
        }
        return nextStart
    }

    private func updateFormatDescription(bytes: UnsafeBufferPointer<UInt8>, paramSets: [(start: Int, count: Int)]) {
        var pointers: [UnsafePointer<UInt8>] = []
        var sizes: [Int] = []
        for ps in paramSets {
            pointers.append(bytes.baseAddress!.advanced(by: ps.start))
            sizes.append(ps.count)
        }

        var newFormat: CMVideoFormatDescription?
        let status = pointers.withUnsafeBufferPointer { ptrBuf in
            sizes.withUnsafeBufferPointer { sizeBuf in
                CMVideoFormatDescriptionCreateFromHEVCParameterSets(
                    allocator: nil, parameterSetCount: paramSets.count,
                    parameterSetPointers: ptrBuf.baseAddress!, parameterSetSizes: sizeBuf.baseAddress!,
                    nalUnitHeaderLength: 4, extensions: nil, formatDescriptionOut: &newFormat)
            }
        }
        guard status == noErr, let newFormat else {
            print("[Decoder] Failed to create format description: \(status)")
            return
        }

        if let session { VTDecompressionSessionInvalidate(session) }
        session = nil
        formatDescription = newFormat

        let decoderSpec: [CFString: Any] = [
            kVTVideoDecoderSpecification_EnableHardwareAcceleratedVideoDecoder: true
        ]
        var sessionOut: VTDecompressionSession?
        let decoderStatus = VTDecompressionSessionCreate(
            allocator: nil, formatDescription: newFormat, decoderSpecification: decoderSpec as CFDictionary,
            imageBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
                kCVPixelBufferIOSurfacePropertiesKey: [:] as [String: Any]
            ] as CFDictionary,
            outputCallback: nil, decompressionSessionOut: &sessionOut)
        guard decoderStatus == noErr, let sessionOut else {
            print("[Decoder] Failed to create decompression session: \(decoderStatus)")
            return
        }
        session = sessionOut
        VTSessionSetProperty(sessionOut, key: kVTDecompressionPropertyKey_RealTime, value: kCFBooleanTrue)
    }

    private func decodeCombinedNALs(bytes: UnsafeBufferPointer<UInt8>, ranges: [(start: Int, count: Int)], formatDescription: CMVideoFormatDescription, isKeyframe: Bool) {
        guard let session else { return }

        var totalSize = 0
        for r in ranges { totalSize += 4 + r.count }
        reusableBlockData.count = totalSize
        reusableBlockData.withUnsafeMutableBytes { dest in
            guard let ptr = dest.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return }
            var offset = 0
            for r in ranges {
                var len = UInt32(r.count).bigEndian
                memcpy(ptr.advanced(by: offset), &len, 4); offset += 4
                memcpy(ptr.advanced(by: offset), bytes.baseAddress!.advanced(by: r.start), r.count); offset += r.count
            }
        }

        var blockBuffer: CMBlockBuffer?
        reusableBlockData.withUnsafeMutableBytes { buffer in
            CMBlockBufferCreateWithMemoryBlock(
                allocator: nil, memoryBlock: nil, blockLength: buffer.count, blockAllocator: nil,
                customBlockSource: nil, offsetToData: 0, dataLength: buffer.count, flags: 0, blockBufferOut: &blockBuffer)
            if let blockBuffer {
                CMBlockBufferReplaceDataBytes(with: buffer.baseAddress!, blockBuffer: blockBuffer,
                                              offsetIntoDestination: 0, dataLength: buffer.count)
            }
        }
        guard let blockBuffer else { return }

        var sampleBuffer: CMSampleBuffer?
        var sampleSize = totalSize
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 60),
                                        presentationTimeStamp: CMClockGetTime(CMClockGetHostTimeClock()),
                                        decodeTimeStamp: .invalid)
        CMSampleBufferCreateReady(allocator: nil, dataBuffer: blockBuffer, formatDescription: formatDescription,
                                  sampleCount: 1, sampleTimingEntryCount: 1, sampleTimingArray: &timing,
                                  sampleSizeEntryCount: 1, sampleSizeArray: &sampleSize, sampleBufferOut: &sampleBuffer)
        guard let sampleBuffer else { return }

        if isKeyframe {
            let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: true) as? [NSMutableDictionary]
            attachments?.first?[kCMSampleAttachmentKey_DisplayImmediately] = true
        }

        var flagsOut: VTDecodeInfoFlags = []
        let decodeStatus = VTDecompressionSessionDecodeFrame(session, sampleBuffer: sampleBuffer,
                                          flags: [._EnableAsynchronousDecompression], infoFlagsOut: &flagsOut) { [weak self] status, _, imageBuffer, presentationTime, _ in
            if status != noErr { self?.onDecodeError?(status); return }
            guard let imageBuffer else { return }
            var outputFormatDesc: CMVideoFormatDescription?
            CMVideoFormatDescriptionCreateForImageBuffer(allocator: nil, imageBuffer: imageBuffer, formatDescriptionOut: &outputFormatDesc)
            guard let outputFormatDesc else { return }
            var outputTiming = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 60),
                                                  presentationTimeStamp: presentationTime, decodeTimeStamp: .invalid)
            var outputSampleBuffer: CMSampleBuffer?
            CMSampleBufferCreateForImageBuffer(allocator: nil, imageBuffer: imageBuffer, dataReady: true,
                                               makeDataReadyCallback: nil, refcon: nil, formatDescription: outputFormatDesc,
                                               sampleTiming: &outputTiming, sampleBufferOut: &outputSampleBuffer)
            if let outputSampleBuffer { self?.onDecodedFrame?(outputSampleBuffer) }
        }
        if decodeStatus != noErr { onDecodeError?(decodeStatus) }
    }

    deinit { invalidate() }
}
