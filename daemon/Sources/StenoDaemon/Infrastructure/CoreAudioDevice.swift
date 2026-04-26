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
