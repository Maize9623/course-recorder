import Foundation

@inline(__always) func dbToLinear(_ db: Double) -> Float { Float(pow(10, db / 20)) }
@inline(__always) func linearToDB(_ v: Float) -> Float { v <= 0.000_001 ? -120 : 20 * log10(v) }

/// One-pole smoothing coefficient for a time constant in seconds.
@inline(__always) func smoothingCoefficient(_ seconds: Double, sampleRate: Double) -> Float {
    Float(exp(-1 / max(1e-6, seconds * sampleRate)))
}

struct Biquad {
    var b0: Float = 1, b1: Float = 0, b2: Float = 0, a1: Float = 0, a2: Float = 0
    private var z1: Float = 0, z2: Float = 0

    static func highPass(frequency: Double, q: Double = 0.707, sampleRate: Double = 48000) -> Biquad {
        let w0 = 2 * Double.pi * frequency / sampleRate
        let alpha = sin(w0) / (2 * q)
        let cosw = cos(w0)
        let a0 = 1 + alpha
        var f = Biquad()
        f.b0 = Float((1 + cosw) / 2 / a0)
        f.b1 = Float(-(1 + cosw) / a0)
        f.b2 = Float((1 + cosw) / 2 / a0)
        f.a1 = Float(-2 * cosw / a0)
        f.a2 = Float((1 - alpha) / a0)
        return f
    }

    @inline(__always) mutating func process(_ x: Float) -> Float {
        let y = b0 * x + z1
        z1 = b1 * x - a1 * y + z2
        z2 = b2 * x - a2 * y
        return y
    }
}

/// Downward expander: lowers the level of background noise between phrases instead of hard muting.
struct NoiseGate {
    var thresholdDB: Double = -52
    var floorGain: Float = 0.12
    private var env: Float = 0
    private var gain: Float = 1
    private var hold = 0
    private let attack = smoothingCoefficient(0.002, sampleRate: 48000)
    private let release = smoothingCoefficient(0.08, sampleRate: 48000)
    private let open = smoothingCoefficient(0.004, sampleRate: 48000)
    private let close = smoothingCoefficient(0.15, sampleRate: 48000)
    private let holdSamples = Int(0.2 * 48000)

    @inline(__always) mutating func process(_ x: Float) -> Float {
        let a = abs(x)
        env = a > env ? attack * env + (1 - attack) * a : release * env + (1 - release) * a
        let threshold = dbToLinear(thresholdDB)
        var target: Float
        if env > threshold {
            hold = holdSamples
            target = 1
        } else if hold > 0 {
            hold -= 1
            target = 1
        } else {
            target = floorGain
        }
        let c = target > gain ? open : close
        gain = c * gain + (1 - c) * target
        return x * gain
    }
}

/// Lowers BGM while the presenter is speaking.
struct Ducker {
    var duckGain: Float = 0.32
    var speechThreshold: Float = 0.012
    private var env: Float = 0
    private var gain: Float = 1
    private var hold = 0
    private let envAttack = smoothingCoefficient(0.005, sampleRate: 48000)
    private let envRelease = smoothingCoefficient(0.15, sampleRate: 48000)
    private let down = smoothingCoefficient(0.08, sampleRate: 48000)
    private let up = smoothingCoefficient(0.8, sampleRate: 48000)
    private let holdSamples = Int(0.45 * 48000)

    var current: Float { gain }

    @inline(__always) mutating func process(voice x: Float, enabled: Bool) -> Float {
        let a = abs(x)
        env = a > env ? envAttack * env + (1 - envAttack) * a : envRelease * env + (1 - envRelease) * a
        var target: Float = 1
        if enabled {
            if env > speechThreshold {
                hold = holdSamples
                target = duckGain
            } else if hold > 0 {
                hold -= 1
                target = duckGain
            }
        }
        let c = target < gain ? down : up
        gain = c * gain + (1 - c) * target
        return gain
    }
}

/// Stereo-linked peak limiter (instant attack, smooth release) to avoid clipping.
struct Limiter {
    var ceiling: Float = 0.966
    private var gain: Float = 1
    private let release = smoothingCoefficient(0.12, sampleRate: 48000)

    @inline(__always) mutating func process(_ l: inout Float, _ r: inout Float) {
        let peak = max(abs(l), abs(r))
        let needed: Float = peak > ceiling ? ceiling / peak : 1
        if needed < gain {
            gain = needed
        } else {
            gain = release * gain + (1 - release) * needed
        }
        l *= gain
        r *= gain
    }
}

/// Interleaved stereo float FIFO, single producer / single consumer.
final class StereoRing {
    private var buffer: [Float]
    private let capacity: Int
    private var readIndex = 0
    private var writeIndex = 0
    private var count = 0
    private var lock = os_unfair_lock()

    init(capacityFrames: Int) {
        capacity = capacityFrames
        buffer = [Float](repeating: 0, count: capacityFrames * 2)
    }

    var available: Int {
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }
        return count
    }

    func clear() {
        os_unfair_lock_lock(&lock)
        readIndex = 0
        writeIndex = 0
        count = 0
        os_unfair_lock_unlock(&lock)
    }

    /// Writes frames; `right == nil` duplicates left. Overflows drop the oldest audio.
    func write(left: UnsafePointer<Float>, right: UnsafePointer<Float>?, frames: Int, gain: Float = 1) {
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }
        for i in 0..<frames {
            buffer[writeIndex * 2] = left[i] * gain
            buffer[writeIndex * 2 + 1] = (right?[i] ?? left[i]) * gain
            writeIndex = (writeIndex + 1) % capacity
            if count == capacity {
                readIndex = (readIndex + 1) % capacity
            } else {
                count += 1
            }
        }
    }

    func writeInterleaved(_ src: UnsafePointer<Float>, frames: Int) {
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }
        for i in 0..<frames {
            buffer[writeIndex * 2] = src[i * 2]
            buffer[writeIndex * 2 + 1] = src[i * 2 + 1]
            writeIndex = (writeIndex + 1) % capacity
            if count == capacity {
                readIndex = (readIndex + 1) % capacity
            } else {
                count += 1
            }
        }
    }

    /// Reads up to `frames` interleaved frames, zero-filling the rest. Returns frames actually read.
    @discardableResult
    func read(into dst: UnsafeMutablePointer<Float>, frames: Int) -> Int {
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }
        let n = min(frames, count)
        for i in 0..<n {
            dst[i * 2] = buffer[readIndex * 2]
            dst[i * 2 + 1] = buffer[readIndex * 2 + 1]
            readIndex = (readIndex + 1) % capacity
        }
        count -= n
        if n < frames {
            for i in n..<frames {
                dst[i * 2] = 0
                dst[i * 2 + 1] = 0
            }
        }
        return n
    }

    func discard(_ frames: Int) {
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }
        let n = min(frames, count)
        readIndex = (readIndex + n) % capacity
        count -= n
    }
}
