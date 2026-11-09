import Foundation
import CoreAudio
import AudioToolbox
import Synchronization

// MARK: - Core Audio helpers

struct CAError: LocalizedError {
    let status: OSStatus
    let what: String
    var errorDescription: String? {
        let code = UInt32(bitPattern: status)
        let bytes = [24, 16, 8, 0].map { UInt8((code >> $0) & 0xFF) }
        let fourCC = bytes.allSatisfy { $0 >= 32 && $0 < 127 }
            ? "'" + String(decoding: bytes, as: UTF8.self) + "'" : "\(status)"
        return "\(what) failed (\(fourCC))"
    }
}

enum CA {
    static let system = AudioObjectID(kAudioObjectSystemObject)

    static func address(_ selector: AudioObjectPropertySelector,
                        _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }

    static func defaultOutputDevice() throws -> AudioDeviceID {
        var addr = address(kAudioHardwarePropertyDefaultOutputDevice)
        var id = AudioDeviceID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let err = AudioObjectGetPropertyData(system, &addr, 0, nil, &size, &id)
        guard err == noErr, id != kAudioObjectUnknown else { throw CAError(status: err, what: "Finding output device") }
        return id
    }

    static func string(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
        var addr = address(selector)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let err = AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &value)
        guard err == noErr, let value else { return nil }
        return value.takeRetainedValue() as String
    }

    static func uid(_ id: AudioObjectID) -> String? { string(id, kAudioDevicePropertyDeviceUID) }
    static func name(_ id: AudioObjectID) -> String? { string(id, kAudioObjectPropertyName) }

    static func processObject(for pid: pid_t) -> AudioObjectID {
        var addr = address(kAudioHardwarePropertyTranslatePIDToProcessObject)
        var pid = pid
        var obj = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let err = AudioObjectGetPropertyData(system, &addr, UInt32(MemoryLayout<pid_t>.size), &pid, &size, &obj)
        return err == noErr ? obj : AudioObjectID(kAudioObjectUnknown)
    }
}

// MARK: - DSP parameter block (shared lock-free with the IO thread)

enum Param: Int {
    case gain = 0, balance, mode, limiter
    case peakL, peakR
    case smoothGain, smoothBalL, smoothBalR
    case limiterGain, sampleRate, delayIndex, holdPeak, holdCount
    static let count = 16
    /// Lookahead delay line (stereo interleaved) lives after the named params.
    static let delayOffset = 32
    static let delayLength = 256            // power of two, ≥ max lookahead
    static let storage = delayOffset + 2 * delayLength
}

enum ChannelMode: Int, CaseIterable, Identifiable {
    case stereo = 0, swap, mono, leftOnly, rightOnly
    var id: Int { rawValue }
    var title: String {
        switch self {
        case .stereo: "Stereo"
        case .swap: "Swap"
        case .mono: "Mono"
        case .leftOnly: "Left"
        case .rightOnly: "Right"
        }
    }
    var symbol: String {
        switch self {
        case .stereo: "hifispeaker.2"
        case .swap: "arrow.left.arrow.right"
        case .mono: "circle.grid.cross"
        case .leftOnly: "l.circle"
        case .rightOnly: "r.circle"
        }
    }
}

enum DSP {
    /// Last-resort safety clipper: fully transparent below 0.97 (the limiter keeps us under ~0.89).
    @inline(__always) static func softClip(_ x: Float) -> Float {
        let a = abs(x)
        if a <= 0.97 { return x }
        let y = 0.97 + 0.03 * tanhf((a - 0.97) / 0.03)
        return x < 0 ? -y : y
    }

    /// Output pointers for the first two channels of an output buffer list.
    struct Out {
        var l: UnsafeMutablePointer<Float>
        var r: UnsafeMutablePointer<Float>?
        var stride: Int
        var frames: Int
    }

