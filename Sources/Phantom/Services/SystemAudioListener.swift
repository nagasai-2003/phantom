import AVFoundation
import ScreenCaptureKit

// Listens to what the Mac plays (the other side of a call) through ScreenCaptureKit
// and transcribes it in chunks. The microphone is never opened, so the user's own
// voice is not recorded.
class SystemAudioListener: NSObject, SCStreamOutput, SCStreamDelegate {
    // All callbacks run on the main queue.
    var onText: ((String) -> Void)?
    var onPause: (() -> Void)?
    var onBusy: ((Bool) -> Void)?
    var onError: ((String) -> Void)?

    private(set) var isListening = false
    private var stream: SCStream?
    private let audioQueue = DispatchQueue(label: "phantom.listen.audio")
    private let whisperQueue = DispatchQueue(label: "phantom.listen.whisper")
    private let segmenter = SpeechSegmenter()
    private let target = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000,
                                       channels: 1, interleaved: false)!
    private var converter: AVAudioConverter?

    // Main-queue bookkeeping so a pause waits for chunks still in whisper.
    private var pendingChunks = 0
    private var pauseWaiting = false

    override init() {
        super.init()
        segmenter.pauseSeconds = { UserDefaults.standard.double(forKey: "autoSendPause") }
        segmenter.onSegment = { [weak self] samples in
            DispatchQueue.main.async { self?.enqueue(samples) }
        }
        segmenter.onPause = { [weak self] in
            DispatchQueue.main.async {
                guard let self = self else { return }
                if self.pendingChunks == 0 { self.onPause?() } else { self.pauseWaiting = true }
            }
        }
    }

    func start() {
        guard !isListening else { return }
        guard findWhisperBin() != nil, findWhisperModel() != nil else {
            onError?("Whisper is not installed. Run: brew install whisper-cpp, then download ggml-base.bin (see README).")
            return
        }
        isListening = true
        SCShareableContent.getExcludingDesktopWindows(false, onScreenWindowsOnly: true) { [weak self] content, _ in
            DispatchQueue.main.async { self?.startStream(display: content?.displays.first) }
        }
    }

    private func startStream(display: SCDisplay?) {
        guard isListening else { return }  // stopped while waiting for permission
        guard let display = display else {
            CGRequestScreenCaptureAccess()
            self.fail("Phantom needs Screen & System Audio Recording permission to hear call audio. Turn it on in System Settings > Privacy & Security, then quit and reopen Phantom.")
            return
        }
        let cfg = SCStreamConfiguration()
        cfg.capturesAudio = true
        cfg.excludesCurrentProcessAudio = true
        cfg.sampleRate = 16000
        cfg.channelCount = 1
        if #available(macOS 15.0, *) { cfg.captureMicrophone = false }
        // Video can't be switched off, so keep it tiny and once a second.
        cfg.width = 2; cfg.height = 2
        cfg.minimumFrameInterval = CMTime(value: 1, timescale: 1)

        let s = SCStream(filter: SCContentFilter(display: display, excludingWindows: []),
                         configuration: cfg, delegate: self)
        do {
            try s.addStreamOutput(self, type: .audio, sampleHandlerQueue: self.audioQueue)
            try s.addStreamOutput(self, type: .screen, sampleHandlerQueue: self.audioQueue)
        } catch {
            self.fail("Could not start listening: \(error.localizedDescription)")
            return
        }
        s.startCapture { [weak self] error in
            if let error = error { self?.fail("Could not start listening: \(error.localizedDescription)") }
        }
        self.stream = s
    }

    func stop() {
        guard isListening else { return }
        isListening = false
        stream?.stopCapture(completionHandler: nil)
        stream = nil
        audioQueue.async { [weak self] in self?.segmenter.flush() }
    }

    private func fail(_ message: String) {
        DispatchQueue.main.async {
            self.stop()
            self.onError?(message)
        }
    }

    private func enqueue(_ samples: [Float]) {
        pendingChunks += 1
        onBusy?(true)
        whisperQueue.async { [weak self] in
            let text = transcribeSamples(samples)
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.pendingChunks -= 1
                if let t = text { self.onText?(t) }
                if self.pendingChunks == 0 {
                    self.onBusy?(false)
                    if self.pauseWaiting { self.pauseWaiting = false; self.onPause?() }
                }
            }
        }
    }

    // MARK: SCStreamOutput / SCStreamDelegate

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio, sampleBuffer.isValid,
              let samples = monoSamples(from: sampleBuffer) else { return }
        segmenter.feed(samples)
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        fail("Listening stopped: \(error.localizedDescription)")
    }

    private func monoSamples(from sb: CMSampleBuffer) -> [Float]? {
        guard let desc = sb.formatDescription,
              var asbd = desc.audioStreamBasicDescription,
              let format = AVAudioFormat(streamDescription: &asbd) else { return nil }
        let frames = AVAudioFrameCount(sb.numSamples)
        guard frames > 0, let pcm = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else { return nil }
        pcm.frameLength = frames
        guard CMSampleBufferCopyPCMDataIntoAudioBufferList(sb, at: 0, frameCount: Int32(frames),
                                                           into: pcm.mutableAudioBufferList) == noErr else { return nil }

        var out = pcm
        if format != target {
            if converter == nil || converter?.inputFormat != format {
                converter = AVAudioConverter(from: format, to: target)
            }
            guard let conv = converter else { return nil }
            let cap = AVAudioFrameCount(Double(frames) * target.sampleRate / format.sampleRate) + 16
            guard let converted = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: cap) else { return nil }
            var fed = false, error: NSError?
            conv.convert(to: converted, error: &error) { _, status in
                if fed { status.pointee = .noDataNow; return nil }
                fed = true; status.pointee = .haveData; return pcm
            }
            guard error == nil else { return nil }
            out = converted
        }
        guard let ch = out.floatChannelData else { return nil }
        return Array(UnsafeBufferPointer(start: ch[0], count: Int(out.frameLength)))
    }
}
