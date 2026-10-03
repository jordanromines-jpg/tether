import AppKit
import CoreMedia
import Foundation
import ScreenCaptureKit
import TetherCore

struct DisplayInfo {
    let id: CGDirectDisplayID
    let name: String
    let pixelWidth: Int
    let pixelHeight: Int

    var json: [String: Any] { ["id": id, "name": name, "w": pixelWidth, "h": pixelHeight] }
}

enum Displays {
    static func list() async throws -> [DisplayInfo] {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        let names: [CGDirectDisplayID: String] = await MainActor.run {
            var out: [CGDirectDisplayID: String] = [:]
            for screen in NSScreen.screens {
                if let n = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber {
                    out[n.uint32Value] = screen.localizedName
                }
            }
            return out
        }
        return content.displays.map { d in
            let mode = CGDisplayCopyDisplayMode(d.displayID)
            return DisplayInfo(
                id: d.displayID,
                name: names[d.displayID] ?? "Display \(d.displayID)",
                pixelWidth: mode?.pixelWidth ?? d.width * 2,
                pixelHeight: mode?.pixelHeight ?? d.height * 2)
        }
    }
}

/// Captures one display with ScreenCaptureKit and feeds frames to the H.264 encoder.
final class ScreenStreamer: NSObject, SCStreamOutput, SCStreamDelegate {
    struct Config {
        let codec: String
        let avcC: Data
        let width: Int
        let height: Int
    }

    struct Settings: Equatable {
        var displayID: CGDirectDisplayID
        var codec: VideoCodec
        var maxWidth: Int
        var fps: Int
        var bitrate: Int
        var audio: Bool
    }

    var onFrame: ((VideoEncoder.Output) -> Void)?
    var onStopped: ((Error) -> Void)?
    let audioEncoder = AudioEncoder()
    private let audioQueue = DispatchQueue(label: "tether.audio", qos: .userInitiated)

    private(set) var size: (width: Int, height: Int) = (0, 0)
    private var stream: SCStream?
    private var encoder: VideoEncoder?
    private(set) var codec: VideoCodec = .h264
    private(set) var capturingAudio = false
    private let queue = DispatchQueue(label: "tether.capture", qos: .userInteractive)
    private var lastPixelBuffer: CVPixelBuffer?
    private var wantKeyframe = true

    func start(_ settings: Settings) async throws {
        await stop()
        // A just-created virtual display can take a moment to show up in ScreenCaptureKit.
        var content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        for _ in 0..<6 where !content.displays.contains(where: { $0.displayID == settings.displayID }) {
            try await Task.sleep(nanoseconds: 300_000_000)
            content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        }
        guard let display = content.displays.first(where: { $0.displayID == settings.displayID }) ?? content.displays.first else {
            throw NSError(domain: "Tether", code: 1, userInfo: [NSLocalizedDescriptionKey: "No display to capture"])
        }
        let mode = CGDisplayCopyDisplayMode(display.displayID)
        let native = (mode?.pixelWidth ?? display.width * 2, mode?.pixelHeight ?? display.height * 2)
        let target = Sizing.encodeSize(nativeWidth: native.0, nativeHeight: native.1, maxWidth: settings.maxWidth,
                                       maxPixels: Sizing.maxPixels(for: settings.codec))

        let config = SCStreamConfiguration()
        config.width = target.width
        config.height = target.height
        config.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(settings.fps))
        config.pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        config.showsCursor = false  // clients draw the cursor locally (zero added latency)
        config.queueDepth = 5
        config.capturesAudio = settings.audio
        if settings.audio {
            config.sampleRate = 48_000
            config.channelCount = 2
            config.excludesCurrentProcessAudio = true
        }

        let filter = SCContentFilter(display: display, excludingWindows: [])
        let s = SCStream(filter: filter, configuration: config, delegate: self)
        try s.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
        if settings.audio {
            audioQueue.sync { audioEncoder.reset() }
            try s.addStreamOutput(self, type: .audio, sampleHandlerQueue: audioQueue)
        }

        queue.sync {
            self.size = target
            self.wantKeyframe = true
            self.lastPixelBuffer = nil
            self.codec = settings.codec
            self.encoder = VideoEncoder(codec: settings.codec, width: target.width, height: target.height,
                                        fps: settings.fps, bitrate: settings.bitrate) { [weak self] out in
                self?.onFrame?(out)
            }
                ?? VideoEncoder(codec: .h264, width: target.width, height: target.height,
                                fps: settings.fps, bitrate: settings.bitrate) { [weak self] out in
                    self?.onFrame?(out)
                }
            if self.encoder?.codec != settings.codec { self.codec = .h264 }
        }
        try await s.startCapture()
        stream = s
        capturingAudio = settings.audio
    }

    func stop() async {
        capturingAudio = false
        if let s = stream {
            stream = nil
            try? await s.stopCapture()
        }
        queue.sync {
            encoder?.invalidate()
            encoder = nil
            lastPixelBuffer = nil
        }
    }

    func setBitrate(_ bitrate: Int) {
        queue.async { self.encoder?.setBitrate(bitrate) }
    }

    /// Forces the next frame to be a keyframe. If the screen is idle (SCK sends no new
    /// frames), re-encodes the last captured frame so new clients see something at once.
    func requestKeyframe() {
        queue.async {
            self.wantKeyframe = true
            if let pb = self.lastPixelBuffer, let enc = self.encoder {
                self.wantKeyframe = false
                enc.encode(pb, forceKeyframe: true)
            }
        }
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        if type == .audio {
            audioEncoder.process(sampleBuffer)
            return
        }
        guard type == .screen,
              let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let raw = attachments.first?[.status] as? Int,
              SCFrameStatus(rawValue: raw) == .complete,
              let pb = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        lastPixelBuffer = pb
        let key = wantKeyframe
        wantKeyframe = false
        encoder?.encode(pb, forceKeyframe: key)
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        NSLog("Tether: capture stopped: \(error.localizedDescription)")
        onStopped?(error)
    }
}