    static func outputs(_ outData: UnsafeMutablePointer<AudioBufferList>) -> Out? {
        let outs = UnsafeMutableAudioBufferListPointer(outData)
        for b in outs where b.mData != nil { memset(b.mData, 0, Int(b.mDataByteSize)) }
        guard outs.count > 0, let first = outs[0].mData else { return nil }
        let base = first.assumingMemoryBound(to: Float.self)
        if outs[0].mNumberChannels >= 2 {
            let st = Int(outs[0].mNumberChannels)
            return Out(l: base, r: base + 1, stride: st, frames: Int(outs[0].mDataByteSize) / 4 / st)
        }
        let frames = Int(outs[0].mDataByteSize) / 4
        if outs.count >= 2, let r = outs[1].mData {
            return Out(l: base, r: r.assumingMemoryBound(to: Float.self), stride: 1, frames: frames)
        }
        return Out(l: base, r: nil, stride: 1, frames: frames)
    }

    /// Boost + limit `frames` stereo frames read from `src` (interleaved ring, wrapped by `mask`)
    /// starting at frame `start`, into `out` beginning at output frame `offset`.
    static func render(src: UnsafePointer<Float>, start: Int, mask: Int, frames: Int,
                       out: Out, offset: Int, _ p: UnsafeMutablePointer<Float>) {
        guard frames > 0 else { return }
        let targetGain = p[Param.gain.rawValue]
        let limit = p[Param.limiter.rawValue] > 0.5
        var g = p[Param.smoothGain.rawValue]
        let k: Float = 0.0015 // ~15 ms smoothing at 48 kHz
        var peakL: Float = 0, peakR: Float = 0

        // Stereo-linked lookahead peak limiter: the gain is already down when a peak arrives,
        // so loud boosts stay clean instead of clipping.
        let sr = max(8000, p[Param.sampleRate.rawValue])
        let lookahead = min(Param.delayLength - 1, Int(0.0015 * sr))
        let attack = 1 - expf(-1 / (0.0003 * sr))   // 5 time constants inside the lookahead
        let release = 1 - expf(-1 / (0.2 * sr))     // 200 ms, smooth recovery
        let threshold: Float = 0.89                 // ≈ -1 dBFS
        var lg = p[Param.limiterGain.rawValue]
        let ring = p + Param.delayOffset
        let dmask = Param.delayLength - 1
        var w = Int(p[Param.delayIndex.rawValue]) & dmask
        var hold = p[Param.holdPeak.rawValue]
        var holdCount = Int(p[Param.holdCount.rawValue])

        for i in 0..<frames {
            let idx = ((start + i) & mask) * 2
            g += (targetGain - g) * k
            var l = src[idx] * g
            var r = src[idx + 1] * g
            if limit {
                let peak = max(abs(l), abs(r))
                if peak >= hold { hold = peak; holdCount = lookahead }
                else if holdCount > 0 { holdCount -= 1 }
                else { hold = peak }
                let target: Float = hold > threshold ? threshold / hold : 1
                lg += (target - lg) * (target < lg ? attack : release)
                ring[2 * w] = l; ring[2 * w + 1] = r
                let rd = (w - lookahead) & dmask
                l = softClip(ring[2 * rd] * lg); r = softClip(ring[2 * rd + 1] * lg)
                w = (w + 1) & dmask
            }
            peakL = max(peakL, abs(l)); peakR = max(peakR, abs(r))
            let o = (offset + i) * out.stride
            if let outR = out.r { out.l[o] = l; outR[o] = r } else { out.l[o] = (l + r) * 0.5 }
        }

        p[Param.smoothGain.rawValue] = g
        p[Param.limiterGain.rawValue] = lg
        p[Param.delayIndex.rawValue] = Float(w)
        p[Param.holdPeak.rawValue] = hold
        p[Param.holdCount.rawValue] = Float(holdCount)
        p[Param.peakL.rawValue] = max(p[Param.peakL.rawValue], peakL)
        p[Param.peakR.rawValue] = max(p[Param.peakR.rawValue], peakR)
    }
}

// MARK: - Lock-free FIFO between the tap (producer) and the output device (consumer)

