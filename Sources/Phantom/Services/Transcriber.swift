import Foundation
import AVFoundation

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

// Runs whisper-cli on a WAV file and blocks until it finishes. Deletes the file afterwards.
func transcribeSync(audioURL: URL) -> String? {
    defer { try? FileManager.default.removeItem(at: audioURL) }
    guard let bin   = findWhisperBin(),
          let model = findWhisperModel() else { return nil }
    let task = Process()
    task.executableURL = URL(fileURLWithPath: bin)
    task.arguments = ["--model", model, "--language", "auto", "--output-txt", "--no-prints", "--file", audioURL.path]
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
