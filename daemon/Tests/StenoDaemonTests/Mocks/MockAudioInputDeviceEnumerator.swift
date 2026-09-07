@testable import StenoDaemon

/// Test double for `AudioInputDeviceEnumerating`.
///
/// Core Audio device enumeration cannot run meaningfully in CI (no
/// hardware, no HAL state to assert against), so every test that needs a
/// device list injects this instead.
final class MockAudioInputDeviceEnumerator: AudioInputDeviceEnumerating, @unchecked Sendable {
    var devices: [AudioInputDevice]
    var defaultUID: String?

    init(devices: [AudioInputDevice] = [], defaultUID: String? = nil) {
        self.devices = devices
        self.defaultUID = defaultUID
    }

    func inputDevices() -> [AudioInputDevice] { devices }

    func defaultInputUID() -> String? { defaultUID }
}