final class AudioFIFO {
    static let capacity = 1 << 14          // frames (stereo), ~340 ms at 48 kHz
    let data: UnsafeMutablePointer<Float>
    let written = Atomic<Int>(0)           // total frames produced
    var read = 0                           // consumer only
    var target = 0                         // consumer only: frames kept queued
    var primed = false                     // consumer only

    init() {
        data = .allocate(capacity: 2 * Self.capacity)
        data.initialize(repeating: 0, count: 2 * Self.capacity)
    }
    deinit { data.deallocate() }

    func reset() { written.store(0, ordering: .releasing); read = 0; primed = false; target = 0 }

    /// Producer: append the tap's input (any channel layout → stereo).
    func push(_ inData: UnsafePointer<AudioBufferList>) {
        let ins = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inData))
        guard let first = ins.first, let d0 = first.mData else { return }
        let a = d0.assumingMemoryBound(to: Float.self)
        let ch = Int(first.mNumberChannels)
        var b: UnsafeMutablePointer<Float>? = nil
        var stride = 1, frames = 0
        if ch >= 2 { stride = ch; frames = Int(first.mDataByteSize) / 4 / ch }
        else {
            frames = Int(first.mDataByteSize) / 4
            if ins.count >= 2, let d1 = ins[1].mData { b = d1.assumingMemoryBound(to: Float.self) }
        }
        let mask = Self.capacity - 1
        var w = written.load(ordering: .relaxed)
        for i in 0..<frames {
            let j = (w & mask) * 2
            let l = a[i * stride]
            data[j] = l
            data[j + 1] = ch >= 2 ? a[i * stride + 1] : (b?[i] ?? l)
            w += 1
        }
        written.store(w, ordering: .releasing)
    }
}

// MARK: - System-audio tap engine

/// Captures the output device's audio with a Core Audio process tap (muting the original) and
/// plays the boosted signal straight to the same device.
///
/// The tap sits in its own tap-only aggregate. Putting the real device inside that aggregate makes
/// Core Audio align the tap to the device's playback time, which delays it by the whole device
/// latency (~185 ms on Bluetooth) — and then it goes through that latency again on the way out.
/// Kept separate, the tap delivers audio as soon as it's mixed; only a few ms of buffering remain.
final class TapEngine {
    let params: UnsafeMutablePointer<Float>
    private let fifo = AudioFIFO()
    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var tapProc: AudioDeviceIOProcID?
    private var outputID = AudioObjectID(kAudioObjectUnknown)
    private var outProc: AudioDeviceIOProcID?
    private let tapQueue = DispatchQueue(label: "amplify.tap", qos: .userInteractive)
    private let outQueue = DispatchQueue(label: "amplify.out", qos: .userInteractive)

    var isRunning: Bool { outProc != nil }

    /// IO buffer size requested for both sides (frames); clamped to what each device allows.
    var bufferFrames: UInt32 = 128
    private var tapBuffer = 256
    private var outBuffer = 256

    init() {
        params = .allocate(capacity: Param.storage)
        params.initialize(repeating: 0, count: Param.storage)
        params[Param.gain.rawValue] = 1
        params[Param.smoothGain.rawValue] = 1
        params[Param.limiter.rawValue] = 1
        params[Param.limiterGain.rawValue] = 1
        params[Param.sampleRate.rawValue] = 48000
    }

    deinit {
        stop()
        params.deallocate()
    }

    func set(_ param: Param, _ value: Float) { params[param.rawValue] = value }

    func takePeaks() -> (Float, Float) {
        let l = params[Param.peakL.rawValue], r = params[Param.peakR.rawValue]
        params[Param.peakL.rawValue] = 0
        params[Param.peakR.rawValue] = 0
        return (l, r)
    }

