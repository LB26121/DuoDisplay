import Foundation
import CoreMedia

/// Layout of one encoded frame as it travels over the network (before chunking):
///
///   [0]      codec (VideoCodec raw value)
///   [1]      flags (bit 0 = keyframe)
///   [2..9]   capture timestamp, sender host clock, ns (UInt64 LE)
///   [10]     parameter set count N (only > 0 on keyframes)
///   N times: UInt16 LE length + parameter set bytes (SPS/PPS or VPS/SPS/PPS;
///            ProRes has none, it sends one 4-byte set instead: UInt16 LE width + UInt16 LE height)
///   rest:    sample data, AVCC/HVCC format (4-byte big-endian NAL lengths) or one ProRes frame
struct ParsedFrame {
    let codec: VideoCodec
    let keyframe: Bool
    let captureNs: UInt64
    let parameterSets: [Data]
    let sampleRange: Range<Int>
}

enum FrameCodec {
    static func buildPayload(codec: VideoCodec, keyframe: Bool, captureNs: UInt64,
                             parameterSets: [Data], sampleData: CMBlockBuffer) -> Data {
        let sampleLength = CMBlockBufferGetDataLength(sampleData)
        let psBytes = parameterSets.reduce(0) { $0 + 2 + $1.count }
        var payload = Data(capacity: 11 + psBytes + sampleLength)
        payload.append(codec.rawValue)
        payload.append(keyframe ? 1 : 0)
        payload.appendLE(captureNs)
        payload.append(UInt8(parameterSets.count))
        for ps in parameterSets {
            payload.appendLE(UInt16(ps.count))
            payload.append(ps)
        }
        let offset = payload.count
        payload.count += sampleLength
        payload.withUnsafeMutableBytes { raw in
            _ = CMBlockBufferCopyDataBytes(sampleData, atOffset: 0, dataLength: sampleLength,
                                           destination: raw.baseAddress! + offset)
        }
        return payload
    }

    static func parse(_ data: Data) -> ParsedFrame? {
        data.withUnsafeBytes { raw -> ParsedFrame? in
            guard raw.count >= 11, let codec = VideoCodec(rawValue: raw[0]) else { return nil }
            let keyframe = raw[1] & 1 != 0
            let captureNs = raw.readLE(2, as: UInt64.self)
            let count = Int(raw[10])
            var offset = 11
            var sets: [Data] = []
            sets.reserveCapacity(count)
            for _ in 0..<count {
                guard offset + 2 <= raw.count else { return nil }
                let len = Int(raw.readLE(offset, as: UInt16.self))
                offset += 2
                guard offset + len <= raw.count else { return nil }
                sets.append(Data(UnsafeRawBufferPointer(rebasing: raw[offset..<(offset + len)])))
                offset += len
            }
            guard offset < raw.count else { return nil }
            return ParsedFrame(codec: codec, keyframe: keyframe, captureNs: captureNs,
                               parameterSets: sets, sampleRange: offset..<raw.count)
        }
    }

