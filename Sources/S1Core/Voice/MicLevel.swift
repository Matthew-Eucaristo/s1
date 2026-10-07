import AVFoundation
import Foundation

/// Live microphone level for the Siri-style waveform — proof that a voice
/// actually reached the mic while a listen turn is open.
///
/// Design: the audio taps (only installed during an active listen turn)
/// push one smoothed RMS sample per buffer (~11/sec); views pull the
/// recent window from a `TimelineView` that only ticks while onscreen —
/// so the whole feature costs nothing when nothing is listening.
public final class MicLevel: @unchecked Sendable {
    public static let shared = MicLevel()

    private let lock = NSLock()
    private var samples: [Float] = []
    private var smoothed: Float = 0
    /// Kept window — roughly four seconds of audio at tap rate.
    public let capacity = 48

    /// Newest sample last. `level` is a 0–1 smoothed envelope (fast attack,
    /// slow decay — the Siri feel: peaks linger a beat instead of flickering).
    public func push(_ level: Float) {
        let x = min(max(level, 0), 1)
        lock.lock()
        smoothed = x > smoothed ? x : smoothed * 0.82
        samples.append(smoothed)
        if samples.count > capacity { samples.removeFirst(samples.count - capacity) }
        lock.unlock()
    }

    /// Turn boundary — call when a tap stops so the next listen opens on a
    /// flat line instead of the last command's frozen peak.
    public func reset() {
        lock.lock()
        samples.removeAll()
        smoothed = 0
        lock.unlock()
    }

    /// The recent window, oldest → newest. Views right-align the tail.
    public var recent: [Float] {
        lock.lock(); defer { lock.unlock() }
        return samples
    }

    public var latest: Float {
        lock.lock(); defer { lock.unlock() }
        return samples.last ?? 0
    }

    /// RMS level of a PCM tap buffer in dBFS (-120 for digital silence).
    public static func dB(of buffer: AVAudioPCMBuffer) -> Float? {
        guard let data = buffer.floatChannelData else { return nil }
        let n = Int(buffer.frameLength)
        let chans = Int(buffer.format.channelCount)
        guard n > 0, chans > 0 else { return nil }
        var sum: Float = 0
        for c in 0 ..< chans {
            let ch = data[c]
            for i in 0 ..< n { sum += ch[i] * ch[i] }
        }
        let rms = sqrt(sum / Float(n * chans))
        return rms > 0 ? max(-120, 20 * log10(rms)) : -120
    }

    /// RMS of a PCM tap buffer → 0–1 display level.
    /// -50 dB and quieter reads as silence, -10 dB as full bars.
    /// Returns the buffer's dBFS so the tap can feed an `Endpointer` too.
    @discardableResult
    public static func push(buffer: AVAudioPCMBuffer) -> Float? {
        guard let dB = dB(of: buffer) else { return nil }
        shared.push(max(0, min(1, (dB + 50) / 40)))
        return dB
    }
}

/// Energy endpointer: decides when the user has finished talking, from mic
/// level alone — independent of the recognizer, which on some systems never
/// declares an utterance final and kept the mic open for the whole turn.
///
/// Speech = level a margin above an adaptive noise floor. The turn ends
/// after `minSpeech` of voice followed by `trailingSilence` of quiet, or
/// after `noSpeechTimeout` if the user never spoke.
public final class Endpointer: @unchecked Sendable {
    public struct Config: Sendable {
        public var margin: Float = 10          // dB above noise floor = voiced
        public var absoluteMin: Float = -52    // never call quieter than this speech
        public var minSpeech: Double = 0.2
        public var trailingSilence: Double = 0.8
        public var noSpeechTimeout: Double = 8
        /// Once speaking, frames this far under the speech peak count as silence
        /// — room noise above a too-low floor can't hold the turn open.
        public var peakDrop: Float = 22
        public init() {}
    }

    public enum State: Equatable, Sendable { case waiting, speaking, ended, timedOut }

    private let lock = NSLock()
    private let config: Config
    private var floor: Float?
    private var peak: Float = -120
    private var voiced = 0.0, silence = 0.0, elapsed = 0.0, talked = 0.0
    private var _state = State.waiting

    public init(config: Config = Config()) { self.config = config }

    public var state: State { lock.lock(); defer { lock.unlock() }; return _state }
    public var isDone: Bool { let s = state; return s == .ended || s == .timedOut }
    public var heardSpeech: Bool { let s = state; return s == .speaking || s == .ended }

    public func feed(buffer: AVAudioPCMBuffer, dB: Float?) {
        guard let dB, buffer.format.sampleRate > 0 else { return }
        feed(dB: dB, seconds: Double(buffer.frameLength) / buffer.format.sampleRate)
    }

    public func feed(dB: Float, seconds: Double) {
        lock.lock(); defer { lock.unlock() }
        guard _state == .waiting || _state == .speaking else { return }
        elapsed += seconds
        // Floor drops instantly to quieter frames and creeps up slowly, so
        // speech itself barely lifts it while room noise changes do.
        // Digital-silence frames at engine start (-120) must not pin the
        // floor so low that ordinary room noise reads as speech forever.
        // Only quiet frames teach the floor: during a long sentence the voice
        // itself would otherwise drag the floor up to speech level within
        // ~10 s, and the rest of the sentence would read as silence.
        let lvl = max(dB, -80)
        let f0 = floor ?? lvl
        // The peak fades (~3 dB/s): one loud word early on mustn't make
        // ordinary speech afterwards count as silence.
        peak = max(-120, peak - Float(3 * seconds))
        var threshold = max(f0 + config.margin, config.absoluteMin)
        if _state == .speaking { threshold = max(threshold, peak - config.peakDrop) }
        let isVoice = dB > threshold
        if isVoice { peak = max(peak, dB) }
        // Before speech starts the floor learns the room (steady fan noise);
        // once someone is talking, only the quiet frames between words do.
        if lvl < f0 { floor = lvl }
        else if _state == .waiting || !isVoice { floor = f0 + (lvl - f0) * 0.02 }
        else { floor = f0 }
        switch _state {
        case .waiting:
            voiced = isVoice ? voiced + seconds : max(0, voiced - seconds)
            if voiced >= config.minSpeech { _state = .speaking; silence = 0; talked = voiced }
            else if elapsed >= config.noSpeechTimeout { _state = .timedOut }
        case .speaking:
            if isVoice { talked += seconds }
            silence = isVoice ? 0 : silence + seconds
            // Someone talking at length pauses to think: the longer they've
            // spoken, the longer a pause has to be to end the turn.
            if silence >= config.trailingSilence + TurnEnd.patience(spoken: talked) { _state = .ended }
        default: break
        }
    }
}
