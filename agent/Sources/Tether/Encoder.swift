import CoreMedia
import Foundation
import VideoToolbox

import TetherCore

/// Hardware H.264/HEVC encoder tuned for interactive remote desktop:
/// real-time, low-latency rate control, no B-frames, keyframes on demand.
final class VideoEncoder {
    struct Output {
        let data: Data          // AVCC access unit
        let isKeyframe: Bool
        let description: Data?  // avcC/hvcC decoder config, present on keyframes
        let timestampMicros: UInt64
    }

    private var session: VTCompressionSession?
    private let onOutput: (Output) -> Void
    private var bitrate: Int

    let codec: VideoCodec

    init?(codec: VideoCodec, width: Int, height: Int, fps: Int, bitrate: Int, onOutput: @escaping (Output) -> Void) {
        self.onOutput = onOutput
        self.codec = codec
        self.bitrate = bitrate
        let codecType = codec == .hevc ? kCMVideoCodecType_HEVC : kCMVideoCodecType_H264
        let lowLatency = [kVTVideoEncoderSpecification_EnableLowLatencyRateControl: kCFBooleanTrue] as CFDictionary
        var s: VTCompressionSession?
        var status = VTCompressionSessionCreate(
            allocator: nil, width: Int32(width), height: Int32(height), codecType: codecType,
            encoderSpecification: lowLatency, imageBufferAttributes: nil, compressedDataAllocator: nil,
            outputCallback: nil, refcon: nil, compressionSessionOut: &s)
        if status != noErr {
            NSLog("Tether: low-latency encoder unavailable (\(status)), falling back")
            status = VTCompressionSessionCreate(
                allocator: nil, width: Int32(width), height: Int32(height), codecType: codecType,
                encoderSpecification: nil, imageBufferAttributes: nil, compressedDataAllocator: nil,
                outputCallback: nil, refcon: nil, compressionSessionOut: &s)
        }
        guard status == noErr, let s else { return nil }
        session = s
        VTSessionSetProperty(s, key: kVTCompressionPropertyKey_RealTime, value: kCFBooleanTrue)
        VTSessionSetProperty(s, key: kVTCompressionPropertyKey_AllowFrameReordering, value: kCFBooleanFalse)
        if codec == .hevc {
            VTSessionSetProperty(s, key: kVTCompressionPropertyKey_ProfileLevel, value: kVTProfileLevel_HEVC_Main_AutoLevel)
        } else if VTSessionSetProperty(s, key: kVTCompressionPropertyKey_ProfileLevel,
                                       value: kVTProfileLevel_H264_ConstrainedHigh_AutoLevel) != noErr {
            VTSessionSetProperty(s, key: kVTCompressionPropertyKey_ProfileLevel, value: kVTProfileLevel_H264_High_AutoLevel)
        }
        VTSessionSetProperty(s, key: kVTCompressionPropertyKey_AverageBitRate, value: bitrate as CFNumber)
        VTSessionSetProperty(s, key: kVTCompressionPropertyKey_ExpectedFrameRate, value: fps as CFNumber)
        VTSessionSetProperty(s, key: kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration, value: 10 as CFNumber)
        VTCompressionSessionPrepareToEncodeFrames(s)
    }

    deinit { invalidate() }

    /// Changes the target bitrate on the fly (no new keyframe needed).
    func setBitrate(_ bitrate: Int) {
        self.bitrate = bitrate
        guard let session else { return }
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AverageBitRate, value: bitrate as CFNumber)
    }

    /// A still screen deserves a sharp picture: one keyframe with a bigger bit budget and a cap on the
    /// quantizer, then back to normal. Text that arrived soft while things moved turns crisp.
    func encodeRefined(_ pixelBuffer: CVPixelBuffer) {
        oneFrame(pixelBuffer, bitrate: bitrate * 6, qp: (kVTCompressionPropertyKey_MaxAllowedFrameQP, 22))
    }

    /// A light first frame, so the picture shows quickly on a slow link (the sharp one follows once the
    /// screen is still).
    func encodeQuick(_ pixelBuffer: CVPixelBuffer) {
        oneFrame(pixelBuffer, bitrate: bitrate, qp: (kVTCompressionPropertyKey_MinAllowedFrameQP, 34))
    }

    private func oneFrame(_ pixelBuffer: CVPixelBuffer, bitrate frameBitrate: Int, qp: (CFString, Int)) {
        guard let session else { return }
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AverageBitRate, value: frameBitrate as CFNumber)
        VTSessionSetProperty(session, key: qp.0, value: qp.1 as CFNumber)
        encode(pixelBuffer, forceKeyframe: true)
        VTCompressionSessionCompleteFrames(session, untilPresentationTimeStamp: .invalid)
        VTSessionSetProperty(session, key: qp.0, value: (qp.0 == kVTCompressionPropertyKey_MaxAllowedFrameQP ? 51 : 0) as CFNumber)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AverageBitRate, value: bitrate as CFNumber)
    }

    func invalidate() {
        if let session {
            VTCompressionSessionCompleteFrames(session, untilPresentationTimeStamp: .invalid)
            VTCompressionSessionInvalidate(session)
        }
        session = nil
    }

    func encode(_ pixelBuffer: CVPixelBuffer, forceKeyframe: Bool) {
        guard let session else { return }
        let now = CMClockGetTime(CMClockGetHostTimeClock())
        let props = forceKeyframe ? [kVTEncodeFrameOptionKey_ForceKeyFrame: kCFBooleanTrue] as CFDictionary : nil
        let micros = UInt64(max(0, now.seconds) * 1_000_000)
        VTCompressionSessionEncodeFrame(
            session, imageBuffer: pixelBuffer, presentationTimeStamp: now, duration: .invalid,
            frameProperties: props, infoFlagsOut: nil
        ) { [onOutput, codec] status, _, sampleBuffer in
            guard status == noErr, let sampleBuffer, let block = CMSampleBufferGetDataBuffer(sampleBuffer) else { return }
            let length = CMBlockBufferGetDataLength(block)
            var data = Data(count: length)
            let copied = data.withUnsafeMutableBytes { raw in
                CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length, destination: raw.baseAddress!)
            }
            guard copied == kCMBlockBufferNoErr else { return }

            var isKey = true
            if let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[CFString: Any]],
               let notSync = attachments.first?[kCMSampleAttachmentKey_NotSync] as? Bool {
                isKey = !notSync
            }
            var description: Data?
            if isKey, let fmt = CMSampleBufferGetFormatDescription(sampleBuffer),
               let atoms = CMFormatDescriptionGetExtension(fmt, extensionKey: kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms) as? [String: Any] {
                description = atoms[codec == .hevc ? "hvcC" : "avcC"] as? Data
            }
            onOutput(Output(data: data, isKeyframe: isKey, description: description, timestampMicros: micros))
        }
    }
}
