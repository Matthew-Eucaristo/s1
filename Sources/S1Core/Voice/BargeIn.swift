import AVFoundation
import Foundation

/// Voice interrupt ("barge-in"): watches the mic while a run or the TTS
/// reply is in flight — a sustained voiced burst fires `onSpeech` once so
/// the caller can abort the run and stop speaking.
///
/// Why it exists separately from the listen turn: the turn pipeline owns
/// the mic only between runs. While the agent acts and speaks, nobody is
/// listening — "stop" said out loud went unheard. This is the cheap
/// monitor that fills that gap: one tap, RMS energy only, no recognizer,
/// so it costs almost nothing.
///
/// Echo is the hard part: the monitor runs while TTS is playing out loud.
/// `setVoiceProcessingEnabled(true)` puts Apple's voice-processing AEC on
/// the input — the same pipeline FaceTime uses — so the speaker's own
/// output is subtracted instead of read as a user interruption. The burst
/// threshold stays conservative anyway: a cough or one stray word does
/// not count; speech must hold above the adaptive floor for
/// `minSpeechSeconds` continuously.
public final class BargeMonitor: @unchecked Sendable {
    private let onSpeech: @Sendable () -> Void
    private let minSpeechSeconds: Double
    /// dB above the adaptive noise floor that counts as voiced — a bit
    /// higher than the turn endpointer's: false barges are worse than a
    /// slightly late one.
    private let margin: Float

    private let engine = AVAudioEngine()
    private let lock = NSLock()
    private var running = false
    private var fired = false
    private var floor: Float?
    private var voiced = 0.0

    public init(minSpeechSeconds: Double = 0.45, margin: Float = 13,
                onSpeech: @escaping @Sendable () -> Void) {
        self.minSpeechSeconds = minSpeechSeconds
        self.margin = margin
        self.onSpeech = onSpeech
    }

    /// Attach the tap and start the engine. No-op when already running,
    /// when there is no input device, or when voice processing can't be
    /// enabled (barge-in silently degrades to "not available" — the
    /// kill switch and hotkey still interrupt).
    public func start() {
        lock.lock()
        defer { lock.unlock() }
        guard !running else { return }
        let input = engine.inputNode
        // AEC is what makes listening through TTS playback workable.
        // Without it the speaker's own voice would hold the floor up
        // and every reply would read as an interruption.
        try? input.setVoiceProcessingEnabled(true)
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0 else { return }
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            self?.feed(buffer)
        }
        do {
            try engine.start()
            running = true
        } catch {
            input.removeTap(onBus: 0)
        }
    }

    public func stop() {
        lock.lock()
        defer { lock.unlock() }
        guard running else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        running = false
    }

    deinit { stop() }

    /// Audio-thread callback — keep it allocation-free and never block:
    /// just the floor update and the burst counter, then hop queues.
    private func feed(_ buffer: AVAudioPCMBuffer) {
        guard let dB = MicLevel.dB(of: buffer) else { return }
        let seconds = Double(buffer.frameLength) / buffer.format.sampleRate
        var fire = false
        lock.lock()
        let lvl = max(dB, -80)
        let f = floor.map { lvl < $0 ? lvl : $0 + (lvl - $0) * 0.05 } ?? lvl
        floor = f
        let isVoice = dB > f + margin
        voiced = isVoice ? voiced + seconds : max(0, voiced - seconds * 2)
        if !fired, voiced >= minSpeechSeconds {
            fired = true
            fire = true
        }
        lock.unlock()
        guard fire else { return }
        DispatchQueue.global(qos: .userInitiated).async { [onSpeech] in onSpeech() }
    }
}