    static func parameterSets(of format: CMFormatDescription, codec: VideoCodec) -> [Data] {
        var result: [Data] = []
        var count = 0
        switch codec {
        case .prores:
            let size = CMVideoFormatDescriptionGetDimensions(format)
            var set = Data(capacity: 4)
            set.appendLE(UInt16(clamping: size.width))
            set.appendLE(UInt16(clamping: size.height))
            result.append(set)
        case .h264:
            guard CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
                format, parameterSetIndex: 0, parameterSetPointerOut: nil, parameterSetSizeOut: nil,
                parameterSetCountOut: &count, nalUnitHeaderLengthOut: nil) == noErr else { return [] }
            for i in 0..<count {
                var ptr: UnsafePointer<UInt8>?
                var size = 0
                if CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
                    format, parameterSetIndex: i, parameterSetPointerOut: &ptr, parameterSetSizeOut: &size,
                    parameterSetCountOut: nil, nalUnitHeaderLengthOut: nil) == noErr, let ptr {
                    result.append(Data(bytes: ptr, count: size))
                }
            }
        case .hevc:
            guard CMVideoFormatDescriptionGetHEVCParameterSetAtIndex(
                format, parameterSetIndex: 0, parameterSetPointerOut: nil, parameterSetSizeOut: nil,
                parameterSetCountOut: &count, nalUnitHeaderLengthOut: nil) == noErr else { return [] }
            for i in 0..<count {
                var ptr: UnsafePointer<UInt8>?
                var size = 0
                if CMVideoFormatDescriptionGetHEVCParameterSetAtIndex(
                    format, parameterSetIndex: i, parameterSetPointerOut: &ptr, parameterSetSizeOut: &size,
                    parameterSetCountOut: nil, nalUnitHeaderLengthOut: nil) == noErr, let ptr {
                    result.append(Data(bytes: ptr, count: size))
                }
            }
        }
        return result
    }

    static func makeFormatDescription(codec: VideoCodec, parameterSets: [Data]) -> CMVideoFormatDescription? {
        guard !parameterSets.isEmpty else { return nil }
        if codec == .prores {
            // The decoder only needs the size; everything else is in each frame's own header.
            guard parameterSets[0].count == 4 else { return nil }
            let (width, height) = parameterSets[0].withUnsafeBytes {
                (Int32($0.readLE(0, as: UInt16.self)), Int32($0.readLE(2, as: UInt16.self)))
            }
            guard width > 0, height > 0 else { return nil }
            var format: CMFormatDescription?
            let status = CMVideoFormatDescriptionCreate(allocator: kCFAllocatorDefault, codecType: codec.cmCodecType,
                                                        width: width, height: height, extensions: nil,
                                                        formatDescriptionOut: &format)
            return status == noErr ? format : nil
        }
        let buffers: [UnsafeMutablePointer<UInt8>] = parameterSets.map { set in
            let p = UnsafeMutablePointer<UInt8>.allocate(capacity: max(set.count, 1))
            set.copyBytes(to: p, count: set.count)
            return p
        }
        defer { buffers.forEach { $0.deallocate() } }
        let pointers = buffers.map { UnsafePointer($0) }
        let sizes = parameterSets.map { $0.count }
        var format: CMFormatDescription?
        let status: OSStatus
        switch codec {
        case .h264:
            status = CMVideoFormatDescriptionCreateFromH264ParameterSets(
                allocator: kCFAllocatorDefault, parameterSetCount: pointers.count,
                parameterSetPointers: pointers, parameterSetSizes: sizes,
                nalUnitHeaderLength: 4, formatDescriptionOut: &format)
        case .hevc:
            status = CMVideoFormatDescriptionCreateFromHEVCParameterSets(
                allocator: kCFAllocatorDefault, parameterSetCount: pointers.count,
                parameterSetPointers: pointers, parameterSetSizes: sizes,
                nalUnitHeaderLength: 4, extensions: nil, formatDescriptionOut: &format)
        case .prores:
            return nil   // handled above
        }
        return status == noErr ? format : nil
    }

    /// Wraps the sample bytes in a CMSampleBuffer flagged for immediate display.
    static func makeSampleBuffer(from data: Data, range: Range<Int>, format: CMFormatDescription) -> CMSampleBuffer? {
        let length = range.count
        var block: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: length,
            blockAllocator: kCFAllocatorDefault, customBlockSource: nil, offsetToData: 0,
            dataLength: length, flags: kCMBlockBufferAssureMemoryNowFlag, blockBufferOut: &block) == noErr,
              let block else { return nil }
        let copyStatus = data.withUnsafeBytes { raw in
            CMBlockBufferReplaceDataBytes(with: raw.baseAddress! + range.lowerBound, blockBuffer: block,
                                          offsetIntoDestination: 0, dataLength: length)
        }
        guard copyStatus == noErr else { return nil }

        var timing = CMSampleTimingInfo(duration: .invalid,
                                        presentationTimeStamp: CMClockGetTime(CMClockGetHostTimeClock()),
                                        decodeTimeStamp: .invalid)
        var size = length
        var sample: CMSampleBuffer?
        guard CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault, dataBuffer: block, formatDescription: format,
            sampleCount: 1, sampleTimingEntryCount: 1, sampleTimingArray: &timing,
            sampleSizeEntryCount: 1, sampleSizeArray: &size, sampleBufferOut: &sample) == noErr,
              let sample else { return nil }

        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: true),
           CFArrayGetCount(attachments) > 0 {
            let dict = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0), to: CFMutableDictionary.self)
            CFDictionarySetValue(dict,
                                 Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
                                 Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
        }
        return sample
    }
}
