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

    /// RMS of a PCM tap buffer → 0–1 display level.
    /// -50 dB and quieter reads as silence, -10 dB as full bars.
    public static func push(buffer: AVAudioPCMBuffer) {
        guard let data = buffer.floatChannelData else { return }
        let n = Int(buffer.frameLength)
        guard n > 0 else { return }
        var sum: Float = 0
        for c in 0 ..< Int(buffer.format.channelCount) {
            let ch = data[c]
            for i in 0 ..< n { sum += ch[i] * ch[i] }
        }
        let rms = sqrt(sum / Float(n * Int(buffer.format.channelCount)))
        guard rms > 0 else { shared.push(0); return }
        let dB = 20 * log10(rms)
        shared.push(max(0, min(1, (dB + 50) / 40)))
    }
}
