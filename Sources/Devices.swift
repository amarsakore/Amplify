import Foundation
import CoreAudio
import AudioToolbox

struct OutputDevice: Identifiable, Equatable {
    let id: AudioDeviceID
    let name: String
    let transport: UInt32

    var symbol: String {
        let n = name.lowercased()
        switch transport {
        case kAudioDeviceTransportTypeBuiltIn:
            return n.contains("display") ? "display" : "laptopcomputer"
        case kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE:
            if n.contains("airpods max") { return "airpodsmax" }
            if n.contains("airpods pro") { return "airpodspro" }
            if n.contains("airpods") { return "airpods" }
            if n.contains("speaker") || n.contains("boom") || n.contains("jbl") { return "hifispeaker.fill" }
            return "headphones"
        case kAudioDeviceTransportTypeHDMI, kAudioDeviceTransportTypeDisplayPort:
            return "tv"
        case kAudioDeviceTransportTypeAirPlay:
            return "airplay.audio"
        case kAudioDeviceTransportTypeUSB:
            return n.contains("head") ? "headphones" : "hifispeaker.fill"
        default:
            return "speaker.wave.2.fill"
        }
    }
}

extension CA {
    static func outputDevices() -> [OutputDevice] {
        var addr = address(kAudioHardwarePropertyDevices)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(system, &addr, 0, nil, &size) == noErr else { return [] }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(system, &addr, 0, nil, &size, &ids) == noErr else { return [] }

        return ids.compactMap { id in
            var streams = address(kAudioDevicePropertyStreams, kAudioObjectPropertyScopeOutput)
            var s: UInt32 = 0
            guard AudioObjectGetPropertyDataSize(id, &streams, 0, nil, &s) == noErr, s > 0 else { return nil }
            let transport = uint32(id, kAudioDevicePropertyTransportType) ?? 0
            // Hide aggregates and virtual loopback drivers (BlackHole, Soundflower, meeting apps…).
            if transport == kAudioDeviceTransportTypeAggregate || transport == kAudioDeviceTransportTypeVirtual { return nil }
            guard let name = name(id) else { return nil }
            return OutputDevice(id: id, name: name, transport: transport)
        }
    }

    static func sampleRate(_ id: AudioObjectID) -> Double? {
        var addr = address(kAudioDevicePropertyNominalSampleRate)
        var v: Float64 = 0
        var size = UInt32(MemoryLayout<Float64>.size)
        return AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &v) == noErr ? v : nil
    }

    static func uint32(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector) -> UInt32? {
        var addr = address(selector)
        var v: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        return AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &v) == noErr ? v : nil
    }

    static func setDefaultOutput(_ id: AudioDeviceID) {
        var dev = id
        let size = UInt32(MemoryLayout<AudioDeviceID>.size)
        for sel in [kAudioHardwarePropertyDefaultOutputDevice, kAudioHardwarePropertyDefaultSystemOutputDevice] {
            var addr = address(sel)
            AudioObjectSetPropertyData(system, &addr, 0, nil, size, &dev)
        }
    }

    // MARK: Volume (virtual main volume, falling back to per-channel scalars)

    static let volumeAddress = address(kAudioHardwareServiceDeviceProperty_VirtualMainVolume, kAudioObjectPropertyScopeOutput)

    static func volume(_ id: AudioDeviceID) -> Float? {
        var addr = volumeAddress
        var v: Float32 = 0
        var size = UInt32(MemoryLayout<Float32>.size)
        if AudioObjectHasProperty(id, &addr), AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &v) == noErr { return v }
        for element in [kAudioObjectPropertyElementMain, 1] as [UInt32] {
            var a = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyVolumeScalar,
                                               mScope: kAudioObjectPropertyScopeOutput, mElement: element)
            if AudioObjectHasProperty(id, &a), AudioObjectGetPropertyData(id, &a, 0, nil, &size, &v) == noErr { return v }
        }
        return nil
    }

    static func setVolume(_ id: AudioDeviceID, _ value: Float) {
        var v = Float32(min(1, max(0, value)))
        let size = UInt32(MemoryLayout<Float32>.size)
        var addr = volumeAddress
        var settable: DarwinBoolean = false
        if AudioObjectHasProperty(id, &addr),
           AudioObjectIsPropertySettable(id, &addr, &settable) == noErr, settable.boolValue {
            AudioObjectSetPropertyData(id, &addr, 0, nil, size, &v)
            return
        }
        for element in [kAudioObjectPropertyElementMain, 1, 2] as [UInt32] {
            var a = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyVolumeScalar,
                                               mScope: kAudioObjectPropertyScopeOutput, mElement: element)
            if AudioObjectHasProperty(id, &a) { AudioObjectSetPropertyData(id, &a, 0, nil, size, &v) }
        }
    }
}
