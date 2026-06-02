// Capture Zoom app audio (others) + default mic (me) to two WAV files.
// Usage: zoom-audio-capture <others.wav> <me.wav> <start-epoch-file>
//
// Writes the capture-start epoch (Unix seconds, 3 decimals) to start-epoch-file
// once capture begins, so a downstream merge can align whisper segment offsets
// to wall-clock. Runs until SIGTERM/SIGINT, then finalizes both files.
//
// Requires Screen Recording permission (for ScreenCaptureKit app-audio).

import AVFoundation
import ScreenCaptureKit
import Darwin

func die(_ msg: String, _ code: Int32 = 1) -> Never {
    FileHandle.standardError.write((msg + "\n").data(using: .utf8)!)
    exit(code)
}

func log(_ msg: String) {
    FileHandle.standardError.write((msg + "\n").data(using: .utf8)!)
}

guard CommandLine.arguments.count == 4 else {
    die("usage: zoom-audio-capture <others.wav> <me.wav> <start-epoch-file>", 2)
}
let othersPath = CommandLine.arguments[1]
let mePath = CommandLine.arguments[2]
let startEpochPath = CommandLine.arguments[3]

// 16 kHz mono int16 WAV — the format whisper-cli expects.
func makeWavFile(_ path: String) throws -> AVAudioFile {
    let settings: [String: Any] = [
        AVFormatIDKey: kAudioFormatLinearPCM,
        AVSampleRateKey: 16000.0,
        AVNumberOfChannelsKey: 1,
        AVLinearPCMBitDepthKey: 16,
        AVLinearPCMIsFloatKey: false,
        AVLinearPCMIsBigEndianKey: false,
    ]
    return try AVAudioFile(forWriting: URL(fileURLWithPath: path), settings: settings)
}

// Convert one input buffer to the file's processing format and write it.
func convertAndWrite(_ inBuf: AVAudioPCMBuffer, to file: AVAudioFile,
                     using converter: AVAudioConverter) {
    let outFormat = file.processingFormat
    let ratio = outFormat.sampleRate / inBuf.format.sampleRate
    let cap = AVAudioFrameCount(Double(inBuf.frameLength) * ratio + 1024)
    guard let out = AVAudioPCMBuffer(pcmFormat: outFormat, frameCapacity: cap) else { return }
    var err: NSError?
    var fed = false
    converter.convert(to: out, error: &err) { _, status in
        if fed { status.pointee = .noDataNow; return nil }
        fed = true
        status.pointee = .haveData
        return inBuf
    }
    if err == nil, out.frameLength > 0 {
        try? file.write(from: out)
    }
}

// --- Mic capture via AVAudioEngine ---
final class MicRecorder {
    let engine = AVAudioEngine()
    var file: AVAudioFile?
    var converter: AVAudioConverter?
    let outPath: String
    init(_ path: String) { outPath = path }

    func start() throws {
        let input = engine.inputNode
        let inFormat = input.outputFormat(forBus: 0)
        file = try makeWavFile(outPath)
        guard let conv = AVAudioConverter(from: inFormat, to: file!.processingFormat) else {
            throw NSError(domain: "mic", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "no mic converter"])
        }
        converter = conv
        input.installTap(onBus: 0, bufferSize: 4096, format: inFormat) { [weak self] buf, _ in
            guard let self = self, let file = self.file, let conv = self.converter else { return }
            convertAndWrite(buf, to: file, using: conv)
        }
        try engine.start()
    }

    func stop() {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        file = nil
    }
}

// --- App audio capture via ScreenCaptureKit ---
final class AppAudioRecorder: NSObject, SCStreamOutput {
    var stream: SCStream?
    var file: AVAudioFile?
    let outPath: String
    init(_ path: String) { outPath = path }

    func start() async throws {
        let content = try await SCShareableContent.excludingDesktopWindows(
            false, onScreenWindowsOnly: false)
        guard let zoomApp = content.applications.first(where: {
            $0.bundleIdentifier == "us.zoom.xos" || $0.applicationName == "zoom.us"
        }) else {
            throw NSError(domain: "appaudio", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "zoom.us not found among shareable apps"])
        }
        guard let display = content.displays.first else {
            throw NSError(domain: "appaudio", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "no display found"])
        }
        let filter = SCContentFilter(display: display, including: [zoomApp], exceptingWindows: [])
        let cfg = SCStreamConfiguration()
        cfg.capturesAudio = true
        cfg.excludesCurrentProcessAudio = true
        cfg.sampleRate = 16000
        cfg.channelCount = 1
        // SCK needs a video config even for audio-only; keep it minimal.
        cfg.width = 2
        cfg.height = 2
        cfg.minimumFrameInterval = CMTime(value: 1, timescale: 1)

        file = try makeWavFile(outPath)
        let s = SCStream(filter: filter, configuration: cfg, delegate: nil)
        try s.addStreamOutput(self, type: .audio, sampleHandlerQueue: DispatchQueue(label: "audio"))
        try await s.startCapture()
        stream = s
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sb: CMSampleBuffer,
                of type: SCStreamOutputType) {
        guard type == .audio, let file = file, CMSampleBufferDataIsReady(sb) else { return }
        guard let fmtDesc = CMSampleBufferGetFormatDescription(sb),
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(fmtDesc)?.pointee
        else { return }
        var streamDesc = asbd
        guard let inFormat = AVAudioFormat(streamDescription: &streamDesc) else { return }
        let frames = AVAudioFrameCount(CMSampleBufferGetNumSamples(sb))
        guard frames > 0,
              let buf = AVAudioPCMBuffer(pcmFormat: inFormat, frameCapacity: frames) else { return }
        buf.frameLength = frames
        CMSampleBufferCopyPCMDataIntoAudioBufferList(
            sb, at: 0, frameCount: Int32(frames), into: buf.mutableAudioBufferList)
        guard let conv = AVAudioConverter(from: inFormat, to: file.processingFormat) else { return }
        convertAndWrite(buf, to: file, using: conv)
    }

    func stop() async {
        if let s = stream { try? await s.stopCapture() }
        file = nil
    }
}

let mic = MicRecorder(mePath)
let app = AppAudioRecorder(othersPath)

// Signal handling: flip an atomic flag, finalize from the main runloop.
let stopRequested = DispatchSemaphore(value: 0)
let sigSrcTerm = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
let sigSrcInt = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
signal(SIGTERM, SIG_IGN)
signal(SIGINT, SIG_IGN)
sigSrcTerm.setEventHandler { stopRequested.signal() }
sigSrcInt.setEventHandler { stopRequested.signal() }
sigSrcTerm.resume()
sigSrcInt.resume()

let started = DispatchSemaphore(value: 0)
Task {
    do {
        try mic.start()
        try await app.start()
        let epoch = Date().timeIntervalSince1970
        try? String(format: "%.3f", epoch).write(
            toFile: startEpochPath, atomically: true, encoding: .utf8)
        log("capture started @ \(epoch)")
    } catch {
        die("start failed: \(error)")
    }
    started.signal()
}
started.wait()

// Block until a stop signal arrives, servicing the main queue meanwhile.
DispatchQueue.global().async {
    stopRequested.wait()
    let done = DispatchSemaphore(value: 0)
    Task {
        mic.stop()
        await app.stop()
        log("capture finalized")
        done.signal()
    }
    done.wait()
    exit(0)
}

// Run the main loop so the SCStream callbacks and signal sources fire.
RunLoop.main.run()
