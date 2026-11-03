import Foundation

// Splits a 16 kHz mono stream into speech segments by frame loudness.
// A short gap ends a segment (sent to whisper); a longer gap means the speaker
// has finished, which triggers onPause.
final class SpeechSegmenter {
    var onSegment: (([Float]) -> Void)?
    var onPause: (() -> Void)?
    // Seconds of quiet that mean the speaker finished; 0 = never auto-send.
    var pauseSeconds: () -> Double = { 3.0 }

    private let frame = 480                // 30 ms
    private let frameSeconds = 0.03
    private let threshold: Float = 0.006   // RMS above this counts as speech
    private let endSilenceFrames = 20      // 0.6 s quiet ends a segment
    private let maxSegmentFrames = 500     // cut long monologues every 15 s
    private let minSpeechFrames = 10       // ignore blips shorter than 0.3 s
    private let preRollFrames = 10         // keep 0.3 s before speech starts

    private var carry: [Float] = []
    private var segment: [Float] = []
    private var preRoll: [[Float]] = []
    private var segmentFrames = 0, speechFrames = 0, silentFrames = 0
    private var inSpeech = false
    private var heardSinceSend = false

    func feed(_ samples: [Float]) {
        carry += samples
        var i = 0
        while carry.count - i >= frame {
            process(Array(carry[i..<i + frame]))
            i += frame
        }
        carry.removeFirst(i)
    }

    // Ends any open segment, e.g. when listening stops.
    func flush() {
        if inSpeech { endSegment() }
        carry = []; preRoll = []
        heardSinceSend = false
    }

    private func process(_ f: [Float]) {
        let rms = sqrt(f.reduce(0) { $0 + $1 * $1 } / Float(f.count))
        let loud = rms > threshold
        if inSpeech {
            segment += f; segmentFrames += 1
            if loud { speechFrames += 1; silentFrames = 0 } else { silentFrames += 1 }
            if silentFrames >= endSilenceFrames || segmentFrames >= maxSegmentFrames { endSegment() }
        } else if loud {
            inSpeech = true
            segment = preRoll.flatMap { $0 } + f
            segmentFrames = preRoll.count + 1; speechFrames = 1; silentFrames = 0
            preRoll.removeAll()
        } else {
            preRoll.append(f)
            if preRoll.count > preRollFrames { preRoll.removeFirst() }
            silentFrames += 1
            let pause = pauseSeconds()
            if heardSinceSend && pause > 0 && Double(silentFrames) * frameSeconds >= pause {
                heardSinceSend = false
                onPause?()
            }
        }
    }

    private func endSegment() {
        if speechFrames >= minSpeechFrames {
            onSegment?(segment)
            heardSinceSend = true
        }
        segment = []; inSpeech = false
        segmentFrames = 0; speechFrames = 0
        // silentFrames keeps counting toward the pause.
    }
}
