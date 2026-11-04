import Foundation
import AVFoundation
import Speech

let WHISPER_BIN = "/usr/local/bin/whisper-cli"

func findWhisperBin() -> String? {
    [WHISPER_BIN, "/opt/homebrew/bin/whisper-cli", "/usr/local/bin/whisper-cli"]
        .first { FileManager.default.fileExists(atPath: $0) }
}

func findWhisperModel() -> String? {
    let dirs = [
        "/opt/homebrew/share/whisper-cpp",
        "/opt/homebrew/share/whisper-cpp/models",
        "/usr/local/share/whisper-cpp",
        NSHomeDirectory() + "/.cache/whisper",
        NSHomeDirectory() + "/.ollama-chat",
    ]
    let preferred = ["ggml-base.en.bin","ggml-base.bin","ggml-small.bin","ggml-tiny.bin","ggml-medium.bin"]
    for dir in dirs {
        for name in preferred {
            let p = dir + "/" + name
            if FileManager.default.fileExists(atPath: p) { return p }
        }
        if let files = try? FileManager.default.contentsOfDirectory(atPath: dir),
           let m = files.first(where: { $0.hasSuffix(".bin") && $0.contains("ggml") }) {
            return dir + "/" + m
        }
    }
    return nil
}

var whisperInstalled: Bool { findWhisperBin() != nil && findWhisperModel() != nil }

// Transcribes a WAV file and blocks until it finishes. Deletes the file afterwards.
// Uses whisper-cli when it is installed, otherwise macOS's built-in speech recognition,
// so listening works on a fresh Mac with nothing to install.
func transcribeSync(audioURL: URL) -> String? {
    defer { try? FileManager.default.removeItem(at: audioURL) }
    if let bin = findWhisperBin(), let model = findWhisperModel() {
        return whisperSync(audioURL: audioURL, bin: bin, model: model)
    }
    return AppleSpeech.transcribeSync(audioURL)
}

private func whisperSync(audioURL: URL, bin: String, model: String) -> String? {
    let task = Process()
    task.executableURL = URL(fileURLWithPath: bin)
    // English only, whatever language the audio sounds like.
    task.arguments = ["--model", model, "--language", "en", "--output-txt", "--no-prints", "--file", audioURL.path]
    let pipe = Pipe()
    task.standardOutput = pipe; task.standardError = FileHandle.nullDevice
    do { try task.run() } catch { print("[whisper] \(error)"); return nil }
    let stdout = pipe.fileHandleForReading.readDataToEndOfFile()
    task.waitUntilExit()

    let txtURL = audioURL.deletingPathExtension().appendingPathExtension("txt")
    defer { try? FileManager.default.removeItem(at: txtURL) }
    let raw = (try? String(contentsOf: txtURL, encoding: .utf8)) ?? String(data: stdout, encoding: .utf8) ?? ""
    // Whisper marks non-speech as [BLANK_AUDIO], (music), etc.
    let cleaned = raw
        .replacingOccurrences(of: "\\[.*?\\]", with: "", options: .regularExpression)
        .replacingOccurrences(of: "\\(.*?\\)", with: "", options: .regularExpression)
        .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        .trimmingCharacters(in: .whitespacesAndNewlines)
    return cleaned.isEmpty ? nil : cleaned
}

func transcribe(audioURL: URL, completion: @escaping (String?) -> Void) {
    DispatchQueue.global(qos: .userInitiated).async {
        completion(transcribeSync(audioURL: audioURL))
    }
}

// Writes 16 kHz mono samples to a temporary WAV and transcribes it.
func transcribeSamples(_ samples: [Float]) -> String? {
    let url = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("phantom_listen_\(UUID().uuidString).wav")
    let settings: [String: Any] = [
        AVFormatIDKey: kAudioFormatLinearPCM,
        AVSampleRateKey: 16000.0,
        AVNumberOfChannelsKey: 1,
        AVLinearPCMBitDepthKey: 16,
        AVLinearPCMIsFloatKey: false,
        AVLinearPCMIsBigEndianKey: false
    ]
    do {
        let file = try AVAudioFile(forWriting: url, settings: settings,
                                   commonFormat: .pcmFormatFloat32, interleaved: false)
        guard let buf = AVAudioPCMBuffer(pcmFormat: file.processingFormat,
                                         frameCapacity: AVAudioFrameCount(samples.count)) else { return nil }
        buf.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { buf.floatChannelData![0].update(from: $0.baseAddress!, count: samples.count) }
        try file.write(from: buf)
    } catch { print("[listen] wav: \(error)"); return nil }
    return transcribeSync(audioURL: url)
}

// macOS's own speech recognition: on-device where the language supports it.
enum AppleSpeech {
    static var status: SFSpeechRecognizerAuthorizationStatus { SFSpeechRecognizer.authorizationStatus() }

    // Asks once for Speech Recognition permission; calls back on the main queue.
    static func requestAccess(_ done: @escaping (Bool) -> Void) {
        SFSpeechRecognizer.requestAuthorization { s in
            DispatchQueue.main.async { done(s == .authorized) }
        }
    }

    private static let recognizer: SFSpeechRecognizer? = {
        // English only: the Mac's own English variant (en-IN, en-GB…) when it has one, else US English.
        let current = Locale.current.identifier.replacingOccurrences(of: "_", with: "-")
        let english = current.hasPrefix("en") ? current : "en-US"
        let r = SFSpeechRecognizer(locale: Locale(identifier: english)) ?? SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
        let q = OperationQueue()
        q.maxConcurrentOperationCount = 1
        r?.queue = q   // results arrive here, so a caller can block without stalling the main queue
        return r
    }()

    static func transcribeSync(_ url: URL) -> String? {
        guard status == .authorized, let r = recognizer, r.isAvailable else { return nil }
        let req = SFSpeechURLRecognitionRequest(url: url)
        req.shouldReportPartialResults = false
        req.addsPunctuation = true
        if r.supportsOnDeviceRecognition { req.requiresOnDeviceRecognition = true }
        let done = DispatchSemaphore(value: 0)
        let lock = NSLock()
        var text: String?
        var finished = false
        let task = r.recognitionTask(with: req) { result, error in
            lock.lock(); defer { lock.unlock() }
            guard !finished else { return }
            if let result = result, result.isFinal {
                text = result.bestTranscription.formattedString
                finished = true; done.signal()
            } else if error != nil {
                finished = true; done.signal()   // includes "no speech detected"
            }
        }
        if done.wait(timeout: .now() + 30) == .timedOut { task.cancel() }
        let t = text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return t.isEmpty ? nil : t
    }
}