    @discardableResult
    func start() throws -> String {
        stop()
        do {
            let output = try CA.defaultOutputDevice()
            guard let outputUID = CA.uid(output) else { throw CAError(status: -1, what: "Reading output device") }
            let outputName = CA.name(output) ?? "Output"
            params[Param.sampleRate.rawValue] = Float(CA.sampleRate(output) ?? 48000)
            params[Param.limiterGain.rawValue] = 1
            params[Param.smoothGain.rawValue] = params[Param.gain.rawValue]
            (params + Param.delayOffset).update(repeating: 0, count: 2 * Param.delayLength)
            fifo.reset()

            // 1. Tap everything playing on the output device except ourselves; mute the original.
            let me = CA.processObject(for: getpid())
            let excluded: [AudioObjectID] = me == kAudioObjectUnknown ? [] : [me]
            let desc = CATapDescription(excludingProcesses: excluded, deviceUID: outputUID, stream: 0)
            desc.uuid = UUID()
            desc.name = "Amplify Tap"
            desc.isPrivate = true
            desc.muteBehavior = CATapMuteBehavior.muted

            var tap = AudioObjectID(kAudioObjectUnknown)
            var err = AudioHardwareCreateProcessTap(desc, &tap)
            guard err == noErr else { throw CAError(status: err, what: "Creating audio tap") }
            tapID = tap

            // 2. Tap-only private aggregate (no sub-devices, see the type comment).
            let aggregate: [String: Any] = [
                kAudioAggregateDeviceNameKey: "Amplify",
                kAudioAggregateDeviceUIDKey: "com.amplify.aggregate.\(UUID().uuidString)",
                kAudioAggregateDeviceIsPrivateKey: true,
                kAudioAggregateDeviceIsStackedKey: false,
                kAudioAggregateDeviceTapAutoStartKey: true,
                kAudioAggregateDeviceTapListKey: [[
                    kAudioSubTapUIDKey: desc.uuid.uuidString,
                    kAudioSubTapDriftCompensationKey: false,
                ]],
            ]
            var agg = AudioObjectID(kAudioObjectUnknown)
            err = AudioHardwareCreateAggregateDevice(aggregate as CFDictionary, &agg)
            guard err == noErr else { throw CAError(status: err, what: "Creating aggregate device") }
            aggregateID = agg
            tapBuffer = setBufferSize(agg, bufferFrames)
            outputID = output
            outBuffer = setBufferSize(output, bufferFrames)

            // 3. Producer: tap → FIFO.
            let fifo = self.fifo
            var proc: AudioDeviceIOProcID?
            err = AudioDeviceCreateIOProcIDWithBlock(&proc, agg, tapQueue) { _, inData, _, _, _ in
                fifo.push(inData)
            }
            guard err == noErr, let proc else { throw CAError(status: err, what: "Creating tap IO proc") }
            tapProc = proc

            // 4. Consumer: FIFO → boost/limit → output device.
            let p = params
            let baseTarget = tapBuffer + outBuffer / 2 + 64
            var oproc: AudioDeviceIOProcID?
            err = AudioDeviceCreateIOProcIDWithBlock(&oproc, output, outQueue) { _, _, _, outData, outTime in
                guard let out = DSP.outputs(outData) else { return }
                TapEngine.consume(fifo, out: out, base: baseTarget, p)
                TapEngine.probeOutput(out, outTime, p)
            }
            guard err == noErr, let oproc else { throw CAError(status: err, what: "Creating output IO proc") }
            outProc = oproc

            err = AudioDeviceStart(agg, proc)
            guard err == noErr else { throw CAError(status: err, what: "Starting tap") }
            err = AudioDeviceStart(output, oproc)
            guard err == noErr else { throw CAError(status: err, what: "Starting output") }
            return outputName
        } catch {
            stop()
            throw error
        }
    }

