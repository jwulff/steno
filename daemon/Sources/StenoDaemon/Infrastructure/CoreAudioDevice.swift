import Foundation
import CoreAudio

/// Look up the current default-input device UID via Core Audio HAL.
///
/// Used by U6's heal rule on wake to compare the post-wake input device
/// against the device captured at the last pipeline bring-up. A change
/// (e.g., AirPods reconnected as default vs. built-in mic before sleep)
/// rolls the session over even if the wall-clock gap is short.
///
/// Returns `nil` if Core Audio cannot resolve a default-input device or
/// returns an unexpected status. The heal rule treats `nil` device UIDs
/// as "unknown" — see `HealRule.decide(...)` for the matching semantics.
public func defaultInputDeviceUID() -> String? {
    var deviceID = AudioDeviceID(0)
    var size = UInt32(MemoryLayout<AudioDeviceID>.size)

    var defaultInputAddress = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDefaultInputDevice,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )

    let getDefaultStatus = AudioObjectGetPropertyData(
        AudioObjectID(kAudioObjectSystemObject),
        &defaultInputAddress,
        0,
        nil,
        &size,
        &deviceID
    )
    guard getDefaultStatus == noErr, deviceID != 0 else { return nil }

    var uidAddress = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyDeviceUID,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )

    var cfStringRef: CFString = "" as CFString
    var uidSize = UInt32(MemoryLayout<CFString?>.size)

    // CoreAudio fills a CFString; we use withUnsafeMutablePointer so
    // ARC properly retains the returned CFString.
    let uidStatus = withUnsafeMutablePointer(to: &cfStringRef) { ptr -> OSStatus in
        AudioObjectGetPropertyData(
            deviceID,
            &uidAddress,
            0,
            nil,
            &uidSize,
            ptr
        )
    }
    guard uidStatus == noErr else { return nil }
    return cfStringRef as String
}

/// Read a CFString device property, or `nil` if the HAL refuses it.
///
/// `withUnsafeMutablePointer` is what makes ARC retain the CFString the
/// HAL writes back; passing `&cfString` directly leaks the retain.
private func deviceStringProperty(
    _ device: AudioDeviceID,
    _ selector: AudioObjectPropertySelector
) -> String? {
    var address = AudioObjectPropertyAddress(
        mSelector: selector,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )
    var value: CFString = "" as CFString
    var size = UInt32(MemoryLayout<CFString?>.size)

    let status = withUnsafeMutablePointer(to: &value) { ptr -> OSStatus in
        AudioObjectGetPropertyData(device, &address, 0, nil, &size, ptr)
    }
    guard status == noErr else { return nil }
    return value as String
}

/// Total input channels across every input stream on a device.
///
/// This is the test for "can this device record" — output-only devices
/// report zero, and listing them would offer the user a device that can
/// never produce a buffer.
private func inputChannelCount(_ device: AudioDeviceID) -> Int {
    var address = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyStreamConfiguration,
        mScope: kAudioObjectPropertyScopeInput,
        mElement: kAudioObjectPropertyElementMain
    )

    var size: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(device, &address, 0, nil, &size) == noErr,
          size >= UInt32(MemoryLayout<AudioBufferList>.size) else {
        return 0
    }

    let raw = UnsafeMutableRawPointer.allocate(
        byteCount: Int(size),
        alignment: MemoryLayout<AudioBufferList>.alignment
    )
    defer { raw.deallocate() }

    guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, raw) == noErr else {
        return 0
    }

    let list = UnsafeMutableAudioBufferListPointer(
        raw.assumingMemoryBound(to: AudioBufferList.self)
    )
    return list.reduce(0) { $0 + Int($1.mNumberChannels) }
}

/// Every audio object the HAL currently knows about.
private func allAudioDeviceIDs() -> [AudioDeviceID] {
    var address = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDevices,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )

    var size: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(
        AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size
    ) == noErr else {
        return []
    }

    let count = Int(size) / MemoryLayout<AudioDeviceID>.size
    guard count > 0 else { return [] }

    var ids = [AudioDeviceID](repeating: 0, count: count)
    let status = ids.withUnsafeMutableBytes { buffer -> OSStatus in
        guard let base = buffer.baseAddress else { return kAudio_ParamError }
        return AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, base
        )
    }
    guard status == noErr else { return [] }
    return ids
}

/// Production `AudioInputDeviceEnumerating` backed by the Core Audio HAL.
///
/// Added for #104: `RecordingEngine.availableDevices()` used to return an
/// empty array, so `{"cmd":"devices"}` could never tell a client what to
/// pass as `{"cmd":"start","device":"..."}`.
public struct CoreAudioInputDeviceEnumerator: AudioInputDeviceEnumerating {
    public init() {}

    public func inputDevices() -> [AudioInputDevice] {
        allAudioDeviceIDs().compactMap { id in
            guard inputChannelCount(id) > 0 else { return nil }
            guard let uid = deviceStringProperty(id, kAudioDevicePropertyDeviceUID) else { return nil }
            // Fall back to the UID for the rare device that reports no
            // name — better an ugly identifier than an unlistable device.
            let name = deviceStringProperty(id, kAudioObjectPropertyName) ?? uid
            return AudioInputDevice(id: id, uid: uid, name: name)
        }
    }

    public func defaultInputUID() -> String? {
        defaultInputDeviceUID()
    }
}
