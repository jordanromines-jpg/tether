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
        var excludedWindowIDs: [CGWindowID] = []
        var windowID: CGWindowID?    // single-window mode
        /// Re-encode a still screen once at high quality (off in Battery saver: it costs data).
        var refineWhenStill = true
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
    /// The first frame of a capture goes out light and quick; then a still screen gets one sharp frame.
    private var quickNext = true
    private var refine = true
    private var changeCount = 0
    private var settling = 0
    private var refinedAt = -1
    private static let stillAfter: DispatchTimeInterval = .milliseconds(StillPolicy.stillAfterMs)

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
        var native = (mode?.pixelWidth ?? display.width * 2, mode?.pixelHeight ?? display.height * 2)
        // Single-window mode: capture just that window, at its own size (wherever it is).
        var windowFilter: SCContentFilter?
        if let wid = settings.windowID {
            guard let w = content.windows.first(where: { $0.windowID == wid }) else {
                throw NSError(domain: "Tether", code: 2, userInfo: [NSLocalizedDescriptionKey: "That window isn't on screen any more"])
            }
            windowFilter = SCContentFilter(desktopIndependentWindow: w)
            let scale = Double(mode?.pixelWidth ?? display.width * 2) / Double(max(display.width, 1))
            native = (max(64, Int(w.frame.width * scale)), max(64, Int(w.frame.height * scale)))
        }
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

        // Tether's own curtain windows are left out, so the person controlling sees the desktop.
        let excluded = content.windows.filter { settings.excludedWindowIDs.contains($0.windowID) }
        let filter = windowFilter ?? SCContentFilter(display: display, excludingWindows: excluded)
        let s = SCStream(filter: filter, configuration: config, delegate: self)
        try s.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
        if settings.audio {
            audioQueue.sync { audioEncoder.reset() }
            try s.addStreamOutput(self, type: .audio, sampleHandlerQueue: audioQueue)
        }

        queue.sync {
            self.size = target
            self.wantKeyframe = true
            self.quickNext = true
            self.refine = settings.refineWhenStill
            self.lastPixelBuffer = nil
            self.codec = settings.codec
            self.encoder = VideoEncoder(codec: settings.codec, width: target.width, height: target.height,
                                        fps: settings.fps, bitrate: settings.bitrate) { [weak self] out in
                self?.onFrame?(out)
                self?.noteEncoded(out)
            }
                ?? VideoEncoder(codec: .h264, width: target.width, height: target.height,
                                fps: settings.fps, bitrate: settings.bitrate) { [weak self] out in
                    self?.onFrame?(out)
                    self?.noteEncoded(out)
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
                // The screen is still (or this frame would be new): send it sharp straight away.
                if self.refine { enc.encodeRefined(pb); self.refinedAt = self.changeCount } else { enc.encode(pb, forceKeyframe: true) }
            }
        }
    }

    /// Half a second after the last change, if nothing new arrived, send one sharp version of the screen.
    private func scheduleRefine() {
        guard refine else { return }
        let change = changeCount
        queue.asyncAfter(deadline: .now() + Self.stillAfter) { [weak self] in
            guard let self, self.changeCount == change, self.refinedAt != change,
                  let pb = self.lastPixelBuffer, let enc = self.encoder else { return }
            self.refinedAt = change
            enc.encodeRefined(pb)
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
        if key && quickNext {
            quickNext = false
            encoder?.encodeQuick(pb)
            changeCount += 1
            scheduleRefine()
        } else {
            encoder?.encode(pb, forceKeyframe: key)
        }
    }

    /// Every encoded frame: a big in-between frame means the screen moved, so restart the "still" clock.
    /// The encoder settles for a few frames after a keyframe; those frames say nothing about movement.
    private func noteEncoded(_ out: VideoEncoder.Output) {
        queue.async {
            if out.isKeyframe { self.settling = StillPolicy.settleFrames; return }
            if self.settling > 0 { self.settling -= 1; return }
            guard StillPolicy.isMotion(frameBytes: out.data.count, pixels: self.size.width * self.size.height) else { return }
            self.changeCount += 1
            self.scheduleRefine()
        }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        NSLog("Tether: capture stopped: \(error.localizedDescription)")
        onStopped?(error)
    }
}