    /// Pulls one output buffer's worth from the FIFO, keeping just enough queued to never run dry.
    private static func consume(_ f: AudioFIFO, out: DSP.Out, base: Int, _ p: UnsafeMutablePointer<Float>) {
        let w = f.written.load(ordering: .acquiring)
        let mask = AudioFIFO.capacity - 1
        if f.target == 0 { f.target = base }
        var avail = w - f.read
        if avail > AudioFIFO.capacity - 1024 { f.read = w - f.target; avail = f.target }   // way behind
        if !f.primed {
            guard avail >= f.target else { return }            // silence until enough is queued
            f.read = w - f.target; avail = f.target; f.primed = true
        } else if avail > f.target + max(512, f.target) {
            f.read = w - f.target; avail = f.target             // drifted late: catch up
        }
        let n = min(avail, out.frames)
        DSP.render(src: f.data, start: f.read, mask: mask, frames: n, out: out, offset: 0, p)
        f.read += n
        if n < out.frames {                                    // ran dry: queue a little more next time
            f.primed = false
            f.target = min(4096, f.target + 128)
        }
    }

    @discardableResult
    private func setBufferSize(_ dev: AudioObjectID, _ wanted: UInt32) -> Int {
        var rangeAddr = CA.address(kAudioDevicePropertyBufferFrameSizeRange)
        var range = AudioValueRange()
        var size = UInt32(MemoryLayout<AudioValueRange>.size)
        var frames = wanted
        if AudioObjectGetPropertyData(dev, &rangeAddr, 0, nil, &size, &range) == noErr {
            frames = UInt32(min(max(Double(wanted), range.mMinimum), range.mMaximum))
        }
        var addr = CA.address(kAudioDevicePropertyBufferFrameSize)
        AudioObjectSetPropertyData(dev, &addr, 0, nil, UInt32(MemoryLayout<UInt32>.size), &frames)
        var actual: UInt32 = 0
        size = 4
        AudioObjectGetPropertyData(dev, &addr, 0, nil, &size, &actual)
        return Int(actual == 0 ? frames : actual)
    }

    func stop() {
        if let outProc {
            AudioDeviceStop(outputID, outProc)
            AudioDeviceDestroyIOProcID(outputID, outProc)
        }
        outProc = nil
        if let tapProc {
            AudioDeviceStop(aggregateID, tapProc)
            AudioDeviceDestroyIOProcID(aggregateID, tapProc)
        }
        tapProc = nil
        if aggregateID != kAudioObjectUnknown { AudioHardwareDestroyAggregateDevice(aggregateID) }
        aggregateID = AudioObjectID(kAudioObjectUnknown)
        if tapID != kAudioObjectUnknown { AudioHardwareDestroyProcessTap(tapID) }
        tapID = AudioObjectID(kAudioObjectUnknown)
    }
}

// MARK: - Debug latency probe (--latency): time an external click from the device to our output

extension TapEngine {
    nonisolated(unsafe) static var probe: UnsafeMutablePointer<UInt64>?

    static func probeOutput(_ out: DSP.Out, _ outTime: UnsafePointer<AudioTimeStamp>, _ p: UnsafeMutablePointer<Float>) {
        guard let probe = TapEngine.probe, probe[1] == 0 else { return }
        guard let i = (0..<out.frames).first(where: { abs(out.l[$0 * out.stride]) > 0.05 }) else { return }
        var tb = mach_timebase_info(); mach_timebase_info(&tb)
        let frameNs = UInt64(Double(i) / Double(p[Param.sampleRate.rawValue]) * 1e9)
        probe[1] = outTime.pointee.mHostTime * UInt64(tb.numer) / UInt64(tb.denom) + frameNs
    }

    static func probeLatency(seconds: Double) -> [String] {
        let e = TapEngine()
        let pr = UnsafeMutablePointer<UInt64>.allocate(capacity: 2); pr[0] = 0; pr[1] = 0
        probe = pr
        do { try e.start() } catch { return ["start failed: \(error.localizedDescription)"] }
        Thread.sleep(forTimeInterval: seconds)
        let out = ["tapBuffer=\(e.tapBuffer) outBuffer=\(e.outBuffer) target=\(e.fifo.target)", "outNs=\(pr[1])"]
        probe = nil
        e.stop()
        return out
    }
}
