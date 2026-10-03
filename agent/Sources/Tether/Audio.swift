import AVFoundation
import CoreMedia
import TetherCore

/// Turns ScreenCaptureKit audio sample buffers into network frames:
/// AAC-LC (for browsers with WebCodecs AudioDecoder) and/or 24 kHz 16-bit PCM (fallback).
final class AudioEncoder {
    var wantAAC = false
    var wantPCM = false
    var onFrame: ((AudioFormat, Data) -> Void)?

    private var converter: AVAudioConverter?
    private var inputFormat: AVAudioFormat?
    private var pending: [AVAudioPCMBuffer] = []

    /// AudioSpecificConfig for AAC-LC, 48 kHz, stereo (the client's decoder description).
    static let aacDescription = Data([0x11, 0x90])

    func process(_ sampleBuffer: CMSampleBuffer) {
        guard wantAAC || wantPCM, let pcm = Self.pcmBuffer(from: sampleBuffer) else { return }
        if wantPCM, let data = Self.pcm16Downsampled(pcm) { onFrame?(.pcm, data) }
        if wantAAC { encodeAAC(pcm) }
    }

    func reset() {
        converter = nil
        inputFormat = nil
        pending.removeAll()
    }

    private func encodeAAC(_ buffer: AVAudioPCMBuffer) {
        if converter == nil || inputFormat != buffer.format {
            var desc = AudioStreamBasicDescription(
                mSampleRate: 48_000, mFormatID: kAudioFormatMPEG4AAC, mFormatFlags: 0, mBytesPerPacket: 0,
                mFramesPerPacket: 1024, mBytesPerFrame: 0, mChannelsPerFrame: 2, mBitsPerChannel: 0, mReserved: 0)
            guard let out = AVAudioFormat(streamDescription: &desc),
                  let conv = AVAudioConverter(from: buffer.format, to: out) else { return }
            conv.bitRate = 128_000
            converter = conv
            inputFormat = buffer.format
        }
        guard let converter else { return }
        pending.append(buffer)
        while true {
            let out = AVAudioCompressedBuffer(format: converter.outputFormat, packetCapacity: 8,
                                              maximumPacketSize: max(converter.maximumOutputPacketSize, 1536))
            var error: NSError?
            let status = converter.convert(to: out, error: &error) { [weak self] _, inputStatus in
                guard let self, !self.pending.isEmpty else { inputStatus.pointee = .noDataNow; return nil }
                inputStatus.pointee = .haveData
                return self.pending.removeFirst()
            }
            if out.packetCount > 0, let descs = out.packetDescriptions {
                for i in 0..<Int(out.packetCount) {
                    let d = descs[i]
                    onFrame?(.aac, Data(bytes: out.data.advanced(by: Int(d.mStartOffset)), count: Int(d.mDataByteSize)))
                }
            }
            if status != .haveData || out.packetCount == 0 { break }
        }
    }

    private static func pcmBuffer(from sb: CMSampleBuffer) -> AVAudioPCMBuffer? {
        guard let fmt = CMSampleBufferGetFormatDescription(sb),
              var asbd = CMAudioFormatDescriptionGetStreamBasicDescription(fmt)?.pointee,
              let format = AVAudioFormat(streamDescription: &asbd) else { return nil }
        let frames = AVAudioFrameCount(CMSampleBufferGetNumSamples(sb))
        guard frames > 0, let pcm = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else { return nil }
        pcm.frameLength = frames
        let status = CMSampleBufferCopyPCMDataIntoAudioBufferList(sb, at: 0, frameCount: Int32(frames), into: pcm.mutableAudioBufferList)
        return status == noErr ? pcm : nil
    }

    /// Float32 (any layout) 48 kHz → interleaved s16le stereo at 24 kHz.
    private static func pcm16Downsampled(_ buf: AVAudioPCMBuffer) -> Data? {
        guard let ch = buf.floatChannelData else { return nil }
        let channels = Int(buf.format.channelCount), frames = Int(buf.frameLength)
        let interleaved = buf.format.isInterleaved
        let step = buf.format.sampleRate >= 44_000 ? 2 : 1
        var out = Data(capacity: frames / step * 4)
        func sample(_ c: Int, _ i: Int) -> Float {
            let cc = min(c, channels - 1)
            return interleaved ? ch[0][i * channels + cc] : ch[cc][i]
        }
        var i = 0
        while i + step - 1 < frames {
            for c in 0..<2 {
                var v: Float = 0
                for k in 0..<step { v += sample(c, i + k) }
                let s = Int16(max(-1, min(1, v / Float(step))) * 32767)
                withUnsafeBytes(of: s.littleEndian) { out.append(contentsOf: $0) }
            }
            i += step
        }
        return out
    }
}
