import Foundation
import CoreAudio
import Observation
import ServiceManagement

@MainActor
@Observable
final class AudioController {
    static let shared = AudioController()

    private let engine = TapEngine()
    private let defaults = UserDefaults.standard

    static let strengthOptions: [Double] = [1.25, 1.5, 1.75, 2.0]

    /// How loud the booster gets when it's on (global setting).
    var boostStrength: Double {
        didSet {
            defaults.set(boostStrength, forKey: "boostStrength")
            engine.set(.gain, Float(boost))
            applyRunning()
        }
    }

    /// Booster on/off per output device, keyed by device UID.
    private var boostOnByDevice: [String: Bool]
    private var currentUID = ""

    /// Booster toggle for the current device.
    var boostOn: Bool {
        get { boostOnByDevice[currentUID] ?? false }
        set {
            boostOnByDevice[currentUID] = newValue
            defaults.set(boostOnByDevice, forKey: "boostOn")
            engine.set(.gain, Float(boost))
            applyRunning()
        }
    }

    /// Effective gain for the current device. 1.0 = normal (engine off).
    /// Each strength step is doubled so it's clearly audible: 125% → 1.5×, 150% → 2×, 175% → 2.5×, 200% → 3×.
    var boost: Double { boostOn ? 1 + (boostStrength - 1) * 2 : 1 }

    var launchAtLogin: Bool { didSet { updateLoginItem() } }

    private(set) var devices: [OutputDevice] = []
    private(set) var currentID: AudioDeviceID = 0
    private(set) var volume: Double = 0
    private(set) var volumeAvailable = false
    private(set) var errorMessage: String?
    private(set) var isBoosting = false

    var current: OutputDevice? { devices.first { $0.id == currentID } }
    var isBoosted: Bool { boost > 1.005 }

    var menuIcon: String { isBoosting ? "speaker.wave.3.fill" : "speaker.wave.2.fill" }

    private var volumeListener: AudioObjectPropertyListenerBlock?
    private var volumeListenerDevice: AudioDeviceID = 0

    private init() {
        defaults.register(defaults: ["boostStrength": 1.5])
        boostStrength = defaults.double(forKey: "boostStrength")
        if let saved = defaults.dictionary(forKey: "boostOn") as? [String: Bool] {
            boostOnByDevice = saved
        } else {
            // Migrate older per-device boost levels: anything above 100% counts as "on".
            let old = (defaults.dictionary(forKey: "boosts") as? [String: Double]) ?? [:]
            boostOnByDevice = old.mapValues { $0 > 1.005 }
        }
        launchAtLogin = SMAppService.mainApp.status == .enabled
        engine.set(.limiter, 1)

        listen(kAudioHardwarePropertyDefaultOutputDevice) { c in c.refreshDevices(); c.restartForCurrentDevice() }
        listen(kAudioHardwarePropertyDevices) { c in c.refreshDevices() }
        refreshDevices()
        engine.set(.gain, Float(boost))
    }

    func launch() { applyRunning() }
    func shutdown() { engine.stop() }

    // MARK: Actions

    func select(_ device: OutputDevice) {
        guard device.id != currentID else { return }
        CA.setDefaultOutput(device.id)
    }

    func setVolume(_ value: Double) {
        volume = value
        CA.setVolume(currentID, Float(value))
    }

    // MARK: Internals

    private func refreshDevices() {
        devices = CA.outputDevices()
        currentID = (try? CA.defaultOutputDevice()) ?? 0
        currentUID = CA.uid(currentID) ?? ""
        watchVolume(of: currentID)
        readVolume()
    }

    private func readVolume() {
        if let v = CA.volume(currentID) {
            volume = Double(v); volumeAvailable = true
        } else {
            volume = 1; volumeAvailable = false
        }
    }

    private func applyRunning() {
        if isBoosted, !engine.isRunning {
            do { try engine.start(); errorMessage = nil }
            catch { errorMessage = error.localizedDescription }
        } else if !isBoosted, engine.isRunning {
            engine.stop()
        }
        isBoosting = engine.isRunning
    }

    /// The output device changed: load that device's boost and rebuild the tap around it.
    private func restartForCurrentDevice() {
        engine.stop()
        engine.set(.gain, Float(boost))
        applyRunning()
    }

    private func listen(_ selector: AudioObjectPropertySelector, _ handler: @escaping @MainActor (AudioController) -> Void) {
        var addr = CA.address(selector)
        AudioObjectAddPropertyListenerBlock(CA.system, &addr, .main) { _, _ in
            MainActor.assumeIsolated { handler(AudioController.shared) }
        }
    }

    private func watchVolume(of id: AudioDeviceID) {
        guard id != volumeListenerDevice else { return }
        if let volumeListener, volumeListenerDevice != 0 {
            for el in [kAudioObjectPropertyElementMain, 1] as [UInt32] {
                var a = CA.volumeAddress
                a.mElement = el
                if el == 1 { a.mSelector = kAudioDevicePropertyVolumeScalar }
                AudioObjectRemovePropertyListenerBlock(volumeListenerDevice, &a, .main, volumeListener)
            }
        }
        let block: AudioObjectPropertyListenerBlock = { _, _ in
            MainActor.assumeIsolated { AudioController.shared.readVolume() }
        }
        var main = CA.volumeAddress
        AudioObjectAddPropertyListenerBlock(id, &main, .main, block)
        var scalar = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyVolumeScalar,
                                                mScope: kAudioObjectPropertyScopeOutput, mElement: 1)
        AudioObjectAddPropertyListenerBlock(id, &scalar, .main, block)
        volumeListener = block
        volumeListenerDevice = id
    }

    private func updateLoginItem() {
        do {
            if launchAtLogin { try SMAppService.mainApp.register() }
            else { try SMAppService.mainApp.unregister() }
        } catch {
            errorMessage = "Login item: \(error.localizedDescription)"
        }
    }
}
